BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    Mock Invoke-AzDevOps { Invoke-FakeAzDevOps -Connection $Connection -Method $Method -Scope $Scope -Path $Path -Body $Body -All:$All }
    Mock Write-Host {}

    function Initialize-Project {
        Reset-FakeAzureDevOps
        Invoke-TestScript -Name 'Set-Environments' -Parameters @{ Organization = 'my-org'; Project = 'my-project' }
        $pipelines = @{}
        foreach ($component in (Get-SampleSystem).Components) { $pipelines[$component.Pipeline] = Add-FakePipeline -Name $component.Pipeline }
        $Fake.Writes.Clear()
        $Fake.Calls.Clear()
        $pipelines
    }

    function Invoke-Rollout {
        param([string] $Environment, [string] $Mode, [hashtable] $Extra = @{})
        $parameters = @{ Organization = 'my-org'; Project = 'my-project'; Environment = $Environment; Mode = $Mode; PollSeconds = 1; Sleep = {} }
        foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
        @(Invoke-TestScript -Name 'Invoke-Rollout' -Parameters $parameters)
    }

    function Get-FakeEnvironment { param([string] $Name) @($global:Fake.Environments | Where-Object { $_.name -eq $Name })[0] }
}

Describe 'Deploy all' {
    BeforeAll {
        $null = Initialize-Project
        $script:Results = Invoke-Rollout -Environment 'test' -Mode DeployAll
    }

    It 'runs every component pipeline once, wave by wave' {
        @($Fake.Runs | ForEach-Object { $_.pipeline }) | Should -Be @(
            'shop-network', 'shop-monitoring', 'shop-messaging', 'shop-data', 'shop-gateway', 'shop-payments-fn', 'shop-orders-api', 'shop-web-ui'
        )
        @($Results | ForEach-Object { $_.Result } | Select-Object -Unique) | Should -Be @('succeeded')
    }

    It 'starts a wave only after the previous wave completed' {
        $queued = @($Fake.Calls | Where-Object { $_ -match '^POST Project pipelines/\d+/runs' -or $_ -match '^GET Project pipelines/\d+/runs/\d+' })
        $firstQueueOfWave2 = [array]::FindIndex([string[]]$queued, [Predicate[string]] { param($c) $c -match "pipelines/$(($Fake.Pipelines | Where-Object { $_.name -eq 'shop-monitoring' }).id)/runs" })
        $lastPollOfWave1 = [array]::FindLastIndex([string[]]$queued, [Predicate[string]] { param($c) $c -match "pipelines/$(($Fake.Pipelines | Where-Object { $_.name -eq 'shop-network' }).id)/runs/" })
        $lastPollOfWave1 | Should -BeLessThan $firstQueueOfWave2
    }

    It 'passes the environment as a template parameter and deploys the branch head' {
        $run = @($Fake.Runs | Where-Object { $_.pipeline -eq 'shop-data' })[0]
        $run.body.templateParameters.environment | Should -BeExactly 'test'
        $run.body.resources.repositories.self.refName | Should -BeExactly 'refs/heads/main'
        $run.body.resources.repositories.self.Contains('version') | Should -BeFalse
    }
}

Describe 'A failing wave' {
    It 'stops and does not start later waves' {
        $null = Initialize-Project
        $Fake.RunResults['shop-messaging'] = 'failed'
        { Invoke-Rollout -Environment 'dev' -Mode DeployAll } | Should -Throw '*Wave 2 did not succeed (messaging: failed)*later waves were not started*'
        @($Fake.Runs | ForEach-Object { $_.pipeline }) | Should -Not -Contain 'shop-gateway'
        @($Fake.Runs) | Should -HaveCount 4
    }

    It 'treats a run that does not complete in time as a failure' {
        $null = Initialize-Project
        $Fake.PollsUntilComplete = 1000
        { Invoke-Rollout -Environment 'dev' -Mode DeployAll -Extra @{ PollSeconds = 60; TimeoutMinutes = 2 } } | Should -Throw '*network: timedOut*'
    }

    It 'refuses a missing pipeline before queuing anything' {
        $null = Initialize-Project
        $null = $Fake.Pipelines.Remove(@($Fake.Pipelines | Where-Object { $_.name -eq 'shop-web-ui' })[0])
        { Invoke-Rollout -Environment 'dev' -Mode DeployAll } | Should -Throw '*not found*shop-web-ui*'
        $Fake.Runs | Should -BeNullOrEmpty
    }
}

Describe 'Redeploy' {
    BeforeAll {
        $script:Pipelines = Initialize-Project
        $older = [datetime]'2026-02-20T03:00:00Z'
        $newer = [datetime]'2026-02-27T03:00:00Z'
        foreach ($component in (Get-SampleSystem).Components) {
            $suffix = if ($component.Name -eq 'data') { ' - Data' } else { '' }
            $environment = Get-FakeEnvironment "shop - acc$suffix"
            $pipeline = $Pipelines[$component.Pipeline]
            Add-FakeDeploymentRecord -Environment $environment -Pipeline $pipeline -Result 'succeeded' -FinishTime $older -Version "old-$($component.Name)"
            Add-FakeDeploymentRecord -Environment $environment -Pipeline $pipeline -Result 'succeeded' -FinishTime $newer -Version "good-$($component.Name)" -Branch 'refs/heads/release/2026.2'
        }
        # The latest attempt of the API failed: redeploy must take the last good one, not the latest.
        Add-FakeDeploymentRecord -Environment (Get-FakeEnvironment 'shop - acc') -Pipeline $Pipelines['shop-orders-api'] -Result 'failed' -FinishTime ([datetime]'2026-03-01T03:00:00Z') -Version 'broken'
        $script:Results = Invoke-Rollout -Environment 'acc' -Mode Redeploy
    }

    It 'deploys the last successful version of every component, from its branch' {
        foreach ($run in $Fake.Runs) {
            $component = $run.pipeline -replace '^shop-', ''
            $run.body.resources.repositories.self.version | Should -BeExactly "good-$component"
            $run.body.resources.repositories.self.refName | Should -BeExactly 'refs/heads/release/2026.2'
        }
        @($Fake.Runs) | Should -HaveCount 8
    }

    It 'refuses when a component has never been deployed successfully' {
        $null = Initialize-Project
        { Invoke-Rollout -Environment 'dev' -Mode Redeploy } | Should -Throw "*Cannot redeploy 'network' to 'shop - dev'*no successful deployment*"
        $Fake.Runs | Should -BeNullOrEmpty
    }
}

Describe 'Guards and -WhatIf' {
    It 'queues nothing with -WhatIf' {
        $null = Initialize-Project
        $results = Invoke-Rollout -Environment 'test' -Mode DeployAll -Extra @{ WhatIf = $true }
        $results | Should -BeNullOrEmpty
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'refuses deploy all on prod, where it is switched off' {
        $null = Initialize-Project
        { Invoke-Rollout -Environment 'prod' -Mode DeployAll } | Should -Throw '*DeployAll is not enabled*'
        $Fake.Calls | Should -BeNullOrEmpty
    }
}
