Set-StrictMode -Version Latest

<#
    Deploy all and redeploy: queue the pipeline of every component, wave by wave, and wait for each
    wave to succeed before starting the next one. The component pipelines do the real work in their
    own deployment jobs, bound to their own Azure DevOps environments, so every check (lock, branch
    control, approval) still applies - orchestration never bypasses a gate.

      DeployAll: the latest commit of each component's branch.
      Redeploy:  the exact commit that last deployed successfully to the environment, read from the
                 deployment history of the Azure DevOps environment.
#>

function Get-PipelineId {
    <# Maps pipeline names to IDs; throws when one does not exist, before anything is queued. #>
    param([Parameter(Mandatory)] [hashtable] $Connection, [Parameter(Mandatory)] [string[]] $Name)
    $ids = @{}
    foreach ($pipeline in @(Invoke-AzDevOps -Connection $Connection -Path "pipelines?`$top=1000&api-version=7.1" -All)) {
        $ids[[string]$pipeline.name] = $pipeline.id
    }
    $missing = @($Name | Where-Object { -not $ids.ContainsKey($_) })
    if ($missing.Count -gt 0) { throw "Pipeline(s) not found in project '$($Connection.Project)': $($missing -join ', ')." }
    $ids
}

function Get-LastSuccessfulDeployment {
    <#
    .SYNOPSIS
        The run and commit that last deployed the pipeline successfully to the Azure DevOps environment,
        or $null when there is none.
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $Connection,
        [Parameter(Mandatory)] [object] $EnvironmentId,
        [Parameter(Mandatory)] [object] $PipelineId
    )
    $records = @(Invoke-AzDevOps -Connection $Connection -Path "distributedtask/environments/$EnvironmentId/environmentdeploymentrecords?top=100&api-version=7.1" -All)
    $last = @($records |
            Where-Object { "$(Get-OptionalValue $_ 'definition.id' '')" -eq "$PipelineId" -and [string](Get-OptionalValue $_ 'result' '') -eq 'succeeded' } |
            Sort-Object { [datetime](Get-OptionalValue $_ 'finishTime' '0001-01-01') } -Descending |
            Select-Object -First 1)
    if ($last.Count -eq 0) { return $null }
    $runId = Get-OptionalValue $last[0] 'owner.id'
    $build = Invoke-AzDevOps -Connection $Connection -Path "build/builds/${runId}?api-version=7.1"
    [pscustomobject]@{
        RunId = $runId
        Branch = [string](Get-OptionalValue $build 'sourceBranch' '')
        Version = [string](Get-OptionalValue $build 'sourceVersion' '')
        FinishTime = Get-OptionalValue $last[0] 'finishTime'
    }
}

function Get-RolloutPlan {
    <#
    .SYNOPSIS
        The deployment plan enriched with pipeline IDs and, for Redeploy, the version to deploy again.
        Reads only.
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $Connection,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $System,
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [ValidateSet('DeployAll', 'Redeploy')] [string] $Mode
    )
    $plan = @(Get-DeploymentPlan -System $System -Environment $Environment)
    $pipelineIds = Get-PipelineId -Connection $Connection -Name @($plan | ForEach-Object { $_.Pipeline } | Select-Object -Unique)
    $environmentIds = @{}
    if ($Mode -eq 'Redeploy') {
        foreach ($adoEnvironment in @(Get-ActualEnvironment -Connection $Connection)) { $environmentIds[[string]$adoEnvironment.name] = $adoEnvironment.id }
    }
    foreach ($item in $plan) {
        $branch = $item.Branch
        $version = $null
        if ($Mode -eq 'Redeploy') {
            $where = "'$($item.Component)' to '$($item.AzureDevOpsEnvironment)'"
            if (-not $environmentIds.ContainsKey($item.AzureDevOpsEnvironment)) { throw "Cannot redeploy ${where}: the Azure DevOps environment does not exist." }
            $last = Get-LastSuccessfulDeployment -Connection $Connection -EnvironmentId $environmentIds[$item.AzureDevOpsEnvironment] -PipelineId $pipelineIds[$item.Pipeline]
            if ($null -eq $last) { throw "Cannot redeploy ${where}: no successful deployment found. Use DeployAll first." }
            if ($last.Branch) { $branch = $last.Branch }
            $version = $last.Version
        }
        [pscustomobject]@{
            Wave = $item.Wave
            Component = $item.Component
            Pipeline = $item.Pipeline
            PipelineId = $pipelineIds[$item.Pipeline]
            Branch = $branch
            Version = $version
            AzureDevOpsEnvironment = $item.AzureDevOpsEnvironment
            ResourceGroup = $item.ResourceGroup
        }
    }
}

function Start-ComponentRun {
    param([Parameter(Mandatory)] [hashtable] $Connection, [Parameter(Mandatory)] [object] $Item, [Parameter(Mandatory)] [string] $Environment)
    $self = @{ refName = $Item.Branch }
    if ($Item.Version) { $self.version = $Item.Version }
    $body = @{
        resources = @{ repositories = @{ self = $self } }
        templateParameters = @{ environment = $Environment }
    }
    Invoke-AzDevOps -Connection $Connection -Method POST -Path "pipelines/$($Item.PipelineId)/runs?api-version=7.1" -Body $body
}

function Invoke-RolloutPlan {
    <#
    .SYNOPSIS
        Queues the runs wave by wave and waits for every run of a wave. Stops at the first wave with a
        failed, cancelled or timed-out run: later waves are not started. Emits one result per run.
    .PARAMETER Sleep
        How to wait between polls; tests pass a no-op.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Connection,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plan,
        [Parameter(Mandatory)] [string] $Environment,
        [ValidateRange(1, 3600)] [int] $PollSeconds = 30,
        [ValidateRange(1, 1440)] [int] $TimeoutMinutes = 180,
        [scriptblock] $Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )
    $maxPolls = [Math]::Ceiling(($TimeoutMinutes * 60) / $PollSeconds)
    foreach ($wave in @($Plan | Group-Object -Property Wave | Sort-Object { [int]$_.Name })) {
        $runs = [Collections.Generic.List[object]]::new()
        foreach ($item in $wave.Group) {
            $target = "$($item.Pipeline) -> $($item.AzureDevOpsEnvironment)"
            $what = if ($item.Version) { "Queue run at $($item.Version)" } else { "Queue run on $($item.Branch)" }
            if (-not $PSCmdlet.ShouldProcess($target, $what)) { continue }
            $run = Start-ComponentRun -Connection $Connection -Item $item -Environment $Environment
            Write-Host "wave $($wave.Name): queued $($item.Pipeline) run $($run.id)"
            $runs.Add([pscustomobject]@{ Wave = [int]$wave.Name; Component = $item.Component; Pipeline = $item.Pipeline; PipelineId = $item.PipelineId; RunId = $run.id; State = 'inProgress'; Result = $null })
        }
        if ($runs.Count -eq 0) { continue }

        $poll = 0
        while (@($runs | Where-Object { $_.State -ne 'completed' }).Count -gt 0 -and $poll -lt $maxPolls) {
            $poll++
            & $Sleep $PollSeconds
            foreach ($run in @($runs | Where-Object { $_.State -ne 'completed' })) {
                $status = Invoke-AzDevOps -Connection $Connection -Path "pipelines/$($run.PipelineId)/runs/$($run.RunId)?api-version=7.1"
                $run.State = [string](Get-OptionalValue $status 'state' 'inProgress')
                if ($run.State -eq 'completed') { $run.Result = [string](Get-OptionalValue $status 'result' 'unknown') }
            }
        }
        foreach ($run in $runs) {
            if ($run.State -ne 'completed') { $run.Result = 'timedOut' }
            $run
        }
        $failed = @($runs | Where-Object { $_.Result -ne 'succeeded' })
        if ($failed.Count -gt 0) {
            throw "Wave $($wave.Name) did not succeed ($(@($failed | ForEach-Object { "$($_.Component): $($_.Result)" }) -join ', ')); later waves were not started."
        }
    }
}
