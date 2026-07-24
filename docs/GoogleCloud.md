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
    pipe-safe text and do not need it. The script is deliberately opinionated about broad discovery: `gcloud`,
    `gsutil` (bucket sizing) and `bq` (BigQuery sizing) are all **required** and the preflight fails fast if any
    is missing. `kubectl` (GKE) is the one exception — the script auto-provisions it when absent.

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
The script writes CSV summaries and any JSON output to `Output/gcp_<timestamp>/` (with a `.zip` archive beside it) and the run log to `Logs/gcp_<timestamp>.log`, at the repository top level. In Cloud Shell you can download these via the built‑in file browser. Share the ZIP or individual CSVs with the team as needed.

