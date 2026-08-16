<#
.SYNOPSIS
    Prints everything needed to work out why WSL is not cooperating.

.DESCRIPTION
    Read-only. Changes nothing. Run it, paste the whole output.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\diagnose.ps1
#>

$ErrorActionPreference = "Continue"

function Section($name) {
    Write-Host ""
    Write-Host "===== $name =====" -ForegroundColor Cyan
}

Section "Windows"
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
Write-Host "Caption      : $($os.Caption)"
Write-Host "Version      : $($os.Version)"
Write-Host "Build        : $($os.BuildNumber)"
Write-Host "RAM (GB)     : $([math]::Round($cs.TotalPhysicalMemory / 1GB, 1))"
Write-Host "CPUs         : $($cs.NumberOfLogicalProcessors)"
Write-Host "Hypervisor   : $($cs.HypervisorPresent)"

Section "Administrator?"
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Elevated     : $isAdmin"

Section "Optional features"
foreach ($f in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform", "HypervisorPlatform")) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue).State
    if (-not $state) { $state = "(not present on this edition)" }
    Write-Host ("{0,-40} {1}" -f $f, $state)
}

Section "Pending reboot?"
$pending = $false
$keys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
)
foreach ($k in $keys) {
    if (Test-Path $k) { $pending = $true; Write-Host "pending: $k" }
}
if (-not $pending) { Write-Host "no reboot flags set" }

Section "wsl --version"
wsl --version 2>&1 | Out-Host

Section "wsl --status"
wsl --status 2>&1 | Out-Host

Section "wsl --list --verbose"
wsl --list --verbose 2>&1 | Out-Host

Section "wsl --list --online"
wsl --list --online 2>&1 | Out-Host

Section ".wslconfig"
$cfg = Join-Path $env:USERPROFILE ".wslconfig"
if (Test-Path $cfg) { Get-Content $cfg | Out-Host } else { Write-Host "(none)" }

Section "Docker on the Windows side"
foreach ($exe in @("docker", "kubectl", "kind", "helm", "terraform")) {
    $cmd = Get-Command $exe -ErrorAction SilentlyContinue
    if ($cmd) { Write-Host ("{0,-12} {1}" -f $exe, $cmd.Source) }
    else      { Write-Host ("{0,-12} not on PATH" -f $exe) }
}

Write-Host ""
Write-Host "Copy everything above and paste it back." -ForegroundColor Green
