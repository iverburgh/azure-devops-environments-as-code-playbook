BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    Mock Write-Host {}

    function Get-Problem {
        param([Parameter(Mandatory)] [hashtable[]] $Files)
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $folder
        $index = 0
        foreach ($content in $Files) {
            $index++
            [IO.File]::WriteAllText((Join-Path $folder "$index.json"), (ConvertTo-Json -InputObject $content -Depth 20))
        }
        @((Get-EnvironmentConfigResult -Path $folder).Problems)
    }

    function New-Group {
        param([string] $Group = 'dev', [object[]] $Environments, [hashtable] $Policy)
        $content = @{ system = 'shop'; group = $Group; environments = $Environments }
        if ($Policy) { $content.policy = $Policy }
        $content
    }
}

Describe 'The sample configuration' {
    It 'is valid: schemas, rules and consistency' {
        Invoke-TestScript -Name 'Test-Configuration'
        $LASTEXITCODE | Should -Be 0
    }

    It 'has one group per environment of system.json' {
        @(Get-SampleGroup | ForEach-Object { $_.Group }) | Should -Be @('acc', 'dev', 'prod', 'test')
    }

    It 'applies defaults so the rest of the code can rely on every value' {
        $prod = @(Get-SampleGroup -Group 'prod')[0]
        $environment = $prod.Environments[0]
        $environment.ExclusiveLock.TimeoutMinutes | Should -Be 43200
        $environment.Approval.ExecutionOrder | Should -BeExactly 'anyOrder'
        $prod.Environments[2].Approval.Enabled | Should -BeFalse
    }
}

Describe 'Schema validation of environment files' {
    It 'rejects an unknown property' {
        $problems = Get-Problem @(New-Group -Environments @(@{ name = 'shop - dev'; exclusivLock = @{ enabled = $true } }))
        $problems -join "`n" | Should -Match 'schema'
    }

    It 'rejects a branch that is not a full ref' {
        $problems = Get-Problem @(New-Group -Environments @(@{ name = 'shop - dev'; branchControl = @{ enabled = $true; allowedBranches = @('main') } }))
        $problems -join "`n" | Should -Match 'schema'
    }

    It 'rejects zero required approvers' {
        $problems = Get-Problem @(New-Group -Environments @(@{ name = 'shop - dev'; approval = @{ enabled = $true; approvers = @('alice@example.com'); minRequiredApprovers = 0 } }))
        $problems -join "`n" | Should -Match 'schema'
    }

    It 'rejects a group name with a hyphen' {
        $problems = Get-Problem @(New-Group -Group 'dev-2' -Environments @(@{ name = 'shop - dev-2' }))
        $problems -join "`n" | Should -Match 'schema'
    }

    It 'makes Read-EnvironmentConfig throw with every problem' {
        $path = New-TestJsonFile -Name 'broken/dev.json' -Content (New-Group -Environments @(@{ name = 'shop - dev'; bogus = 1 }))
        { Read-EnvironmentConfig -Path $path } | Should -Throw '*Environment configuration is invalid*'
    }
}

Describe 'Rules beyond the schema' {
    It 'requires the naming convention' {
        $problems = Get-Problem @(New-Group -Environments @(@{ name = 'shop-dev' }))
        $problems -join "`n" | Should -Match "must be named 'shop - dev'"
    }

    It 'refuses the same name twice, ignoring case' {
        $problems = Get-Problem @(New-Group -Environments @(@{ name = 'shop - dev - Data' }, @{ name = 'shop - dev - data' }))
        $problems -join "`n" | Should -Match 'defined twice'
    }

    It 'refuses the same group in two files' {
        $problems = Get-Problem @((New-Group -Environments @(@{ name = 'shop - dev' })), (New-Group -Environments @(@{ name = 'shop - dev - Data' })))
        $problems -join "`n" | Should -Match "group 'dev' is also defined"
    }

    It 'refuses an approval without approvers' {
        $problems = Get-Problem @(New-Group -Environments @(@{ name = 'shop - dev'; approval = @{ enabled = $true } }))
        $problems -join "`n" | Should -Match 'has no approvers'
    }

    It 'refuses more required approvers than approvers, because a group counts as one' {
        $problems = Get-Problem @(New-Group -Environments @(@{ name = 'shop - dev'; approval = @{ enabled = $true; approvers = @('[shop]\Platform Team'); minRequiredApprovers = 2 } }))
        $problems -join "`n" | Should -Match 'a group counts as one approver'
    }

    It 'enforces the four-eyes policy of a group' {
        $policy = @{ requireFourEyes = $true }
        $problems = Get-Problem @(New-Group -Group 'prod' -Policy $policy -Environments @(@{ name = 'shop - prod'; approval = @{ enabled = $true; approvers = @('[shop]\Production Approvers') } }))
        $problems -join "`n" | Should -Match 'requireFourEyes'
    }

    It 'accepts a deviation from the policy only with a policyExemption' {
        $policy = @{ requireFourEyes = $true; requireBranchControl = $true; requireExclusiveLock = $true }
        $problems = Get-Problem @(New-Group -Group 'prod' -Policy $policy -Environments @(@{ name = 'shop - prod - Tools'; policyExemption = 'Read-only tooling without access to production data.' }))
        $problems | Should -BeNullOrEmpty
    }
}

Describe 'Rules for system.json' {
    BeforeEach {
        $script:Raw = Get-SampleJson 'orchestration/system.json'
    }

    It 'detects a dependency cycle' {
        ($Raw.components | Where-Object { $_.name -eq 'network' }).dependsOn = @('web-ui')
        $result = Get-SystemConfigResult -Path (New-TestJsonFile -Name 'cycle/system.json' -Content $Raw)
        $result.Problems -join "`n" | Should -Match 'Dependency cycle between: network'
    }

    It 'detects an unknown dependency' {
        ($Raw.components | Where-Object { $_.name -eq 'web-ui' }).dependsOn = @('nope')
        $result = Get-SystemConfigResult -Path (New-TestJsonFile -Name 'unknown/system.json' -Content $Raw)
        $result.Problems -join "`n" | Should -Match "unknown component 'nope'"
    }

    It 'refuses remove on a protected environment' {
        $Raw.environments.acc.remove = $true
        $result = Get-SystemConfigResult -Path (New-TestJsonFile -Name 'protected/system.json' -Content $Raw)
        $result.Problems -join "`n" | Should -Match "'acc' is protected"
    }

    It 'requires the approval gate environment when remove is allowed' {
        $groups = @(Get-SampleGroup | ForEach-Object {
                if ($_.Group -eq 'dev') { $_.Environments = @($_.Environments | Where-Object { $_.Name -ne 'shop - dev - RemoveAll' }) }
                $_
            })
        $problems = @(Get-CrossConfigProblem -System (Get-SampleSystem) -Groups $groups)
        $problems -join "`n" | Should -Match "'shop - dev - RemoveAll' \(the approval gate\) must be defined"
    }

    It 'requires the environment every component deploys to' {
        $groups = @(Get-SampleGroup | ForEach-Object {
                if ($_.Group -eq 'test') { $_.Environments = @($_.Environments | Where-Object { $_.Name -ne 'shop - test - Data' }) }
                $_
            })
        $problems = @(Get-CrossConfigProblem -System (Get-SampleSystem) -Groups $groups)
        $problems -join "`n" | Should -Match "component 'data' deploys to 'shop - test - Data'"
    }

    It 'makes Test-Configuration exit 1' {
        $Raw.environments.acc.remove = $true
        $path = New-TestJsonFile -Name 'exit/system.json' -Content $Raw
        Invoke-TestScript -Name 'Test-Configuration' -Parameters @{ SystemPath = $path }
        $LASTEXITCODE | Should -Be 1
    }
}
