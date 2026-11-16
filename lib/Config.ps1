Set-StrictMode -Version Latest

<#
    Loads and validates the configuration:
      - environments/<group>.json  against schemas/environments.schema.json
      - orchestration/system.json  against schemas/system.schema.json
    The schemas document the format; this file adds the rules a schema cannot express (unique names,
    naming convention, group policy, dependency graph, consistency between the two) and fills in the
    defaults, so the rest of the code can rely on every value being present.
#>

function Get-PlaybookRoot { Split-Path -Parent $PSScriptRoot }

function Get-SchemaProblem {
    <# Emits one message per schema violation; nothing when the JSON is valid. #>
    param([Parameter(Mandatory)] [string] $Json, [Parameter(Mandatory)] [string] $SchemaPath)
    $schema = Get-Content -LiteralPath $SchemaPath -Raw
    $schemaErrors = $null
    if (-not (Test-Json -Json $Json -Schema $schema -ErrorVariable schemaErrors -ErrorAction SilentlyContinue)) {
        $messages = @(foreach ($schemaError in @($schemaErrors)) { if ($schemaError) { "schema: $($schemaError.Exception.Message)" } })
        # Some PowerShell versions (7.6.8, 7.6.9) return false without reporting violations inside a $ref.
        if ($messages.Count -eq 0) { $messages = @('schema: the JSON does not match the schema (Test-Json reported no details).') }
        foreach ($message in $messages) { $message }
    }
}

function ConvertTo-EnvironmentModel {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Raw)
    $lock = Get-OptionalValue $Raw 'exclusiveLock'
    $branch = Get-OptionalValue $Raw 'branchControl'
    $approval = Get-OptionalValue $Raw 'approval'
    [ordered]@{
        Name = $Raw.name
        Description = Get-OptionalValue $Raw 'description'
        PolicyExemption = Get-OptionalValue $Raw 'policyExemption'
        ExclusiveLock = @{
            Enabled = [bool](Get-OptionalValue $lock 'enabled' $false)
            TimeoutMinutes = [int](Get-OptionalValue $lock 'timeoutMinutes' 43200)
        }
        BranchControl = @{
            Enabled = [bool](Get-OptionalValue $branch 'enabled' $false)
            AllowedBranches = @(Get-OptionalValue $branch 'allowedBranches' @())
            VerifyBranchProtection = [bool](Get-OptionalValue $branch 'verifyBranchProtection' $false)
            TimeoutMinutes = [int](Get-OptionalValue $branch 'timeoutMinutes' 1440)
        }
        Approval = @{
            Enabled = [bool](Get-OptionalValue $approval 'enabled' $false)
            Approvers = @(Get-OptionalValue $approval 'approvers' @())
            MinRequiredApprovers = [int](Get-OptionalValue $approval 'minRequiredApprovers' 1)
            RequesterCannotBeApprover = [bool](Get-OptionalValue $approval 'requesterCannotBeApprover' $false)
            ExecutionOrder = [string](Get-OptionalValue $approval 'executionOrder' 'anyOrder')
            Instructions = [string](Get-OptionalValue $approval 'instructions' '')
            TimeoutMinutes = [int](Get-OptionalValue $approval 'timeoutMinutes' 4320)
        }
    }
}

function ConvertTo-EnvironmentGroupModel {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Raw, [string] $File)
    [ordered]@{
        File = $File
        System = $Raw.system
        Group = $Raw.group
        Policy = @{
            RequireFourEyes = [bool](Get-OptionalValue $Raw 'policy.requireFourEyes' $false)
            RequireBranchControl = [bool](Get-OptionalValue $Raw 'policy.requireBranchControl' $false)
            RequireExclusiveLock = [bool](Get-OptionalValue $Raw 'policy.requireExclusiveLock' $false)
        }
        Security = @{
            Administrators = @(Get-OptionalValue $Raw 'security.administrators' @())
            RemoveCreatorRole = [bool](Get-OptionalValue $Raw 'security.removeCreatorRole' $false)
        }
        Environments = @(foreach ($environment in @($Raw.environments)) { ConvertTo-EnvironmentModel -Raw $environment })
    }
}

function Get-EnvironmentRuleProblem {
    <# The rules a schema cannot express. Emits one message per problem. #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Groups)
    $systems = @($Groups | ForEach-Object { $_.System } | Sort-Object -Unique)
    if ($systems.Count -gt 1) { "All files must use the same system; found: $($systems -join ', ')." }

    $seenGroups = @{}
    $seenNames = @{}
    foreach ($group in $Groups) {
        $file = Split-Path -Leaf $group.File
        if ($seenGroups.ContainsKey($group.Group)) { "${file}: group '$($group.Group)' is also defined in $($seenGroups[$group.Group])." }
        $seenGroups[$group.Group] = $file
        $base = "$($group.System) - $($group.Group)"

        foreach ($environment in $group.Environments) {
            $name = $environment.Name
            $where = "${file}: '$name'"
            if ($name -ne $base -and -not ($name.StartsWith("$base - ") -and $name.Length -gt "$base - ".Length)) {
                "${where} must be named '$base' or '$base - <suffix>'."
            }
            if ($seenNames.ContainsKey($name)) { "${where} is defined twice (environment names are case-insensitive)." }
            $seenNames[$name] = $true

            $branch = $environment.BranchControl
            if ($branch.Enabled -and $branch.AllowedBranches.Count -eq 0) { "${where}: branchControl is enabled but allowedBranches is empty." }
            $approval = $environment.Approval
            if ($approval.Enabled) {
                if ($approval.Approvers.Count -eq 0) { "${where}: approval is enabled but has no approvers." }
                elseif ($approval.MinRequiredApprovers -gt $approval.Approvers.Count) {
                    "${where}: minRequiredApprovers ($($approval.MinRequiredApprovers)) is larger than the number of approvers ($($approval.Approvers.Count)); a group counts as one approver."
                }
            }

            if ($environment.PolicyExemption) { continue }
            if ($group.Policy.RequireFourEyes -and -not ($approval.Enabled -and $approval.RequesterCannotBeApprover)) {
                "${where}: group policy requireFourEyes needs an approval with requesterCannotBeApprover = true (or a policyExemption)."
            }
            if ($group.Policy.RequireBranchControl -and -not $branch.Enabled) {
                "${where}: group policy requireBranchControl needs branchControl (or a policyExemption)."
            }
            if ($group.Policy.RequireExclusiveLock -and -not $environment.ExclusiveLock.Enabled) {
                "${where}: group policy requireExclusiveLock needs exclusiveLock (or a policyExemption)."
            }
        }
    }
}

function Get-EnvironmentConfigResult {
    <# Validates environment group files. Returns @{ Groups; Problems } and never throws on invalid content. #>
    param(
        [Parameter(Mandatory)] [string[]] $Path,
        [string] $SchemaPath = (Join-Path (Get-PlaybookRoot) 'schemas/environments.schema.json')
    )
    $problems = [Collections.Generic.List[string]]::new()
    $groups = [Collections.Generic.List[object]]::new()
    $files = @(Resolve-ConfigFile -Path $Path)
    if ($files.Count -eq 0) { $problems.Add("No *.json files found in $($Path -join ', ').") }

    foreach ($file in $files) {
        $json = Get-Content -LiteralPath $file -Raw
        $schemaProblems = @(Get-SchemaProblem -Json $json -SchemaPath $SchemaPath)
        if ($schemaProblems.Count -gt 0) {
            foreach ($problem in $schemaProblems) { $problems.Add("$(Split-Path -Leaf $file): $problem") }
            continue
        }
        $groups.Add((ConvertTo-EnvironmentGroupModel -Raw ($json | ConvertFrom-Json -AsHashtable) -File $file))
    }
    if ($problems.Count -eq 0) {
        foreach ($problem in @(Get-EnvironmentRuleProblem -Groups $groups.ToArray())) { $problems.Add($problem) }
    }
    @{ Groups = $groups.ToArray(); Problems = $problems.ToArray() }
}

function Read-EnvironmentConfig {
    <# Loads environment group files; throws with every problem when one is invalid. Emits the groups. #>
    param(
        [Parameter(Mandatory)] [string[]] $Path,
        [string] $SchemaPath = (Join-Path (Get-PlaybookRoot) 'schemas/environments.schema.json')
    )
    $result = Get-EnvironmentConfigResult -Path $Path -SchemaPath $SchemaPath
    if ($result.Problems.Count -gt 0) {
        throw "Environment configuration is invalid:`n - $($result.Problems -join "`n - ")"
    }
    foreach ($group in $result.Groups) { $group }
}

function ConvertTo-SystemModel {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Raw, [string] $File)
    $environments = [ordered]@{}
    foreach ($key in $Raw.environments.Keys) {
        $value = $Raw.environments[$key]
        $environments[$key] = @{
            Name = $key
            SubscriptionId = $value.subscriptionId
            Protected = [bool](Get-OptionalValue $value 'protected' $false)
            DeployAll = [bool](Get-OptionalValue $value 'deployAll' $false)
            Redeploy = [bool](Get-OptionalValue $value 'redeploy' $false)
            Remove = [bool](Get-OptionalValue $value 'remove' $false)
        }
    }
    $defaultBranch = [string](Get-OptionalValue $Raw 'defaultBranch' 'refs/heads/main')
    $cleanup = Get-OptionalValue $Raw 'cleanup'
    [ordered]@{
        File = $File
        System = $Raw.system
        DefaultBranch = $defaultBranch
        Environments = $environments
        Components = @(foreach ($component in @($Raw.components)) {
                @{
                    Name = $component.name
                    Pipeline = $component.pipeline
                    Branch = [string](Get-OptionalValue $component 'branch' $defaultBranch)
                    EnvironmentSuffix = Get-OptionalValue $component 'environmentSuffix'
                    ResourceGroup = $component.resourceGroup
                    DependsOn = @(Get-OptionalValue $component 'dependsOn' @())
                }
            })
        Cleanup = if ($null -eq $cleanup) { $null } else {
            @{
                ResourceGroupPattern = $cleanup.resourceGroupPattern
                ProtectedRoleNames = @(Get-OptionalValue $cleanup 'protectedRoleNames' @('Owner', 'User Access Administrator'))
                MinimumAgeDays = [int](Get-OptionalValue $cleanup 'minimumAgeDays' 7)
                MaxOrphanRatio = [double](Get-OptionalValue $cleanup 'maxOrphanRatio' 0.5)
                MinimumAssignmentsForRatioCheck = [int](Get-OptionalValue $cleanup 'minimumAssignmentsForRatioCheck' 20)
            }
        }
    }
}

function Get-SystemRuleProblem {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $System)
    $problems = [Collections.Generic.List[string]]::new()
    $names = @{}
    foreach ($component in $System.Components) {
        if ($names.ContainsKey($component.Name)) { $problems.Add("Component '$($component.Name)' is defined twice.") }
        $names[$component.Name] = $true
    }
    foreach ($component in $System.Components) {
        foreach ($dependency in $component.DependsOn) {
            if ($dependency -eq $component.Name) { $problems.Add("Component '$($component.Name)' depends on itself.") }
            elseif (-not $names.ContainsKey($dependency)) { $problems.Add("Component '$($component.Name)' depends on unknown component '$dependency'.") }
        }
    }
    if ($problems.Count -eq 0) {
        try { $null = @(Get-DependencyWave -Components $System.Components) }
        catch { $problems.Add($_.Exception.Message) }
    }
    foreach ($environment in $System.Environments.Values) {
        if ($environment.Protected -and $environment.Remove) {
            $problems.Add("Environment '$($environment.Name)' is protected and can therefore not allow remove.")
        }
    }
    foreach ($problem in $problems) { $problem }
}

function Get-SystemConfigResult {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $SchemaPath = (Join-Path (Get-PlaybookRoot) 'schemas/system.schema.json')
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ System = $null; Problems = @("System configuration '$Path' does not exist.") } }
    $json = Get-Content -LiteralPath $Path -Raw
    $problems = @(Get-SchemaProblem -Json $json -SchemaPath $SchemaPath | ForEach-Object { "$(Split-Path -Leaf $Path): $_" })
    if ($problems.Count -gt 0) { return @{ System = $null; Problems = $problems } }
    $system = ConvertTo-SystemModel -Raw ($json | ConvertFrom-Json -AsHashtable) -File $Path
    @{ System = $system; Problems = @(Get-SystemRuleProblem -System $system | ForEach-Object { "$(Split-Path -Leaf $Path): $_" }) }
}

function Read-SystemConfig {
    param(
        [string] $Path = (Join-Path (Get-PlaybookRoot) 'orchestration/system.json'),
        [string] $SchemaPath = (Join-Path (Get-PlaybookRoot) 'schemas/system.schema.json')
    )
    $result = Get-SystemConfigResult -Path $Path -SchemaPath $SchemaPath
    if ($result.Problems.Count -gt 0) {
        throw "System configuration is invalid:`n - $($result.Problems -join "`n - ")"
    }
    $result.System
}

function Get-CrossConfigProblem {
    <# Consistency between orchestration/system.json and environments/*.json. #>
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $System,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Groups
    )
    $names = @{}
    $groupNames = @{}
    foreach ($group in $Groups) {
        if ($group.System -ne $System.System) { "$(Split-Path -Leaf $group.File): system '$($group.System)' differs from '$($System.System)' in system.json." }
        $groupNames[$group.Group] = $true
        foreach ($environment in $group.Environments) { $names[$environment.Name] = $true }
    }
    foreach ($environment in $System.Environments.Values) {
        if (-not $groupNames.ContainsKey($environment.Name)) {
            "system.json: environment '$($environment.Name)' has no environments/$($environment.Name).json."
            continue
        }
        foreach ($component in $System.Components) {
            $name = Get-ComponentEnvironmentName -System $System -Component $component -Environment $environment.Name
            if (-not $names.ContainsKey($name)) { "system.json: component '$($component.Name)' deploys to '$name', which is not defined in environments/$($environment.Name).json." }
        }
        if ($environment.Remove) {
            $gate = "$($System.System) - $($environment.Name) - RemoveAll"
            if (-not $names.ContainsKey($gate)) { "system.json: environment '$($environment.Name)' allows remove, so '$gate' (the approval gate) must be defined." }
        }
    }
}

function Get-ComponentEnvironmentName {
    <# The Azure DevOps environment a component's deployment job binds to. #>
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $System,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Component,
        [Parameter(Mandatory)] [string] $Environment
    )
    $name = "$($System.System) - $Environment"
    if ($Component.EnvironmentSuffix) { $name = "$name - $($Component.EnvironmentSuffix)" }
    $name
}
