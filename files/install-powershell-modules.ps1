#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Installs the PowerShell modules listed in a text file (one per line, '#' comments
  allowed) from the PowerShell Gallery for ALL users and applies PowerCLI defaults.
  Runs as root while the execution environment image is built.
#>
param([Parameter(Mandatory = $true)][string]$ModuleList)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$modules = Get-Content $ModuleList |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') }

Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

foreach ($module in $modules) {
    Write-Host "==> Installing PowerShell module $module"
    Install-Module -Name $module -Scope AllUsers -AcceptLicense -AllowClobber -Force
}

if ($modules | Where-Object { $_ -ieq 'VMware.PowerCLI' }) {
    Write-Host '==> PowerCLI defaults: ignore invalid certificates, no CEIP'
    Set-PowerCLIConfiguration -Scope AllUsers -InvalidCertificateAction Ignore -ParticipateInCeip $false -Confirm:$false | Out-Null
}

Write-Host '==> Installed modules (top level)'
foreach ($module in $modules) {
    $m = Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $m) { throw "module $module is not available after installation" }
    Write-Host ("    {0,-28} {1}" -f $m.Name, $m.Version)
}
