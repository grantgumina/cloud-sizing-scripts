<#
    CVSizing.Kubectl.ps1 - One cross-platform kubectl provisioner shared by the AWS, Azure and GCP scripts.

    Replaces three divergent copies, each broken differently:
      - Azure  hardcoded /tmp/kubectl AND always downloaded bin/linux/amd64/kubectl. On macOS that writes a Linux
               ELF binary, chmod +x succeeds, and every later kubectl call fails with an exec-format error. It
               then hardcoded /tmp into PATH instead of using the resolved directory.
      - GCP    hardcoded /tmp/kubectl-bin and pinned $arch = 'amd64' - wrong on Apple Silicon and Graviton.
      - AWS    hardcoded C:\kubectl, and its non-Windows branch only printed "install manually", so -Types EKS
               silently produced no persistent-volume data on macOS/Linux while the other two auto-provisioned.

    Rules: temp via [IO.Path]::GetTempPath(), never a literal /tmp or C:\. Architecture from the runtime, never
    assumed. PATH joined with [IO.Path]::PathSeparator, never a literal ';' or ':'.

    Get-CVKubectlPlatform is pure and injectable so tests/Invoke-CVEnvironmentTests.ps1 can assert URL and
    directory resolution for win-amd64 / linux-amd64 / darwin-arm64 without downloading anything.
#>

function Get-CVKubectlPlatform {
    <#
      .SYNOPSIS  Resolve the kubectl download descriptor for a platform.
      .DESCRIPTION Defaults to the current runtime. Override -OS/-Architecture in tests.
      .OUTPUTS   pscustomobject { OS; Architecture; FileName; UrlPath; IsWindows }
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('windows', 'darwin', 'linux')][string]$OS,
        [ValidateSet('amd64', 'arm64')][string]$Architecture
    )

    if (-not $OS) {
        $OS = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'windows' }
              elseif ($IsMacOS)                            { 'darwin' }
              else                                         { 'linux' }
    }
    if (-not $Architecture) {
        # OSArchitecture is the authoritative runtime answer; the previous scripts assumed amd64 outright.
        $Architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
            'Arm64' { 'arm64' }
            'Arm'   { 'arm64' }
            default { 'amd64' }
        }
    }

    $fileName = if ($OS -eq 'windows') { 'kubectl.exe' } else { 'kubectl' }
    return [pscustomobject]@{
        OS           = $OS
        Architecture = $Architecture
        FileName     = $fileName
        UrlPath      = "bin/$OS/$Architecture/$fileName"
        IsWindows    = ($OS -eq 'windows')
    }
}

function Get-CVKubectlInstallDir {
    <# .SYNOPSIS  A writable, platform-appropriate directory for a provisioned kubectl. #>
    [CmdletBinding()]
    param([string]$BaseDir)
    if (-not $BaseDir) { $BaseDir = [IO.Path]::GetTempPath() }
    return [IO.Path]::Combine($BaseDir, 'cv-sizing-kubectl')
}

function Add-CVPathSegment {
    <# .SYNOPSIS  Prepend a directory to PATH using the platform's separator. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory)
    if (-not $Directory) { return }
    $sep = [IO.Path]::PathSeparator
    if (($env:PATH -split $sep) -notcontains $Directory) { $env:PATH = $Directory + $sep + $env:PATH }
}

function Install-CVKubectl {
    <#
      .SYNOPSIS  Ensure kubectl is available, downloading a matching build only if needed.
      .DESCRIPTION Prefers an already-installed kubectl. Otherwise downloads the stable release for THIS os/arch
                   into a temp directory and prepends it to PATH. Never throws - callers degrade gracefully.
      .OUTPUTS   pscustomobject { Path; Dir; Installed; Source; Platform; Error }
                 Source: Existing | Downloaded | None
    #>
    [CmdletBinding()]
    param(
        [switch]$Force,
        [string]$BaseDir,
        [int]$TimeoutSec = 120
    )

    $platform = Get-CVKubectlPlatform
    $result = [pscustomobject]@{
        Path      = $null
        Dir       = $null
        Installed = $false
        Source    = 'None'
        Platform  = "$($platform.OS)-$($platform.Architecture)"
        Error     = $null
    }

    if (-not $Force) {
        $existing = $null
        try { $existing = (Get-Command kubectl -ErrorAction SilentlyContinue).Source } catch { $existing = $null }
        if ($existing) {
            $result.Path      = $existing
            $result.Dir       = Split-Path -Parent $existing
            $result.Installed = $true
            $result.Source    = 'Existing'
            return $result
        }
    }

    $dir  = Get-CVKubectlInstallDir -BaseDir $BaseDir
    $dest = [IO.Path]::Combine($dir, $platform.FileName)

    if ((Test-Path -LiteralPath $dest -PathType Leaf) -and -not $Force) {
        Add-CVPathSegment -Directory $dir
        $result.Path = $dest; $result.Dir = $dir; $result.Installed = $true; $result.Source = 'Existing'
        return $result
    }

    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }

        $stable = (Invoke-RestMethod -Uri 'https://dl.k8s.io/release/stable.txt' -TimeoutSec 30 -ErrorAction Stop).ToString().Trim()
        $url    = "https://dl.k8s.io/release/$stable/$($platform.UrlPath)"
        Invoke-WebRequest -Uri $url -OutFile $dest -TimeoutSec $TimeoutSec -ErrorAction Stop

        if (-not $platform.IsWindows) {
            # Best-effort; a non-executable file is caught by the verification below rather than assumed working.
            try { & chmod +x $dest 2>$null } catch { }
        }

        # Verify it actually RUNS. This is what catches the old "Linux binary on macOS" failure, which silently
        # produced a chmod-ed file that every later invocation failed on.
        $ok = $false
        try {
            $probe = & $dest version --client=true --output=yaml 2>&1
            $ok = ($LASTEXITCODE -eq 0 -and "$probe" -match 'gitVersion|clientVersion')
        } catch { $ok = $false }

        if (-not $ok) {
            $result.Error = "Downloaded kubectl for $($result.Platform) did not execute successfully."
            return $result
        }

        Add-CVPathSegment -Directory $dir
        $result.Path = $dest; $result.Dir = $dir; $result.Installed = $true; $result.Source = 'Downloaded'
        return $result
    } catch {
        $result.Error = $_.Exception.Message
        return $result
    }
}
