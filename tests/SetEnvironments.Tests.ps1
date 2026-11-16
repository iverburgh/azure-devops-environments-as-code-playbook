BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    # $PSBoundParameters is empty inside a mock body, so the parameters are passed on by name.
    # The entry script dot-sources the library again; the mock still wins.
    Mock Invoke-AzDevOps { Invoke-FakeAzDevOps -Connection $Connection -Method $Method -Scope $Scope -Path $Path -Body $Body -All:$All }
    Mock Write-Host {}

    $script:Connect = @{ Organization = 'my-org'; Project = 'my-project' }

    function Invoke-Set {
        param([hashtable] $Extra = @{})
        $parameters = $script:Connect.Clone()
        foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
        Invoke-TestScript -Name 'Set-Environments' -Parameters $parameters
    }

    function Get-Kinds {
        param([string] $Name)
        @(Get-FakeChecks -EnvironmentName $Name | ForEach-Object { Get-CheckKind -Check $_ } | Sort-Object)
    }

    function Get-FakeCheck {
        param([string] $Name, [string] $Kind)
        @(Get-FakeChecks -EnvironmentName $Name | Where-Object { (Get-CheckKind -Check $_) -eq $Kind })[0]
    }

    function Get-FakeEnvironment { param([string] $Name) @($global:Fake.Environments | Where-Object { $_.name -eq $Name })[0] }
}

Describe 'Creating environments in an empty project' {
    BeforeAll {
        Reset-FakeAzureDevOps
        Invoke-Set
        $script:Expected = @(Get-SampleGroup | ForEach-Object { $_.Environments } | ForEach-Object { $_.Name })
    }

    It 'creates every configured environment' {
        @($Fake.Environments | ForEach-Object { $_.name } | Sort-Object) | Should -Be @($Expected | Sort-Object)
    }

    It 'adds exactly the configured checks' {
        Get-Kinds 'shop - dev' | Should -Be @('ExclusiveLock')
        Get-Kinds 'shop - dev - RemoveAll' | Should -Be @('Approval')
        Get-Kinds 'shop - prod' | Should -Be @('Approval', 'BranchControl', 'ExclusiveLock')
        Get-Kinds 'shop - prod - Diagnostics' | Should -Be @('BranchControl')
    }

    It 'sends branch control as the evaluatebranchProtection task with a comma-separated list' {
        $check = Get-FakeCheck 'shop - acc' 'BranchControl'
        $check.type.id | Should -BeExactly 'fe1de3ee-a436-41b4-bb20-f6eb4cb879a7'
        $check.settings.definitionRef.name | Should -BeExactly 'evaluatebranchProtection'
        $check.settings.inputs.allowedBranches | Should -BeExactly 'refs/heads/main,refs/heads/release/*'
        $check.settings.inputs.ensureProtectionOfBranch | Should -BeExactly 'true'
    }

    It 'sends the four-eyes approval with resolved identities' {
        $check = Get-FakeCheck 'shop - prod - Data' 'Approval'
        @($check.settings.approvers | ForEach-Object { $_.id }) | Should -Be @('00000000-0000-0000-0000-00000000a004', '00000000-0000-0000-0000-00000000a005')
        $check.settings.minRequiredApprovers | Should -Be 2
        $check.settings.requesterCannotBeApprover | Should -BeTrue
        $check.timeout | Should -Be 4320
    }

    It 'gives the administrators the Administrator role and removes the creator' {
        $environment = Get-FakeEnvironment 'shop - prod'
        $assignments = @($Fake.RoleAssignments | Where-Object { $_.resource -eq "$($Fake.ProjectId)_$($environment.id)" })
        @($assignments | ForEach-Object { $_.userId }) | Should -Be @('00000000-0000-0000-0000-00000000a001')
        $assignments[0].roleName | Should -BeExactly 'Administrator'
    }

    It 'changes nothing on a second run' {
        $Fake.Writes.Clear()
        Invoke-Set
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'reports no drift afterwards' {
        Invoke-Set @{ Check = $true }
        $LASTEXITCODE | Should -Be 0
    }
}

Describe '-WhatIf' {
    It 'writes nothing for an empty project' {
        Reset-FakeAzureDevOps
        Invoke-Set @{ WhatIf = $true }
        $Fake.Writes | Should -BeNullOrEmpty
        $Fake.Environments | Should -BeNullOrEmpty
    }

    It 'writes nothing when there is drift' {
        Reset-FakeAzureDevOps
        Invoke-Set
        $null = Add-FakeCheck -Environment (Get-FakeEnvironment 'shop - dev') -Type (Get-CheckTypeReference -Kind 'ExclusiveLock')
        $Fake.Writes.Clear()
        Invoke-Set @{ WhatIf = $true }
        $Fake.Writes | Should -BeNullOrEmpty
        @(Get-FakeChecks -EnvironmentName 'shop - dev').Count | Should -Be 2
    }
}

Describe 'Drift: changes made by hand' {
    BeforeAll {
        Reset-FakeAzureDevOps
        Invoke-Set
        # Someone narrows branch control, deletes a lock, adds a duplicate lock, adds an approval that
        # is not in the configuration, edits a description and adds a business hours check.
        (Get-FakeCheck 'shop - test' 'BranchControl').settings.inputs.allowedBranches = 'refs/heads/main'
        $null = $Fake.Checks.Remove((Get-FakeCheck 'shop - acc' 'ExclusiveLock'))
        $null = Add-FakeCheck -Environment (Get-FakeEnvironment 'shop - dev') -Type (Get-CheckTypeReference -Kind 'ExclusiveLock')
        $null = Add-FakeCheck -Environment (Get-FakeEnvironment 'shop - dev - Data') -Type (Get-CheckTypeReference -Kind 'Approval') -Settings @{
            approvers = @(@{ id = '00000000-0000-0000-0000-00000000a006' }); minRequiredApprovers = 1
        }
        (Get-FakeEnvironment 'shop - prod').description = 'edited in the portal'
        $script:BusinessHours = Add-FakeCheck -Environment (Get-FakeEnvironment 'shop - prod') -Type @{ id = '00000000-0000-0000-0000-00000000e001'; name = 'Task Check' } -Settings @{
            displayName = 'Business hours'; definitionRef = @{ name = 'evaluateBusinessHours' }
        }
        $Fake.Writes.Clear()
    }

    It 'makes -Check exit 1 without writing' {
        Invoke-Set @{ Check = $true }
        $LASTEXITCODE | Should -Be 1
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'plans exactly the differences and leaves unmanaged checks alone' {
        $groups = Get-SampleGroup
        $plan = @(Get-EnvironmentPlan -Connection (Get-TestConnection) -Groups $groups 3>$null)
        @($plan | ForEach-Object { "$($_.Action) $($_.Environment) $($_.Kind)".Trim() } | Sort-Object) | Should -Be @(
            'AddCheck shop - acc ExclusiveLock'
            'DeleteCheck shop - dev - Data Approval'
            'DeleteCheck shop - dev ExclusiveLock'
            'Unmanaged shop - prod Task Check'
            'UpdateCheck shop - test BranchControl'
            'UpdateEnvironment shop - prod'
        )
    }

    It 'repairs the drift, keeps the unmanaged check and is idempotent afterwards' {
        Invoke-Set 3>$null
        @($Fake.Writes) | Should -HaveCount 5
        (Get-FakeCheck 'shop - test' 'BranchControl').settings.inputs.allowedBranches | Should -BeExactly 'refs/heads/main,refs/heads/release/*'
        (Get-FakeEnvironment 'shop - prod').description | Should -Not -Be 'edited in the portal'
        @(Get-FakeChecks -EnvironmentName 'shop - prod' | Where-Object { $_.id -eq $BusinessHours.id }) | Should -HaveCount 1
        Invoke-Set @{ Check = $true } 3>$null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Deleting environments' {
    BeforeEach {
        Reset-FakeAzureDevOps
        Invoke-Set
        $null = Add-FakeEnvironment -Name 'shop - dev - feature-x'
        $null = Add-FakeEnvironment -Name 'shop - dev - experiment'
        $null = Add-FakeEnvironment -Name 'other - dev'
        $Fake.Writes.Clear()
    }

    It 'never deletes without -RemoveUndefined' {
        Invoke-Set
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'refuses -RemoveUndefined without -RemoveFilter' {
        { Invoke-Set @{ RemoveUndefined = $true } } | Should -Throw '*needs -RemoveFilter*'
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'deletes only undefined environments of a configured group that match the filter' {
        Invoke-Set @{ RemoveUndefined = $true; RemoveFilter = @('shop - dev - feature-*', 'other - *') }
        @($Fake.Environments | ForEach-Object { $_.name }) | Should -Not -Contain 'shop - dev - feature-x'
        @($Fake.Environments | ForEach-Object { $_.name }) | Should -Contain 'shop - dev - experiment'
        @($Fake.Environments | ForEach-Object { $_.name }) | Should -Contain 'other - dev'
        @($Fake.Writes) | Should -HaveCount 1
    }
}

Describe 'Partial runs and failures' {
    It 'applies only the given file' {
        Reset-FakeAzureDevOps
        Invoke-Set @{ Path = @(Get-SampleEnvironmentPath 'prod') }
        @($Fake.Environments | ForEach-Object { $_.name } | Sort-Object) | Should -Be @('shop - prod', 'shop - prod - Data', 'shop - prod - Diagnostics')
    }

    It 'stops before any write when an approver cannot be resolved' {
        Reset-FakeAzureDevOps
        $content = Get-SampleJson 'environments/dev.json'
        $content.environments[2].approval.approvers = @('nobody@example.com')
        $path = New-TestJsonFile -Name 'unknown-approver/dev.json' -Content $content
        { Invoke-Set @{ Path = @($path) } } | Should -Throw "*Identity 'nobody@example.com' was not found*"
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'stops before any call when the configuration is invalid' {
        Reset-FakeAzureDevOps
        $content = Get-SampleJson 'environments/dev.json'
        $content.environments[0].name = 'shop-dev'
        $path = New-TestJsonFile -Name 'invalid/dev.json' -Content $content
        { Invoke-Set @{ Path = @($path) } } | Should -Throw '*must be named*'
        $Fake.Calls | Should -BeNullOrEmpty
    }
}
