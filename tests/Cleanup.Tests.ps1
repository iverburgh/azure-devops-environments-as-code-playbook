BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    Mock Invoke-AzCli { Invoke-FakeAzCli -Arguments $Arguments -AllowFailure:$AllowFailure }
    Mock Write-Host {}

    $script:Old = [datetime]'2026-01-01T00:00:00Z'

    function Initialize-Subscription {
        <# The test environment: two scanned resource groups and one that does not match the pattern. #>
        Reset-FakeAzure -SubscriptionId '00000000-0000-0000-0000-000000000012'
        Add-FakeResourceGroup -Name 'rg-shop-test-orders', 'rg-shop-test-data', 'rg-other'
        $assignments = @{
            Orphaned = Add-FakeRoleAssignment -ResourceGroup 'rg-shop-test-orders' -Exists $false -CreatedOn $Old
            TooRecent = Add-FakeRoleAssignment -ResourceGroup 'rg-shop-test-orders' -Exists $false -CreatedOn $TestNow.AddDays(-2)
            Owner = Add-FakeRoleAssignment -ResourceGroup 'rg-shop-test-orders' -Role 'Owner' -Exists $false -PrincipalType 'User' -CreatedOn $Old
            Unreadable = Add-FakeRoleAssignment -ResourceGroup 'rg-shop-test-orders' -NameReadable $false -CreatedOn $Old
            DataOrphan = Add-FakeRoleAssignment -ResourceGroup 'rg-shop-test-data' -Role 'Reader' -Exists $false -PrincipalType 'Group' -CreatedOn $Old
            OtherOrphan = Add-FakeRoleAssignment -ResourceGroup 'rg-other' -Exists $false -CreatedOn $Old
        }
        foreach ($i in 1..4) { $null = Add-FakeRoleAssignment -ResourceGroup 'rg-shop-test-orders' }
        foreach ($i in 1..3) { $null = Add-FakeRoleAssignment -ResourceGroup 'rg-shop-test-data' }
        $assignments
    }

    function Invoke-Cleanup {
        param([hashtable] $Extra = @{})
        $parameters = @{ Environment = 'test'; Now = $TestNow }
        foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
        @(Invoke-TestScript -Name 'Remove-OrphanedRoleAssignments' -Parameters $parameters 3>$null)
    }
}

Describe 'Dry run (the default)' {
    BeforeAll {
        $script:A = Initialize-Subscription
        $script:Report = Join-Path $TestDrive 'dry-run.csv'
        $script:Output = Invoke-Cleanup @{ ReportPath = $Report }
        $script:Rows = @(Import-Csv -LiteralPath $Report)
    }

    It 'changes nothing' {
        $FakeAz.Writes | Should -BeNullOrEmpty
        $Output | Should -BeNullOrEmpty
    }

    It 'reports orphans with a status, only in the resource groups of the environment' {
        @($Rows | ForEach-Object { "$($_.Status) $($_.Id)" } | Sort-Object) | Should -Be @(
            "Orphaned $($A.DataOrphan.id)", "Orphaned $($A.Orphaned.id)", "ProtectedRole $($A.Owner.id)", "TooRecent $($A.TooRecent.id)"
        ) -Because 'rg-other does not match rg-shop-test-*'
    }

    It 'does not flag a principal that exists but whose name could not be read' {
        @($Rows | ForEach-Object { $_.Id }) | Should -Not -Contain $A.Unreadable.id
    }

    It 'writes a report with a header even when there is nothing to clean' {
        Reset-FakeAzure -SubscriptionId '00000000-0000-0000-0000-000000000012'
        Add-FakeResourceGroup -Name 'rg-shop-test-orders'
        $path = Join-Path $TestDrive 'clean.csv'
        $null = Invoke-Cleanup @{ ReportPath = $path }
        (Get-Content -LiteralPath $path -Raw) | Should -Match '^"Id","ResourceGroup"'
    }
}

Describe 'Executing' {
    BeforeEach {
        $script:A = Initialize-Subscription
    }

    It 'deletes only the orphans that are old enough and not protected' {
        $results = Invoke-Cleanup @{ Execute = $true; Confirm = $false }
        @($results | ForEach-Object { $_.Id } | Sort-Object) | Should -Be @(@($A.Orphaned.id, $A.DataOrphan.id) | Sort-Object)
        @($FakeAz.Writes) | Should -HaveCount 2
        @($FakeAz.RoleAssignments | ForEach-Object { $_.id }) | Should -Contain $A.Owner.id
        @($FakeAz.RoleAssignments | ForEach-Object { $_.id }) | Should -Contain $A.TooRecent.id
        @($FakeAz.RoleAssignments | ForEach-Object { $_.id }) | Should -Contain $A.OtherOrphan.id
    }

    It 'deletes nothing with -WhatIf' {
        $null = Invoke-Cleanup @{ Execute = $true; WhatIf = $true }
        $FakeAz.Writes | Should -BeNullOrEmpty
    }

    It 'deletes only what is in the approved report' {
        $approved = Join-Path $TestDrive 'approved.csv'
        [pscustomobject]@{ Id = $A.DataOrphan.id; Status = 'Orphaned' } | Export-Csv -LiteralPath $approved -NoTypeInformation
        $results = Invoke-Cleanup @{ Execute = $true; Confirm = $false; ApprovedReport = $approved }
        @($results | ForEach-Object { $_.Id }) | Should -Be @($A.DataOrphan.id)
    }

    It 'deletes nothing when the approved report is empty' {
        $approved = Join-Path $TestDrive 'empty.csv'
        [IO.File]::WriteAllText($approved, '"Id","Status"' + "`n")
        $results = Invoke-Cleanup @{ Execute = $true; Confirm = $false; ApprovedReport = $approved }
        $results | Should -BeNullOrEmpty
        $FakeAz.Writes | Should -BeNullOrEmpty
    }

    It 'refuses an approved report without -Execute' {
        { Invoke-Cleanup @{ ApprovedReport = 'whatever.csv' } } | Should -Throw '*only used with -Execute*'
    }
}

Describe 'Safety nets' {
    It 'stops when a lookup fails for another reason than not found' {
        $null = Initialize-Subscription
        $FakeAz.LookupError = 'ERROR: Insufficient privileges to complete the operation.'
        { Invoke-Cleanup @{ Execute = $true; Confirm = $false } } | Should -Throw '*Insufficient privileges*'
        $FakeAz.Writes | Should -BeNullOrEmpty
    }

    It 'trips the circuit breaker when too many assignments look orphaned, also in a dry run' {
        Reset-FakeAzure -SubscriptionId '00000000-0000-0000-0000-000000000012'
        Add-FakeResourceGroup -Name 'rg-shop-test-orders'
        foreach ($i in 1..12) { $null = Add-FakeRoleAssignment -ResourceGroup 'rg-shop-test-orders' -Exists $false -CreatedOn $Old }
        foreach ($i in 1..8) { $null = Add-FakeRoleAssignment -ResourceGroup 'rg-shop-test-orders' }
        { Invoke-Cleanup } | Should -Throw '*Circuit breaker: 12 of 20*Nothing was deleted*'
        { Invoke-Cleanup @{ Execute = $true; Confirm = $false } } | Should -Throw '*Circuit breaker*'
        $FakeAz.Writes | Should -BeNullOrEmpty
    }

    It 'skips a locked resource group by default' {
        $A = Initialize-Subscription
        Add-FakeLock -ResourceGroup 'rg-shop-test-orders'
        $results = Invoke-Cleanup @{ Execute = $true; Confirm = $false }
        @($results | ForEach-Object { "$($_.Result) $($_.Id)" } | Sort-Object) | Should -Be @("Deleted $($A.DataOrphan.id)", "SkippedLocked $($A.Orphaned.id)")
        @(Get-FakeLocks -ResourceGroup 'rg-shop-test-orders') | Should -HaveCount 1
    }

    It 'removes a lock temporarily and restores it exactly' {
        $A = Initialize-Subscription
        Add-FakeLock -ResourceGroup 'rg-shop-test-orders' -Name 'keep' -Level 'ReadOnly' -Notes 'owned by the platform team'
        $results = Invoke-Cleanup @{ Execute = $true; Confirm = $false; RemoveLocksTemporarily = $true }
        @($results | Where-Object { $_.Result -eq 'Deleted' }) | Should -HaveCount 2
        $lock = @(Get-FakeLocks -ResourceGroup 'rg-shop-test-orders')
        $lock | Should -HaveCount 1
        $lock[0].name | Should -BeExactly 'keep'
        $lock[0].level | Should -BeExactly 'ReadOnly'
        $lock[0].notes | Should -BeExactly 'owned by the platform team'
    }

    It 'restores the lock when a deletion fails' {
        $null = Initialize-Subscription
        Add-FakeLock -ResourceGroup 'rg-shop-test-orders' -Name 'keep'
        $rows = @([pscustomobject]@{ Id = '/subscriptions/x/resourceGroups/rg-shop-test-orders/providers/Microsoft.Authorization/roleAssignments/gone'; ResourceGroup = 'rg-shop-test-orders'; Status = 'Orphaned' })
        { $null = @(Remove-OrphanedRoleAssignment -Rows $rows -SubscriptionId '00000000-0000-0000-0000-000000000012' -RemoveLocksTemporarily -Confirm:$false) } | Should -Throw '*does not exist*'
        @(Get-FakeLocks -ResourceGroup 'rg-shop-test-orders') | Should -HaveCount 1
        @($FakeAz.Writes)[-1] | Should -BeExactly 'lock create keep on rg-shop-test-orders'
    }
}
