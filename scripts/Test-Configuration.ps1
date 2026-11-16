#Requires -Version 7.2
<#
.SYNOPSIS
    Validates environments/*.json and orchestration/system.json offline: schemas, rules and the
    consistency between them. Exits 1 when there are problems, else 0. Needs no credentials.

.EXAMPLE
    ./scripts/Test-Configuration.ps1
#>
[CmdletBinding()]
param(
    [string[]] $EnvironmentsPath = @((Join-Path $PSScriptRoot '..' 'environments')),
    [string] $SystemPath = (Join-Path $PSScriptRoot '..' 'orchestration' 'system.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($file in 'Common', 'Config', 'Orchestration') { . (Join-Path $PSScriptRoot '..' 'lib' "$file.ps1") }

$environments = Get-EnvironmentConfigResult -Path $EnvironmentsPath
$system = Get-SystemConfigResult -Path $SystemPath
$problems = @($environments.Problems) + @($system.Problems)
if ($problems.Count -eq 0) {
    $problems = @(Get-CrossConfigProblem -System $system.System -Groups $environments.Groups)
}

if ($problems.Count -gt 0) {
    Write-Host "Configuration has $($problems.Count) problem(s):"
    foreach ($problem in $problems) { Write-Host " - $problem" }
    exit 1
}
$count = @($environments.Groups | ForEach-Object { $_.Environments }).Count
Write-Host "Configuration is valid: $($environments.Groups.Count) group(s), $count environment(s), $($system.System.Components.Count) component(s)."
exit 0
