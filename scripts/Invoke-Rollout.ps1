#Requires -Version 7.2
<#
.SYNOPSIS
    Deploys a complete environment (DeployAll) or deploys the last successful versions again
    (Redeploy), by queueing the component pipelines wave by wave in dependency order.

.DESCRIPTION
    Each wave starts only after every run of the previous wave succeeded. The component pipelines
    deploy through their own deployment jobs, so the checks of their Azure DevOps environments
    (exclusive lock, branch control, approvals) still apply. -WhatIf shows the plan and queues nothing.

.EXAMPLE
    ./scripts/Invoke-Rollout.ps1 -Organization my-org -Project my-project -Environment test -Mode DeployAll -WhatIf

.EXAMPLE
    ./scripts/Invoke-Rollout.ps1 -Organization my-org -Project my-project -Environment dev -Mode Redeploy
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Organization = $env:SYSTEM_COLLECTIONURI,
    [string] $Project = $env:SYSTEM_TEAMPROJECT,
    [Parameter(Mandatory)] [string] $Environment,
    [Parameter(Mandatory)] [ValidateSet('DeployAll', 'Redeploy')] [string] $Mode,
    [string] $SystemPath = (Join-Path $PSScriptRoot '..' 'orchestration' 'system.json'),
    [ValidateRange(1, 3600)] [int] $PollSeconds = 30,
    [ValidateRange(1, 1440)] [int] $TimeoutMinutes = 180,
    [scriptblock] $Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds }
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($file in 'Common', 'AzureDevOps', 'Config', 'Orchestration', 'Environments', 'Rollout') { . (Join-Path $PSScriptRoot '..' 'lib' "$file.ps1") }

if (-not $Organization -or -not $Project) { throw 'Pass -Organization and -Project (or run in a pipeline, which sets them).' }

$system = Read-SystemConfig -Path $SystemPath
Assert-EnvironmentAction -System $system -Environment $Environment -Action $Mode
$connection = New-AzDevOpsConnection -Organization $Organization -Project $Project
$plan = @(Get-RolloutPlan -Connection $connection -System $system -Environment $Environment -Mode $Mode)
Write-OrchestrationPlan -Plan $plan -Title "$Mode $Environment$(if ($WhatIfPreference) { ' (WhatIf: nothing is queued)' })"

$results = @(Invoke-RolloutPlan -Connection $connection -Plan $plan -Environment $Environment -PollSeconds $PollSeconds -TimeoutMinutes $TimeoutMinutes -Sleep $Sleep)
foreach ($result in $results) { Write-Host "wave $($result.Wave)  $($result.Component.PadRight(14)) run $($result.RunId): $($result.Result)" }
$results
