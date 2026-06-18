#!/usr/bin/env python3
"""
CVAzureCloudSizingScript.py

Cross-platform Azure cloud resource discovery / sizing tool.

Inventories Azure resources across one or more subscriptions and produces
timestamped Excel workbooks (one per subscription plus a combined
"comprehensive" workbook) summarizing provisioned/used capacity for capacity
planning and Commvault protection-cost estimation.

This is a Python port of the original CVAzureCloudSizingScript.ps1 (PowerShell),
mirroring the architecture of CVAWSCloudSizingScript.py. The cloud-agnostic
scaffolding (Excel output, terminal UX, CLI, driver) lives in the shared
cloudsizing_common.py at the repo root; this file supplies only the Azure
specifics (auth, collectors, workload dataclasses).

Unlike AWS, Azure lists resources at subscription scope (each resource carries
its own .location), so there is no per-region API loop: the run is
subscription -> workload, with region derived per resource.

Supported workloads:
    virtual-machines, storage-accounts, azure-files, azure-netapp-files,
    azure-sql-database, azure-sql-managed-instance, azure-database-mysql,
    azure-database-postgresql, azure-cosmos-db, aks, cloud-rewind-quote

Backup detection (on by default; --no-backup-status to skip): each resource is
annotated with whether it is already protected by an Azure-native mechanism --
Azure Backup (Recovery Services vaults and DataProtection "Backup vaults"),
managed-disk snapshots, or built-in PaaS automated backup. Detection uses Azure
Resource Graph (needs only Reader) and adds protected-vs-unprotected coverage to
the summary. See the README for details and caveats.

Run with --help for usage.
"""

import sys
import os
import re
import json
import logging
import shutil
import tempfile
import subprocess
import argparse
from datetime import datetime, timezone, timedelta
from dataclasses import dataclass, field


# --------------------------------------------------------------------------- #
# Shared cloud-agnostic toolkit (repo root)
# --------------------------------------------------------------------------- #
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import cloudsizing_common as common  # noqa: E402

from azure.identity import DefaultAzureCredential, CredentialUnavailableError  # noqa: E402
from azure.core.exceptions import (  # noqa: E402
    HttpResponseError, ClientAuthenticationError,
)
from azure.mgmt.subscription import SubscriptionClient  # noqa: E402
from azure.mgmt.resource import ResourceManagementClient  # noqa: E402
from azure.mgmt.compute import ComputeManagementClient  # noqa: E402
from azure.mgmt.network import NetworkManagementClient  # noqa: E402
from azure.mgmt.storage import StorageManagementClient  # noqa: E402
from azure.mgmt.monitor import MonitorManagementClient  # noqa: E402
from azure.mgmt.netapp import NetAppManagementClient  # noqa: E402
from azure.mgmt.sql import SqlManagementClient  # noqa: E402
from azure.mgmt.cosmosdb import CosmosDBManagementClient  # noqa: E402
from azure.mgmt.containerservice import ContainerServiceClient  # noqa: E402

__version__ = "0.1.0"

# Runtime options populated from CLI args (the agnostic flags consumed by the
# shared driver are also returned in the args dict by parse_args).
OPTIONS = {
    "no_input": False,
    "json": False,
    "quiet": False,
}


# --------------------------------------------------------------------------- #
# Azure helpers
# --------------------------------------------------------------------------- #
def rg_from_id(resource_id):
    """Extract the resource-group name from an ARM resource id."""
    m = re.search(r"/resourceGroups/([^/]+)/", resource_id or "", re.IGNORECASE)
    return m.group(1) if m else ""


def _enum(value):
    """Stringify an Azure SDK enum/None into a plain string."""
    if value is None:
        return ""
    return str(getattr(value, "value", value))


def get_azure_metric(monitor_client, resource_uri, metric_names,
                     aggregation="Maximum", hours=1):
    """Return {metric_name: newest_datapoint_value} for Azure Monitor metrics.

    Mirrors the AWS get_cw_metric helper. metric_names may be a list or a
    comma-separated string. Missing/failed metrics yield an empty dict.
    """
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=hours)
    names = metric_names if isinstance(metric_names, str) else ",".join(metric_names)
    try:
        result = monitor_client.metrics.list(
            resource_uri,
            timespan=f"{start.isoformat()}/{end.isoformat()}",
            interval="PT1H",
            metricnames=names,
            aggregation=aggregation)
    except (HttpResponseError, Exception) as exc:  # noqa: BLE001 - best effort
        logging.debug(f"Azure metric [{names}] failed for {resource_uri}: {exc}")
        return {}

    attr = aggregation.lower()
    out = {}
    for metric in result.value:
        name = metric.name.value
        latest = 0
        for ts in metric.timeseries:
            for dp in ts.data:
                v = getattr(dp, attr, None)
                if v is not None:
                    latest = v
        out[name] = latest
    return out


# --------------------------------------------------------------------------- #
# Backup-protection detection via Azure Resource Graph (ARG)
#
# A single RecoveryServicesResources query returns protected items from BOTH
# classic Recovery Services vaults and the newer DataProtection "Backup vaults",
# and a Resources query returns managed-disk snapshots. Both honor RBAC (Reader
# is sufficient) and are scoped per subscription. Each protected item exposes the
# protected resource's ARM id, which we join against the resources the collectors
# already enumerate. Best-effort: any failure (missing package, unregistered
# provider, throttling, RBAC denial) degrades to blank backup columns.
# --------------------------------------------------------------------------- #
_ARG_PROTECTED_ITEMS = """
RecoveryServicesResources
| where type in~ (
    'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems',
    'microsoft.dataprotection/backupVaults/backupInstances')
| extend isDP = type =~ 'microsoft.dataprotection/backupVaults/backupInstances'
| extend vaultType = iff(isDP, 'BackupVault', 'RSV')
| extend vaultName = iff(isDP,
    tostring(split(split(id, '/Microsoft.DataProtection/backupVaults/')[1], '/')[0]),
    tostring(split(split(id, '/Microsoft.RecoveryServices/vaults/')[1], '/')[0]))
| extend dpResourceId = tolower(tostring(properties.dataSourceInfo.resourceID))
| extend sourceResId = tolower(tostring(properties.sourceResourceId))
| extend dataSourceType = iff(isDP,
    tostring(properties.dataSourceSetInfo.datasourceType),
    tostring(properties.backupManagementType))
| extend policyName = iff(isDP,
    tostring(properties.policyInfo.name), tostring(properties.policyName))
| extend protectionState = tostring(properties.currentProtectionState)
| extend lastRecoveryPoint = tostring(properties.lastRecoveryPoint)
| extend friendlyName = tostring(properties.friendlyName)
| project dpResourceId, sourceResId, vaultType, vaultName, dataSourceType,
          policyName, protectionState, lastRecoveryPoint, friendlyName
"""

_ARG_DISK_SNAPSHOTS = """
Resources
| where type =~ 'microsoft.compute/snapshots'
| extend src = tolower(tostring(properties.creationData.sourceResourceId))
| where isnotempty(src)
| summarize count = count(),
            newest = tostring(max(todatetime(properties.timeCreated))) by src
"""


def _arg_query(credential, sub_id, query):
    """Run one Azure Resource Graph KQL query for a subscription, following skip
    tokens. Best-effort: on a missing package, unregistered provider, throttling,
    or RBAC denial, log at debug and return [] (backup columns stay blank)."""
    try:
        from azure.mgmt.resourcegraph import ResourceGraphClient
        from azure.mgmt.resourcegraph.models import (
            QueryRequest, QueryRequestOptions, ResultFormat)
    except ImportError as exc:
        logging.debug(f"azure-mgmt-resourcegraph unavailable: {exc}")
        return []
    client = ResourceGraphClient(credential)
    rows, skip_token = [], None
    try:
        while True:
            options = QueryRequestOptions(
                result_format=ResultFormat.OBJECT_ARRAY, skip_token=skip_token)
            resp = client.resources(QueryRequest(
                subscriptions=[sub_id], query=query, options=options))
            rows.extend(resp.data or [])
            skip_token = getattr(resp, "skip_token", None)
            if not skip_token:
                break
    except (HttpResponseError, Exception) as exc:  # noqa: BLE001 - best effort
        logging.debug(f"ARG query failed for subscription {sub_id}: {exc}")
    return rows


def build_backup_index(credential, sub_id):
    """Return (protected_by_id, snapshots_by_disk_id) for one subscription.

    protected_by_id maps a lowercased ARM id -> protection details. Azure Files
    protected items reference the storage-account id (with the share name in
    friendlyName), so file shares are additionally keyed "<account-id>|<share>".
    snapshots_by_disk_id maps a lowercased source-disk id -> {count, newest}.
    """
    protected_by_id, snapshots_by_disk_id = {}, {}
    for r in _arg_query(credential, sub_id, _ARG_PROTECTED_ITEMS):
        key = r.get("dpResourceId") or r.get("sourceResId") or ""
        if not key or key in ("none", "null"):
            continue
        entry = {
            "protectionState": r.get("protectionState") or "",
            "vaultType": r.get("vaultType") or "",
            "vaultName": r.get("vaultName") or "",
            "policyName": r.get("policyName") or "",
            "dataSourceType": r.get("dataSourceType") or "",
            "lastRecoveryPoint": r.get("lastRecoveryPoint") or "",
            "friendlyName": r.get("friendlyName") or "",
        }
        # RSV Azure Files items key off the storage-account id with the share in
        # friendlyName; register them ONLY under "<account-id>|<share>" so the
        # blob-level storage-account workload doesn't falsely match a file backup.
        friendly = entry["friendlyName"].lower()
        is_fileshare = (entry["vaultType"] == "RSV"
                        and entry["dataSourceType"].lower() == "azurestorage")
        if is_fileshare and friendly:
            protected_by_id.setdefault(f"{key}|{friendly}", entry)
        else:
            protected_by_id.setdefault(key, entry)
    for r in _arg_query(credential, sub_id, _ARG_DISK_SNAPSHOTS):
        src = r.get("src") or ""
        if src and src not in ("none", "null"):
            snapshots_by_disk_id[src] = {
                "count": int(r.get("count") or 0),
                "newest": r.get("newest") or "",
            }
    return protected_by_id, snapshots_by_disk_id


def _set_backup_fields(o, entry=None, snap=None):
    """Set the six backup columns on a collected resource. Backup Type label
    priority: vault > snapshot > built-in (Snapshot Count is recorded either way).
    `entry`/`snap` come from the ARG index; built-in PaaS backup is read from a
    `builtin_backup` descriptor the collector stashed on the object."""
    if snap and snap.get("count"):
        o.snapshot_count = snap["count"]
    if entry:
        o.native_backup = "Yes"
        o.backup_type = "RSV" if entry.get("vaultType") == "RSV" else "Backup Vault"
        o.backup_vault = entry.get("vaultName", "")
        o.backup_policy = entry.get("policyName", "")
        o.last_backup = entry.get("lastRecoveryPoint", "")
        state = entry.get("protectionState") or ""
        if state and state != "ProtectionConfigured":
            o.backup_type = f"{o.backup_type} ({state})"
    elif snap and snap.get("count"):
        o.native_backup = "Yes"
        o.backup_type = "Snapshot"
        o.last_backup = snap.get("newest", "")
    elif getattr(o, "builtin_backup", ""):
        o.native_backup = "Yes"
        o.backup_type = "Built-in"
        o.backup_policy = o.builtin_backup
    else:
        o.native_backup = "No"
        o.backup_type = "None"


def annotate_backup_status(workload, rows, backup_index):
    """Post-collection pass: stamp each resource with its existing protection by
    matching its ARM id against the per-subscription ARG backup index."""
    protected_by_id, snapshots_by_disk_id = backup_index
    if protected_by_id is None:
        return
    for o in rows:
        arm_id = (getattr(o, "arm_id", "") or "").lower()
        if workload == "azure-files":
            # the vault keys Azure Files at the storage account + share name
            entry = protected_by_id.get(f"{arm_id}|{(o.share_name or '').lower()}")
        else:
            entry = protected_by_id.get(arm_id)
        snap = None
        if workload == "virtual-machines":
            count, newest = 0, ""
            for did in (getattr(o, "disk_arm_ids", None) or []):
                s = snapshots_by_disk_id.get((did or "").lower())
                if s:
                    count += s.get("count", 0)
                    newest = max(newest, s.get("newest", "") or "")
            if count:
                snap = {"count": count, "newest": newest}
        _set_backup_fields(o, entry, snap)


# --------------------------------------------------------------------------- #
# Resource data classes (mirror the AWS dataclass pattern; consumed generically
# by cloudsizing_common's Excel + summary helpers).
# --------------------------------------------------------------------------- #
_COMMON = ["Subscription ID", "Subscription Name", "Resource Group", "Region"]
_STD_SUMMARY = ["Region", "Count", "Total Size (GB)", "Total Size (TB)"]
_STD_SUM_FIELDS = [("size_gb", "Total Size (GB)"), ("size_tb", "Total Size (TB)")]

# Trailing columns appended to every workload that supports backup detection
# (populated by annotate_backup_status; see the ARG backup-detection helpers).
_BACKUP_HEADERS = ["Native Backup", "Backup Type", "Backup Vault",
                   "Backup Policy", "Last Backup", "Snapshot Count"]


def _backup_cols(o):
    """The trailing backup-status columns appended to an annotated to_row()."""
    return [o.native_backup, o.backup_type, o.backup_vault,
            o.backup_policy, o.last_backup, o.snapshot_count]


@dataclass
class VirtualMachine:
    WORKLOAD = "virtual-machines"
    INFO_SHEET = "Azure VM Info"
    SUMMARY_SHEET = "Azure VM Summary"
    INFO_HEADERS = _COMMON + ["VM Name", "VM Size", "OS", "Disk Count",
                              "Size (GiB)", "Size (TiB)", "Size (GB)", "Size (TB)",
                              "Disk Details", "Tags"] + _BACKUP_HEADERS
    SUMMARY_HEADERS = _STD_SUMMARY
    SUMMARY_SUM_FIELDS = _STD_SUM_FIELDS
    GRAND_LABEL = "Total Azure VMs"

    subscription_id: str = ""
    subscription_name: str = ""
    resource_group: str = ""
    region: str = ""
    vm_name: str = ""
    vm_size: str = ""
    os_type: str = ""
    disk_count: int = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    disk_details: str = ""
    tags: dict = field(default_factory=dict)
    arm_id: str = ""              # hidden: backup matching only
    disk_arm_ids: list = field(default_factory=list)  # hidden: disk-snapshot lookup
    native_backup: str = ""
    backup_type: str = ""
    backup_vault: str = ""
    backup_policy: str = ""
    last_backup: str = ""
    snapshot_count: int = 0

    def to_row(self):
        return [self.subscription_id, self.subscription_name, self.resource_group,
                self.region, self.vm_name, self.vm_size, self.os_type,
                self.disk_count, self.size_gib, self.size_tib, self.size_gb,
                self.size_tb, self.disk_details, str(self.tags)] + _backup_cols(self)


@dataclass
class StorageAccount:
    WORKLOAD = "storage-accounts"
    INFO_SHEET = "Azure Storage Account Info"
    SUMMARY_SHEET = "Azure Storage Account Summary"
    INFO_HEADERS = _COMMON + ["Storage Account", "SKU", "Kind", "Access Tier",
                              "Container Count", "Blob Count", "Size (GiB)",
                              "Size (TiB)", "Size (GB)", "Size (TB)", "Tags"] + _BACKUP_HEADERS
    SUMMARY_HEADERS = _STD_SUMMARY
    SUMMARY_SUM_FIELDS = _STD_SUM_FIELDS
    GRAND_LABEL = "Total Azure Storage Accounts"

    subscription_id: str = ""
    subscription_name: str = ""
    resource_group: str = ""
    region: str = ""
    account_name: str = ""
    sku: str = ""
    kind: str = ""
    access_tier: str = ""
    container_count: int = 0
    blob_count: int = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    tags: dict = field(default_factory=dict)
    arm_id: str = ""              # hidden: backup matching only
    native_backup: str = ""
    backup_type: str = ""
    backup_vault: str = ""
    backup_policy: str = ""
    last_backup: str = ""
    snapshot_count: int = 0

    def to_row(self):
        return [self.subscription_id, self.subscription_name, self.resource_group,
                self.region, self.account_name, self.sku, self.kind,
                self.access_tier, self.container_count, self.blob_count,
                self.size_gib, self.size_tib, self.size_gb, self.size_tb,
                str(self.tags)] + _backup_cols(self)


@dataclass
class FileShare:
    WORKLOAD = "azure-files"
    INFO_SHEET = "Azure Files Info"
    SUMMARY_SHEET = "Azure Files Summary"
    INFO_HEADERS = _COMMON + ["Share Name", "Storage Account", "Tier",
                              "Quota (GiB)", "Size (GiB)", "Size (TiB)",
                              "Size (GB)", "Size (TB)"] + _BACKUP_HEADERS
    SUMMARY_HEADERS = _STD_SUMMARY
    SUMMARY_SUM_FIELDS = _STD_SUM_FIELDS
    GRAND_LABEL = "Total Azure File Shares"

    subscription_id: str = ""
    subscription_name: str = ""
    resource_group: str = ""
    region: str = ""
    share_name: str = ""
    account_name: str = ""
    tier: str = ""
    quota_gib: float = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    arm_id: str = ""              # hidden: storage-account id for backup matching
    native_backup: str = ""
    backup_type: str = ""
    backup_vault: str = ""
    backup_policy: str = ""
    last_backup: str = ""
    snapshot_count: int = 0

    def to_row(self):
        return [self.subscription_id, self.subscription_name, self.resource_group,
                self.region, self.share_name, self.account_name, self.tier,
                self.quota_gib, self.size_gib, self.size_tib, self.size_gb,
                self.size_tb] + _backup_cols(self)


@dataclass
class NetAppVolume:
    WORKLOAD = "azure-netapp-files"
    INFO_SHEET = "Azure NetApp Files Info"
    SUMMARY_SHEET = "Azure NetApp Files Summary"
    INFO_HEADERS = _COMMON + ["Volume", "NetApp Account", "Capacity Pool",
                              "Service Level", "Provisioned (GiB)", "Size (GiB)",
                              "Size (TiB)", "Size (GB)", "Size (TB)"] + _BACKUP_HEADERS
    SUMMARY_HEADERS = _STD_SUMMARY
    SUMMARY_SUM_FIELDS = _STD_SUM_FIELDS
    GRAND_LABEL = "Total Azure NetApp Volumes"

    subscription_id: str = ""
    subscription_name: str = ""
    resource_group: str = ""
    region: str = ""
    volume_name: str = ""
    netapp_account: str = ""
    capacity_pool: str = ""
    service_level: str = ""
    provisioned_gib: float = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    arm_id: str = ""              # hidden: backup matching only
    native_backup: str = ""
    backup_type: str = ""
    backup_vault: str = ""
    backup_policy: str = ""
    last_backup: str = ""
    snapshot_count: int = 0

    def to_row(self):
        return [self.subscription_id, self.subscription_name, self.resource_group,
                self.region, self.volume_name, self.netapp_account,
                self.capacity_pool, self.service_level, self.provisioned_gib,
                self.size_gib, self.size_tib, self.size_gb, self.size_tb] + _backup_cols(self)


@dataclass
class SQLDatabase:
    WORKLOAD = "azure-sql-database"
    INFO_SHEET = "Azure SQL Database Info"
    SUMMARY_SHEET = "Azure SQL Database Summary"
    INFO_HEADERS = _COMMON + ["Server", "Database", "Edition", "Status",
                              "Max Size (GiB)", "Size (GiB)", "Size (TiB)",
                              "Size (GB)", "Size (TB)"] + _BACKUP_HEADERS
    SUMMARY_HEADERS = _STD_SUMMARY
    SUMMARY_SUM_FIELDS = _STD_SUM_FIELDS
    GRAND_LABEL = "Total Azure SQL Databases"

    subscription_id: str = ""
    subscription_name: str = ""
    resource_group: str = ""
    region: str = ""
    server: str = ""
    database: str = ""
    edition: str = ""
    status: str = ""
    max_size_gib: float = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    arm_id: str = ""              # hidden: backup matching only
    builtin_backup: str = ""      # hidden: built-in PaaS backup descriptor
    native_backup: str = ""
    backup_type: str = ""
    backup_vault: str = ""
    backup_policy: str = ""
    last_backup: str = ""
    snapshot_count: int = 0

    def to_row(self):
        return [self.subscription_id, self.subscription_name, self.resource_group,
                self.region, self.server, self.database, self.edition,
                self.status, self.max_size_gib, self.size_gib, self.size_tib,
                self.size_gb, self.size_tb] + _backup_cols(self)


@dataclass
class SQLManagedInstance:
    WORKLOAD = "azure-sql-managed-instance"
    INFO_SHEET = "Azure SQL Managed Instance Info"
    SUMMARY_SHEET = "Azure SQL MI Summary"
    INFO_HEADERS = _COMMON + ["Managed Instance", "vCores", "License", "State",
                              "Storage (GiB)", "Size (GiB)", "Size (TiB)",
                              "Size (GB)", "Size (TB)"] + _BACKUP_HEADERS
    SUMMARY_HEADERS = _STD_SUMMARY
    SUMMARY_SUM_FIELDS = _STD_SUM_FIELDS
    GRAND_LABEL = "Total Azure SQL Managed Instances"

    subscription_id: str = ""
    subscription_name: str = ""
    resource_group: str = ""
    region: str = ""
    name: str = ""
    vcores: int = 0
    license_type: str = ""
    state: str = ""
    storage_gib: float = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    arm_id: str = ""              # hidden: backup matching only
    builtin_backup: str = ""      # hidden: built-in PaaS backup descriptor
    native_backup: str = ""
    backup_type: str = ""
    backup_vault: str = ""
    backup_policy: str = ""
    last_backup: str = ""
    snapshot_count: int = 0

    def to_row(self):
        return [self.subscription_id, self.subscription_name, self.resource_group,
                self.region, self.name, self.vcores, self.license_type,
                self.state, self.storage_gib, self.size_gib, self.size_tib,
                self.size_gb, self.size_tb] + _backup_cols(self)


@dataclass
class MySQLServer:
    WORKLOAD = "azure-database-mysql"
    INFO_SHEET = "Azure MySQL Info"
    SUMMARY_SHEET = "Azure MySQL Summary"
    INFO_HEADERS = _COMMON + ["Server", "Type", "Version", "SKU",
                              "Provisioned (GiB)", "Size (GiB)", "Size (TiB)",
                              "Size (GB)", "Size (TB)"] + _BACKUP_HEADERS
    SUMMARY_HEADERS = _STD_SUMMARY
    SUMMARY_SUM_FIELDS = _STD_SUM_FIELDS
    GRAND_LABEL = "Total Azure MySQL Servers"

    subscription_id: str = ""
    subscription_name: str = ""
    resource_group: str = ""
    region: str = ""
    name: str = ""
    server_type: str = ""
    version: str = ""
    sku: str = ""
    provisioned_gib: float = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    arm_id: str = ""              # hidden: backup matching only
    builtin_backup: str = ""      # hidden: built-in PaaS backup descriptor
    native_backup: str = ""
    backup_type: str = ""
    backup_vault: str = ""
    backup_policy: str = ""
    last_backup: str = ""
    snapshot_count: int = 0

    def to_row(self):
        return [self.subscription_id, self.subscription_name, self.resource_group,
                self.region, self.name, self.server_type, self.version, self.sku,
                self.provisioned_gib, self.size_gib, self.size_tib, self.size_gb,
                self.size_tb] + _backup_cols(self)


@dataclass
class PostgreSQLServer:
    WORKLOAD = "azure-database-postgresql"
    INFO_SHEET = "Azure PostgreSQL Info"
    SUMMARY_SHEET = "Azure PostgreSQL Summary"
    INFO_HEADERS = _COMMON + ["Server", "Type", "Version", "SKU",
                              "Provisioned (GiB)", "Size (GiB)", "Size (TiB)",
                              "Size (GB)", "Size (TB)"] + _BACKUP_HEADERS
    SUMMARY_HEADERS = _STD_SUMMARY
    SUMMARY_SUM_FIELDS = _STD_SUM_FIELDS
    GRAND_LABEL = "Total Azure PostgreSQL Servers"

    subscription_id: str = ""
    subscription_name: str = ""
    resource_group: str = ""
    region: str = ""
    name: str = ""
    server_type: str = ""
    version: str = ""
    sku: str = ""
    provisioned_gib: float = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    arm_id: str = ""              # hidden: backup matching only
    builtin_backup: str = ""      # hidden: built-in PaaS backup descriptor
    native_backup: str = ""
    backup_type: str = ""
    backup_vault: str = ""
    backup_policy: str = ""
    last_backup: str = ""
    snapshot_count: int = 0

    def to_row(self):
        return [self.subscription_id, self.subscription_name, self.resource_group,
                self.region, self.name, self.server_type, self.version, self.sku,
                self.provisioned_gib, self.size_gib, self.size_tib, self.size_gb,
                self.size_tb] + _backup_cols(self)


@dataclass
class CosmosDBAccount:
    WORKLOAD = "azure-cosmos-db"
    INFO_SHEET = "Azure Cosmos DB Info"
    SUMMARY_SHEET = "Azure Cosmos DB Summary"
    INFO_HEADERS = _COMMON + ["Account", "Kind", "Document Count", "Size (GiB)",
                              "Size (TiB)", "Size (GB)", "Size (TB)"] + _BACKUP_HEADERS
    SUMMARY_HEADERS = _STD_SUMMARY
    SUMMARY_SUM_FIELDS = _STD_SUM_FIELDS
    GRAND_LABEL = "Total Azure Cosmos DB Accounts"

    subscription_id: str = ""
    subscription_name: str = ""
    resource_group: str = ""
    region: str = ""
    name: str = ""
    kind: str = ""
    document_count: int = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    arm_id: str = ""              # hidden: backup matching only
    builtin_backup: str = ""      # hidden: built-in PaaS backup descriptor
    native_backup: str = ""
    backup_type: str = ""
    backup_vault: str = ""
    backup_policy: str = ""
    last_backup: str = ""
    snapshot_count: int = 0

    def to_row(self):
        return [self.subscription_id, self.subscription_name, self.resource_group,
                self.region, self.name, self.kind, self.document_count,
                self.size_gib, self.size_tib, self.size_gb, self.size_tb] + _backup_cols(self)


@dataclass
class AKSCluster:
    WORKLOAD = "aks"
    INFO_SHEET = "Azure AKS Info"
    SUMMARY_SHEET = "Azure AKS Summary"
    INFO_HEADERS = _COMMON + ["Cluster Name", "Kubernetes Version", "PVC Count",
                              "Node Count", "Size (GiB)", "Size (TiB)",
                              "Size (GB)", "Size (TB)", "PVC Details",
                              "Node Details"] + _BACKUP_HEADERS
    SUMMARY_HEADERS = _STD_SUMMARY
    SUMMARY_SUM_FIELDS = _STD_SUM_FIELDS
    GRAND_LABEL = "Total Azure AKS Clusters"

    subscription_id: str = ""
    subscription_name: str = ""
    resource_group: str = ""
    region: str = ""
    cluster_name: str = ""
    k8s_version: str = ""
    pvc_count: int = 0
    node_count: int = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    pvc_details: str = ""
    node_details: str = ""
    arm_id: str = ""              # hidden: backup matching only
    native_backup: str = ""
    backup_type: str = ""
    backup_vault: str = ""
    backup_policy: str = ""
    last_backup: str = ""
    snapshot_count: int = 0

    def to_row(self):
        return [self.subscription_id, self.subscription_name, self.resource_group,
                self.region, self.cluster_name, self.k8s_version, self.pvc_count,
                self.node_count, self.size_gib, self.size_tib, self.size_gb,
                self.size_tb, self.pvc_details, self.node_details] + _backup_cols(self)


@dataclass
class CloudRewindQuote:
    WORKLOAD = "cloud-rewind-quote"
    INFO_SHEET = "Cloud Rewind Info"
    SUMMARY_SHEET = "Cloud Rewind Summary"
    INFO_HEADERS = [
        "Subscription ID", "Subscription Name", "Resource Group", "Subscription",
        "Resource Name", "Resource Type", "Billing Category", "Resource Class",
        "Billable Data", "Billable Config", "Non-Billable Data",
        "Non-Billable Config", "Total Billable", "Total Non-Billable", "Total Count",
    ]
    SUMMARY_HEADERS = [
        "Subscription", "Protectable Resources", "Billable Data", "Billable Config",
        "Non-Billable Data", "Non-Billable Config", "Total Billable",
        "Total Non-Billable", "Total Count",
    ]
    SUMMARY_SUM_FIELDS = [
        ("protectable_count", "Protectable Resources"),
        ("billable_data", "Billable Data"),
        ("billable_config", "Billable Config"),
        ("non_billable_data", "Non-Billable Data"),
        ("non_billable_config", "Non-Billable Config"),
        ("total_billable", "Total Billable"),
        ("total_non_billable", "Total Non-Billable"),
        ("total_count", "Total Count"),
    ]
    GRAND_LABEL = "Tenant Total"

    subscription_id: str = ""
    subscription_name: str = ""
    resource_group: str = ""
    region: str = ""
    resource_name: str = ""
    resource_type: str = ""
    billing_category: str = ""
    resource_class: str = ""
    billable_data: int = 0
    billable_config: int = 0
    non_billable_data: int = 0
    non_billable_config: int = 0
    total_billable: int = 0
    total_non_billable: int = 0
    total_count: int = 0
    protectable_count: int = 0

    def to_row(self):
        return [
            self.subscription_id, self.subscription_name, self.resource_group,
            self.region, self.resource_name, self.resource_type,
            self.billing_category, self.resource_class, self.billable_data,
            self.billable_config, self.non_billable_data, self.non_billable_config,
            self.total_billable, self.total_non_billable, self.total_count,
        ]


# Registry of all workload classes, in display order.
WORKLOAD_CLASSES = [
    VirtualMachine, StorageAccount, FileShare, NetAppVolume, SQLDatabase,
    SQLManagedInstance, MySQLServer, PostgreSQLServer, CosmosDBAccount, AKSCluster,
    CloudRewindQuote,
]
WORKLOAD_BY_KEY = {cls.WORKLOAD: cls for cls in WORKLOAD_CLASSES}


# Cloud Rewind quote classification constants.
CRW_BILLABLE_RESOURCE_TYPES = {
    "microsoft.web/sites",
    "microsoft.network/applicationgateways",
    "microsoft.network/azurefirewalls",
    "microsoft.keyvault/vaults",
    "microsoft.network/loadbalancers",
    "microsoft.compute/disks",
    "microsoft.network/natgateways",
    "microsoft.network/publicipaddresses",
    "microsoft.sql/servers",
    "microsoft.sql/servers/databases",
    "microsoft.storage/storageaccounts",
    "microsoft.compute/virtualmachines",
    "microsoft.network/virtualnetworks",
    "microsoft.compute/virtualmachinescalesets",
}

CRW_NON_BILLABLE_RESOURCE_TYPES = {
    "microsoft.web/serverfarms",
    "microsoft.compute/availabilitysets",
    "microsoft.network/networkinterfaces",
    "microsoft.network/networksecuritygroups",
    "microsoft.network/privateendpoints",
    "microsoft.network/routetables",
    "microsoft.network/virtualnetworkpeerings",
    "microsoft.compute/images",
    "microsoft.compute/virtualmachinescalesets/virtualmachines",
}

CRW_FILTER_UNUSED_RESOURCE_TYPES = {
    "microsoft.compute/disks",
    "microsoft.network/publicipaddresses",
    "microsoft.network/networkinterfaces",
    "microsoft.network/networksecuritygroups",
    "microsoft.network/applicationgateways",
    "microsoft.network/loadbalancers",
    "microsoft.network/virtualnetworks",
}


def _cloud_rewind_resource_class(resource_type):
    if resource_type in ("microsoft.compute/virtualmachines", "microsoft.compute/disks"):
        return "Data"
    return "Config"


def _cloud_rewind_test_resource_associated(resource, resource_type, compute, network):
    rg = rg_from_id(resource.id)
    name = resource.name

    try:
        if resource_type == "microsoft.compute/disks":
            disk = compute.disks.get(rg, name)
            return bool(getattr(disk, "managed_by", None))

        if resource_type == "microsoft.network/publicipaddresses":
            pip = network.public_ip_addresses.get(rg, name)
            return bool(getattr(pip, "ip_configuration", None))

        if resource_type == "microsoft.network/networkinterfaces":
            nic = network.network_interfaces.get(rg, name)
            return bool(getattr(nic, "virtual_machine", None))

        if resource_type == "microsoft.network/networksecuritygroups":
            nsg = network.network_security_groups.get(rg, name)
            return bool((nsg.subnets or []) or (nsg.network_interfaces or []))

        if resource_type == "microsoft.network/applicationgateways":
            agw = network.application_gateways.get(rg, name)
            return bool((agw.http_listeners or []) or (agw.backend_address_pools or []))

        if resource_type == "microsoft.network/loadbalancers":
            lb = network.load_balancers.get(rg, name)
            return bool((lb.frontend_ip_configurations or []) or (lb.backend_address_pools or []))

        if resource_type == "microsoft.network/virtualnetworks":
            vnet = network.virtual_networks.get(rg, name)
            return bool((vnet.subnets or []) or (vnet.virtual_network_peerings or []))
    except (HttpResponseError, Exception) as exc:  # noqa: BLE001
        logging.debug(f"Cloud Rewind association check failed for {resource.id}: {exc}")
        return False

    return True


# --------------------------------------------------------------------------- #
# Per-service collectors (each takes the shared credential + subscription and
# returns a list of its dataclass; region is read from each resource).
# --------------------------------------------------------------------------- #
def collect_vm(credential, sub_id, sub_name):
    out = []
    compute = ComputeManagementClient(credential, sub_id)
    for vm in compute.virtual_machines.list_all():
        rg = rg_from_id(vm.id)
        sp = vm.storage_profile
        disks = []
        if sp:
            if sp.os_disk:
                disks.append(sp.os_disk)
            disks.extend(sp.data_disks or [])
        total_gib = 0
        details = []
        disk_ids = []
        for d in disks:
            md = getattr(d, "managed_disk", None)
            if md and getattr(md, "id", None):
                disk_ids.append(md.id)  # for disk-snapshot matching
            gib = getattr(d, "disk_size_gb", None)
            if not gib and md:
                try:
                    disk = compute.disks.get(rg, md.id.split("/")[-1])
                    gib = disk.disk_size_gb
                except Exception:  # noqa: BLE001
                    gib = 0
            gib = gib or 0
            total_gib += gib
            details.append(f"{getattr(d, 'name', 'disk')}:{gib}GiB")
        sizes = common.convert_bytes_to_sizes(total_gib * (1024 ** 3))
        out.append(VirtualMachine(
            subscription_id=sub_id, subscription_name=sub_name, resource_group=rg,
            region=vm.location, vm_name=vm.name,
            vm_size=(vm.hardware_profile.vm_size if vm.hardware_profile else ""),
            os_type=_enum(sp.os_disk.os_type) if sp and sp.os_disk else "",
            disk_count=len(disks),
            size_gib=sizes["GiB"], size_tib=sizes["TiB"],
            size_gb=sizes["GB"], size_tb=sizes["TB"],
            disk_details="; ".join(details), tags=dict(vm.tags or {}),
            arm_id=vm.id, disk_arm_ids=disk_ids))
    return out


def collect_storage_account(credential, sub_id, sub_name):
    out = []
    storage = StorageManagementClient(credential, sub_id)
    monitor = MonitorManagementClient(credential, sub_id)
    for sa in storage.storage_accounts.list():
        rg = rg_from_id(sa.id)
        metrics = get_azure_metric(
            monitor, f"{sa.id}/blobServices/default",
            ["BlobCapacity", "BlobCount", "ContainerCount"], aggregation="Maximum")
        used = metrics.get("BlobCapacity", 0) or 0
        sizes = common.convert_bytes_to_sizes(used)
        out.append(StorageAccount(
            subscription_id=sub_id, subscription_name=sub_name, resource_group=rg,
            region=sa.location, account_name=sa.name,
            sku=(sa.sku.name if sa.sku else ""), kind=_enum(sa.kind),
            access_tier=_enum(sa.access_tier),
            container_count=int(metrics.get("ContainerCount", 0) or 0),
            blob_count=int(metrics.get("BlobCount", 0) or 0),
            size_gib=sizes["GiB"], size_tib=sizes["TiB"],
            size_gb=sizes["GB"], size_tb=sizes["TB"], tags=dict(sa.tags or {}),
            arm_id=sa.id))
    return out


def collect_file_share(credential, sub_id, sub_name):
    out = []
    storage = StorageManagementClient(credential, sub_id)
    for sa in storage.storage_accounts.list():
        rg = rg_from_id(sa.id)
        try:
            shares = list(storage.file_shares.list(rg, sa.name))
        except (HttpResponseError, Exception) as exc:  # noqa: BLE001
            logging.debug(f"file_shares.list failed for {sa.name}: {exc}")
            continue
        for sh in shares:
            quota_gib = getattr(sh, "share_quota", 0) or 0
            used_bytes = 0
            try:
                full = storage.file_shares.get(rg, sa.name, sh.name, expand="stats")
                used_bytes = getattr(full, "share_usage_bytes", 0) or 0
            except (HttpResponseError, Exception):  # noqa: BLE001
                used_bytes = 0
            sizes = common.convert_bytes_to_sizes(used_bytes)
            out.append(FileShare(
                subscription_id=sub_id, subscription_name=sub_name,
                resource_group=rg, region=sa.location, share_name=sh.name,
                account_name=sa.name, tier=_enum(getattr(sh, "access_tier", "")),
                quota_gib=quota_gib, size_gib=sizes["GiB"], size_tib=sizes["TiB"],
                size_gb=sizes["GB"], size_tb=sizes["TB"], arm_id=sa.id))
    return out


def collect_netapp_volume(credential, sub_id, sub_name):
    out = []
    netapp = NetAppManagementClient(credential, sub_id)
    monitor = MonitorManagementClient(credential, sub_id)
    try:
        accounts = list(netapp.accounts.list_by_subscription())
    except (HttpResponseError, Exception) as exc:  # noqa: BLE001
        logging.debug(f"NetApp accounts.list_by_subscription failed: {exc}")
        return out
    for acct in accounts:
        rg = rg_from_id(acct.id)
        acct_name = acct.name.split("/")[-1]
        try:
            pools = list(netapp.pools.list(rg, acct_name))
        except (HttpResponseError, Exception):  # noqa: BLE001
            continue
        for pool in pools:
            pool_name = pool.name.split("/")[-1]
            try:
                volumes = list(netapp.volumes.list(rg, acct_name, pool_name))
            except (HttpResponseError, Exception):  # noqa: BLE001
                continue
            for vol in volumes:
                vol_name = vol.name.split("/")[-1]
                provisioned = getattr(vol, "usage_threshold", 0) or 0  # bytes
                used = get_azure_metric(monitor, vol.id, ["VolumeLogicalSize"],
                                        aggregation="Average").get("VolumeLogicalSize", 0) or 0
                sizes = common.convert_bytes_to_sizes(used or provisioned)
                out.append(NetAppVolume(
                    subscription_id=sub_id, subscription_name=sub_name,
                    resource_group=rg, region=vol.location, volume_name=vol_name,
                    netapp_account=acct_name, capacity_pool=pool_name,
                    service_level=_enum(getattr(vol, "service_level", "")),
                    provisioned_gib=round(provisioned / (1024 ** 3), 2),
                    size_gib=sizes["GiB"], size_tib=sizes["TiB"],
                    size_gb=sizes["GB"], size_tb=sizes["TB"], arm_id=vol.id))
    return out


def collect_sql_database(credential, sub_id, sub_name):
    out = []
    sql = SqlManagementClient(credential, sub_id)
    monitor = MonitorManagementClient(credential, sub_id)
    for server in sql.servers.list():
        rg = rg_from_id(server.id)
        try:
            dbs = list(sql.databases.list_by_server(rg, server.name))
        except (HttpResponseError, Exception):  # noqa: BLE001
            continue
        for db in dbs:
            if db.name == "master":
                continue
            max_bytes = getattr(db, "max_size_bytes", 0) or 0
            used = get_azure_metric(monitor, db.id, ["storage"],
                                    aggregation="Maximum").get("storage", 0) or 0
            sizes = common.convert_bytes_to_sizes(used or max_bytes)
            out.append(SQLDatabase(
                subscription_id=sub_id, subscription_name=sub_name,
                resource_group=rg, region=db.location, server=server.name,
                database=db.name, edition=_enum(getattr(db, "edition", "")),
                status=_enum(getattr(db, "status", "")),
                max_size_gib=round(max_bytes / (1024 ** 3), 2),
                size_gib=sizes["GiB"], size_tib=sizes["TiB"],
                size_gb=sizes["GB"], size_tb=sizes["TB"],
                arm_id=db.id, builtin_backup="PITR (automated)"))
    return out


def collect_sql_managed_instance(credential, sub_id, sub_name):
    out = []
    sql = SqlManagementClient(credential, sub_id)
    monitor = MonitorManagementClient(credential, sub_id)
    for mi in sql.managed_instances.list():
        rg = rg_from_id(mi.id)
        prov_gib = getattr(mi, "storage_size_in_gb", 0) or 0
        used_mb = get_azure_metric(monitor, mi.id, ["storage_space_used_mb"],
                                   aggregation="Maximum").get("storage_space_used_mb", 0) or 0
        sizes = common.convert_bytes_to_sizes((used_mb * 1024 * 1024)
                                              or prov_gib * (1024 ** 3))
        out.append(SQLManagedInstance(
            subscription_id=sub_id, subscription_name=sub_name, resource_group=rg,
            region=mi.location, name=mi.name, vcores=getattr(mi, "v_cores", 0) or 0,
            license_type=_enum(getattr(mi, "license_type", "")),
            state=_enum(getattr(mi, "state", "")), storage_gib=prov_gib,
            size_gib=sizes["GiB"], size_tib=sizes["TiB"],
            size_gb=sizes["GB"], size_tb=sizes["TB"],
            arm_id=mi.id, builtin_backup="PITR (automated)"))
    return out


def _builtin_backup_desc(retention_days, geo_value):
    """Describe a PaaS automated-backup config for the Backup Policy column."""
    if not retention_days:
        return "Automated"
    geo = "enabled" in _enum(geo_value).lower()
    return f"Automated ({retention_days}d{', geo' if geo else ''})"


def _collect_rdbms(credential, sub_id, sub_name, cls, flex_import, single_import):
    """Shared MySQL/PostgreSQL collector (flexible + single servers)."""
    out = []
    monitor = MonitorManagementClient(credential, sub_id)
    # Flexible servers
    try:
        flex_mod = __import__(flex_import, fromlist=["MySQLManagementClient",
                                                     "PostgreSQLManagementClient"])
        flex_client_cls = getattr(flex_mod, "MySQLManagementClient", None) or \
            getattr(flex_mod, "PostgreSQLManagementClient")
        for s in flex_client_cls(credential, sub_id).servers.list():
            rg = rg_from_id(s.id)
            storage_gib = getattr(getattr(s, "storage", None), "storage_size_gb", 0) or 0
            used = get_azure_metric(monitor, s.id, ["storage_used"],
                                    aggregation="Maximum").get("storage_used", 0) or 0
            sizes = common.convert_bytes_to_sizes(used or storage_gib * (1024 ** 3))
            out.append(cls(
                subscription_id=sub_id, subscription_name=sub_name,
                resource_group=rg, region=s.location, name=s.name,
                server_type="Flexible", version=str(getattr(s, "version", "") or ""),
                sku=(s.sku.name if getattr(s, "sku", None) else ""),
                provisioned_gib=storage_gib, size_gib=sizes["GiB"],
                size_tib=sizes["TiB"], size_gb=sizes["GB"], size_tb=sizes["TB"],
                arm_id=s.id, builtin_backup=_builtin_backup_desc(
                    getattr(getattr(s, "backup", None), "backup_retention_days", None),
                    getattr(getattr(s, "backup", None), "geo_redundant_backup", ""))))
    except (HttpResponseError, Exception) as exc:  # noqa: BLE001
        logging.debug(f"{flex_import} flexible servers failed: {exc}")
    # Single servers (legacy)
    try:
        single_mod = __import__(single_import, fromlist=["MySQLManagementClient",
                                                         "PostgreSQLManagementClient"])
        single_client_cls = getattr(single_mod, "MySQLManagementClient", None) or \
            getattr(single_mod, "PostgreSQLManagementClient")
        for s in single_client_cls(credential, sub_id).servers.list():
            rg = rg_from_id(s.id)
            sp = getattr(s, "storage_profile", None)
            storage_mb = getattr(sp, "storage_mb", 0) or 0
            used = get_azure_metric(monitor, s.id, ["storage_used"],
                                    aggregation="Maximum").get("storage_used", 0) or 0
            sizes = common.convert_bytes_to_sizes(used or storage_mb * 1024 * 1024)
            out.append(cls(
                subscription_id=sub_id, subscription_name=sub_name,
                resource_group=rg, region=s.location, name=s.name,
                server_type="Single", version=str(getattr(s, "version", "") or ""),
                sku=(s.sku.name if getattr(s, "sku", None) else ""),
                provisioned_gib=round(storage_mb / 1024, 2), size_gib=sizes["GiB"],
                size_tib=sizes["TiB"], size_gb=sizes["GB"], size_tb=sizes["TB"],
                arm_id=s.id, builtin_backup=_builtin_backup_desc(
                    getattr(sp, "backup_retention_days", None),
                    getattr(sp, "geo_redundant_backup", ""))))
    except (HttpResponseError, Exception) as exc:  # noqa: BLE001
        logging.debug(f"{single_import} single servers failed: {exc}")
    return out


def collect_mysql_server(credential, sub_id, sub_name):
    return _collect_rdbms(credential, sub_id, sub_name, MySQLServer,
                          "azure.mgmt.rdbms.mysql_flexibleservers",
                          "azure.mgmt.rdbms.mysql")


def collect_postgresql_server(credential, sub_id, sub_name):
    return _collect_rdbms(credential, sub_id, sub_name, PostgreSQLServer,
                          "azure.mgmt.rdbms.postgresql_flexibleservers",
                          "azure.mgmt.rdbms.postgresql")


def collect_cosmosdb_account(credential, sub_id, sub_name):
    out = []
    cosmos = CosmosDBManagementClient(credential, sub_id)
    monitor = MonitorManagementClient(credential, sub_id)
    for acct in cosmos.database_accounts.list():
        rg = rg_from_id(acct.id)
        metrics = get_azure_metric(monitor, acct.id, ["DataUsage", "DocumentCount"],
                                   aggregation="Maximum")
        used = metrics.get("DataUsage", 0) or 0
        sizes = common.convert_bytes_to_sizes(used)
        bp = getattr(acct, "backup_policy", None)
        mode = _enum(getattr(bp, "type", "")) if bp else ""
        out.append(CosmosDBAccount(
            subscription_id=sub_id, subscription_name=sub_name, resource_group=rg,
            region=acct.location, name=acct.name, kind=_enum(acct.kind),
            document_count=int(metrics.get("DocumentCount", 0) or 0),
            size_gib=sizes["GiB"], size_tib=sizes["TiB"],
            size_gb=sizes["GB"], size_tb=sizes["TB"], arm_id=acct.id,
            builtin_backup=f"{mode} backup" if mode else "Automated"))
    return out


def collect_aks_cluster(credential, sub_id, sub_name):
    out = []
    aks = ContainerServiceClient(credential, sub_id)
    clusters = list(aks.managed_clusters.list())
    if clusters and not shutil.which("kubectl"):
        logging.warning("kubectl not found; AKS clusters listed without PVC/node sizing.")

    for c in clusters:
        rg = rg_from_id(c.id)
        info = AKSCluster(subscription_id=sub_id, subscription_name=sub_name,
                          resource_group=rg, region=c.location, cluster_name=c.name,
                          k8s_version=getattr(c, "kubernetes_version", "") or "",
                          arm_id=c.id)
        if shutil.which("kubectl"):
            kubeconfig = os.path.join(tempfile.gettempdir(),
                                      f"kubeconfig_az_{sub_id}_{c.name}")
            try:
                creds = aks.managed_clusters.list_cluster_user_credentials(rg, c.name)
                with open(kubeconfig, "wb") as fh:
                    fh.write(creds.kubeconfigs[0].value)
                env = dict(os.environ, KUBECONFIG=kubeconfig)
                pvc_json = json.loads(subprocess.run(
                    ["kubectl", "get", "pvc", "-A", "-o", "json"],
                    check=True, capture_output=True, text=True, env=env).stdout)
                total_bytes = 0
                pvc_details = []
                for pvc in pvc_json.get("items", []):
                    meta = pvc.get("metadata", {})
                    cap = (pvc.get("spec", {}).get("resources", {})
                           .get("requests", {}).get("storage"))
                    total_bytes += common.convert_k8s_size_to_bytes(cap)
                    pvc_details.append(
                        f"{meta.get('namespace', 'default')}/{meta.get('name', '')}:{cap}")
                sizes = common.convert_bytes_to_sizes(total_bytes)
                info.pvc_count = len(pvc_json.get("items", []))
                info.pvc_details = "; ".join(pvc_details)
                info.size_gib, info.size_tib = sizes["GiB"], sizes["TiB"]
                info.size_gb, info.size_tb = sizes["GB"], sizes["TB"]

                node_json = json.loads(subprocess.run(
                    ["kubectl", "get", "nodes", "-o", "json"],
                    check=True, capture_output=True, text=True, env=env).stdout)
                node_details = []
                for n in node_json.get("items", []):
                    nname = n.get("metadata", {}).get("name", "")
                    itype = (n.get("metadata", {}).get("labels", {})
                             .get("node.kubernetes.io/instance-type", ""))
                    node_details.append(f"{nname}:{itype}")
                info.node_count = len(node_json.get("items", []))
                info.node_details = "; ".join(node_details)
            except (subprocess.CalledProcessError, json.JSONDecodeError, OSError,
                    HttpResponseError, Exception) as exc:  # noqa: BLE001
                logging.warning(f"AKS {c.name}: kubectl sizing failed: {exc}")
            finally:
                try:
                    os.remove(kubeconfig)
                except OSError:
                    pass
        out.append(info)
    return out


def collect_cloud_rewind_quote(credential, sub_id, sub_name):
    out = []
    resources = ResourceManagementClient(credential, sub_id)
    compute = ComputeManagementClient(credential, sub_id)
    network = NetworkManagementClient(credential, sub_id)

    for resource in resources.resources.list():
        rtype = (resource.type or "").lower()

        # Exclude Azure SQL master DB.
        if rtype == "microsoft.sql/servers/databases" and (resource.name or "").lower().endswith("/master"):
            continue

        # Exclude specific unused/unattached resource types.
        if rtype in CRW_FILTER_UNUSED_RESOURCE_TYPES and not _cloud_rewind_test_resource_associated(
                resource, rtype, compute, network):
            continue

        # Include only uniform-orchestration VMSS.
        if rtype == "microsoft.compute/virtualmachinescalesets":
            rg = rg_from_id(resource.id)
            try:
                vmss = compute.virtual_machine_scale_sets.get(rg, resource.name)
                if _enum(getattr(vmss, "orchestration_mode", "")).lower() != "uniform":
                    continue
            except (HttpResponseError, Exception) as exc:  # noqa: BLE001
                logging.debug(f"Cloud Rewind VMSS check failed for {resource.id}: {exc}")
                continue

        # For disks, count only managed data disks (exclude OS disks).
        if rtype == "microsoft.compute/disks":
            rg = rg_from_id(resource.id)
            try:
                disk = compute.disks.get(rg, resource.name)
                if getattr(disk, "os_type", None):
                    continue
            except (HttpResponseError, Exception) as exc:  # noqa: BLE001
                logging.debug(f"Cloud Rewind disk check failed for {resource.id}: {exc}")
                continue

        rclass = _cloud_rewind_resource_class(rtype)

        billing_category = ""
        billable_data = 0
        billable_config = 0
        non_billable_data = 0
        non_billable_config = 0

        if rtype in CRW_BILLABLE_RESOURCE_TYPES:
            billing_category = "Billable"
            if rclass == "Data":
                billable_data = 1
            else:
                billable_config = 1
        elif rtype in CRW_NON_BILLABLE_RESOURCE_TYPES:
            billing_category = "Non-Billable"
            if rclass == "Data":
                non_billable_data = 1
            else:
                non_billable_config = 1
        else:
            continue

        out.append(CloudRewindQuote(
            subscription_id=sub_id,
            subscription_name=sub_name,
            resource_group=rg_from_id(resource.id),
            region=sub_name,
            resource_name=resource.name,
            resource_type=resource.type,
            billing_category=billing_category,
            resource_class=rclass,
            billable_data=billable_data,
            billable_config=billable_config,
            non_billable_data=non_billable_data,
            non_billable_config=non_billable_config,
            total_billable=billable_data + billable_config,
            total_non_billable=non_billable_data + non_billable_config,
            total_count=1,
            protectable_count=1 if billing_category == "Billable" else 0,
        ))

    return out


COLLECTORS = {
    "virtual-machines": collect_vm,
    "storage-accounts": collect_storage_account,
    "azure-files": collect_file_share,
    "azure-netapp-files": collect_netapp_volume,
    "azure-sql-database": collect_sql_database,
    "azure-sql-managed-instance": collect_sql_managed_instance,
    "azure-database-mysql": collect_mysql_server,
    "azure-database-postgresql": collect_postgresql_server,
    "azure-cosmos-db": collect_cosmosdb_account,
    "aks": collect_aks_cluster,
    "cloud-rewind-quote": collect_cloud_rewind_quote,
}


# --------------------------------------------------------------------------- #
# Authentication + credential preflight
# --------------------------------------------------------------------------- #
def build_credential(args):
    """Build a DefaultAzureCredential (env SP / managed identity / az CLI)."""
    return DefaultAzureCredential(exclude_interactive_browser_credential=True)


def list_subscriptions(credential):
    """Return the Enabled subscriptions accessible to the credential."""
    subs = []
    for s in SubscriptionClient(credential).subscriptions.list():
        state = _enum(getattr(s, "state", "")).lower()
        if state and "enabled" not in state:
            continue
        subs.append(s)
    return subs


def classify_credential_error(exc):
    """Map an Azure SDK exception to a (kind, human_detail) pair."""
    if isinstance(exc, CredentialUnavailableError):
        return ("no_credentials",
                "no Azure credentials found (checked env service principal, "
                "managed identity, az CLI)")
    if isinstance(exc, ClientAuthenticationError):
        msg = str(exc)
        first = msg.splitlines()[0][:200]
        low = msg.lower()
        # The whole DefaultAzureCredential chain failing means nothing is
        # configured -> treat as "no credentials" (show the full setup menu).
        if "failed to retrieve a token from the included credentials" in low:
            return ("no_credentials",
                    "no Azure credentials found (checked env service principal, "
                    "managed identity, az CLI)")
        if "expired" in low:
            return "expired", f"Azure credentials/token expired: {first}"
        return "invalid_key", f"Azure authentication failed: {first}"
    if isinstance(exc, HttpResponseError):
        status = getattr(exc, "status_code", None)
        if status == 403:
            return "access_denied", "authenticated but authorization (RBAC) denied"
        if status == 401:
            return "expired", "Azure token rejected (401)"
        return "other", f"HTTP {status}: {str(exc).splitlines()[0][:200]}"
    return "other", str(exc)


def build_sessions(args):
    """Resolve credentials + subscriptions into (sessions, failures).

    sessions: (credential, subscription_id, subscription_name) per subscription.
    failures: (label, error_kind, error_detail) for auth/scope problems.
    """
    try:
        credential = build_credential(args)
        subs = list_subscriptions(credential)
    except Exception as exc:  # noqa: BLE001
        kind, detail = classify_credential_error(exc)
        return [], [("default", kind, detail)]

    if not subs:
        return [], [("default", "no_credentials",
                     "no accessible subscriptions found for this identity")]

    want = set(s.lower() for s in (args.get("subscriptions") or []))
    tenant = (args.get("tenant") or "").lower()
    sessions = []
    for s in subs:
        if tenant and str(getattr(s, "tenant_id", "") or "").lower() != tenant:
            continue
        name = s.display_name or s.subscription_id
        if want and (s.subscription_id.lower() not in want
                     and str(name).lower() not in want):
            continue
        sessions.append((credential, s.subscription_id, name))

    failures = []
    if not sessions and (want or tenant):
        available = ", ".join(f"{s.display_name} ({s.subscription_id})" for s in subs)
        failures.append(("filter", "other",
                          f"no subscriptions matched the filter; available: {available}"))
    return sessions, failures


CREDENTIAL_SETUP_GUIDANCE = """\
No Azure credentials could be authenticated. Configure credentials ONE of these
ways, then re-run:

  1. Azure CLI (interactive, easiest for a laptop):
       az login
       python CVAzureCloudSizingScript.py

  2. Service principal via environment variables (CI / automation):
       export AZURE_CLIENT_ID=...
       export AZURE_CLIENT_SECRET=...
       export AZURE_TENANT_ID=...

  3. Run inside Azure (Cloud Shell, or a VM/AKS with a managed identity) -- no
     setup needed; the identity is picked up automatically.

Scope to specific subscriptions with --subscriptions=<id-or-name>,... and verify
with:  az account show
"""


def offer_azure_login():
    """On an interactive TTY with the az CLI present, offer to run `az login`.
    Returns True if subscriptions are reachable afterward."""
    if OPTIONS["no_input"] or not (sys.stdin.isatty() and shutil.which("az")):
        return False
    try:
        answer = input("\nRun 'az login' now to set up credentials? [y/N] ")
    except (EOFError, KeyboardInterrupt):
        return False
    if answer.strip().lower() not in ("y", "yes"):
        return False
    try:
        subprocess.run(["az", "login"], check=False)
    except OSError as exc:
        logging.error(f"Could not launch 'az login': {exc}")
        return False
    try:
        ok = bool(list_subscriptions(build_credential({})))
    except Exception:  # noqa: BLE001
        ok = False
    logging.info("Azure credentials configured successfully."
                 if ok else "Still unable to authenticate after 'az login'.")
    return ok


def print_credential_help(failures):
    """Log actionable, failure-kind-specific guidance for a zero-session run."""
    for label, _kind, detail in failures:
        logging.error(f"Credential check failed for '{label}': {detail}")

    kind = common.dominant_failure_kind(failures)
    if kind == "expired":
        logging.error("Azure credentials have expired. Run `az login` (or refresh "
                      "the service-principal secret) and re-run.")
        return False
    if kind == "invalid_key":
        logging.error("Azure authentication failed. Check the AZURE_CLIENT_ID/"
                      "SECRET/TENANT_ID env vars or run `az login`.")
        return False
    if kind == "access_denied":
        logging.error("Authenticated, but RBAC denied. Grant the identity the "
                      "Reader role on the target subscriptions and re-run.")
        return False

    logging.debug("No credentials authenticated; showing setup guidance.")
    common.console.print()
    common.console.print(CREDENTIAL_SETUP_GUIDANCE.rstrip("\n"),
                         markup=False, highlight=False)
    return offer_azure_login()


def validate_args(args):
    """Reject nonsensical flag combinations (Azure has few)."""
    if args.get("regions") is not None and not args["regions"]:
        logging.error("--regions was provided but empty.")
        sys.exit(1)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
EXAMPLES = """\
examples:
  # default credentials (az login / env / managed identity), all subscriptions
  python CVAzureCloudSizingScript.py

  # just VMs and storage in two regions, scoped to two subscriptions
  python CVAzureCloudSizingScript.py --subscriptions=Prod,Dev --regions=eastus,westus2 --workload=vm,storage_account

  # check credentials without collecting anything
  python CVAzureCloudSizingScript.py --validate-only

  # skip the Azure-native backup-protection detection (faster; default is on)
  python CVAzureCloudSizingScript.py --no-backup-status

  # only subscriptions in one tenant
  python CVAzureCloudSizingScript.py --tenant=00000000-0000-0000-0000-000000000000

  # machine-readable output for scripting
  python CVAzureCloudSizingScript.py --json --regions=eastus | jq .
"""


def build_parser():
    parser = argparse.ArgumentParser(
        prog="CVAzureCloudSizingScript.py",
        description="Inventory Azure resources across subscriptions and write "
                    "Excel sizing workbooks for Commvault protection planning.",
        epilog=EXAMPLES,
        formatter_class=argparse.RawDescriptionHelpFormatter)

    auth = parser.add_argument_group(
        "authentication", "default: DefaultAzureCredential "
        "(az CLI / env service principal / managed identity)")
    auth.add_argument("--subscriptions", type=common._csv, metavar="ID,NAME",
                      help="only these subscription IDs or names (default: all accessible)")
    auth.add_argument("--tenant", metavar="TENANT_ID",
                      help="only subscriptions in this tenant")

    scope = parser.add_argument_group("scope")
    scope.add_argument("--regions", "--locations", dest="regions",
                       type=common._csv, metavar="r1,r2",
                       help="regions to collect resources from (default: all). "
                            "--locations is accepted as an alias")

    backup = parser.add_argument_group("backup detection")
    backup.add_argument("--no-backup-status", action="store_true",
                        help="skip detecting existing Azure-native backup "
                             "protection (on by default; uses Azure Resource "
                             "Graph, needs Reader, adds ~2 queries per subscription)")

    common.add_common_args(parser, __version__, WORKLOAD_CLASSES)
    return parser


def parse_args(argv):
    """Parse argv into a settings dict and populate the OPTIONS globals."""
    ns = build_parser().parse_args(argv)
    OPTIONS["no_input"] = ns.no_input
    OPTIONS["json"] = ns.json
    OPTIONS["quiet"] = ns.quiet
    return {
        "subscriptions": ns.subscriptions,
        "tenant": ns.tenant,
        "regions": ns.regions,
        "workload": ns.workload,
        "validate_only": ns.validate_only,
        "json": ns.json,
        "quiet": ns.quiet,
        "verbose": ns.verbose,
        "no_color": ns.no_color,
        "no_input": ns.no_input,
        "check_backup_status": not ns.no_backup_status,
    }


# --------------------------------------------------------------------------- #
# Cloud config: wire the Azure-specific hooks into the shared driver.
# --------------------------------------------------------------------------- #
def azure_collect(handle, sub_id, sub_name, args, workloads, reporter, label):
    """Driver hook: collect one subscription, advancing the reporter per workload."""
    credential = handle
    regions = set(r.lower() for r in (args.get("regions") or []))
    data = {cls.WORKLOAD: [] for cls in WORKLOAD_CLASSES}

    # Build the per-subscription backup-protection index once (2 ARG queries),
    # then annotate each workload's resources as they are collected.
    backup_index = (None, None)
    if args.get("check_backup_status"):
        reporter.update(f"{label} | backup index")
        backup_index = build_backup_index(credential, sub_id)

    reporter.start_account(label, len(workloads))
    for wl in workloads:
        reporter.update(f"{label} | {wl}")
        try:
            rows = COLLECTORS[wl](credential, sub_id, sub_name)
            if regions:
                rows = [r for r in rows if (r.region or "").lower() in regions]
            if args.get("check_backup_status"):
                annotate_backup_status(wl, rows, backup_index)
            data[wl] = rows
        except Exception as exc:  # noqa: BLE001 - never abort the run
            logging.error(f"[{sub_id}] {wl} collector crashed: {exc}")
        reporter.advance()
    return data


def summarize_backup_coverage_rows(combined):
    """Build the 'Backup coverage' summary section (protected vs unprotected per
    workload + a grand total). Returns the dict consumed by render_summary_table /
    build_json_summary, or None when no resources were annotated (e.g. when run
    with --no-backup-status)."""
    rows = []
    g_prot = g_total = 0
    for cls in WORKLOAD_CLASSES:
        if cls is CloudRewindQuote:
            continue
        annotated = [o for o in (combined.get(cls.WORKLOAD) or [])
                     if getattr(o, "native_backup", "")]
        if not annotated:
            continue
        prot = sum(1 for o in annotated if o.native_backup == "Yes")
        total = len(annotated)
        g_prot += prot
        g_total += total
        name = cls.INFO_SHEET.replace(" Info", "")
        rows.append((name, f"{prot:,} protected / {total - prot:,} unprotected"))
    if not rows:
        return None
    rows.append(("Total", f"{g_prot:,} protected / {g_total - g_prot:,} unprotected"))
    return {"title": "Backup coverage", "key": "backup_coverage", "rows": rows}


def azure_describe_scope(handle, args):
    """Driver hook: the per-subscription line shown under --validate-only.

    Mirrors AWS's "N region(s)": shows the region filter when set, else the
    fact that every region in the subscription will be collected."""
    regions = args.get("regions")
    return f"{len(regions)} region(s)" if regions else "all regions"


AZURE_CONFIG = common.CloudConfig(
    name="Azure",
    version=__version__,
    log_prefix="azure_sizing",
    comprehensive_label="all_azure_subscriptions",
    scope_noun="subscription",
    unit_noun="workloads",
    workload_classes=WORKLOAD_CLASSES,
    parse_args=parse_args,
    validate_args=validate_args,
    build_sessions=build_sessions,
    collect=azure_collect,
    describe_scope=azure_describe_scope,
    print_credential_help=print_credential_help,
    extra_summary_rows=summarize_backup_coverage_rows,
    noisy_loggers=("azure", "azure.core.pipeline.policies.http_logging_policy",
                   "urllib3", "msal", "msrest"),
    banner_subtitle=None,
    scope_already_filtered=lambda args: bool(args.get("subscriptions")
                                             or args.get("tenant")),
)


if __name__ == "__main__":
    common.run_sizing(AZURE_CONFIG)
