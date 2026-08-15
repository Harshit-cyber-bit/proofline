<#
.SYNOPSIS
    Prepares Windows to run proofline: enables WSL2, installs Ubuntu, and
    configures resource limits and systemd.

.DESCRIPTION
    Run this ONCE, in an Administrator PowerShell. It does not install Docker --
    Docker Engine goes inside WSL2, installed by bootstrap-wsl.sh, which avoids
    Docker Desktop entirely (no licence question, no separate service, and the
    cgroup v2 layout the Ansible fleet needs).

    Safe to re-run. Every step checks whether it is already done.

.EXAMPLE
    # In an Administrator PowerShell:
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    .\bootstrap-windows.ps1
#>

[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-24.04",

    # Memory ceiling for the WSL2 VM. proofline needs roughly 6 GB with
    # monitoring, 4 GB without. Leave at least 4 GB for Windows itself.
    [string]$WslMemory = "8GB",

    [int]$WslProcessors = 4
)

$ErrorActionPreference = "Stop"

function Write-Step($message) {
    Write-Host ""
    Write-Host "==> $message" -ForegroundColor Cyan
}

function Write-Ok($message) {
    Write-Host "    ok   $message" -ForegroundColor Green
}

function Write-Warn($message) {
    Write-Host "    warn $message" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- preflight

Write-Step "Checking prerequisites"

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "This script must run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> 'Run as administrator', then re-run."
    exit 1
}
Write-Ok "running as Administrator"

$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
if ($build -lt 19041) {
    Write-Host "Windows build $build is too old for WSL2 (need 19041+)." -ForegroundColor Red
    exit 1
}
Write-Ok "Windows build $build supports WSL2"

# Virtualisation must be on in firmware. Without it WSL2 fails with an error
# that reads like a Windows problem rather than a BIOS setting.
$virt = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
if (-not $virt) {
    Write-Warn "hardware virtualisation does not appear to be enabled"
    Write-Warn "if WSL2 fails below, enable Intel VT-x / AMD-V in your BIOS"
} else {
    Write-Ok "hardware virtualisation available"
}

$totalGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
Write-Ok "$totalGb GB total RAM detected"

if ($totalGb -le 8) {
    Write-Warn "with $totalGb GB, use WslMemory of 5GB and skip the monitoring stage"
    Write-Warn "  re-run as: .\bootstrap-windows.ps1 -WslMemory 5GB -WslProcessors 2"
}

# ------------------------------------------------------------------- wsl2

Write-Step "Enabling WSL2"

$needsReboot = $false

$features = @(
    "Microsoft-Windows-Subsystem-Linux",
    "VirtualMachinePlatform"
)

foreach ($feature in $features) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
    if ($state -eq "Enabled") {
        Write-Ok "$feature already enabled"
    } else {
        Write-Host "    enabling $feature ..."
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature `
            -All -NoRestart
        if ($result.RestartNeeded) { $needsReboot = $true }
        Write-Ok "$feature enabled"
    }
}

if ($needsReboot) {
    Write-Host ""
    Write-Host "A reboot is required before continuing." -ForegroundColor Yellow
    Write-Host "Reboot, then run this script again -- it will pick up where it left off."
    exit 0
}

Write-Step "Updating the WSL kernel"
try {
    wsl --update | Out-Host
    Write-Ok "kernel up to date"
} catch {
    Write-Warn "wsl --update failed: $($_.Exception.Message)"
    Write-Warn "continuing; the distro install below will report if this matters"
}

wsl --set-default-version 2 | Out-Host
Write-Ok "WSL2 is the default version"

# ------------------------------------------------------------------ distro

Write-Step "Installing $Distro"

# `wsl --list` emits UTF-16, which mangles a naive -match. Normalise first.
$installed = (wsl --list --quiet) -replace "`0", "" -split "`r?`n" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne "" }

if ($installed -contains $Distro) {
    Write-Ok "$Distro already installed"
} else {
    Write-Host "    this downloads ~500 MB and takes a few minutes ..."
    wsl --install -d $Distro --no-launch | Out-Host
    Write-Ok "$Distro installed"
    Write-Host ""
    Write-Host "First launch will ask you to create a UNIX username and password." -ForegroundColor Yellow
    Write-Host "Pick anything you will remember -- you need the password for sudo."
}

# ------------------------------------------------------------------ config

Write-Step "Writing .wslconfig"

# Without a ceiling, WSL2 will claim up to half of physical RAM and hold it.
# With a kind cluster plus Prometheus inside, that becomes noticeable.
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$wslConfig = @"
# Written by proofline bootstrap-windows.ps1
[wsl2]
memory=$WslMemory
processors=$WslProcessors
swap=2GB

# Frees cached memory back to Windows instead of holding the high-water mark
# for the life of the VM.
autoMemoryReclaim=gradual

# The kind cluster's NodePorts (Prometheus 30090, Grafana 30300) are reachable
# from Windows at localhost with this on.
localhostForwarding=true
"@

if (Test-Path $wslConfigPath) {
    $backup = "$wslConfigPath.proofline-backup"
    if (-not (Test-Path $backup)) {
        Copy-Item $wslConfigPath $backup
        Write-Ok "backed up your existing .wslconfig to $backup"
    }
}

Set-Content -Path $wslConfigPath -Value $wslConfig -Encoding ASCII
Write-Ok "$wslConfigPath written ($WslMemory, $WslProcessors CPUs)"

# ----------------------------------------------------------------- systemd

Write-Step "Enabling systemd inside $Distro"

# systemd is not optional here. The Ansible fleet runs systemd inside Docker
# containers so the roles can manage real units and therefore work unchanged
# against EC2. That needs a systemd-managed cgroup hierarchy on the host.
$wslConf = "[boot]`nsystemd=true`n"

try {
    wsl -d $Distro -u root -- bash -lc "printf '%s' '$wslConf' > /etc/wsl.conf"
    Write-Ok "systemd enabled in /etc/wsl.conf"
} catch {
    Write-Warn "could not write /etc/wsl.conf: $($_.Exception.Message)"
    Write-Warn "if $Distro has not been launched yet, open it once, create your"
    Write-Warn "user, then re-run this script."
    exit 1
}

Write-Step "Restarting WSL so the settings take effect"
wsl --shutdown
Start-Sleep -Seconds 5
Write-Ok "WSL restarted"

# -------------------------------------------------------------------- done

Write-Host ""
Write-Host "Windows side is ready." -ForegroundColor Green
Write-Host ""
Write-Host "Next, in a normal (non-admin) terminal:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  wsl -d $Distro"
Write-Host ""
Write-Host "then inside Ubuntu:"
Write-Host ""
Write-Host "  cd ~ && unzip /mnt/c/Users/$env:USERNAME/Downloads/proofline.zip"
Write-Host "  cd proofline && bash hack/windows/bootstrap-wsl.sh"
Write-Host ""
Write-Host "That second script installs everything else and runs the whole demo."
Write-Host ""
