#Requires -Version 7.2
<#
.SYNOPSIS
    Shows, offline, what deploy all, redeploy or remove would do for an environment: the waves and
    pipelines, or the resource groups in removal order. Refuses what the action guards refuse.

.EXAMPLE
    ./scripts/Get-OrchestrationPlan.ps1 -Action DeployAll -Environment test

.EXAMPLE
    ./scripts/Get-OrchestrationPlan.ps1 -Action Remove -Environment dev -Components messaging -Format Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('DeployAll', 'Redeploy', 'Remove')] [string] $Action,
    [Parameter(Mandatory)] [string] $Environment,
    # Remove only: these components and everything that depends on them.
    [string[]] $Components = @(),
    [string] $SystemPath = (Join-Path $PSScriptRoot '..' 'orchestration' 'system.json'),
    [ValidateSet('Text', 'Json')] [string] $Format = 'Text'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($file in 'Common', 'Config', 'Orchestration') { . (Join-Path $PSScriptRoot '..' 'lib' "$file.ps1") }

$system = Read-SystemConfig -Path $SystemPath
Assert-EnvironmentAction -System $system -Environment $Environment -Action $Action
$plan = if ($Action -eq 'Remove') { @(Get-RemovalPlan -System $system -Environment $Environment -Components $Components) }
else { @(Get-DeploymentPlan -System $system -Environment $Environment) }

if ($Format -eq 'Json') { ConvertTo-Json -InputObject @($plan) -Depth 5; return }
Write-OrchestrationPlan -Plan @($plan) -Title "$Action $Environment"
