Set-StrictMode -Version Latest

<#
    In-memory fake of the Azure CLI commands used by remove and cleanup. Tests replace Invoke-AzCli
    with Invoke-FakeAzCli. Like the real platform, a management lock blocks deleting a resource
    group or a role assignment in it. Every write is recorded in $global:FakeAz.Writes.
#>

function Reset-FakeAzure {
    param([string] $SubscriptionId = '00000000-0000-0000-0000-000000000011')
    $global:FakeAz = @{
        SubscriptionId = $SubscriptionId
        Groups = [Collections.Generic.List[string]]::new()
        Locks = @{}
        RoleAssignments = [Collections.Generic.List[hashtable]]::new()
        Principals = @{}
        LookupError = $null
        NextId = 0
        Writes = [Collections.Generic.List[string]]::new()
    }
}

function Add-FakeResourceGroup {
    param([Parameter(Mandatory)] [string[]] $Name)
    foreach ($item in $Name) { $global:FakeAz.Groups.Add($item) }
}

function Add-FakeLock {
    param([Parameter(Mandatory)] [string] $ResourceGroup, [string] $Name = 'do-not-delete', [string] $Level = 'CanNotDelete', [string] $Notes = '')
    if (-not $global:FakeAz.Locks.ContainsKey($ResourceGroup)) { $global:FakeAz.Locks[$ResourceGroup] = [Collections.Generic.List[hashtable]]::new() }
    $global:FakeAz.NextId++
    $global:FakeAz.Locks[$ResourceGroup].Add(@{
            id = "/subscriptions/$($global:FakeAz.SubscriptionId)/resourceGroups/$ResourceGroup/providers/Microsoft.Authorization/locks/$Name"
            name = $Name
            level = $Level
            notes = $Notes
        })
}

function Get-FakeLocks {
    param([Parameter(Mandatory)] [string] $ResourceGroup)
    if ($global:FakeAz.Locks.ContainsKey($ResourceGroup)) { $global:FakeAz.Locks[$ResourceGroup] }
}

function Add-FakeRoleAssignment {
    <# -Exists $false makes the principal deleted: an empty principalName and 'does not exist' on lookup. #>
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [string] $Role = 'Contributor',
        [string] $PrincipalType = 'ServicePrincipal',
        [bool] $Exists = $true,
        [bool] $NameReadable = $true,
        [datetime] $CreatedOn = [datetime]'2026-01-01T00:00:00Z'
    )
    $global:FakeAz.NextId++
    $principalId = '00000000-0000-0000-0000-00000000{0:x4}' -f (0xd000 + $global:FakeAz.NextId)
    $id = "/subscriptions/$($global:FakeAz.SubscriptionId)/resourceGroups/$ResourceGroup/providers/Microsoft.Authorization/roleAssignments/ra-$($global:FakeAz.NextId)"
    if ($Exists) { $global:FakeAz.Principals[$principalId] = $true }
    $assignment = @{
        id = $id
        scope = "/subscriptions/$($global:FakeAz.SubscriptionId)/resourceGroups/$ResourceGroup"
        principalId = $principalId
        principalName = if ($Exists -and $NameReadable) { "principal-$($global:FakeAz.NextId)" } else { '' }
        principalType = $PrincipalType
        roleDefinitionName = $Role
        createdOn = $CreatedOn.ToUniversalTime().ToString('o')
    }
    $global:FakeAz.RoleAssignments.Add($assignment)
    $assignment
}

function Get-FakeArgument {
    param([string[]] $Arguments, [string] $Name)
    $index = [array]::IndexOf($Arguments, $Name)
    if ($index -lt 0 -or $index + 1 -ge $Arguments.Count) { return $null }
    $Arguments[$index + 1]
}

function Invoke-FakeAzCli {
    param([string[]] $Arguments, [switch] $AllowFailure)
    $command = ($Arguments | Select-Object -First 3) -join ' '
    $resourceGroup = Get-FakeArgument $Arguments '--resource-group'
    $name = Get-FakeArgument $Arguments '--name'
    $ids = Get-FakeArgument $Arguments '--ids'

    if ($Arguments[0] -eq 'ad' -and $Arguments[2] -eq 'show') {
        $id = Get-FakeArgument $Arguments '--id'
        if ($global:FakeAz.LookupError) { return [pscustomobject]@{ Succeeded = $false; Output = $null; Error = $global:FakeAz.LookupError } }
        if ($global:FakeAz.Principals.ContainsKey($id)) { return [pscustomobject]@{ Succeeded = $true; Output = [pscustomobject]@{ id = $id }; Error = '' } }
        return [pscustomobject]@{ Succeeded = $false; Output = $null; Error = "ERROR: Resource '$id' does not exist or one of its queried reference-property objects are not present." }
    }

    $locked = { param($group) $global:FakeAz.Locks.ContainsKey($group) -and $global:FakeAz.Locks[$group].Count -gt 0 }
    switch ($command) {
        'group exists --name' { return ($global:FakeAz.Groups -contains $name) }
        'group list --subscription' {
            foreach ($group in $global:FakeAz.Groups) { [pscustomobject]@{ name = $group; location = 'westeurope' } }
            return
        }
        'group delete --name' {
            $global:FakeAz.Writes.Add("group delete $name")
            if (& $locked $name) { throw "ScopeLocked: resource group '$name' has a lock." }
            $null = $global:FakeAz.Groups.Remove($name)
            foreach ($assignment in @($global:FakeAz.RoleAssignments | Where-Object { $_.scope -like "*/resourceGroups/$name" })) { $null = $global:FakeAz.RoleAssignments.Remove($assignment) }
            return
        }
        'lock list --resource-group' {
            foreach ($lock in @(Get-FakeLocks -ResourceGroup $resourceGroup)) { [pscustomobject]$lock }
            return
        }
        'lock delete --ids' {
            $global:FakeAz.Writes.Add("lock delete $ids")
            foreach ($group in @($global:FakeAz.Locks.Keys)) {
                foreach ($lock in @($global:FakeAz.Locks[$group] | Where-Object { $_.id -eq $ids })) { $null = $global:FakeAz.Locks[$group].Remove($lock) }
            }
            return
        }
        'lock create --name' {
            $global:FakeAz.Writes.Add("lock create $name on $resourceGroup")
            Add-FakeLock -ResourceGroup $resourceGroup -Name $name -Level (Get-FakeArgument $Arguments '--lock-type') -Notes ([string](Get-FakeArgument $Arguments '--notes'))
            return
        }
        'role assignment list' {
            $scope = Get-FakeArgument $Arguments '--scope'
            foreach ($assignment in @($global:FakeAz.RoleAssignments | Where-Object { $_.scope.StartsWith($scope, [StringComparison]::OrdinalIgnoreCase) })) { [pscustomobject]$assignment }
            return
        }
        'role assignment delete' {
            $global:FakeAz.Writes.Add("role assignment delete $ids")
            $assignment = @($global:FakeAz.RoleAssignments | Where-Object { $_.id -eq $ids })
            if ($assignment.Count -eq 0) { throw "Role assignment $ids does not exist." }
            $group = ($assignment[0].scope -split '/')[-1]
            if (& $locked $group) { throw "ScopeLocked: resource group '$group' has a lock." }
            $null = $global:FakeAz.RoleAssignments.Remove($assignment[0])
            return
        }
        default { throw "FakeAzure does not support: az $($Arguments -join ' ')" }
    }
}
