Set-StrictMode -Version Latest

<#
    Exports environments and their checks from Azure DevOps into environments/<group>.json files.
    Use it to adopt an existing project (export first, review, commit, then manage) and to see what
    someone changed by hand. Only what Set-Environments.ps1 manages is exported; policy and security
    are not stored in Azure DevOps in a way that maps back, so they are left out - add them yourself.
#>

function Get-ApproverName {
    <# A name Set-Environments.ps1 can resolve again: e-mail address for users, display name for groups. #>
    param([Parameter(Mandatory)] [hashtable] $Connection, [Parameter(Mandatory)] [object] $Approver)
    $unique = [string](Get-OptionalValue $Approver 'uniqueName' '')
    if ($unique -match '@') { return $unique }
    $display = [string](Get-OptionalValue $Approver 'displayName' '')
    if ($display) { return $display }
    $id = [string](Get-OptionalValue $Approver 'id' '')
    $response = Invoke-AzDevOps -Connection $Connection -Scope Identity -Path "identities?identityIds=$id&queryMembership=None&api-version=7.1"
    $found = @(Get-OptionalValue $response 'value' @())
    if ($found.Count -eq 0) { throw "Approver identity $id could not be resolved to a name." }
    [string](Get-OptionalValue $found[0] 'providerDisplayName' $id)
}

function ConvertTo-ExportedEnvironment {
    param([Parameter(Mandatory)] [hashtable] $Connection, [Parameter(Mandatory)] [object] $Environment)
    $result = [ordered]@{ name = [string]$Environment.name }
    $description = [string](Get-OptionalValue $Environment 'description' '')
    if ($description) { $result.description = $description }

    $checks = @(Get-ActualCheck -Connection $Connection -EnvironmentId $Environment.id)
    foreach ($check in $checks) {
        $kind = Get-CheckKind -Check $check
        $timeout = [int](Get-OptionalValue $check 'timeout' 0)
        $settings = Get-OptionalValue $check 'settings'
        switch ($kind) {
            'ExclusiveLock' {
                if ($result.Contains('exclusiveLock')) { break }
                $result.exclusiveLock = [ordered]@{ enabled = $true }
                if ($timeout -gt 0) { $result.exclusiveLock.timeoutMinutes = $timeout }
            }
            'BranchControl' {
                if ($result.Contains('branchControl')) { break }
                $branches = @(([string](Get-OptionalValue $settings 'inputs.allowedBranches' '')) -split ',' |
                        ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
                $result.branchControl = [ordered]@{
                    enabled = $true
                    allowedBranches = $branches
                    verifyBranchProtection = ConvertTo-Bool (Get-OptionalValue $settings 'inputs.ensureProtectionOfBranch' 'false')
                }
                if ($timeout -gt 0) { $result.branchControl.timeoutMinutes = $timeout }
            }
            'Approval' {
                if ($result.Contains('approval')) { break }
                $approvers = @(foreach ($approver in @(Get-OptionalValue $settings 'approvers' @())) { Get-ApproverName -Connection $Connection -Approver $approver })
                $result.approval = [ordered]@{
                    enabled = $true
                    approvers = $approvers
                    minRequiredApprovers = [Math]::Max(1, [int](Get-OptionalValue $settings 'minRequiredApprovers' 1))
                    requesterCannotBeApprover = ConvertTo-Bool (Get-OptionalValue $settings 'requesterCannotBeApprover' $false)
                    executionOrder = ConvertTo-ExecutionOrder (Get-OptionalValue $settings 'executionOrder' 'anyOrder')
                }
                $instructions = [string](Get-OptionalValue $settings 'instructions' '')
                if ($instructions) { $result.approval.instructions = $instructions }
                if ($timeout -gt 0) { $result.approval.timeoutMinutes = $timeout }
            }
            default {
                Write-Warning "$($Environment.name): '$(Get-OptionalValue $check 'type.name' '?')' check is not exported (not managed by this playbook)."
            }
        }
    }
    $result
}

function Export-EnvironmentGroup {
    <#
    .SYNOPSIS
        Writes one <group>.json per environment group of the system. Emits the paths written.
    .PARAMETER Group
        Export only these groups. Default: every group found.
    .PARAMETER Force
        Overwrite existing files. Without it an existing file is an error, so an export never
        silently replaces reviewed configuration.
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $Connection,
        [Parameter(Mandatory)] [string] $System,
        [string[]] $Group = @(),
        [Parameter(Mandatory)] [string] $OutputDirectory,
        [string] $SchemaReference = '../schemas/environments.schema.json',
        [switch] $Force
    )
    $pattern = '^' + [regex]::Escape($System) + '\s+-\s+(?<group>[^-\s]+)(?:\s+-\s+.+)?$'
    $byGroup = [ordered]@{}
    foreach ($environment in @(Get-ActualEnvironment -Connection $Connection | Sort-Object { [string]$_.name })) {
        $match = [regex]::Match([string]$environment.name, $pattern)
        if (-not $match.Success) { continue }
        $name = $match.Groups['group'].Value
        if ($Group.Count -gt 0 -and $Group -notcontains $name) { continue }
        if (-not $byGroup.Contains($name)) { $byGroup[$name] = [Collections.Generic.List[object]]::new() }
        $byGroup[$name].Add($environment)
    }
    if ($byGroup.Count -eq 0) { Write-Warning "No environments named '$System - <group>[ - <suffix>]' found."; return }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) { $null = New-Item -ItemType Directory -Path $OutputDirectory }
    foreach ($name in $byGroup.Keys) {
        $file = Join-Path $OutputDirectory "$name.json"
        if ((Test-Path -LiteralPath $file) -and -not $Force) { throw "$file already exists; pass -Force to overwrite it." }
        # Base environment first, then the suffixed ones alphabetically.
        $environments = @($byGroup[$name] | Sort-Object { [string]$_.name -ne "$System - $name" }, { [string]$_.name })
        $document = [ordered]@{
            '$schema' = $SchemaReference
            system = $System
            group = $name
            environments = @(foreach ($environment in $environments) { ConvertTo-ExportedEnvironment -Connection $Connection -Environment $environment })
        }
        $json = ConvertTo-Json -InputObject $document -Depth 10
        [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($file), $json + "`n", [Text.UTF8Encoding]::new($false))
        $file
    }
}
