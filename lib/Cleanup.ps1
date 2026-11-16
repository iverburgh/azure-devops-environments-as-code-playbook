Set-StrictMode -Version Latest

<#
    Finds and (optionally) deletes orphaned role assignments in the resource groups of an environment:
    assignments whose principal (user, group, service principal, managed identity) no longer exists.
    They pile up when environments are removed and recreated, and they count towards the role
    assignment limit of a subscription.

    Safety, in order:
      1. Detection is two-step: the Azure CLI shows an empty principalName for a principal it cannot
         resolve, but that also happens without directory read permission. Each candidate is
         therefore looked up by ID; only 'does not exist' counts as orphaned, any other error stops.
      2. Grace period: assignments younger than minimumAgeDays are left alone (directory replication).
      3. Protected roles (Owner, User Access Administrator by default) are reported, never deleted.
      4. Circuit breaker: when the share of orphans is implausibly high the lookup is probably broken,
         so everything stops before a single deletion.
      5. Deleting is a separate, explicit step (-Execute), optionally limited to an approved report.
      6. Locks are only removed with -RemoveLocksTemporarily and are always restored (finally).
#>

function Test-PrincipalExists {
    <# $true / $false; throws when the lookup itself fails for another reason than 'not found'. #>
    param([Parameter(Mandatory)] [string] $PrincipalId, [string] $PrincipalType = 'ServicePrincipal')
    $noun = switch ($PrincipalType) {
        'User' { 'user' }
        'Group' { 'group' }
        default { 'sp' }
    }
    $result = Invoke-AzCli -Arguments @('ad', $noun, 'show', '--id', $PrincipalId) -AllowFailure
    if ($result.Succeeded) { return $true }
    if ($result.Error -match 'does not exist|not found|Request_ResourceNotFound') { return $false }
    throw "Looking up principal $PrincipalId failed: $($result.Error)"
}

function Get-OrphanedRoleAssignment {
    <#
    .SYNOPSIS
        Reads only. Returns @{ Rows; TotalAssignments; ResourceGroups }. Rows have a Status of
        Orphaned (can be deleted), TooRecent or ProtectedRole.
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $Cleanup,
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [datetime] $Now = [datetime]::UtcNow
    )
    $pattern = $Cleanup.ResourceGroupPattern.Replace('{env}', $Environment)
    $groups = @(Invoke-AzCli -Arguments @('group', 'list', '--subscription', $SubscriptionId) | Where-Object { [string]$_.name -like $pattern } | Sort-Object { [string]$_.name })
    $rows = [Collections.Generic.List[object]]::new()
    $total = 0
    $cutoff = $Now.ToUniversalTime().AddDays(-$Cleanup.MinimumAgeDays)

    foreach ($group in $groups) {
        $scope = "/subscriptions/$SubscriptionId/resourceGroups/$($group.name)"
        $assignments = @(Invoke-AzCli -Arguments @('role', 'assignment', 'list', '--scope', $scope, '--subscription', $SubscriptionId) |
                Where-Object { ([string]$_.scope).StartsWith($scope, [StringComparison]::OrdinalIgnoreCase) })
        $total += $assignments.Count
        foreach ($assignment in $assignments) {
            if ([string](Get-OptionalValue $assignment 'principalName' '')) { continue }
            $principalType = [string](Get-OptionalValue $assignment 'principalType' 'ServicePrincipal')
            if (Test-PrincipalExists -PrincipalId $assignment.principalId -PrincipalType $principalType) {
                Write-Verbose "Principal $($assignment.principalId) exists; its name was just not readable."
                continue
            }
            $role = [string](Get-OptionalValue $assignment 'roleDefinitionName' '')
            $createdOn = Get-OptionalValue $assignment 'createdOn'
            $created = if ($createdOn) { ([datetime]$createdOn).ToUniversalTime() } else { [datetime]::MinValue }
            $status = if ($Cleanup.ProtectedRoleNames -contains $role) { 'ProtectedRole' }
            elseif ($created -gt $cutoff) { 'TooRecent' }
            else { 'Orphaned' }
            $rows.Add([pscustomobject]@{
                    Id = [string]$assignment.id
                    ResourceGroup = [string]$group.name
                    Scope = [string]$assignment.scope
                    RoleDefinitionName = $role
                    PrincipalId = [string]$assignment.principalId
                    PrincipalType = $principalType
                    CreatedOn = if ($createdOn) { $created.ToString('o') } else { '' }
                    Status = $status
                })
        }
    }
    @{ Rows = $rows.ToArray(); TotalAssignments = $total; ResourceGroups = @($groups | ForEach-Object { [string]$_.name }) }
}

function Assert-OrphanRatio {
    <# The circuit breaker. Throws when the share of orphaned assignments is implausibly high. #>
    param([Parameter(Mandatory)] [hashtable] $Result, [Parameter(Mandatory)] [hashtable] $Cleanup)
    $orphaned = @($Result.Rows).Count
    if ($Result.TotalAssignments -lt $Cleanup.MinimumAssignmentsForRatioCheck -or $Result.TotalAssignments -eq 0) { return }
    $ratio = $orphaned / $Result.TotalAssignments
    if ($ratio -gt $Cleanup.MaxOrphanRatio) {
        throw ("Circuit breaker: {0} of {1} role assignments ({2:P0}) look orphaned, more than the maximum of {3:P0}. " +
            'The principal lookup is probably failing (permissions, wrong tenant). Nothing was deleted.') -f $orphaned, $Result.TotalAssignments, $ratio, $Cleanup.MaxOrphanRatio
    }
}

function Remove-OrphanedRoleAssignment {
    <#
    .SYNOPSIS
        Deletes the rows with Status Orphaned. Emits one result per row it acted on.
    .PARAMETER ApprovedId
        When given, only these assignment IDs are deleted (the reviewed report of an earlier dry run);
        an ID that is no longer orphaned is not deleted.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows,
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [AllowNull()] [AllowEmptyCollection()] [string[]] $ApprovedId,
        [switch] $RemoveLocksTemporarily
    )
    $candidates = @($Rows | Where-Object { $_.Status -eq 'Orphaned' })
    # Bound but empty means "nothing approved", never "no filter".
    if ($PSBoundParameters.ContainsKey('ApprovedId')) {
        $approved = @{}
        foreach ($id in @($ApprovedId | Where-Object { $_ })) { $approved[$id] = $true }
        $notApproved = @($candidates | Where-Object { -not $approved.ContainsKey($_.Id) })
        foreach ($row in $notApproved) { Write-Warning "Not in the approved report, so not deleted: $($row.Id)" }
        $candidates = @($candidates | Where-Object { $approved.ContainsKey($_.Id) })
    }

    foreach ($group in @($candidates | Group-Object -Property ResourceGroup)) {
        $resourceGroup = $group.Name
        $locks = @(Invoke-AzCli -Arguments @('lock', 'list', '--resource-group', $resourceGroup, '--subscription', $SubscriptionId))
        if ($locks.Count -gt 0 -and -not $RemoveLocksTemporarily) {
            Write-Warning "$resourceGroup has $($locks.Count) lock(s); its orphaned role assignments are skipped. Use -RemoveLocksTemporarily."
            foreach ($row in $group.Group) { [pscustomobject]@{ Id = $row.Id; ResourceGroup = $resourceGroup; Result = 'SkippedLocked' } }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($resourceGroup, "Delete $($group.Count) orphaned role assignment(s)")) { continue }

        $removedLocks = [Collections.Generic.List[object]]::new()
        try {
            foreach ($lock in $locks) {
                $null = @(Invoke-AzCli -Arguments @('lock', 'delete', '--ids', $lock.id))
                $removedLocks.Add($lock)
            }
            foreach ($row in $group.Group) {
                $null = @(Invoke-AzCli -Arguments @('role', 'assignment', 'delete', '--ids', $row.Id, '--subscription', $SubscriptionId))
                [pscustomobject]@{ Id = $row.Id; ResourceGroup = $resourceGroup; Result = 'Deleted' }
            }
        }
        finally {
            foreach ($lock in $removedLocks) {
                $arguments = @('lock', 'create', '--name', $lock.name, '--lock-type', $lock.level, '--resource-group', $resourceGroup, '--subscription', $SubscriptionId)
                $notes = [string](Get-OptionalValue $lock 'notes' '')
                if ($notes) { $arguments += @('--notes', $notes) }
                $null = @(Invoke-AzCli -Arguments $arguments)
            }
        }
    }
}
