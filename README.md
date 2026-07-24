# Cloud Sizing Scripts

This repository contains scripts for cloud resource discovery. They help Commvault representatives gather information about cloud resources that may need protection and estimate the cost of protecting them.

## Quick start

Clone the repo and run the script for your cloud from `src/` — no build step required:

```powershell
git clone <repo-url>
cd dy-cloud-sizing-scripts/src

# install the prerequisites for your cloud first (see docs/), then:
./CVAWSCloudSizingScript.ps1    -DefaultProfile -Regions "us-east-1"
./CVAzureCloudSizingScript.ps1  -Types VM,Storage
./CVGoogleCloudSizingScript.ps1 -Types VM,Storage
```

Each script loads the shared console/diagnostics layer from `common/` automatically. Add `-NonInteractive` for plain, pipe-safe output (CI / automation). Setup and full parameter details are in the per-cloud docs below.

## Repository layout

```
src/                 All sizing scripts (run these directly)
  CVAWSCloudSizingScript.ps1
  CVAzureCloudSizingScript.ps1
  CVGoogleCloudSizingScript.ps1
  CVM365SizingScript.ps1
  FetchAllAccountCreds.ps1          AWS multi-account SSO helper
  common/CVSizing.Console.ps1       Shared console/diagnostics layer (loaded by the scripts)
  OCI/                              Oracle Cloud sizing (Python subproject)
docs/                Per-cloud setup & run instructions (AWS.md, Azure.md, GoogleCloud.md)
tests/               Dependency-free test suite for the shared console layer
tools/               Show-CVConsoleDemo.ps1 - visual demo of the console layer
k8s/                 Dockerfiles, entrypoints and Job manifests for containerized runs
Output/              Run output (CSV/JSON/Excel + ZIP), one timestamped subfolder per run   (git-ignored)
Logs/                Run logs, one file per run                                              (git-ignored)
```

Every run writes its output to `Output/<cloud>_<timestamp>/` (with the ZIP beside it) and its log to `Logs/<cloud>_<timestamp>.log`, at the repository top level. When a script is run outside a repository, those folders are created in the current directory instead.

## Scripts

| Cloud | Script | Setup |
|---|---|---|
| **AWS** | `src/CVAWSCloudSizingScript.ps1` | [docs/AWS.md](docs/AWS.md) |
| **Azure** | `src/CVAzureCloudSizingScript.ps1` | [docs/Azure.md](docs/Azure.md) |
| **Google Cloud** | `src/CVGoogleCloudSizingScript.ps1` | [docs/GoogleCloud.md](docs/GoogleCloud.md) |
| **OCI** | `src/OCI/CVOracleCloudSizingScript.py` | [src/OCI/README.md](src/OCI/README.md) |
| **M365** | `src/CVM365SizingScript.ps1` | (inline `-?` help) |

The AWS/Azure/GCP PowerShell scripts share a polished terminal UI and unified error handling via `src/common/CVSizing.Console.ps1`. `PwshSpectreConsole` is required for the interactive UI; runs started with `-NonInteractive` fall back to plain, pipe-safe output (used by the containerized Jobs in `k8s/`).
