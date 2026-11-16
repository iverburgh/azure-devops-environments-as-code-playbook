BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    Mock Invoke-AzDevOps { Invoke-FakeAzDevOps -Connection $Connection -Method $Method -Scope $Scope -Path $Path -Body $Body -All:$All }
    Mock Write-Host {}

    function Invoke-Export {
        param([string] $OutputDirectory, [hashtable] $Extra = @{})
        $parameters = @{ Organization = 'my-org'; Project = 'my-project'; System = 'shop'; OutputDirectory = $OutputDirectory }
        foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
        @(Invoke-TestScript -Name 'Export-Environments' -Parameters $parameters)
    }
}

Describe 'Export round-trip' {
    BeforeAll {
        Reset-FakeAzureDevOps
        Invoke-TestScript -Name 'Set-Environments' -Parameters @{ Organization = 'my-org'; Project = 'my-project' }
        $null = Add-FakeEnvironment -Name 'unrelated environment'
        $script:Folder = Join-Path $TestDrive 'roundtrip'
        $script:Written = Invoke-Export -OutputDirectory $Folder
    }

    It 'writes one file per group and skips environments outside the naming convention' {
        @($Written | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object) | Should -Be @('acc.json', 'dev.json', 'prod.json', 'test.json')
    }

    It 'writes files that pass the schema and the rules' {
        $result = Get-EnvironmentConfigResult -Path $Folder
        $result.Problems | Should -BeNullOrEmpty
    }

    It 'puts the base environment first' {
        $content = Get-Content -LiteralPath (Join-Path $Folder 'prod.json') -Raw | ConvertFrom-Json
        @($content.environments | ForEach-Object { $_.name }) | Should -Be @('shop - prod', 'shop - prod - Data', 'shop - prod - Diagnostics')
    }

    It 'exports approvers as names that resolve again' {
        $content = Get-Content -LiteralPath (Join-Path $Folder 'prod.json') -Raw | ConvertFrom-Json
        @($content.environments[1].approval.approvers) | Should -Be @('[shop]\Production Approvers', '[shop]\Database Administrators')
        $content.environments[1].approval.requesterCannotBeApprover | Should -BeTrue
        $content.environments[0].branchControl.allowedBranches | Should -Be @('refs/heads/main')
    }

    It 'produces a configuration that plans no change against the same project' {
        $groups = @(Read-EnvironmentConfig -Path $Folder)
        $plan = @(Get-EnvironmentPlan -Connection (Get-TestConnection) -Groups $groups)
        $plan | Should -BeNullOrEmpty
    }

    It 'only reads' {
        $Fake.Writes.Clear()
        $null = Invoke-Export -OutputDirectory (Join-Path $TestDrive 'readonly')
        $Fake.Writes | Should -BeNullOrEmpty
    }
}

Describe 'Export safety' {
    BeforeEach {
        Reset-FakeAzureDevOps
        Invoke-TestScript -Name 'Set-Environments' -Parameters @{ Organization = 'my-org'; Project = 'my-project'; Path = @(Get-SampleEnvironmentPath 'dev') }
        $script:Folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
    }

    It 'refuses to overwrite an existing file without -Force' {
        $null = Invoke-Export -OutputDirectory $Folder
        { Invoke-Export -OutputDirectory $Folder } | Should -Throw '*already exists*-Force*'
        @(Invoke-Export -OutputDirectory $Folder -Extra @{ Force = $true }) | Should -HaveCount 1
    }

    It 'reports a check it does not manage instead of exporting it' {
        $environment = @($Fake.Environments | Where-Object { $_.name -eq 'shop - dev' })[0]
        $null = Add-FakeCheck -Environment $environment -Type @{ id = '00000000-0000-0000-0000-00000000e002'; name = 'Invoke REST API' } -Settings @{}
        $warnings = @()
        $null = Invoke-Export -OutputDirectory $Folder 3>&1 | Where-Object { $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { $warnings += $_ }
        $warnings -join "`n" | Should -Match "'Invoke REST API' check is not exported"
        $content = Get-Content -LiteralPath (Join-Path $Folder 'dev.json') -Raw | ConvertFrom-Json -AsHashtable
        @($content.environments[0].Keys | Sort-Object) | Should -Be @('description', 'exclusiveLock', 'name')
    }

    It 'exports only the requested group' {
        @(Invoke-Export -OutputDirectory $Folder -Extra @{ Group = @('prod') } 3>$null) | Should -BeNullOrEmpty
    }
}
