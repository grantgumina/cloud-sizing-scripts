#!/usr/bin/env python3
"""
CVAWSCloudSizingScript.py

Cross-platform AWS cloud resource discovery / sizing tool.

Inventories AWS resources across one or more accounts and regions and produces
timestamped Excel workbooks (one per account plus a combined "comprehensive"
workbook) summarizing provisioned/used capacity for capacity planning and
Commvault protection-cost estimation.

This is a Python port of the original CVAWSCloudSizingScript.ps1 (PowerShell),
written to run identically on Linux, macOS, Windows, and AWS CloudShell. It uses
the native AWS SDK (boto3) for all API access and shells out to kubectl only for
EKS persistent-volume sizing (mirroring the OCI reference script's OKE handling).

Supported workloads:
    ec2, ebs-unattached, s3, efs, fsx, fsx-svm, rds, documentdb, dynamodb, redshift, eks

Run with --help for usage.
"""

import sys
import subprocess
import os
import json
import time
import re
import logging
import shutil
import tempfile
import argparse
from datetime import datetime, timezone, timedelta
from dataclasses import dataclass, field


# --------------------------------------------------------------------------- #
# Shared cloud-agnostic toolkit (repo root)
# --------------------------------------------------------------------------- #
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import cloudsizing_common as common  # noqa: E402

import boto3  # noqa: E402
from botocore.config import Config  # noqa: E402
from botocore.exceptions import (  # noqa: E402
    ClientError, BotoCoreError, NoCredentialsError, ProfileNotFound,
)

__version__ = "0.1.0"

# Reuse the agnostic helpers under their original local names so the AWS-specific
# code below (collectors, etc.) is unchanged. Human output goes through
# common.console (reassigned by --no-color), so reference it via `common.`.
convert_bytes_to_sizes = common.convert_bytes_to_sizes
tags_to_dict = common.tags_to_dict
convert_k8s_size_to_bytes = common.convert_k8s_size_to_bytes


# --------------------------------------------------------------------------- #
# Runtime options (populated from CLI args in main)
# --------------------------------------------------------------------------- #
OPTIONS = {
    "skip_bucket_tags": False,
    "s3_enumerate_fallback": True,
    "s3_enum_max_seconds": 120,
    "s3_enum_max_objects": 100000,
    "partition": "",  # "" (standard) or "GovCloud"
    "role_session_name": "CVAWS-Cost-Sizing",
    "external_id": None,
    "cross_account_role": None,
    "no_input": False,   # --no-input: never prompt, even on a TTY
    "json": False,       # --json: emit machine-readable summary to stdout
    "quiet": False,      # -q: suppress progress + INFO console output
}

# Constants ----------------------------------------------------------------- #
CW_LOOKBACK_DAYS = 7
CW_PERIOD = 86400  # 1 day

S3_STORAGE_TYPES = [
    "StandardStorage",
    "StandardIAStorage",
    "OneZoneIAStorage",
    "ReducedRedundancyStorage",
    "GlacierStorage",
    "GlacierInstantRetrievalStorage",
    "DeepArchiveStorage",
    "IntelligentTieringFAStorage",
    "IntelligentTieringIAStorage",
]


def iam_partition():
    """Return the IAM ARN partition string for the selected AWS partition."""
    return "aws-us-gov" if OPTIONS["partition"] == "GovCloud" else "aws"


def default_query_region():
    return "us-gov-west-1" if OPTIONS["partition"] == "GovCloud" else "us-east-1"


# --------------------------------------------------------------------------- #
# AWS CloudWatch metric helper
# --------------------------------------------------------------------------- #
def get_cw_metric(cw_client, namespace, metric_name, dimensions, stat="Average",
                  days=CW_LOOKBACK_DAYS, period=CW_PERIOD):
    """Return the most recent datapoint for a CloudWatch metric, or 0."""
    try:
        end = datetime.now(timezone.utc)
        start = end - timedelta(days=days)
        resp = cw_client.get_metric_statistics(
            Namespace=namespace,
            MetricName=metric_name,
            Dimensions=dimensions,
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=[stat],
        )
        datapoints = resp.get("Datapoints", [])
        if not datapoints:
            return 0
        datapoints.sort(key=lambda d: d["Timestamp"])
        return datapoints[-1].get(stat, 0) or 0
    except (ClientError, BotoCoreError) as exc:
        logging.debug(f"CloudWatch {namespace}/{metric_name} failed: {exc}")
        return 0


# --------------------------------------------------------------------------- #
# Resource data classes
#
# Each Info class declares the sheet names, headers, summary-aggregation config,
# and a to_row() that produces the ordered Excel row. Summaries are derived
# generically from the collected Info objects (group by region, count + sum).
# --------------------------------------------------------------------------- #
_COMMON = ["Account ID", "Account Alias", "Region"]


@dataclass
class EC2Instance:
    WORKLOAD = "ec2"
    INFO_SHEET = "EC2 Info"
    SUMMARY_SHEET = "EC2 Summary"
    INFO_HEADERS = _COMMON + ["Instance ID", "Instance Type", "State", "Launch Time",
                              "Volume Count", "Size (GiB)", "Size (TiB)", "Size (GB)",
                              "Size (TB)", "Volume Details", "Tags"]
    SUMMARY_HEADERS = ["Region", "Instance Count", "Total Size (GB)", "Total Size (TB)"]
    SUMMARY_SUM_FIELDS = [("size_gb", "Total Size (GB)"), ("size_tb", "Total Size (TB)")]
    GRAND_LABEL = "Total Instances"

    account_id: str = ""
    account_alias: str = ""
    region: str = ""
    instance_id: str = ""
    instance_type: str = ""
    state: str = ""
    launch_time: str = ""
    volume_count: int = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    volume_details: str = ""
    tags: dict = field(default_factory=dict)

    def to_row(self):
        return [self.account_id, self.account_alias, self.region, self.instance_id,
                self.instance_type, self.state, self.launch_time, self.volume_count,
                self.size_gib, self.size_tib, self.size_gb, self.size_tb,
                self.volume_details, str(self.tags)]


@dataclass
class UnattachedVolume:
    WORKLOAD = "ebs-unattached"
    INFO_SHEET = "Unattached EBS Info"
    SUMMARY_SHEET = "Unattached EBS Summary"
    INFO_HEADERS = _COMMON + ["Volume ID", "Volume Type", "State", "Create Time",
                              "Size (GiB)", "Size (TiB)", "Size (GB)", "Size (TB)", "Tags"]
    SUMMARY_HEADERS = ["Region", "Volume Count", "Total Size (GB)", "Total Size (TB)"]
    SUMMARY_SUM_FIELDS = [("size_gb", "Total Size (GB)"), ("size_tb", "Total Size (TB)")]
    GRAND_LABEL = "Total Unattached Volumes"

    account_id: str = ""
    account_alias: str = ""
    region: str = ""
    volume_id: str = ""
    volume_type: str = ""
    state: str = ""
    create_time: str = ""
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    tags: dict = field(default_factory=dict)

    def to_row(self):
        return [self.account_id, self.account_alias, self.region, self.volume_id,
                self.volume_type, self.state, self.create_time, self.size_gib,
                self.size_tib, self.size_gb, self.size_tb, str(self.tags)]


@dataclass
class S3Bucket:
    WORKLOAD = "s3"
    INFO_SHEET = "S3 Info"
    SUMMARY_SHEET = "S3 Summary"
    INFO_HEADERS = _COMMON + ["Bucket Name", "Object Count", "Creation Date",
                              "Size (GiB)", "Size (TiB)", "Size (GB)", "Size (TB)",
                              "Storage Class Breakdown (GB)", "Tags"]
    SUMMARY_HEADERS = ["Region", "Bucket Count", "Total Object Count",
                       "Total Size (GB)", "Total Size (TB)"]
    SUMMARY_SUM_FIELDS = [("object_count", "Total Object Count"),
                          ("size_gb", "Total Size (GB)"), ("size_tb", "Total Size (TB)")]
    GRAND_LABEL = "Total Buckets"

    account_id: str = ""
    account_alias: str = ""
    region: str = ""
    bucket_name: str = ""
    object_count: int = 0
    creation_date: str = ""
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    storage_breakdown: dict = field(default_factory=dict)
    tags: dict = field(default_factory=dict)

    def to_row(self):
        return [self.account_id, self.account_alias, self.region, self.bucket_name,
                self.object_count, self.creation_date, self.size_gib, self.size_tib,
                self.size_gb, self.size_tb, str(self.storage_breakdown), str(self.tags)]


@dataclass
class EFSFileSystem:
    WORKLOAD = "efs"
    INFO_SHEET = "EFS Info"
    SUMMARY_SHEET = "EFS Summary"
    INFO_HEADERS = _COMMON + ["File System ID", "Name", "Performance Mode", "State",
                              "Creation Time", "Size (GiB)", "Size (TiB)", "Size (GB)",
                              "Size (TB)", "Tags"]
    SUMMARY_HEADERS = ["Region", "File System Count", "Total Size (GB)", "Total Size (TB)"]
    SUMMARY_SUM_FIELDS = [("size_gb", "Total Size (GB)"), ("size_tb", "Total Size (TB)")]
    GRAND_LABEL = "Total File Systems"

    account_id: str = ""
    account_alias: str = ""
    region: str = ""
    file_system_id: str = ""
    name: str = ""
    performance_mode: str = ""
    state: str = ""
    creation_time: str = ""
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    tags: dict = field(default_factory=dict)

    def to_row(self):
        return [self.account_id, self.account_alias, self.region, self.file_system_id,
                self.name, self.performance_mode, self.state, self.creation_time,
                self.size_gib, self.size_tib, self.size_gb, self.size_tb, str(self.tags)]


@dataclass
class FSxFileSystem:
    WORKLOAD = "fsx"
    INFO_SHEET = "FSx Info"
    SUMMARY_SHEET = "FSx Summary"
    INFO_HEADERS = _COMMON + ["File System ID", "Type", "State", "Creation Time",
                              "Storage Capacity (GiB)", "Size (GiB)", "Size (TiB)",
                              "Size (GB)", "Size (TB)", "Tags"]
    SUMMARY_HEADERS = ["Region", "File System Count", "Total Size (GB)", "Total Size (TB)"]
    SUMMARY_SUM_FIELDS = [("size_gb", "Total Size (GB)"), ("size_tb", "Total Size (TB)")]
    GRAND_LABEL = "Total File Systems"

    account_id: str = ""
    account_alias: str = ""
    region: str = ""
    file_system_id: str = ""
    fs_type: str = ""
    state: str = ""
    creation_time: str = ""
    storage_capacity_gib: float = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    tags: dict = field(default_factory=dict)

    def to_row(self):
        return [self.account_id, self.account_alias, self.region, self.file_system_id,
                self.fs_type, self.state, self.creation_time, self.storage_capacity_gib,
                self.size_gib, self.size_tib, self.size_gb, self.size_tb, str(self.tags)]


@dataclass
class FSxSVM:
    WORKLOAD = "fsx-svm"
    INFO_SHEET = "FSx SVM Info"
    SUMMARY_SHEET = "FSx SVM Summary"
    INFO_HEADERS = _COMMON + ["File System ID", "SVM ID", "Name", "State", "UUID",
                              "Volume Count", "Size (GiB)", "Size (TiB)", "Size (GB)",
                              "Size (TB)", "Volume Details"]
    SUMMARY_HEADERS = ["Region", "SVM Count", "Total Size (GB)", "Total Size (TB)"]
    SUMMARY_SUM_FIELDS = [("size_gb", "Total Size (GB)"), ("size_tb", "Total Size (TB)")]
    GRAND_LABEL = "Total SVMs"

    account_id: str = ""
    account_alias: str = ""
    region: str = ""
    file_system_id: str = ""
    svm_id: str = ""
    name: str = ""
    state: str = ""
    uuid: str = ""
    volume_count: int = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    volume_details: str = ""

    def to_row(self):
        return [self.account_id, self.account_alias, self.region, self.file_system_id,
                self.svm_id, self.name, self.state, self.uuid, self.volume_count,
                self.size_gib, self.size_tib, self.size_gb, self.size_tb,
                self.volume_details]


@dataclass
class RDSInstance:
    WORKLOAD = "rds"
    INFO_SHEET = "RDS Info"
    SUMMARY_SHEET = "RDS Summary"
    INFO_HEADERS = _COMMON + ["DB Instance Identifier", "Engine", "DB Instance Class",
                              "Cluster Identifier", "Size (GiB)", "Size (TiB)",
                              "Size (GB)", "Size (TB)", "Tags"]
    SUMMARY_HEADERS = ["Region", "DB Instance Count", "Total Size (GB)", "Total Size (TB)"]
    SUMMARY_SUM_FIELDS = [("size_gb", "Total Size (GB)"), ("size_tb", "Total Size (TB)")]
    GRAND_LABEL = "Total DB Instances"

    account_id: str = ""
    account_alias: str = ""
    region: str = ""
    db_instance_id: str = ""
    engine: str = ""
    db_instance_class: str = ""
    cluster_id: str = ""
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    tags: dict = field(default_factory=dict)

    def to_row(self):
        return [self.account_id, self.account_alias, self.region, self.db_instance_id,
                self.engine, self.db_instance_class, self.cluster_id, self.size_gib,
                self.size_tib, self.size_gb, self.size_tb, str(self.tags)]


@dataclass
class DocumentDBCluster:
    WORKLOAD = "documentdb"
    INFO_SHEET = "DocumentDB Info"
    SUMMARY_SHEET = "DocumentDB Summary"
    INFO_HEADERS = _COMMON + ["Cluster Identifier", "Engine", "Engine Version", "Status",
                              "Instance Count", "Instance Types", "Availability Zones",
                              "Size (GiB)", "Size (TiB)", "Size (GB)", "Size (TB)",
                              "Backup Retention (days)", "Cluster Create Time", "Tags"]
    SUMMARY_HEADERS = ["Region", "Cluster Count", "Total Size (GB)", "Total Size (TB)"]
    SUMMARY_SUM_FIELDS = [("size_gb", "Total Size (GB)"), ("size_tb", "Total Size (TB)")]
    GRAND_LABEL = "Total Clusters"

    account_id: str = ""
    account_alias: str = ""
    region: str = ""
    cluster_id: str = ""
    engine: str = ""
    engine_version: str = ""
    status: str = ""
    instance_count: int = 0
    instance_types: str = ""
    availability_zones: str = ""
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    backup_retention: int = 0
    create_time: str = ""
    tags: dict = field(default_factory=dict)

    def to_row(self):
        return [self.account_id, self.account_alias, self.region, self.cluster_id,
                self.engine, self.engine_version, self.status, self.instance_count,
                self.instance_types, self.availability_zones, self.size_gib,
                self.size_tib, self.size_gb, self.size_tb, self.backup_retention,
                self.create_time, str(self.tags)]


@dataclass
class DynamoDBTable:
    WORKLOAD = "dynamodb"
    INFO_SHEET = "DynamoDB Info"
    SUMMARY_SHEET = "DynamoDB Summary"
    INFO_HEADERS = _COMMON + ["Table Name", "Table ID", "Table ARN", "Status",
                              "Item Count", "Size (GiB)", "Size (TiB)", "Size (GB)",
                              "Size (TB)", "Tags"]
    SUMMARY_HEADERS = ["Region", "Table Count", "Total Item Count",
                       "Total Size (GB)", "Total Size (TB)"]
    SUMMARY_SUM_FIELDS = [("item_count", "Total Item Count"),
                          ("size_gb", "Total Size (GB)"), ("size_tb", "Total Size (TB)")]
    GRAND_LABEL = "Total Tables"

    account_id: str = ""
    account_alias: str = ""
    region: str = ""
    table_name: str = ""
    table_id: str = ""
    table_arn: str = ""
    status: str = ""
    item_count: int = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    tags: dict = field(default_factory=dict)

    def to_row(self):
        return [self.account_id, self.account_alias, self.region, self.table_name,
                self.table_id, self.table_arn, self.status, self.item_count,
                self.size_gib, self.size_tib, self.size_gb, self.size_tb, str(self.tags)]


@dataclass
class RedshiftCluster:
    WORKLOAD = "redshift"
    INFO_SHEET = "Redshift Info"
    SUMMARY_SHEET = "Redshift Summary"
    INFO_HEADERS = _COMMON + ["Cluster Identifier", "Node Type", "Node Count",
                              "Size (GiB)", "Size (TiB)", "Size (GB)", "Size (TB)", "Tags"]
    SUMMARY_HEADERS = ["Region", "Cluster Count", "Total Size (GB)", "Total Size (TB)"]
    SUMMARY_SUM_FIELDS = [("size_gb", "Total Size (GB)"), ("size_tb", "Total Size (TB)")]
    GRAND_LABEL = "Total Clusters"

    account_id: str = ""
    account_alias: str = ""
    region: str = ""
    cluster_id: str = ""
    node_type: str = ""
    node_count: int = 0
    size_gib: float = 0
    size_tib: float = 0
    size_gb: float = 0
    size_tb: float = 0
    tags: dict = field(default_factory=dict)

    def to_row(self):
        return [self.account_id, self.account_alias, self.region, self.cluster_id,
                self.node_type, self.node_count, self.size_gib, self.size_tib,
                self.size_gb, self.size_tb, str(self.tags)]


@dataclass
class EKSCluster:
    WORKLOAD = "eks"
    INFO_SHEET = "EKS Info"
    SUMMARY_SHEET = "EKS Summary"
    INFO_HEADERS = _COMMON + ["Cluster Name", "Kubernetes Version", "PVC Count",
                              "Node Count", "Size (GiB)", "Size (TiB)", "Size (GB)",
                              "Size (TB)", "PVC Details", "Node Details"]
    SUMMARY_HEADERS = ["Region", "Cluster Count", "Total Node Count",
                       "Total PVC Count", "Total Size (GB)", "Total Size (TB)"]
    SUMMARY_SUM_FIELDS = [("node_count", "Total Node Count"),
                          ("pvc_count", "Total PVC Count"),
                          ("size_gb", "Total Size (GB)"), ("size_tb", "Total Size (TB)")]
    GRAND_LABEL = "Total Clusters"

    account_id: str = ""
    account_alias: str = ""
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

    def to_row(self):
        return [self.account_id, self.account_alias, self.region, self.cluster_name,
                self.k8s_version, self.pvc_count, self.node_count, self.size_gib,
                self.size_tib, self.size_gb, self.size_tb, self.pvc_details,
                self.node_details]


# Registry of all workload classes, in display order.
WORKLOAD_CLASSES = [
    EC2Instance, UnattachedVolume, S3Bucket, EFSFileSystem, FSxFileSystem,
    FSxSVM, RDSInstance, DocumentDBCluster, DynamoDBTable, RedshiftCluster, EKSCluster,
]
WORKLOAD_BY_KEY = {cls.WORKLOAD: cls for cls in WORKLOAD_CLASSES}


# --------------------------------------------------------------------------- #
# Per-service collectors
# --------------------------------------------------------------------------- #
def collect_ec2(session, region, account_id, alias):
    out = []
    ec2 = session.client("ec2", region_name=region)
    try:
        for page in ec2.get_paginator("describe_instances").paginate():
            for resv in page.get("Reservations", []):
                for inst in resv.get("Instances", []):
                    state = inst.get("State", {}).get("Name", "")
                    if state == "terminated":
                        continue
                    vol_ids = [bdm["Ebs"]["VolumeId"]
                               for bdm in inst.get("BlockDeviceMappings", [])
                               if "Ebs" in bdm and "VolumeId" in bdm["Ebs"]]
                    total_bytes = 0
                    details = []
                    if vol_ids:
                        try:
                            vols = ec2.describe_volumes(VolumeIds=vol_ids).get("Volumes", [])
                            for v in vols:
                                gib = v.get("Size", 0) or 0
                                total_bytes += gib * (1024 ** 3)
                                details.append(f"{v['VolumeId']}:{gib}GiB:{v.get('VolumeType', '')}")
                        except (ClientError, BotoCoreError) as exc:
                            logging.debug(f"describe_volumes failed for {inst.get('InstanceId')}: {exc}")
                    sizes = convert_bytes_to_sizes(total_bytes)
                    out.append(EC2Instance(
                        account_id=account_id, account_alias=alias, region=region,
                        instance_id=inst.get("InstanceId", ""),
                        instance_type=inst.get("InstanceType", ""),
                        state=state, launch_time=str(inst.get("LaunchTime", "")),
                        volume_count=len(vol_ids),
                        size_gib=sizes["GiB"], size_tib=sizes["TiB"],
                        size_gb=sizes["GB"], size_tb=sizes["TB"],
                        volume_details="; ".join(details),
                        tags=tags_to_dict(inst.get("Tags"))))
    except (ClientError, BotoCoreError) as exc:
        logging.error(f"[{account_id}/{region}] EC2 error: {exc}")
    return out


def collect_unattached_volumes(session, region, account_id, alias):
    out = []
    ec2 = session.client("ec2", region_name=region)
    try:
        paginator = ec2.get_paginator("describe_volumes")
        for page in paginator.paginate(Filters=[{"Name": "status", "Values": ["available"]}]):
            for v in page.get("Volumes", []):
                gib = v.get("Size", 0) or 0
                sizes = convert_bytes_to_sizes(gib * (1024 ** 3))
                out.append(UnattachedVolume(
                    account_id=account_id, account_alias=alias, region=region,
                    volume_id=v.get("VolumeId", ""), volume_type=v.get("VolumeType", ""),
                    state=v.get("State", ""), create_time=str(v.get("CreateTime", "")),
                    size_gib=sizes["GiB"], size_tib=sizes["TiB"],
                    size_gb=sizes["GB"], size_tb=sizes["TB"],
                    tags=tags_to_dict(v.get("Tags"))))
    except (ClientError, BotoCoreError) as exc:
        logging.error(f"[{account_id}/{region}] Unattached EBS error: {exc}")
    return out


def enumerate_bucket_size(s3_client, bucket, on_progress=None):
    """Fallback bucket sizing via object enumeration, with PS-style safeguards.

    on_progress(bucket, count) is called periodically so a long enumeration can
    show live feedback instead of sitting silent for up to s3_enum_max_seconds.
    """
    total = 0
    count = 0
    start = time.time()
    token = None
    while True:
        kwargs = {"Bucket": bucket, "MaxKeys": 1000}
        if token:
            kwargs["ContinuationToken"] = token
        try:
            resp = s3_client.list_objects_v2(**kwargs)
        except (ClientError, BotoCoreError) as exc:
            logging.debug(f"list_objects_v2 failed for {bucket}: {exc}")
            break
        for obj in resp.get("Contents", []):
            total += obj.get("Size", 0) or 0
            count += 1
        if on_progress:
            on_progress(bucket, count)
        if not resp.get("IsTruncated"):
            break
        token = resp.get("NextContinuationToken")
        if (time.time() - start) > OPTIONS["s3_enum_max_seconds"]:
            logging.warning(f"Bucket {bucket}: enumeration timed out, size is partial.")
            break
        if count >= OPTIONS["s3_enum_max_objects"]:
            logging.warning(f"Bucket {bucket}: hit object cap, size is partial.")
            break
    return total


def collect_s3(session, account_id, alias, regions_filter, on_progress=None):
    """S3 is account-global; size each bucket in its own region via CloudWatch."""
    out = []
    s3 = session.client("s3")
    try:
        buckets = s3.list_buckets().get("Buckets", [])
    except (ClientError, BotoCoreError) as exc:
        logging.error(f"[{account_id}] S3 list_buckets error: {exc}")
        return out

    for b in buckets:
        name = b["Name"]
        try:
            loc = s3.get_bucket_location(Bucket=name).get("LocationConstraint")
            region = loc or "us-east-1"
            if region == "EU":
                region = "eu-west-1"
        except (ClientError, BotoCoreError):
            region = "us-east-1"
        if regions_filter and region not in regions_filter:
            continue

        cw = session.client("cloudwatch", region_name=region)
        breakdown = {}
        total_bytes = 0
        for stype in S3_STORAGE_TYPES:
            val = get_cw_metric(cw, "AWS/S3", "BucketSizeBytes",
                                [{"Name": "BucketName", "Value": name},
                                 {"Name": "StorageType", "Value": stype}], stat="Average")
            if val:
                breakdown[stype] = round(val / 1e9, 4)
                total_bytes += val
        object_count = int(get_cw_metric(cw, "AWS/S3", "NumberOfObjects",
                                         [{"Name": "BucketName", "Value": name},
                                          {"Name": "StorageType", "Value": "AllStorageTypes"}],
                                         stat="Average") or 0)

        if total_bytes == 0 and OPTIONS["s3_enumerate_fallback"]:
            total_bytes = enumerate_bucket_size(
                session.client("s3", region_name=region), name, on_progress)

        tags = {}
        if not OPTIONS["skip_bucket_tags"]:
            try:
                tags = tags_to_dict(s3.get_bucket_tagging(Bucket=name).get("TagSet"))
            except (ClientError, BotoCoreError):
                tags = {}

        sizes = convert_bytes_to_sizes(total_bytes)
        out.append(S3Bucket(
            account_id=account_id, account_alias=alias, region=region,
            bucket_name=name, object_count=object_count,
            creation_date=str(b.get("CreationDate", "")),
            size_gib=sizes["GiB"], size_tib=sizes["TiB"],
            size_gb=sizes["GB"], size_tb=sizes["TB"],
            storage_breakdown=breakdown, tags=tags))
    return out


def collect_efs(session, region, account_id, alias):
    out = []
    efs = session.client("efs", region_name=region)
    cw = session.client("cloudwatch", region_name=region)
    try:
        for page in efs.get_paginator("describe_file_systems").paginate():
            for fs in page.get("FileSystems", []):
                bytes_ = (fs.get("SizeInBytes") or {}).get("Value", 0) or 0
                if not bytes_:
                    bytes_ = get_cw_metric(cw, "AWS/EFS", "StorageBytes",
                                           [{"Name": "FileSystemId", "Value": fs["FileSystemId"]}],
                                           stat="Average")
                sizes = convert_bytes_to_sizes(bytes_)
                out.append(EFSFileSystem(
                    account_id=account_id, account_alias=alias, region=region,
                    file_system_id=fs.get("FileSystemId", ""), name=fs.get("Name", ""),
                    performance_mode=fs.get("PerformanceMode", ""),
                    state=fs.get("LifeCycleState", ""),
                    creation_time=str(fs.get("CreationTime", "")),
                    size_gib=sizes["GiB"], size_tib=sizes["TiB"],
                    size_gb=sizes["GB"], size_tb=sizes["TB"],
                    tags=tags_to_dict(fs.get("Tags"))))
    except (ClientError, BotoCoreError) as exc:
        logging.error(f"[{account_id}/{region}] EFS error: {exc}")
    return out


def collect_fsx(session, region, account_id, alias):
    """Returns (file_systems, svms)."""
    fs_out = []
    svm_out = []
    fsx = session.client("fsx", region_name=region)
    try:
        for page in fsx.get_paginator("describe_file_systems").paginate():
            for fs in page.get("FileSystems", []):
                cap_gib = fs.get("StorageCapacity", 0) or 0  # FSx capacity is in GiB
                sizes = convert_bytes_to_sizes(cap_gib * (1024 ** 3))
                fs_out.append(FSxFileSystem(
                    account_id=account_id, account_alias=alias, region=region,
                    file_system_id=fs.get("FileSystemId", ""),
                    fs_type=fs.get("FileSystemType", ""), state=fs.get("Lifecycle", ""),
                    creation_time=str(fs.get("CreationTime", "")),
                    storage_capacity_gib=cap_gib,
                    size_gib=sizes["GiB"], size_tib=sizes["TiB"],
                    size_gb=sizes["GB"], size_tb=sizes["TB"],
                    tags=tags_to_dict(fs.get("Tags"))))
    except (ClientError, BotoCoreError) as exc:
        logging.error(f"[{account_id}/{region}] FSx error: {exc}")

    # ONTAP Storage Virtual Machines + their volumes
    try:
        svms = []
        for page in fsx.get_paginator("describe_storage_virtual_machines").paginate():
            svms.extend(page.get("StorageVirtualMachines", []))
        if svms:
            volumes = []
            for page in fsx.get_paginator("describe_volumes").paginate():
                volumes.extend(page.get("Volumes", []))
            vols_by_svm = {}
            for v in volumes:
                vols_by_svm.setdefault(v.get("StorageVirtualMachineId"), []).append(v)
            for svm in svms:
                svm_id = svm.get("StorageVirtualMachineId", "")
                vlist = vols_by_svm.get(svm_id, [])
                total_bytes = 0
                details = []
                for v in vlist:
                    ontap = v.get("OntapConfiguration", {}) or {}
                    mb = ontap.get("SizeInMegabytes", 0) or 0
                    vbytes = mb * (1024 ** 2)
                    total_bytes += vbytes
                    details.append(f"{v.get('Name', v.get('VolumeId', ''))}:{mb}MiB")
                sizes = convert_bytes_to_sizes(total_bytes)
                svm_out.append(FSxSVM(
                    account_id=account_id, account_alias=alias, region=region,
                    file_system_id=svm.get("FileSystemId", ""), svm_id=svm_id,
                    name=svm.get("Name", ""),
                    state=svm.get("Lifecycle", ""), uuid=svm.get("UUID", ""),
                    volume_count=len(vlist),
                    size_gib=sizes["GiB"], size_tib=sizes["TiB"],
                    size_gb=sizes["GB"], size_tb=sizes["TB"],
                    volume_details="; ".join(details)))
    except (ClientError, BotoCoreError) as exc:
        logging.debug(f"[{account_id}/{region}] FSx SVM error: {exc}")

    return fs_out, svm_out


def collect_rds(session, region, account_id, alias):
    out = []
    rds = session.client("rds", region_name=region)
    cw = session.client("cloudwatch", region_name=region)
    try:
        for page in rds.get_paginator("describe_db_instances").paginate():
            for db in page.get("DBInstances", []):
                engine = db.get("Engine", "")
                if engine.startswith("docdb"):
                    continue  # handled by DocumentDB collector
                cluster_id = db.get("DBClusterIdentifier", "")
                if engine.startswith("aurora"):
                    bytes_ = 0
                    if cluster_id:
                        bytes_ = get_cw_metric(cw, "AWS/RDS", "VolumeBytesUsed",
                                               [{"Name": "DBClusterIdentifier", "Value": cluster_id}],
                                               stat="Maximum")
                else:
                    bytes_ = (db.get("AllocatedStorage", 0) or 0) * (1024 ** 3)
                sizes = convert_bytes_to_sizes(bytes_)
                out.append(RDSInstance(
                    account_id=account_id, account_alias=alias, region=region,
                    db_instance_id=db.get("DBInstanceIdentifier", ""), engine=engine,
                    db_instance_class=db.get("DBInstanceClass", ""), cluster_id=cluster_id,
                    size_gib=sizes["GiB"], size_tib=sizes["TiB"],
                    size_gb=sizes["GB"], size_tb=sizes["TB"],
                    tags=tags_to_dict(db.get("TagList"))))
    except (ClientError, BotoCoreError) as exc:
        logging.error(f"[{account_id}/{region}] RDS error: {exc}")
    return out


def collect_docdb(session, region, account_id, alias):
    out = []
    docdb = session.client("docdb", region_name=region)
    cw = session.client("cloudwatch", region_name=region)
    try:
        clusters = []
        for page in docdb.get_paginator("describe_db_clusters").paginate(
                Filters=[{"Name": "engine", "Values": ["docdb"]}]):
            clusters.extend(page.get("DBClusters", []))
    except (ClientError, BotoCoreError) as exc:
        logging.error(f"[{account_id}/{region}] DocumentDB error: {exc}")
        return out

    for c in clusters:
        cid = c.get("DBClusterIdentifier", "")
        bytes_ = get_cw_metric(cw, "AWS/DocDB", "VolumeBytesUsed",
                               [{"Name": "DBClusterIdentifier", "Value": cid}], stat="Maximum")
        instances = []
        try:
            for page in docdb.get_paginator("describe_db_instances").paginate(
                    Filters=[{"Name": "db-cluster-id", "Values": [cid]}]):
                instances.extend(page.get("DBInstances", []))
        except (ClientError, BotoCoreError):
            instances = []
        instance_types = sorted({i.get("DBInstanceClass", "") for i in instances if i.get("DBInstanceClass")})
        azs = sorted({a for a in (c.get("AvailabilityZones") or [])})
        tags = {}
        try:
            tags = tags_to_dict(docdb.list_tags_for_resource(
                ResourceName=c.get("DBClusterArn", "")).get("TagList"))
        except (ClientError, BotoCoreError):
            tags = {}
        sizes = convert_bytes_to_sizes(bytes_)
        out.append(DocumentDBCluster(
            account_id=account_id, account_alias=alias, region=region, cluster_id=cid,
            engine=c.get("Engine", ""), engine_version=c.get("EngineVersion", ""),
            status=c.get("Status", ""), instance_count=len(instances),
            instance_types="; ".join(instance_types), availability_zones="; ".join(azs),
            size_gib=sizes["GiB"], size_tib=sizes["TiB"],
            size_gb=sizes["GB"], size_tb=sizes["TB"],
            backup_retention=c.get("BackupRetentionPeriod", 0) or 0,
            create_time=str(c.get("ClusterCreateTime", "")), tags=tags))
    return out


def collect_dynamodb(session, region, account_id, alias):
    out = []
    ddb = session.client("dynamodb", region_name=region)
    try:
        for page in ddb.get_paginator("list_tables").paginate():
            for name in page.get("TableNames", []):
                try:
                    t = ddb.describe_table(TableName=name)["Table"]
                except (ClientError, BotoCoreError) as exc:
                    logging.debug(f"describe_table failed for {name}: {exc}")
                    continue
                sizes = convert_bytes_to_sizes(t.get("TableSizeBytes", 0) or 0)
                tags = {}
                try:
                    tags = tags_to_dict(ddb.list_tags_of_resource(
                        ResourceArn=t.get("TableArn", "")).get("Tags"))
                except (ClientError, BotoCoreError):
                    tags = {}
                out.append(DynamoDBTable(
                    account_id=account_id, account_alias=alias, region=region,
                    table_name=t.get("TableName", ""), table_id=t.get("TableId", ""),
                    table_arn=t.get("TableArn", ""), status=t.get("TableStatus", ""),
                    item_count=t.get("ItemCount", 0) or 0,
                    size_gib=sizes["GiB"], size_tib=sizes["TiB"],
                    size_gb=sizes["GB"], size_tb=sizes["TB"], tags=tags))
    except (ClientError, BotoCoreError) as exc:
        logging.error(f"[{account_id}/{region}] DynamoDB error: {exc}")
    return out


def collect_redshift(session, region, account_id, alias):
    out = []
    rs = session.client("redshift", region_name=region)
    try:
        for page in rs.get_paginator("describe_clusters").paginate():
            for c in page.get("Clusters", []):
                mb = c.get("TotalStorageCapacityInMegaBytes", 0) or 0
                sizes = convert_bytes_to_sizes(mb * 1e6)
                out.append(RedshiftCluster(
                    account_id=account_id, account_alias=alias, region=region,
                    cluster_id=c.get("ClusterIdentifier", ""),
                    node_type=c.get("NodeType", ""), node_count=c.get("NumberOfNodes", 0) or 0,
                    size_gib=sizes["GiB"], size_tib=sizes["TiB"],
                    size_gb=sizes["GB"], size_tb=sizes["TB"],
                    tags=tags_to_dict(c.get("Tags"))))
    except (ClientError, BotoCoreError) as exc:
        logging.error(f"[{account_id}/{region}] Redshift error: {exc}")
    return out


def collect_eks(session, region, account_id, alias):
    out = []
    eks = session.client("eks", region_name=region)
    try:
        cluster_names = []
        for page in eks.get_paginator("list_clusters").paginate():
            cluster_names.extend(page.get("clusters", []))
    except (ClientError, BotoCoreError) as exc:
        logging.error(f"[{account_id}/{region}] EKS list error: {exc}")
        return out

    if cluster_names and not shutil.which("kubectl"):
        logging.warning("kubectl not found; EKS clusters listed without PVC/node sizing.")

    # Make the session's credentials available to the aws/kubectl subprocesses.
    sub_env = os.environ.copy()
    try:
        creds = session.get_credentials()
        if creds:
            frozen = creds.get_frozen_credentials()
            sub_env["AWS_ACCESS_KEY_ID"] = frozen.access_key
            sub_env["AWS_SECRET_ACCESS_KEY"] = frozen.secret_key
            if frozen.token:
                sub_env["AWS_SESSION_TOKEN"] = frozen.token
    except Exception:
        pass

    for name in cluster_names:
        try:
            c = eks.describe_cluster(name=name)["cluster"]
        except (ClientError, BotoCoreError):
            c = {"name": name, "version": ""}
        info = EKSCluster(account_id=account_id, account_alias=alias, region=region,
                          cluster_name=name, k8s_version=c.get("version", ""))

        if shutil.which("kubectl") and shutil.which("aws"):
            kubeconfig = os.path.join(tempfile.gettempdir(),
                                      f"kubeconfig_{account_id}_{region}_{name}")
            env = dict(sub_env, KUBECONFIG=kubeconfig)
            try:
                subprocess.run(["aws", "eks", "update-kubeconfig", "--name", name,
                                "--region", region, "--kubeconfig", kubeconfig],
                               check=True, capture_output=True, text=True, env=env)
                pvc_json = json.loads(subprocess.run(
                    ["kubectl", "get", "pvc", "-A", "-o", "json"],
                    check=True, capture_output=True, text=True, env=env).stdout)
                pvc_items = pvc_json.get("items", [])
                total_bytes = 0
                pvc_details = []
                for pvc in pvc_items:
                    meta = pvc.get("metadata", {})
                    cap = (pvc.get("spec", {}).get("resources", {})
                           .get("requests", {}).get("storage"))
                    total_bytes += convert_k8s_size_to_bytes(cap)
                    pvc_details.append(
                        f"{meta.get('namespace', 'default')}/{meta.get('name', '')}:{cap}")
                sizes = convert_bytes_to_sizes(total_bytes)
                info.pvc_count = len(pvc_items)
                info.pvc_details = "; ".join(pvc_details)
                info.size_gib, info.size_tib = sizes["GiB"], sizes["TiB"]
                info.size_gb, info.size_tb = sizes["GB"], sizes["TB"]

                node_json = json.loads(subprocess.run(
                    ["kubectl", "get", "nodes", "-o", "json"],
                    check=True, capture_output=True, text=True, env=env).stdout)
                node_items = node_json.get("items", [])
                node_details = []
                for n in node_items:
                    nname = n.get("metadata", {}).get("name", "")
                    itype = (n.get("metadata", {}).get("labels", {})
                             .get("node.kubernetes.io/instance-type", ""))
                    node_details.append(f"{nname}:{itype}")
                info.node_count = len(node_items)
                info.node_details = "; ".join(node_details)
            except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as exc:
                logging.warning(f"EKS {name}: kubectl sizing failed: {exc}")
            finally:
                try:
                    os.remove(kubeconfig)
                except OSError:
                    pass
        out.append(info)
    return out


# Region-scoped collectors run once per region. S3 (account-global) and FSx
# (returns two workloads) are handled specially in the driver.
REGION_COLLECTORS = {
    "ec2": collect_ec2,
    "ebs-unattached": collect_unattached_volumes,
    "efs": collect_efs,
    "rds": collect_rds,
    "documentdb": collect_docdb,
    "dynamodb": collect_dynamodb,
    "redshift": collect_redshift,
    "eks": collect_eks,
}


# --------------------------------------------------------------------------- #
# Account discovery + region resolution
# --------------------------------------------------------------------------- #
# Fast-fail botocore config for the credential preflight, so a machine that is
# NOT on EC2 doesn't stall ~30s on IMDS retries. Real instance roles answer the
# metadata service in <1s, so this does not affect legitimate instance-role use.
PREFLIGHT_CONFIG = Config(connect_timeout=2, read_timeout=5,
                          retries={"max_attempts": 2})


def classify_credential_error(exc):
    """Map a boto/botocore credential exception to a (kind, human_detail) pair."""
    if isinstance(exc, NoCredentialsError):
        return ("no_credentials",
                "no credentials found (checked env vars, shared config, "
                "instance metadata)")
    if isinstance(exc, ProfileNotFound):
        return "profile_not_found", str(exc)
    if isinstance(exc, ClientError):
        err = exc.response.get("Error", {})
        code = err.get("Code", "")
        if code in ("ExpiredToken", "ExpiredTokenException", "RequestExpired",
                    "TokenRefreshRequired"):
            return "expired", f"credentials have expired ({code})"
        if code in ("InvalidClientTokenId", "UnrecognizedClientException",
                    "SignatureDoesNotMatch", "AuthFailure"):
            return "invalid_key", f"credentials were rejected ({code})"
        if code in ("AccessDenied", "AccessDeniedException"):
            return "access_denied", f"identity valid but STS access denied ({code})"
        return "other", f"{code}: {err.get('Message', str(exc))}".strip(": ")
    return "other", str(exc)


def resolve_identity(session):
    """Validate a session's credentials via STS GetCallerIdentity.

    Returns (ok, account_id, alias, error_kind, error_detail). On success the
    two error fields are empty strings. The account-alias lookup is best-effort
    and never fails the check, since the identity is already proven by STS.
    """
    try:
        sts = session.client("sts", region_name=default_query_region(),
                             config=PREFLIGHT_CONFIG)
        account_id = sts.get_caller_identity().get("Account", "")
    except (ClientError, BotoCoreError, NoCredentialsError, ProfileNotFound) as exc:
        kind, detail = classify_credential_error(exc)
        return False, "", "", kind, detail

    alias = ""
    try:
        aliases = session.client("iam").list_account_aliases().get("AccountAliases", [])
        alias = aliases[0] if aliases else ""
    except (ClientError, BotoCoreError):
        alias = ""
    return True, account_id, alias, "", ""


def resolve_regions(session, requested_regions):
    if requested_regions:
        return requested_regions
    try:
        ec2 = session.client("ec2", region_name=default_query_region())
        return [r["RegionName"] for r in ec2.describe_regions().get("Regions", [])]
    except (ClientError, BotoCoreError) as exc:
        logging.warning(f"Could not enumerate regions ({exc}); using {default_query_region()}.")
        return [default_query_region()]


def collect_account(session, account_id, alias, regions, workloads,
                    reporter=None, label=None):
    """Collect all selected workloads for one account into a data dict.

    reporter (optional) drives the rich progress display: the per-region loop
    advances it and updates its description with the current region/workload.
    """
    data = {wl: [] for wl in WORKLOAD_BY_KEY}
    region_workloads = [w for w in workloads if w in REGION_COLLECTORS]
    fsx_selected = "fsx" in workloads or "fsx-svm" in workloads
    label = label or alias or account_id or "account"

    for region in regions:
        logging.debug(f"[{account_id}] Processing region: {region}")
        for wl in region_workloads:
            if reporter:
                reporter.update(f"{label} | {region} | {wl}")
            try:
                data[wl].extend(REGION_COLLECTORS[wl](session, region, account_id, alias))
            except Exception as exc:  # defensive: never abort the run
                logging.error(f"[{account_id}/{region}] {wl} collector crashed: {exc}")
        if fsx_selected:
            if reporter:
                reporter.update(f"{label} | {region} | fsx")
            try:
                fs_list, svm_list = collect_fsx(session, region, account_id, alias)
                if "fsx" in workloads:
                    data["fsx"].extend(fs_list)
                if "fsx" in workloads or "fsx-svm" in workloads:
                    data["fsx-svm"].extend(svm_list)
            except Exception as exc:
                logging.error(f"[{account_id}/{region}] FSx collector crashed: {exc}")
        if reporter:
            reporter.advance()

    if "s3" in workloads:
        logging.debug(f"[{account_id}] Processing S3 (account-global)")
        if reporter:
            reporter.update(f"{label} | S3 (account-global)")

        def _s3_progress(bucket, count):
            reporter.update(f"{label} | S3 | {bucket} ({count:,} objs)")

        try:
            data["s3"].extend(collect_s3(
                session, account_id, alias,
                regions if requested_regions_flag else None,
                _s3_progress if reporter else None))
        except Exception as exc:
            logging.error(f"[{account_id}] S3 collector crashed: {exc}")
    return data


# --------------------------------------------------------------------------- #
# Authentication scenarios -> list of (session, account_id, alias)
# --------------------------------------------------------------------------- #
def session_from_profile(profile_name=None):
    return boto3.Session(profile_name=profile_name) if profile_name else boto3.Session()


def assume_role_session(base_session, account_id, role_name):
    arn = f"arn:{iam_partition()}:iam::{account_id}:role/{role_name}"
    sts = base_session.client("sts", region_name=default_query_region())
    kwargs = {"RoleArn": arn, "RoleSessionName": OPTIONS["role_session_name"]}
    if OPTIONS["external_id"]:
        kwargs["ExternalId"] = OPTIONS["external_id"]
    creds = sts.assume_role(**kwargs)["Credentials"]
    return boto3.Session(
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"])


def build_sessions(args):
    """Resolve the chosen auth mode into (sessions, failures).

    sessions: list of (session, account_id, alias) whose credentials passed the
              STS GetCallerIdentity preflight.
    failures: list of (label, error_kind, error_detail) that could not
              authenticate, for actionable reporting in main().
    """
    sessions, failures = [], []

    def add(session, label, alias_fallback=False):
        """Preflight a candidate session and sort it into sessions/failures."""
        ok, aid, alias, kind, detail = resolve_identity(session)
        if ok:
            if not alias and alias_fallback:
                alias = label
            sessions.append((session, aid or label, alias))
        else:
            failures.append((label, kind, detail))

    if args.get("cross_account_role"):
        role = args["cross_account_role"]
        base_profile = (args.get("profiles") or [None])[0]
        try:
            base = session_from_profile(base_profile)
        except ProfileNotFound as exc:
            kind, detail = classify_credential_error(exc)
            failures.append((base_profile, kind, detail))
            return sessions, failures
        accounts = list(args.get("accounts") or [])
        if args.get("accounts_file"):
            try:
                with open(args["accounts_file"]) as fh:
                    accounts.extend(line.strip() for line in fh if line.strip())
            except OSError as exc:
                logging.error(f"Could not read --accounts-file: {exc}")
        for acct in accounts:
            try:
                sess = assume_role_session(base, acct, role)
            except (ClientError, BotoCoreError) as exc:
                kind, detail = classify_credential_error(exc)
                failures.append((acct, kind, detail))
                continue
            add(sess, acct)
        return sessions, failures

    if args.get("all_local_profiles"):
        for p in boto3.Session().available_profiles:
            try:
                add(session_from_profile(p), p, alias_fallback=True)
            except ProfileNotFound as exc:
                kind, detail = classify_credential_error(exc)
                failures.append((p, kind, detail))
        return sessions, failures

    if args.get("profiles"):
        for p in args["profiles"]:
            try:
                add(session_from_profile(p), p, alias_fallback=True)
            except ProfileNotFound as exc:
                kind, detail = classify_credential_error(exc)
                failures.append((p, kind, detail))
        return sessions, failures

    # Default credential chain (env / shared config / instance / CloudShell role)
    add(session_from_profile(), "default")
    return sessions, failures


# --------------------------------------------------------------------------- #
# Credential guidance
# --------------------------------------------------------------------------- #
CREDENTIAL_SETUP_GUIDANCE = """\
No AWS credentials could be authenticated. Configure credentials ONE of these
ways, then re-run:

  1. Environment variables (quickest for a one-off):
       export AWS_ACCESS_KEY_ID=...
       export AWS_SECRET_ACCESS_KEY=...
       export AWS_SESSION_TOKEN=...        # only for temporary credentials

  2. A named/default profile via the AWS CLI:
       aws configure                       # writes ~/.aws/credentials
       python CVAWSCloudSizingScript.py --profiles=<name>

  3. AWS IAM Identity Center (SSO):
       aws sso login --profile <name>
       python CVAWSCloudSizingScript.py --profiles=<name>

  4. Run inside AWS (CloudShell, or EC2/ECS with an attached IAM role) -- no
     setup needed; the role is picked up automatically.

  5. Assume a role across accounts:
       python CVAWSCloudSizingScript.py --cross-account-role=<RoleName> \\
           --accounts=<id1>,<id2>

Verify whatever you configured with:  aws sts get-caller-identity
"""


def offer_aws_configure():
    """On an interactive TTY with the AWS CLI present, offer to run
    `aws configure`. Returns True if the default chain authenticates afterward.
    Suppressed by --no-input so CI runs never block on a prompt."""
    if OPTIONS["no_input"] or not (sys.stdin.isatty() and shutil.which("aws")):
        return False
    try:
        answer = input("\nRun 'aws configure' now to set up credentials? [y/N] ")
    except (EOFError, KeyboardInterrupt):
        return False
    if answer.strip().lower() not in ("y", "yes"):
        return False
    try:
        subprocess.run(["aws", "configure"], check=False)
    except OSError as exc:
        logging.error(f"Could not launch 'aws configure': {exc}")
        return False
    ok = resolve_identity(session_from_profile())[0]
    logging.info("Credentials configured successfully."
                 if ok else "Still unable to authenticate after 'aws configure'.")
    return ok


def print_credential_help(failures):
    """Log actionable, failure-kind-specific guidance for a zero-session run.

    Returns True only if the user interactively reconfigured credentials and the
    default chain now authenticates (so main can continue instead of exiting)."""
    for label, _kind, detail in failures:
        logging.error(f"Credential check failed for '{label}': {detail}")

    kind = common.dominant_failure_kind(failures)
    if kind == "expired":
        logging.error("AWS credentials have expired. Refresh them (e.g. "
                      "`aws sso login --profile <name>`, or rotate the access key) "
                      "and re-run.")
        return False
    if kind == "invalid_key":
        logging.error("AWS credentials were rejected. Check the access key / secret "
                      "(or the profile) and verify with `aws sts get-caller-identity`.")
        return False
    if kind == "access_denied":
        logging.error("The identity authenticated but was denied "
                      "sts:GetCallerIdentity. Grant that permission and re-run.")
        return False
    if kind == "profile_not_found":
        try:
            available = boto3.Session().available_profiles
        except Exception:
            available = []
        avail = ", ".join(available) if available else "(none configured)"
        logging.error(f"Named profile not found. Available profiles: {avail}. "
                      f"Create one with `aws configure --profile <name>`.")
        return False

    # no_credentials / other -> full setup menu, then the interactive offer.
    # Printed via the console so the multi-line block keeps its formatting
    # (the per-failure reasons above are already in the file log).
    logging.debug("No credentials authenticated; showing setup guidance.")
    common.console.print()
    common.console.print(CREDENTIAL_SETUP_GUIDANCE.rstrip("\n"),
                         markup=False, highlight=False)
    return offer_aws_configure()


def validate_args(args):
    """Reject nonsensical flag combinations before any AWS calls are made."""
    cross = bool(args.get("cross_account_role"))
    has_accounts = bool(args.get("accounts") or args.get("accounts_file"))

    if has_accounts and not cross:
        logging.error("--accounts/--accounts-file require --cross-account-role "
                      "(there is no role to assume into those accounts).")
        sys.exit(1)
    if cross and not has_accounts:
        logging.error("--cross-account-role requires --accounts or --accounts-file "
                      "(the accounts to assume the role in).")
        sys.exit(1)
    if not cross and OPTIONS["external_id"]:
        logging.warning("--external-id is ignored without --cross-account-role.")
    if not cross and OPTIONS["role_session_name"] != "CVAWS-Cost-Sizing":
        logging.warning("--role-session-name is ignored without --cross-account-role.")
    if args.get("regions") is not None and not args["regions"]:
        logging.error("--regions was provided but empty.")
        sys.exit(1)
    if args.get("profile_location") and not os.path.isfile(args["profile_location"]):
        logging.warning(f"--profile-location path does not exist: "
                        f"{args['profile_location']}")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
EXAMPLES = """\
examples:
  # default credentials, all regions, all workloads
  python CVAWSCloudSizingScript.py

  # just EC2 and S3 in two regions, using a named profile
  python CVAWSCloudSizingScript.py --profiles=prod --regions=us-east-1,us-west-2 --workload=ec2,s3

  # check credentials without collecting anything
  python CVAWSCloudSizingScript.py --validate-only

  # cross-account role assumption across two accounts
  python CVAWSCloudSizingScript.py --cross-account-role=InventoryRole --accounts=111111111111,222222222222

  # machine-readable output for scripting
  python CVAWSCloudSizingScript.py --json --regions=us-east-1 | jq .
"""

# Set in parse_args so collect_account can filter S3 by requested region.
requested_regions_flag = False


def build_parser():
    parser = argparse.ArgumentParser(
        prog="CVAWSCloudSizingScript.py",
        description="Inventory AWS resources across accounts/regions and write "
                    "Excel sizing workbooks for Commvault protection planning.",
        epilog=EXAMPLES,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    auth = parser.add_argument_group(
        "authentication", "default: standard credential chain "
        "(env / shared config / instance / CloudShell role)")
    auth.add_argument("--default-profile", action="store_true",
                      help="explicitly use the default credential chain")
    auth.add_argument("--profiles", type=common._csv, metavar="p1,p2",
                      help="named local AWS CLI profiles to use")
    auth.add_argument("--all-local-profiles", action="store_true",
                      help="use every profile in the AWS credentials file")
    auth.add_argument("--profile-location", metavar="PATH",
                      help="path to a custom shared-credentials file")
    auth.add_argument("--cross-account-role", metavar="NAME",
                      help="IAM role name to assume in each target account")
    auth.add_argument("--accounts", type=common._csv, metavar="ID,ID",
                      help="account IDs for cross-account role assumption")
    auth.add_argument("--accounts-file", metavar="PATH",
                      help="file of account IDs, one per line")
    auth.add_argument("--role-session-name", metavar="NAME",
                      default="CVAWS-Cost-Sizing",
                      help="STS session name (default: CVAWS-Cost-Sizing)")
    auth.add_argument("--external-id", metavar="ID",
                      help="external ID for cross-account role assumption")

    scope = parser.add_argument_group("scope")
    scope.add_argument("--regions", type=common._csv, metavar="r1,r2",
                       help="regions to query (default: all enabled regions)")
    scope.add_argument("--partition", default="", metavar="GovCloud",
                       help="use a non-standard AWS partition (e.g. GovCloud)")

    s3 = parser.add_argument_group("S3 options")
    s3.add_argument("--skip-bucket-tags", action="store_true",
                    help="do not fetch S3 bucket tags")
    s3.add_argument("--no-s3-enumerate", action="store_true",
                    help="disable object-enumeration fallback when CloudWatch "
                         "has no bucket-size metric")

    common.add_common_args(parser, __version__, WORKLOAD_CLASSES)
    return parser


def parse_args(argv):
    """Parse argv into a settings dict and populate the OPTIONS globals."""
    global requested_regions_flag
    ns = build_parser().parse_args(argv)
    requested_regions_flag = bool(ns.regions)

    OPTIONS["skip_bucket_tags"] = ns.skip_bucket_tags
    OPTIONS["s3_enumerate_fallback"] = not ns.no_s3_enumerate
    OPTIONS["partition"] = ns.partition or ""
    OPTIONS["role_session_name"] = ns.role_session_name
    OPTIONS["external_id"] = ns.external_id
    OPTIONS["cross_account_role"] = ns.cross_account_role
    OPTIONS["no_input"] = ns.no_input
    OPTIONS["json"] = ns.json
    OPTIONS["quiet"] = ns.quiet

    return {
        "default_profile": ns.default_profile,
        "profiles": ns.profiles,
        "all_local_profiles": ns.all_local_profiles,
        "profile_location": ns.profile_location,
        "cross_account_role": ns.cross_account_role,
        "accounts": ns.accounts,
        "accounts_file": ns.accounts_file,
        "regions": ns.regions,
        "workload": ns.workload,
        "validate_only": ns.validate_only,
        "json": ns.json,
        "quiet": ns.quiet,
        "verbose": ns.verbose,
        "no_color": ns.no_color,
        "no_input": ns.no_input,
    }


# --------------------------------------------------------------------------- #
# Cloud config: wire the AWS-specific hooks into the shared driver.
# --------------------------------------------------------------------------- #
def aws_collect(handle, scope_id, scope_name, args, workloads, reporter, label):
    """Driver hook: collect one account, driving the progress reporter by region."""
    session = handle
    regions = resolve_regions(session, args.get("regions"))
    reporter.start_account(label, len(regions))
    return collect_account(session, scope_id, scope_name, regions, workloads,
                           reporter=reporter, label=label)


def aws_describe_scope(handle, args):
    """Driver hook: the per-account line shown under --validate-only."""
    return f"{len(resolve_regions(handle, args.get('regions')))} region(s)"


AWS_CONFIG = common.CloudConfig(
    name="AWS",
    version=__version__,
    log_prefix="aws_sizing",
    comprehensive_label="all_aws_accounts",
    scope_noun="account",
    unit_noun="regions",
    workload_classes=WORKLOAD_CLASSES,
    parse_args=parse_args,
    validate_args=validate_args,
    build_sessions=build_sessions,
    collect=aws_collect,
    describe_scope=aws_describe_scope,
    print_credential_help=print_credential_help,
    noisy_loggers=("boto3", "botocore", "urllib3", "s3transfer"),
    banner_subtitle=lambda args: f"{OPTIONS['partition'] or 'standard'} partition",
    scope_already_filtered=lambda args: bool(
        args.get("profiles") or args.get("accounts") or args.get("accounts_file")
        or args.get("all_local_profiles") or args.get("cross_account_role")),
)


if __name__ == "__main__":
    common.run_sizing(AWS_CONFIG)
