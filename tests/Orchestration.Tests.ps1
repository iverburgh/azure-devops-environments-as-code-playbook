BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    Mock Write-Host {}

    function New-Component {
        param([string] $Name, [string[]] $DependsOn = @())
        @{ Name = $Name; DependsOn = $DependsOn }
    }
}

Describe 'Dependency waves' {
    It 'groups the sample system into waves that only depend on earlier waves' {
        $waves = @(Get-DependencyWave -Components (Get-SampleSystem).Components)
        @($waves | ForEach-Object { "$($_.Wave) $($_.Name)" }) | Should -Be @(
            '1 network', '2 monitoring', '2 messaging', '2 data', '3 gateway', '3 payments-fn', '4 orders-api', '4 web-ui'
        )
    }

    It 'names every component of a cycle' {
        $components = @((New-Component 'a' @('c')), (New-Component 'b' @('a')), (New-Component 'c' @('b')), (New-Component 'd'))
        { $null = @(Get-DependencyWave -Components $components) } | Should -Throw 'Dependency cycle between: a, b, c.'
    }

    It 'resolves the Azure DevOps environment and resource group per component' {
        $plan = @(Get-DeploymentPlan -System (Get-SampleSystem) -Environment 'test')
        $data = @($plan | Where-Object { $_.Component -eq 'data' })[0]
        $data.AzureDevOpsEnvironment | Should -BeExactly 'shop - test - Data'
        $data.ResourceGroup | Should -BeExactly 'rg-shop-test-data'
        $data.Branch | Should -BeExactly 'refs/heads/main'
        @($plan | Where-Object { $_.Component -eq 'web-ui' })[0].AzureDevOpsEnvironment | Should -BeExactly 'shop - test'
    }
}

Describe 'Removal order' {
    It 'removes everything in reverse wave order' {
        $plan = @(Get-RemovalPlan -System (Get-SampleSystem) -Environment 'dev')
        @($plan | ForEach-Object { $_.Component }) | Should -Be @(
            'orders-api', 'web-ui', 'gateway', 'payments-fn', 'monitoring', 'messaging', 'data', 'network'
        )
        @($plan | ForEach-Object { $_.Step }) | Should -Be (1..8)
    }

    It 'removes a component together with everything that depends on it, dependents first' {
        $plan = @(Get-RemovalPlan -System (Get-SampleSystem) -Environment 'dev' -Components 'messaging')
        @($plan | ForEach-Object { $_.ResourceGroup }) | Should -Be @(
            'rg-shop-dev-orders', 'rg-shop-dev-web', 'rg-shop-dev-gateway', 'rg-shop-dev-payments', 'rg-shop-dev-messaging'
        )
    }

    It 'refuses an unknown component' {
        { $null = @(Get-RemovalPlan -System (Get-SampleSystem) -Environment 'dev' -Components 'nope') } | Should -Throw "Unknown component 'nope'*"
    }
}

Describe 'Action guards' {
    It 'allows remove on dev and test' {
        { Assert-EnvironmentAction -System (Get-SampleSystem) -Environment 'dev' -Action Remove } | Should -Not -Throw
        { Assert-EnvironmentAction -System (Get-SampleSystem) -Environment 'test' -Action Remove } | Should -Not -Throw
    }

    It 'refuses remove on a protected environment' {
        { Assert-EnvironmentAction -System (Get-SampleSystem) -Environment 'acc' -Action Remove } | Should -Throw '*protected*'
    }

    It 'refuses remove on a production-like name even when the configuration allows it' {
        $system = Get-SampleSystem
        $system.Environments['live'] = @{ Protected = $false; DeployAll = $true; Redeploy = $true; Remove = $true; SubscriptionId = '00000000-0000-0000-0000-000000000015' }
        { Assert-EnvironmentAction -System $system -Environment 'live' -Action Remove } | Should -Throw '*looks like a production environment*'
    }

    It 'recognises production-like names' -TestCases @(
        @{ Name = 'prod'; Expected = $true }, @{ Name = 'prd-weu'; Expected = $true }, @{ Name = 'shop_production'; Expected = $true }
        @{ Name = 'live'; Expected = $true }, @{ Name = 'product-test'; Expected = $false }, @{ Name = 'delivery'; Expected = $false }
    ) {
        Test-ProductionLikeName -Name $Name | Should -Be $Expected
    }

    It 'refuses an action that is switched off' {
        { Assert-EnvironmentAction -System (Get-SampleSystem) -Environment 'prod' -Action DeployAll } | Should -Throw '*DeployAll is not enabled*'
    }

    It 'refuses an unknown environment' {
        { Assert-EnvironmentAction -System (Get-SampleSystem) -Environment 'qa' -Action DeployAll } | Should -Throw "Unknown environment 'qa'*"
    }

    It 'requires the exact environment name as confirmation' {
        { Assert-RemovalConfirmed -Environment 'dev' -Confirmation 'DEV' } | Should -Throw "*-Confirmation 'dev'*"
        { Assert-RemovalConfirmed -Environment 'dev' -Confirmation '' } | Should -Throw
        { Assert-RemovalConfirmed -Environment 'dev' -Confirmation 'dev' } | Should -Not -Throw
        { Assert-RemovalConfirmed -Environment 'dev' -Confirmation '' -WhatIfMode } | Should -Not -Throw
    }
}

Describe 'Get-OrchestrationPlan.ps1' {
    It 'emits the plan as JSON' {
        $json = Invoke-TestScript -Name 'Get-OrchestrationPlan' -Parameters @{ Action = 'DeployAll'; Environment = 'acc'; Format = 'Json' }
        $plan = @(($json -join "`n") | ConvertFrom-Json)
        $plan | Should -HaveCount 8
        $plan[0].Component | Should -BeExactly 'network'
    }

    It 'refuses what the guards refuse' {
        { Invoke-TestScript -Name 'Get-OrchestrationPlan' -Parameters @{ Action = 'Remove'; Environment = 'prod' } } | Should -Throw '*protected*'
    }
}
