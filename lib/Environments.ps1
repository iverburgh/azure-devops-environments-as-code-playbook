Set-StrictMode -Version Latest

<#
    Reconciles Azure DevOps environments and their checks with the configuration.

    Get-EnvironmentPlan only reads; it compares the desired state with the actual state and emits one
    plan item per difference. Invoke-EnvironmentPlan applies a plan and honours -WhatIf / -Confirm.
    A second run after a successful apply produces an empty plan.

    API versions: environments 7.1, checks 7.1-preview.1 (the checks API is still in preview).

    Managed check kinds: ExclusiveLock, BranchControl and Approval. A managed kind that is absent or
    disabled in the configuration must not exist on the environment. Checks of other kinds (business
    hours, required template, invoke REST API, ...) are reported as Unmanaged and left alone.
#>

function Get-CheckTypeReference {
    <# Public, well-known identifiers of the check types: the same in every organisation. #>
    param([Parameter(Mandatory)] [ValidateSet('ExclusiveLock', 'BranchControl', 'Approval')] [string] $Kind)
    switch ($Kind) {
        'ExclusiveLock' { @{ id = '2ef31ad6-baa0-403a-8b45-2cbc9b4e5563'; name = 'ExclusiveLock' } }
        'BranchControl' { @{ id = 'fe1de3ee-a436-41b4-bb20-f6eb4cb879a7'; name = 'Task Check' } }
        'Approval' { @{ id = '8c6f20a7-a545-4486-9777-f762fafe0d4d'; name = 'Approval' } }
    }
}

function Get-BranchControlTaskReference {
    @{ id = '86b05a0c-73e6-4f7d-b3cf-e38f3b39a75b'; name = 'evaluatebranchProtection'; version = '1.0.0' }
}

function Get-CheckKind {
    <# ExclusiveLock, BranchControl, Approval or Unmanaged. #>
    param([Parameter(Mandatory)] [object] $Check)
    $typeName = [string](Get-OptionalValue $Check 'type.name' '')
    if ($typeName -eq 'ExclusiveLock') { return 'ExclusiveLock' }
    if ($typeName -eq 'Approval') { return 'Approval' }
    if ($typeName -eq 'Task Check' -and [string](Get-OptionalValue $Check 'settings.definitionRef.name' '') -eq 'evaluatebranchProtection') {
        return 'BranchControl'
    }
    'Unmanaged'
}

function ConvertTo-ExecutionOrder {
    <# The API has been seen returning names as well as numbers; normalise both. #>
    param([AllowNull()] [object] $Value)
    switch ("$Value") {
        { $_ -in '2', 'inSequence' } { return 'inSequence' }
        default { return 'anyOrder' }
    }
}

function Get-CheckSignature {
    <#
    .SYNOPSIS
        A canonical string of everything this playbook manages in a check, so a desired and an actual
        check compare equal exactly when nothing has to change. Fields the API adds are ignored.
    #>
    param(
        [Parameter(Mandatory)] [string] $Kind,
        [AllowNull()] [object] $Settings,
        [int] $Timeout
    )
    switch ($Kind) {
        'ExclusiveLock' { "timeout=$Timeout" }
        'BranchControl' {
            $branches = @(([string](Get-OptionalValue $Settings 'inputs.allowedBranches' '')) -split ',' |
                    ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
            $protect = ConvertTo-Bool (Get-OptionalValue $Settings 'inputs.ensureProtectionOfBranch' 'false')
            "branches=$($branches -join ',');protect=$protect;timeout=$Timeout"
        }
        'Approval' {
            $ids = @(@(Get-OptionalValue $Settings 'approvers' @()) |
                    ForEach-Object { ([string](Get-OptionalValue $_ 'id' '')).ToLowerInvariant() } | Sort-Object)
            $min = [int](Get-OptionalValue $Settings 'minRequiredApprovers' 0)
            $requester = ConvertTo-Bool (Get-OptionalValue $Settings 'requesterCannotBeApprover' $false)
            $order = ConvertTo-ExecutionOrder (Get-OptionalValue $Settings 'executionOrder' 'anyOrder')
            $instructions = [string](Get-OptionalValue $Settings 'instructions' '')
            "approvers=$($ids -join ',');min=$min;requesterCannotBeApprover=$requester;order=$order;instructions=$instructions;timeout=$Timeout"
        }
    }
}

function Resolve-IdentityId {
    <# Resolves a user (e-mail) or group ('[project]\Group') to its identity ID. #>
    param([Parameter(Mandatory)] [hashtable] $Connection, [Parameter(Mandatory)] [string] $Name)
    $path = "identities?searchFilter=General&filterValue=$([uri]::EscapeDataString($Name))&queryMembership=None&api-version=7.1"
    $response = Invoke-AzDevOps -Connection $Connection -Scope Identity -Path $path
    $found = @(Get-OptionalValue $response 'value' @())
    if ($found.Count -gt 1) {
        $found = @($found | Where-Object { [string](Get-OptionalValue $_ 'providerDisplayName' '') -eq $Name })
    }
    if ($found.Count -eq 0) { throw "Identity '$Name' was not found in the organisation." }
    if ($found.Count -gt 1) { throw "Identity '$Name' is ambiguous: $($found.Count) matches. Use the full group name or the e-mail address." }
    [string]$found[0].id
}

function Resolve-ConfigIdentity {
    <# Resolves every approver and administrator name used by the configuration, once each. #>
    param([Parameter(Mandatory)] [hashtable] $Connection, [Parameter(Mandatory)] [object[]] $Groups)
    $ids = @{}
    foreach ($group in $Groups) {
        $names = @($group.Security.Administrators)
        foreach ($environment in $group.Environments) {
            if ($environment.Approval.Enabled) { $names += $environment.Approval.Approvers }
        }
        foreach ($name in $names) {
            if (-not $ids.ContainsKey($name)) { $ids[$name] = Resolve-IdentityId -Connection $Connection -Name $name }
        }
    }
    $ids
}

function Get-DesiredCheck {
    <# The checks an environment should have, as REST payloads plus their signature. #>
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Environment,
        [Parameter(Mandatory)] [hashtable] $IdentityIds
    )
    if ($Environment.ExclusiveLock.Enabled) {
        $settings = @{}
        @{ Kind = 'ExclusiveLock'; Settings = $settings; Timeout = $Environment.ExclusiveLock.TimeoutMinutes
            Signature = Get-CheckSignature -Kind 'ExclusiveLock' -Settings $settings -Timeout $Environment.ExclusiveLock.TimeoutMinutes }
    }
    if ($Environment.BranchControl.Enabled) {
        $branch = $Environment.BranchControl
        $settings = @{
            displayName = 'Branch control'
            definitionRef = Get-BranchControlTaskReference
            inputs = @{
                allowedBranches = ($branch.AllowedBranches -join ',')
                ensureProtectionOfBranch = "$($branch.VerifyBranchProtection)".ToLowerInvariant()
            }
            retryInterval = 5
        }
        @{ Kind = 'BranchControl'; Settings = $settings; Timeout = $branch.TimeoutMinutes
            Signature = Get-CheckSignature -Kind 'BranchControl' -Settings $settings -Timeout $branch.TimeoutMinutes }
    }
    if ($Environment.Approval.Enabled) {
        $approval = $Environment.Approval
        $settings = @{
            approvers = @(foreach ($name in $approval.Approvers) { @{ id = $IdentityIds[$name]; displayName = $name } })
            executionOrder = $approval.ExecutionOrder
            minRequiredApprovers = $approval.MinRequiredApprovers
            requesterCannotBeApprover = $approval.RequesterCannotBeApprover
            instructions = $approval.Instructions
            blockedApprovers = @()
        }
        @{ Kind = 'Approval'; Settings = $settings; Timeout = $approval.TimeoutMinutes
            Signature = Get-CheckSignature -Kind 'Approval' -Settings $settings -Timeout $approval.TimeoutMinutes }
    }
}

function New-PlanItem {
    param(
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [string] $Environment,
        [string] $Kind = '',
        [string] $Detail = '',
        [AllowNull()] [object] $EnvironmentId = $null,
        [AllowNull()] [object] $CheckId = $null,
        [AllowNull()] [object] $Data = $null
    )
    [pscustomobject]@{
        Action = $Action
        Environment = $Environment
        Kind = $Kind
        Detail = $Detail
        EnvironmentId = $EnvironmentId
        CheckId = $CheckId
        Data = $Data
    }
}

function Get-ActualEnvironment {
    param([Parameter(Mandatory)] [hashtable] $Connection)
    Invoke-AzDevOps -Connection $Connection -Path "distributedtask/environments?`$top=500&api-version=7.1" -All
}

function Get-ActualCheck {
    param([Parameter(Mandatory)] [hashtable] $Connection, [Parameter(Mandatory)] [object] $EnvironmentId)
    Invoke-AzDevOps -Connection $Connection -Path "pipelines/checks/configurations?resourceType=environment&resourceId=$EnvironmentId&`$expand=settings&api-version=7.1-preview.1" -All
}

function Get-EnvironmentPlan {
    <#
    .SYNOPSIS
        Compares configuration and Azure DevOps. Emits plan items; changes nothing.
    .PARAMETER RemoveUndefined
        Also plan the deletion of environments that are not in the configuration, but only those
        within a configured group ('<system> - <group>' or '<system> - <group> - *') whose name
        matches one of the -RemoveFilter wildcard patterns.
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $Connection,
        [Parameter(Mandatory)] [object[]] $Groups,
        [switch] $RemoveUndefined,
        [string[]] $RemoveFilter = @()
    )
    if ($RemoveUndefined -and $RemoveFilter.Count -eq 0) {
        throw '-RemoveUndefined needs -RemoveFilter: name the environments that may be deleted, for example -RemoveFilter "shop - dev - *".'
    }

    $actual = @(Get-ActualEnvironment -Connection $Connection)
    $byName = @{}
    foreach ($environment in $actual) { $byName[[string]$environment.name] = $environment }
    $identityIds = Resolve-ConfigIdentity -Connection $Connection -Groups $Groups
    $desiredNames = @{}

    foreach ($group in $Groups) {
        $administratorIds = @($group.Security.Administrators | ForEach-Object { $identityIds[$_] })
        foreach ($environment in $group.Environments) {
            $name = $environment.Name
            $desiredNames[$name] = $true
            $desired = @(Get-DesiredCheck -Environment $environment -IdentityIds $identityIds)

            if (-not $byName.ContainsKey($name)) {
                New-PlanItem -Action 'CreateEnvironment' -Environment $name -Detail 'new environment' -Data @{
                    Description = [string]$environment.Description
                    AdministratorIds = $administratorIds
                    RemoveCreatorRole = $group.Security.RemoveCreatorRole
                }
                foreach ($check in $desired) {
                    New-PlanItem -Action 'AddCheck' -Environment $name -Kind $check.Kind -Detail $check.Signature -Data $check
                }
                continue
            }

            $existing = $byName[$name]
            $actualDescription = [string](Get-OptionalValue $existing 'description' '')
            if ($null -ne $environment.Description -and $actualDescription -ne $environment.Description) {
                New-PlanItem -Action 'UpdateEnvironment' -Environment $name -Detail "description '$actualDescription' -> '$($environment.Description)'" `
                    -EnvironmentId $existing.id -Data @{ Description = $environment.Description }
            }

            $checks = @(Get-ActualCheck -Connection $Connection -EnvironmentId $existing.id)
            foreach ($check in $checks) {
                if ((Get-CheckKind -Check $check) -eq 'Unmanaged') {
                    New-PlanItem -Action 'Unmanaged' -Environment $name -Kind ([string](Get-OptionalValue $check 'type.name' '?')) `
                        -Detail 'check of a type this playbook does not manage; left alone' -EnvironmentId $existing.id -CheckId $check.id
                }
            }
            foreach ($kind in 'ExclusiveLock', 'BranchControl', 'Approval') {
                $want = @($desired | Where-Object { $_.Kind -eq $kind })
                $have = @($checks | Where-Object { (Get-CheckKind -Check $_) -eq $kind })
                if ($want.Count -eq 0) {
                    foreach ($check in $have) {
                        New-PlanItem -Action 'DeleteCheck' -Environment $name -Kind $kind -Detail 'not in the configuration' -EnvironmentId $existing.id -CheckId $check.id
                    }
                    continue
                }
                if ($have.Count -eq 0) {
                    New-PlanItem -Action 'AddCheck' -Environment $name -Kind $kind -Detail $want[0].Signature -EnvironmentId $existing.id -Data $want[0]
                    continue
                }
                $current = Get-CheckSignature -Kind $kind -Settings (Get-OptionalValue $have[0] 'settings') -Timeout ([int](Get-OptionalValue $have[0] 'timeout' 0))
                if ($current -ne $want[0].Signature) {
                    New-PlanItem -Action 'UpdateCheck' -Environment $name -Kind $kind -Detail "$current -> $($want[0].Signature)" `
                        -EnvironmentId $existing.id -CheckId $have[0].id -Data $want[0]
                }
                foreach ($duplicate in @($have | Select-Object -Skip 1)) {
                    New-PlanItem -Action 'DeleteCheck' -Environment $name -Kind $kind -Detail 'duplicate check of the same kind' -EnvironmentId $existing.id -CheckId $duplicate.id
                }
            }
        }
    }

    if ($RemoveUndefined) {
        foreach ($environment in $actual) {
            $name = [string]$environment.name
            if ($desiredNames.ContainsKey($name)) { continue }
            $inGroup = @($Groups | Where-Object {
                    $base = "$($_.System) - $($_.Group)"
                    $name -eq $base -or $name.StartsWith("$base - ")
                }).Count -gt 0
            $matchesFilter = @($RemoveFilter | Where-Object { $name -like $_ }).Count -gt 0
            if ($inGroup -and $matchesFilter) {
                New-PlanItem -Action 'DeleteEnvironment' -Environment $name -Detail 'not in the configuration; matches -RemoveFilter' -EnvironmentId $environment.id
            }
        }
    }
}

function New-CheckBody {
    param([Parameter(Mandatory)] [hashtable] $Check, [Parameter(Mandatory)] [object] $EnvironmentId, [Parameter(Mandatory)] [string] $EnvironmentName, [AllowNull()] [object] $CheckId = $null)
    $body = @{
        type = Get-CheckTypeReference -Kind $Check.Kind
        settings = $Check.Settings
        resource = @{ type = 'environment'; id = "$EnvironmentId"; name = $EnvironmentName }
        timeout = $Check.Timeout
    }
    if ($null -ne $CheckId) { $body.id = $CheckId }
    $body
}

function Set-NewEnvironmentSecurity {
    <# Gives the configured administrators the Administrator role and, optionally, removes the creator's role. #>
    param(
        [Parameter(Mandatory)] [hashtable] $Connection,
        [Parameter(Mandatory)] [object] $EnvironmentId,
        [string[]] $AdministratorIds = @(),
        [bool] $RemoveCreatorRole
    )
    if ($AdministratorIds.Count -eq 0 -and -not $RemoveCreatorRole) { return }
    $project = Invoke-AzDevOps -Connection $Connection -Scope Organization -Path "projects/$([uri]::EscapeDataString($Connection.Project))?api-version=7.1"
    $resource = "securityroles/scopes/distributedtask.environmentreferencerole/roleassignments/resources/$($project.id)_$EnvironmentId"

    if ($AdministratorIds.Count -gt 0) {
        $assignments = @(foreach ($id in $AdministratorIds) { @{ roleName = 'Administrator'; userId = $id } })
        $null = Invoke-AzDevOps -Connection $Connection -Scope Organization -Method PUT -Path "${resource}?api-version=7.1-preview.1" -Body $assignments
    }
    if ($RemoveCreatorRole) {
        $creator = [string](Get-OptionalValue (Invoke-AzDevOps -Connection $Connection -Scope Organization -Path 'connectionData') 'authenticatedUser.id' '')
        if ($creator -and $AdministratorIds -notcontains $creator) {
            try { $null = Invoke-AzDevOps -Connection $Connection -Scope Organization -Method DELETE -Path "$resource/${creator}?api-version=7.1-preview.1" }
            catch { Write-Warning "Could not remove the creator's role on environment $EnvironmentId : $($_.Exception.Message)" }
        }
    }
}

function Invoke-EnvironmentPlan {
    <#
    .SYNOPSIS
        Applies plan items from Get-EnvironmentPlan. Honours -WhatIf and -Confirm. Emits the applied items.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Connection,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plan
    )
    $created = @{}
    foreach ($item in $Plan) {
        $name = $item.Environment
        switch ($item.Action) {
            'Unmanaged' {
                Write-Warning "$name has a '$($item.Kind)' check that is not managed here; it is left alone."
            }
            'CreateEnvironment' {
                if (-not $PSCmdlet.ShouldProcess($name, 'Create environment')) { continue }
                $body = @{ name = $name; description = $item.Data.Description }
                $environment = Invoke-AzDevOps -Connection $Connection -Method POST -Path "distributedtask/environments?api-version=7.1" -Body $body
                $created[$name] = $environment.id
                Set-NewEnvironmentSecurity -Connection $Connection -EnvironmentId $environment.id `
                    -AdministratorIds @($item.Data.AdministratorIds) -RemoveCreatorRole $item.Data.RemoveCreatorRole
                $item
            }
            'UpdateEnvironment' {
                if (-not $PSCmdlet.ShouldProcess($name, "Update description")) { continue }
                $body = @{ name = $name; description = $item.Data.Description }
                $null = Invoke-AzDevOps -Connection $Connection -Method PATCH -Path "distributedtask/environments/$($item.EnvironmentId)?api-version=7.1" -Body $body
                $item
            }
            'AddCheck' {
                if (-not $PSCmdlet.ShouldProcess($name, "Add $($item.Kind) check")) { continue }
                $environmentId = if ($null -ne $item.EnvironmentId) { $item.EnvironmentId } elseif ($created.ContainsKey($name)) { $created[$name] } else { $null }
                if ($null -eq $environmentId) { Write-Warning "Skipped the $($item.Kind) check: environment '$name' was not created."; continue }
                $body = New-CheckBody -Check $item.Data -EnvironmentId $environmentId -EnvironmentName $name
                $null = Invoke-AzDevOps -Connection $Connection -Method POST -Path "pipelines/checks/configurations?api-version=7.1-preview.1" -Body $body
                $item
            }
            'UpdateCheck' {
                if (-not $PSCmdlet.ShouldProcess($name, "Update $($item.Kind) check")) { continue }
                $body = New-CheckBody -Check $item.Data -EnvironmentId $item.EnvironmentId -EnvironmentName $name -CheckId $item.CheckId
                $null = Invoke-AzDevOps -Connection $Connection -Method PATCH -Path "pipelines/checks/configurations/$($item.CheckId)?api-version=7.1-preview.1" -Body $body
                $item
            }
            'DeleteCheck' {
                if (-not $PSCmdlet.ShouldProcess($name, "Delete $($item.Kind) check")) { continue }
                $null = Invoke-AzDevOps -Connection $Connection -Method DELETE -Path "pipelines/checks/configurations/$($item.CheckId)?api-version=7.1-preview.1"
                $item
            }
            'DeleteEnvironment' {
                if (-not $PSCmdlet.ShouldProcess($name, 'Delete environment (its deployment history is lost)')) { continue }
                $null = Invoke-AzDevOps -Connection $Connection -Method DELETE -Path "distributedtask/environments/$($item.EnvironmentId)?api-version=7.1"
                $item
            }
            default { throw "Unknown plan action '$($item.Action)'." }
        }
    }
}

function Write-PlanSummary {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plan, [string] $Title = 'Plan')
    Write-Host "${Title}:"
    if ($Plan.Count -eq 0) { Write-Host '  no changes'; return }
    foreach ($item in $Plan) {
        $kind = if ($item.Kind) { " [$($item.Kind)]" } else { '' }
        Write-Host "  $($item.Action.PadRight(18)) $($item.Environment)$kind  $($item.Detail)"
    }
    $counts = @($Plan | Group-Object Action | ForEach-Object { "$($_.Name)=$($_.Count)" })
    Write-Host "  Summary: $($counts -join ', ')"
}
