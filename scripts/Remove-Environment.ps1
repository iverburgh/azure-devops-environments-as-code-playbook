#Requires -Version 7.2
<#
.SYNOPSIS
    Removes (tears down) an environment: deletes its resource groups in reverse dependency order.

.DESCRIPTION
    Guards, in order - all of them also apply with -WhatIf, except the confirmation:
      1. The environment must exist in system.json, must not be protected, must not have a
         production-like name, and must have "remove": true.
      2. -Confirmation must be the exact environment name.
      3. Any management lock stops the removal before anything is deleted, unless -IgnoreLocks.
    -Components removes only those components and everything that depends on them.
    In a pipeline also pass -Confirm:$false (the typed confirmation is the guard there).

.EXAMPLE
    ./scripts/Remove-Environment.ps1 -Environment dev -WhatIf

.EXAMPLE
    ./scripts/Remove-Environment.ps1 -Environment dev -Components messaging -Confirmation dev
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $Environment,
    [string[]] $Components = @(),
    [string] $Confirmation = '',
    [switch] $IgnoreLocks,
    [string] $SystemPath = (Join-Path $PSScriptRoot '..' 'orchestration' 'system.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($file in 'Common', 'AzureCli', 'Config', 'Orchestration', 'Removal') { . (Join-Path $PSScriptRoot '..' 'lib' "$file.ps1") }

$system = Read-SystemConfig -Path $SystemPath
Assert-EnvironmentAction -System $system -Environment $Environment -Action Remove
Assert-RemovalConfirmed -Environment $Environment -Confirmation $Confirmation -WhatIfMode:$WhatIfPreference

$plan = @(Get-RemovalPlan -System $system -Environment $Environment -Components $Components)
Write-OrchestrationPlan -Plan $plan -Title "Remove $Environment$(if ($WhatIfPreference) { ' (WhatIf: nothing is deleted)' })"
$subscriptionId = $system.Environments[$Environment].SubscriptionId
$results = @(Invoke-EnvironmentRemoval -Plan $plan -SubscriptionId $subscriptionId -IgnoreLocks:$IgnoreLocks)
foreach ($result in $results) { Write-Host ("  {0,2}. {1,-28} {2}" -f $result.Step, $result.ResourceGroup, $result.Result) }
$results
