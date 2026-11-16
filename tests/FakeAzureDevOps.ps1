Set-StrictMode -Version Latest

<#
    In-memory fake of the parts of the Azure DevOps REST API the playbook uses. Tests replace
    Invoke-AzDevOps with Invoke-FakeAzDevOps; responses are objects, like Invoke-RestMethod returns.
    State is global because the entry scripts run in their own scope. Every write is recorded in
    $global:Fake.Writes, so a test can prove that nothing was written. Unsupported calls throw, so
    a test never passes because a call silently did nothing.
#>

function ConvertTo-FakeResponse {
    param([AllowNull()] [object] $Value)
    if ($null -eq $Value) { return $null }
    ConvertTo-Json -InputObject $Value -Depth 20 | ConvertFrom-Json
}

function New-FakeId {
    $global:Fake.NextId++
    $global:Fake.NextId
}

function Reset-FakeAzureDevOps {
    <# An empty project with the identities the sample configuration refers to. #>
    $identities = [ordered]@{
        '[shop]\Release Administrators' = '00000000-0000-0000-0000-00000000a001'
        '[shop]\Platform Team' = '00000000-0000-0000-0000-00000000a002'
        '[shop]\Test Managers' = '00000000-0000-0000-0000-00000000a003'
        '[shop]\Production Approvers' = '00000000-0000-0000-0000-00000000a004'
        '[shop]\Database Administrators' = '00000000-0000-0000-0000-00000000a005'
        'alice@example.com' = '00000000-0000-0000-0000-00000000a006'
    }
    $global:Fake = @{
        NextId = 100
        ProjectId = '00000000-0000-0000-0000-00000000b001'
        AuthenticatedUserId = '00000000-0000-0000-0000-00000000c001'
        Identities = @{}
        Environments = [Collections.Generic.List[hashtable]]::new()
        Checks = [Collections.Generic.List[hashtable]]::new()
        RoleAssignments = [Collections.Generic.List[hashtable]]::new()
        Pipelines = [Collections.Generic.List[hashtable]]::new()
        Runs = [Collections.Generic.List[hashtable]]::new()
        RunResults = @{}
        PollsUntilComplete = 2
        DeploymentRecords = @{}
        Builds = @{}
        Writes = [Collections.Generic.List[string]]::new()
        Calls = [Collections.Generic.List[string]]::new()
    }
    foreach ($name in $identities.Keys) {
        $global:Fake.Identities[$name] = @{ id = $identities[$name]; providerDisplayName = $name }
    }
}

function Add-FakeEnvironment {
    param([Parameter(Mandatory)] [string] $Name, [string] $Description = '')
    $environment = @{ id = (New-FakeId); name = $Name; description = $Description }
    $global:Fake.Environments.Add($environment)
    $environment
}

function Add-FakeCheck {
    <# Adds a check directly, as if someone created it in the portal. #>
    param(
        [Parameter(Mandatory)] [hashtable] $Environment,
        [Parameter(Mandatory)] [hashtable] $Type,
        [hashtable] $Settings = @{},
        [int] $Timeout = 43200
    )
    $check = @{
        id = (New-FakeId)
        type = $Type
        settings = $Settings
        resource = @{ type = 'environment'; id = "$($Environment.id)"; name = $Environment.name }
        timeout = $Timeout
    }
    $global:Fake.Checks.Add($check)
    $check
}

function Get-FakeChecks {
    <# The checks of an environment, by environment name. #>
    param([Parameter(Mandatory)] [string] $EnvironmentName)
    $global:Fake.Checks | Where-Object { $_.resource.name -eq $EnvironmentName }
}

function Add-FakePipeline {
    param([Parameter(Mandatory)] [string] $Name)
    $pipeline = @{ id = (New-FakeId); name = $Name }
    $global:Fake.Pipelines.Add($pipeline)
    $pipeline
}

function Add-FakeDeploymentRecord {
    param(
        [Parameter(Mandatory)] [hashtable] $Environment,
        [Parameter(Mandatory)] [hashtable] $Pipeline,
        [Parameter(Mandatory)] [string] $Result,
        [Parameter(Mandatory)] [datetime] $FinishTime,
        [string] $Branch = 'refs/heads/main',
        [string] $Version = ''
    )
    $runId = New-FakeId
    $key = "$($Environment.id)"
    if (-not $global:Fake.DeploymentRecords.ContainsKey($key)) { $global:Fake.DeploymentRecords[$key] = [Collections.Generic.List[hashtable]]::new() }
    $global:Fake.DeploymentRecords[$key].Add(@{
            id = (New-FakeId)
            environmentId = $Environment.id
            definition = @{ id = $Pipeline.id; name = $Pipeline.name }
            owner = @{ id = $runId; name = "$runId" }
            result = $Result
            finishTime = $FinishTime.ToString('o')
        })
    $global:Fake.Builds["$runId"] = @{ id = $runId; sourceBranch = $Branch; sourceVersion = $Version }
}

function Split-FakePath {
    param([string] $Path)
    $parts = $Path -split '\?', 2
    $query = @{}
    if ($parts.Count -gt 1) {
        foreach ($pair in $parts[1] -split '&') {
            $kv = $pair -split '=', 2
            $query[[uri]::UnescapeDataString($kv[0])] = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1]) } else { '' }
        }
    }
    @{ Route = $parts[0]; Query = $query }
}

function Invoke-FakeAzDevOps {
    param(
        [hashtable] $Connection,
        [string] $Method = 'GET',
        [string] $Scope = 'Project',
        [string] $Path,
        [AllowNull()] [object] $Body,
        [switch] $All
    )
    if (-not $Method) { $Method = 'GET' }
    if (-not $Scope) { $Scope = 'Project' }
    $parsed = Split-FakePath $Path
    $route = $parsed.Route
    $query = $parsed.Query
    $call = "$Method $Scope $route"
    $global:Fake.Calls.Add($call)
    if ($Method -ne 'GET') { $global:Fake.Writes.Add($call) }
    $requestBody = if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 20 | ConvertFrom-Json -AsHashtable } else { $null }

    $response = $null
    $list = $null
    switch -Regex ("$Scope $Method $route") {
        '^Project GET distributedtask/environments$' {
            $list = @($global:Fake.Environments)
            break
        }
        '^Project POST distributedtask/environments$' {
            if (@($global:Fake.Environments | Where-Object { $_.name -eq $requestBody.name }).Count -gt 0) { throw "Environment '$($requestBody.name)' already exists." }
            $environment = Add-FakeEnvironment -Name $requestBody.name -Description ([string]$requestBody.description)
            # Like the real service: the creator becomes Administrator of the new environment.
            $global:Fake.RoleAssignments.Add(@{ resource = "$($global:Fake.ProjectId)_$($environment.id)"; roleName = 'Administrator'; userId = $global:Fake.AuthenticatedUserId })
            $response = $environment
            break
        }
        '^Project PATCH distributedtask/environments/(\d+)$' {
            $id = [int]$Matches[1]
            $environment = @($global:Fake.Environments | Where-Object { $_.id -eq $id })[0]
            $environment.description = [string]$requestBody.description
            $response = $environment
            break
        }
        '^Project DELETE distributedtask/environments/(\d+)$' {
            $id = [int]$Matches[1]
            $environment = @($global:Fake.Environments | Where-Object { $_.id -eq $id })[0]
            $null = $global:Fake.Environments.Remove($environment)
            foreach ($check in @($global:Fake.Checks | Where-Object { $_.resource.id -eq "$id" })) { $null = $global:Fake.Checks.Remove($check) }
            break
        }
        '^Project GET distributedtask/environments/(\d+)/environmentdeploymentrecords$' {
            $key = $Matches[1]
            $list = @()
            if ($global:Fake.DeploymentRecords.ContainsKey($key)) { $list = @($global:Fake.DeploymentRecords[$key]) }
            break
        }
        '^Project GET pipelines/checks/configurations$' {
            $list = @($global:Fake.Checks | Where-Object { $_.resource.id -eq $query['resourceId'] })
            break
        }
        '^Project POST pipelines/checks/configurations$' {
            $check = @{ id = (New-FakeId); type = $requestBody.type; settings = $requestBody.settings; resource = $requestBody.resource; timeout = $requestBody.timeout }
            $global:Fake.Checks.Add($check)
            $response = $check
            break
        }
        '^Project PATCH pipelines/checks/configurations/(\d+)$' {
            $id = [int]$Matches[1]
            $check = @($global:Fake.Checks | Where-Object { $_.id -eq $id })[0]
            $check.settings = $requestBody.settings
            $check.timeout = $requestBody.timeout
            $response = $check
            break
        }
        '^Project DELETE pipelines/checks/configurations/(\d+)$' {
            $id = [int]$Matches[1]
            $null = $global:Fake.Checks.Remove(@($global:Fake.Checks | Where-Object { $_.id -eq $id })[0])
            break
        }
        '^Identity GET identities$' {
            if ($query.ContainsKey('identityIds')) {
                $value = @($global:Fake.Identities.Values | Where-Object { $_.id -eq $query['identityIds'] })
            }
            else {
                $name = $query['filterValue']
                $value = @($global:Fake.Identities.Keys | Where-Object { $_ -eq $name } | ForEach-Object { $global:Fake.Identities[$_] })
            }
            $response = @{ count = $value.Count; value = $value }
            break
        }
        '^Organization GET projects/(.+)$' {
            $response = @{ id = $global:Fake.ProjectId; name = [uri]::UnescapeDataString($Matches[1]) }
            break
        }
        '^Organization GET connectionData$' {
            $response = @{ authenticatedUser = @{ id = $global:Fake.AuthenticatedUserId } }
            break
        }
        '^Organization PUT securityroles/scopes/distributedtask\.environmentreferencerole/roleassignments/resources/([^/]+)$' {
            $resource = $Matches[1]
            foreach ($assignment in @($requestBody)) {
                $global:Fake.RoleAssignments.Add(@{ resource = $resource; roleName = $assignment.roleName; userId = $assignment.userId })
            }
            break
        }
        '^Organization DELETE securityroles/scopes/distributedtask\.environmentreferencerole/roleassignments/resources/([^/]+)/([^/]+)$' {
            $resource = $Matches[1]
            $userId = $Matches[2]
            foreach ($assignment in @($global:Fake.RoleAssignments | Where-Object { $_.resource -eq $resource -and $_.userId -eq $userId })) {
                $null = $global:Fake.RoleAssignments.Remove($assignment)
            }
            break
        }
        '^Project GET pipelines$' {
            $list = @($global:Fake.Pipelines)
            break
        }
        '^Project POST pipelines/(\d+)/runs$' {
            $pipelineId = [int]$Matches[1]
            $pipeline = @($global:Fake.Pipelines | Where-Object { $_.id -eq $pipelineId })[0]
            $run = @{ id = (New-FakeId); pipelineId = $pipelineId; pipeline = $pipeline.name; body = $requestBody; polls = 0; state = 'inProgress'; result = $null }
            $global:Fake.Runs.Add($run)
            $response = @{ id = $run.id; state = $run.state }
            break
        }
        '^Project GET pipelines/(\d+)/runs/(\d+)$' {
            $runId = [int]$Matches[2]
            $run = @($global:Fake.Runs | Where-Object { $_.id -eq $runId })[0]
            $run.polls++
            if ($run.polls -ge $global:Fake.PollsUntilComplete) {
                $run.state = 'completed'
                $run.result = if ($global:Fake.RunResults.ContainsKey($run.pipeline)) { $global:Fake.RunResults[$run.pipeline] } else { 'succeeded' }
            }
            $response = @{ id = $run.id; state = $run.state; result = $run.result }
            break
        }
        '^Project GET build/builds/(\d+)$' {
            $response = $global:Fake.Builds[$Matches[1]]
            break
        }
        default { throw "FakeAzureDevOps does not support: $Method $Scope $Path" }
    }

    if ($All) {
        if ($list -isnot [array]) { throw "FakeAzureDevOps: -All used on a call that does not return a list: $call" }
        foreach ($item in $list) { ConvertTo-FakeResponse $item }
        return
    }
    if ($list -is [array]) { return ConvertTo-FakeResponse @{ count = $list.Count; value = $list } }
    ConvertTo-FakeResponse $response
}
