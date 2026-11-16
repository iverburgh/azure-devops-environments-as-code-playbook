Set-StrictMode -Version Latest

<#
    Pure planning logic for orchestrating a complete environment, driven by orchestration/system.json:
      - the dependency waves in which components are deployed (deploy all, redeploy)
      - the reverse order in which they are removed, including everything that depends on them
      - the guards that decide whether an action is allowed on an environment at all
    Nothing in this file calls Azure or Azure DevOps.
#>

function Get-DependencyWave {
    <#
    .SYNOPSIS
        Topological sort (Kahn) that groups components into waves: every component in wave N only
        depends on components in earlier waves, so a wave can be deployed in parallel.
        Emits @{ Wave; Name } in wave order, and within a wave in declaration order.
    #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Components)
    $remaining = [Collections.Generic.List[object]]::new()
    foreach ($component in $Components) { $remaining.Add($component) }
    $done = @{}
    $wave = 0
    while ($remaining.Count -gt 0) {
        $wave++
        $ready = @($remaining | Where-Object {
                $component = $_
                @($component.DependsOn | Where-Object { -not $done.ContainsKey($_) }).Count -eq 0
            })
        if ($ready.Count -eq 0) {
            throw "Dependency cycle between: $(@($remaining | ForEach-Object { $_.Name }) -join ', ')."
        }
        foreach ($component in $ready) {
            [pscustomobject]@{ Wave = $wave; Name = $component.Name }
            $null = $remaining.Remove($component)
        }
        foreach ($component in $ready) { $done[$component.Name] = $true }
    }
}

function Get-ComponentClosure {
    <# The given components plus everything that (transitively) depends on them. #>
    param(
        [Parameter(Mandatory)] [object[]] $Components,
        [Parameter(Mandatory)] [string[]] $Name
    )
    $known = @{}
    foreach ($component in $Components) { $known[$component.Name] = $component }
    foreach ($item in $Name) {
        if (-not $known.ContainsKey($item)) { throw "Unknown component '$item'. Known: $(@($Components | ForEach-Object { $_.Name }) -join ', ')." }
    }
    $selected = @{}
    foreach ($item in $Name) { $selected[$item] = $true }
    do {
        $added = $false
        foreach ($component in $Components) {
            if ($selected.ContainsKey($component.Name)) { continue }
            if (@($component.DependsOn | Where-Object { $selected.ContainsKey($_) }).Count -gt 0) {
                $selected[$component.Name] = $true
                $added = $true
            }
        }
    } while ($added)
    foreach ($component in $Components) { if ($selected.ContainsKey($component.Name)) { $component.Name } }
}

function Get-DeploymentPlan {
    <#
    .SYNOPSIS
        Every component of the system with the environment, pipeline and branch to deploy, in waves.
    #>
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $System,
        [Parameter(Mandatory)] [string] $Environment
    )
    $byName = @{}
    foreach ($component in $System.Components) { $byName[$component.Name] = $component }
    foreach ($entry in @(Get-DependencyWave -Components $System.Components)) {
        $component = $byName[$entry.Name]
        [pscustomobject]@{
            Wave = $entry.Wave
            Component = $component.Name
            Pipeline = $component.Pipeline
            Branch = $component.Branch
            AzureDevOpsEnvironment = Get-ComponentEnvironmentName -System $System -Component $component -Environment $Environment
            ResourceGroup = $component.ResourceGroup.Replace('{env}', $Environment)
        }
    }
}

function Get-RemovalPlan {
    <#
    .SYNOPSIS
        The resource groups to delete, in reverse dependency order: dependents before what they depend on.
    .PARAMETER Components
        Remove only these components - and, automatically, everything that depends on them, because
        a component cannot keep running without its dependencies. Default: all components.
    #>
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $System,
        [Parameter(Mandatory)] [string] $Environment,
        [string[]] $Components = @()
    )
    $selected = @{}
    $names = if ($Components.Count -gt 0) { @(Get-ComponentClosure -Components $System.Components -Name $Components) }
    else { @($System.Components | ForEach-Object { $_.Name }) }
    foreach ($name in $names) { $selected[$name] = $true }

    $byName = @{}
    foreach ($component in $System.Components) { $byName[$component.Name] = $component }
    $waves = @(Get-DependencyWave -Components $System.Components | Where-Object { $selected.ContainsKey($_.Name) })
    $ordered = @($waves | Sort-Object -Stable -Property @{ Expression = 'Wave'; Descending = $true })
    $step = 0
    foreach ($entry in $ordered) {
        $step++
        $component = $byName[$entry.Name]
        [pscustomobject]@{
            Step = $step
            Wave = $entry.Wave
            Component = $component.Name
            ResourceGroup = $component.ResourceGroup.Replace('{env}', $Environment)
        }
    }
}

function Test-ProductionLikeName {
    <# A last line of defence that does not depend on configuration: names that look like production. #>
    param([Parameter(Mandatory)] [string] $Name)
    $Name -match '(^|[-_ .])(prd|prod|production|live)($|[-_ .])'
}

function Assert-EnvironmentAction {
    <#
    .SYNOPSIS
        Throws unless the action is allowed on the environment according to system.json.
        Remove is refused for protected environments and for production-like names, whatever the
        configuration says, so a configuration mistake cannot delete production.
    #>
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $System,
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [ValidateSet('DeployAll', 'Redeploy', 'Remove')] [string] $Action
    )
    if (-not $System.Environments.Contains($Environment)) {
        throw "Unknown environment '$Environment'. Known: $(@($System.Environments.Keys) -join ', ')."
    }
    $settings = $System.Environments[$Environment]
    if ($Action -eq 'Remove') {
        if ($settings.Protected) { throw "Refused: environment '$Environment' is protected; remove is never allowed." }
        if (Test-ProductionLikeName -Name $Environment) { throw "Refused: '$Environment' looks like a production environment; remove is never allowed." }
    }
    if (-not $settings[$Action]) {
        throw "Refused: $Action is not enabled for environment '$Environment' in system.json."
    }
}

function Assert-RemovalConfirmed {
    <#
    .SYNOPSIS
        The caller must type the environment name exactly (case-sensitive), like deleting a
        repository on GitHub. Skipped for -WhatIf, which changes nothing.
    #>
    param(
        [Parameter(Mandatory)] [string] $Environment,
        [AllowEmptyString()] [AllowNull()] [string] $Confirmation,
        [switch] $WhatIfMode
    )
    if ($WhatIfMode) { return }
    if ($Confirmation -cne $Environment) {
        throw "Refused: pass -Confirmation '$Environment' (the exact environment name) to remove it."
    }
}

function Write-OrchestrationPlan {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plan, [Parameter(Mandatory)] [string] $Title)
    Write-Host "${Title}:"
    if ($Plan.Count -eq 0) { Write-Host '  nothing to do'; return }
    foreach ($item in $Plan) {
        if ($item.PSObject.Properties['Step']) {
            Write-Host ("  {0,2}. {1,-14} {2}" -f $item.Step, $item.Component, $item.ResourceGroup)
        }
        else {
            $version = if ($item.PSObject.Properties['Version'] -and $item.Version) { " @ $($item.Version)" } else { '' }
            Write-Host ("  wave {0}  {1,-14} {2} -> {3}{4}" -f $item.Wave, $item.Component, $item.Pipeline, $item.AzureDevOpsEnvironment, $version)
        }
    }
}
