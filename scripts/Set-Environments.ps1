#Requires -Version 7.2
<#
.SYNOPSIS
    Creates and updates Azure DevOps environments and their checks from environments/*.json.

.DESCRIPTION
    Idempotent: a second run changes nothing. Reads the configuration, compares it with Azure DevOps,
    prints the plan and applies it.
      -WhatIf  prints the plan and writes nothing.
      -Check   prints the plan, writes nothing and exits 1 when there is drift (for CI), else 0.
    Environments are never deleted unless you pass -RemoveUndefined together with -RemoveFilter.
    Checks of types this playbook does not manage (business hours, required template, ...) are left alone.

.EXAMPLE
    ./scripts/Set-Environments.ps1 -Organization my-org -Project my-project -WhatIf

.EXAMPLE
    ./scripts/Set-Environments.ps1 -Organization my-org -Project my-project -Path ./environments/prod.json -Check

.EXAMPLE
    ./scripts/Set-Environments.ps1 -Organization my-org -Project my-project -RemoveUndefined -RemoveFilter 'shop - dev - *'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Organisation name or URL. In a pipeline: $(System.CollectionUri).
    [string] $Organization = $env:SYSTEM_COLLECTIONURI,
    [string] $Project = $env:SYSTEM_TEAMPROJECT,
    # Files or folders with environment group files.
    [string[]] $Path = @((Join-Path $PSScriptRoot '..' 'environments')),
    [switch] $Check,
    [switch] $RemoveUndefined,
    [string[]] $RemoveFilter = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($file in 'Common', 'AzureDevOps', 'Config', 'Environments') { . (Join-Path $PSScriptRoot '..' 'lib' "$file.ps1") }

if (-not $Organization -or -not $Project) { throw 'Pass -Organization and -Project (or run in a pipeline, which sets them).' }

$groups = @(Read-EnvironmentConfig -Path $Path)
$connection = New-AzDevOpsConnection -Organization $Organization -Project $Project
$plan = @(Get-EnvironmentPlan -Connection $connection -Groups $groups -RemoveUndefined:$RemoveUndefined -RemoveFilter $RemoveFilter)
$changes = @($plan | Where-Object { $_.Action -ne 'Unmanaged' })

if ($Check) {
    Write-PlanSummary -Plan $plan -Title "Drift check for $($groups.Count) group(s)"
    if ($changes.Count -gt 0) {
        Write-Host "Drift: $($changes.Count) difference(s) between the configuration and Azure DevOps."
        exit 1
    }
    Write-Host 'No drift.'
    exit 0
}

Write-PlanSummary -Plan $plan -Title $(if ($WhatIfPreference) { 'Plan (WhatIf: nothing is changed)' } else { 'Plan' })
$applied = @(Invoke-EnvironmentPlan -Connection $connection -Plan $plan)
if (-not $WhatIfPreference) { Write-Host "Applied $($applied.Count) of $($changes.Count) change(s)." }
