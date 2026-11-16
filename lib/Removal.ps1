Set-StrictMode -Version Latest

<#
    Removes the resource groups of an environment in the order of Get-RemovalPlan (dependents first).
    Guards (prod, confirmation) live in Orchestration.ps1 and the entry script; this file only does
    the deleting, with -WhatIf / -Confirm support and a lock check before anything is deleted.
#>

function Get-ResourceGroupState {
    <# Exists + locks for every resource group of the plan. Reads only. #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plan, [Parameter(Mandatory)] [string] $SubscriptionId)
    foreach ($item in $Plan) {
        $exists = ConvertTo-Bool (@(Invoke-AzCli -Arguments @('group', 'exists', '--name', $item.ResourceGroup, '--subscription', $SubscriptionId)) | Select-Object -First 1)
        $locks = if ($exists) { @(Invoke-AzCli -Arguments @('lock', 'list', '--resource-group', $item.ResourceGroup, '--subscription', $SubscriptionId)) } else { @() }
        [pscustomobject]@{ Item = $item; Exists = $exists; Locks = @($locks) }
    }
}

function Invoke-EnvironmentRemoval {
    <#
    .SYNOPSIS
        Deletes the resource groups of the plan one by one, in plan order. Emits one result per step.
    .PARAMETER IgnoreLocks
        Delete management locks before deleting a group. Without it, any lock stops the removal
        before the first group is deleted, so an environment is never left half removed by a lock.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plan,
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [switch] $IgnoreLocks
    )
    $states = @(Get-ResourceGroupState -Plan $Plan -SubscriptionId $SubscriptionId)
    $locked = @($states | Where-Object { $_.Locks.Count -gt 0 })
    if ($locked.Count -gt 0 -and -not $IgnoreLocks) {
        $list = @($locked | ForEach-Object { "$($_.Item.ResourceGroup) ($(@($_.Locks | ForEach-Object { "$($_.name):$($_.level)" }) -join ', '))" })
        throw "Refused: resource groups with management locks: $($list -join '; '). Nothing was deleted. Remove the locks or pass -IgnoreLocks."
    }

    foreach ($state in $states) {
        $item = $state.Item
        if (-not $state.Exists) {
            [pscustomobject]@{ Step = $item.Step; Component = $item.Component; ResourceGroup = $item.ResourceGroup; Result = 'AlreadyGone' }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($item.ResourceGroup, 'Delete resource group and every resource in it')) { continue }
        foreach ($lock in $state.Locks) {
            Write-Warning "Deleting lock '$($lock.name)' on $($item.ResourceGroup)."
            $null = @(Invoke-AzCli -Arguments @('lock', 'delete', '--ids', $lock.id))
        }
        $null = @(Invoke-AzCli -Arguments @('group', 'delete', '--name', $item.ResourceGroup, '--subscription', $SubscriptionId, '--yes'))
        [pscustomobject]@{ Step = $item.Step; Component = $item.Component; ResourceGroup = $item.ResourceGroup; Result = 'Deleted' }
    }
}
