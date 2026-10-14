### Google Cloud - Execution Instructions

Below are two ways to run the Google Cloud sizing script. Method 1 (Local Powershell) is the recommended as Google Cloud Shell timeouts long processes leading to non graceful terminations of the execution.

### Environment Definitions
The term "environment" here refers to the scale of the Google Cloud (GC) environment in use. The scale is categorized based on the number of projects, as defined below:

1. Small-Scale GC Environments: Up to 10 projects

2. Medium-Scale GC Environments: Up to 50 projects

3. Large-Scale GC Environments: More than 50 projects

#### Method 1 (Recommendation: **Medium to Large Scale GC Environments**) – Run Locally with PowerShell 7

1. Install PowerShell 7:
    https://github.com/PowerShell/PowerShell/releases

2. Install Google Cloud SDK:
    https://cloud.google.com/sdk/docs/install

    Then install the console UI module (`PwshSpectreConsole`) for the polished progress / summary output:
    ```powershell
    Install-Module PwshSpectreConsole -Scope CurrentUser -Force
    ```
    Required for interactive runs; headless / automation runs started with `-NonInteractive` fall back to plain,
    pipe-safe text and do not need it. `gcloud` is **required** and the preflight fails fast if it is missing.
    `gsutil` and `bq` are no longer used: buckets and BigQuery are sized from Cloud Monitoring (see
    [How buckets and BigQuery are sized](#how-buckets-and-bigquery-are-sized)). `kubectl` (GKE) is auto-provisioned
    when absent.

3. Authenticate:
    ```powershell
    gcloud auth login
    ```

4. Verify permissions:
    Ensure the authenticated account has Viewer (or higher) on each project you want to include.

5. Change to the script directory (where this repo was cloned/unzipped):
    ```powershell
    cd ./GoogleCloud
    ```

6. (Windows only, first run) If script execution is blocked you may need (in an elevated PowerShell):
    ```powershell
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
    ```

7. Run the script (same parameter syntax as Cloud Shell examples below).

#### Method 2 (Recommendedation: **Small Scale GC Environments**) – Run in Google Cloud Shell

1. (Optional) Review Cloud Shell basics:
    https://cloud.google.com/shell/docs

2. Confirm permissions:
    Your identity must have at least the Viewer role (or equivalent list/get permissions) on each target project.

3. Launch Cloud Shell:
    - Sign in to the Google Cloud Console.
    - Click the Cloud Shell (terminal) icon.

4. Get the scripts into Cloud Shell:
    - Clone the repo and change into `src/`: `git clone <repo-url>` then `cd dy-cloud-sizing-scripts/src`.
      (The script loads its shared console layer from `common/` next to it, so run it from `src/`.)
    - Enter PowerShell:
      ```bash
      pwsh
      ```
    - (Optional) Make executable:
      ```bash
      chmod +x CVGoogleCloudSizingScript.ps1
      ```

5. Run the script (examples below). With no parameters it scans all accessible projects and all supported workload types.

#### Common Parameters
* `-Projects`  Comma‑separated list of GCP project IDs. Omit to include all projects visible to your credentials.
* `-Types`     Comma‑separated list of workload types to limit discovery (e.g. `VM,Storage,Fileshare`). Omit for all supported types.
* `-NonInteractive` / `-Quiet`  Plain, pipe‑safe output for CI / automation (no progress bars or rich UI). Auto‑enabled when output is not a terminal.
* (Review the script header for any advanced/optional parameters.)

#### Example Invocations
```powershell
# All workloads in all accessible projects
./CVGoogleCloudSizingScript.ps1

# Only VM and Storage workloads in all accessible projects
./CVGoogleCloudSizingScript.ps1 -Types VM,Storage

# All workloads in specific projects
./CVGoogleCloudSizingScript.ps1 -Projects my-gcp-project-1,my-gcp-project-2

# Only VMs in specific projects
./CVGoogleCloudSizingScript.ps1 -Types VM -Projects my-gcp-project-1,my-gcp-project-2
```

#### Results & Output
The script writes CSVs and any JSON output to `Output/gcp_<timestamp>/` (with a `.zip` archive beside it) and the run log to `Logs/gcp_<timestamp>.log`, at the repository top level. In Cloud Shell you can download these via the built‑in file browser. Share the ZIP or individual CSVs with the team as needed. The loose files are always kept — the ZIP is a copy, not a move — and if the archive cannot be written the script says so explicitly and points at the folder instead of claiming success.

**Every CSV is pure CSV**: one header, one row per resource, nothing appended. Four files used to carry a trailing `Summary:` block whose aggregate row parsed as data — on `gcp_disk_snapshots_*.csv` that made `sum(StorageTB)` return exactly twice the real total.

- `gcp_inventory_summary_<ts>.csv` — the rollup, in four tiers: overall, overall by region, per project, then per project by region. Columns: `Project`, `ResourceType`, `Region`, `Count`, `TotalSizeGB`, `TotalSizeTB`, `TotalSizeTiB` — the same seven Azure and AWS publish. The old `Level` and `Zone` columns are gone: `Level` was fully derivable from `(Project, Region)`, and zone detail moved to its own file. Each database service (Cloud SQL, Spanner, AlloyDB, BigQuery) now gets its own row stating its basis, instead of one fused total that mixed provisioned disk with a derived capacity ceiling.
- `gcp_vm_zone_rollup_<ts>.csv` — per-zone VM capacity (`Project`, `Region`, `Zone`, `VMCount`, sizes). Computed from VM rows, so regional persistent disks are attributed to the zone of the VM using them; the previous in-summary zone tier stamped regional disks `Zone=''` and silently lost their capacity.
- `gcp_<service>_*.csv` — one row per resource, full metadata, for VMs, attached and unattached disks, buckets, Filestore, GKE clusters and their PVs/PVCs, disk snapshots, Cloud SQL, Spanner, AlloyDB and BigQuery. `gcp_bigquery_tables_*.csv` is no longer produced (see below).

#### How buckets and BigQuery are sized

Both are read from **Cloud Monitoring**: one query per project, however many objects or tables it holds. The previous method listed every object in every bucket (`gsutil du -s`, 1,000 objects per request) and started a separate `bq show` process for every BigQuery table, which is how large environments took several hours.

| | Cloud Storage | BigQuery |
|---|---|---|
| Metric | `storage.googleapis.com/storage/v2/total_bytes` | `bigquery.googleapis.com/storage/stored_bytes`, `storage/table_count` |
| Size reported | Live objects (`UsedCapacity*`); noncurrent versions in `NoncurrentVersionBytes`; soft-deleted and multipart-upload bytes excluded | **Logical** bytes (`TotalLogicalSizeGB`, also `StorageGB`). Physical bytes are not available from Monitoring, so `TotalPhysicalSizeGB` is blank |
| Freshness | Measured **once a day**: up to ~24h old | Sampled every 30 min, visible up to 3h later |
| Per-item detail | — | Largest table per dataset (`LargestTable`, `LargestTableLogicalGB`); there is no per-table CSV |

Each bucket and dataset row carries `SizeSource`, `SizeStatus` and `SizeNote`. A blank size means **not measured**, never zero:

- `Ok` — measured.
- `Empty` — measured as empty (buckets: none of the metric's series and the bucket is over 48h old, because Monitoring does not track empty buckets; datasets: zero tables).
- `NotYetMeasured` / `NoDatapoint` — too new to have been measured, or no datapoint; size blank.
- `Error` — the Monitoring query failed for that project (for example, the Cloud Monitoring API is disabled or permission is denied); size blank, reason in `SizeNote`.

If Cloud Monitoring cannot be read for a project (API disabled, or no permission), its buckets and datasets are still listed with blank sizes, and:

- `gcp_project_status_storage_<ts>.csv` and the new `gcp_project_status_bigquery_<ts>.csv` show `SizeStatus = Error` with the reason in `SizeError`, and a blank (not 0) total for that project. `Status` there still describes listing only.
- The end of the run prints which projects are affected, grouped by cause, with the fix for each — for a disabled API, `gcloud services enable monitoring.googleapis.com --project <id>`. The `gcp_inventory_summary` totals exclude those projects' sizes.

Permissions: **Viewer** already includes `monitoring.timeSeries.list` and `bigquery.datasets.get`. With custom roles, grant **Monitoring Viewer** (`roles/monitoring.viewer`) and **BigQuery Metadata Viewer** (`roles/bigquery.metadataViewer`). The `gcp_inventory_summary` BigQuery row is now labelled `BigQuery Dataset (logical)`; it previously summed physical bytes.
- `gcp_resilience_signals_<ts>.csv` *(unless `-SkipResilienceReport`)* — raw cyber-resilience signal values; the backend applies the thresholds. A blank cell means **not collected**, never "no", and the `*DataStatus` columns say why. See [CYBER_RESILIENCE_SIGNALS.md](../CYBER_RESILIENCE_SIGNALS.md).
- `gcp_cloudrewind_*.csv` *(unless `-SkipCloudRewind`)* — billable-resource sizing.

> **Filestore and GKE backup coverage changed meaning.** `HasBackup` and `HasBackupPlan` were computed per *project*, so one backup or plan anywhere marked every share or cluster in that project as protected. They are now matched to the individual resource, so previously-"protected" resources will start reporting gaps on a Critical control. Those resources were never verified as protected.

