BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    Mock Invoke-AzCli { Invoke-FakeAzCli -Arguments $Arguments -AllowFailure:$AllowFailure }
    Mock Write-Host {}

    $script:DevGroups = @(
        'rg-shop-dev-network', 'rg-shop-dev-monitoring', 'rg-shop-dev-messaging', 'rg-shop-dev-data',
        'rg-shop-dev-gateway', 'rg-shop-dev-orders', 'rg-shop-dev-payments', 'rg-shop-dev-web'
    )

    function Invoke-Remove {
        param([hashtable] $Parameters)
        @(Invoke-TestScript -Name 'Remove-Environment' -Parameters $Parameters 3>$null)
    }
}

Describe 'Removing an environment' {
    BeforeEach {
        Reset-FakeAzure
        Add-FakeResourceGroup -Name ($DevGroups + 'rg-shop-test-network' + 'rg-other')
    }

    It 'deletes every resource group in reverse dependency order and nothing else' {
        $results = Invoke-Remove @{ Environment = 'dev'; Confirmation = 'dev'; Confirm = $false }
        @($FakeAz.Writes) | Should -Be @(
            'group delete rg-shop-dev-orders', 'group delete rg-shop-dev-web', 'group delete rg-shop-dev-gateway', 'group delete rg-shop-dev-payments'
            'group delete rg-shop-dev-monitoring', 'group delete rg-shop-dev-messaging', 'group delete rg-shop-dev-data', 'group delete rg-shop-dev-network'
        )
        @($FakeAz.Groups) | Should -Be @('rg-shop-test-network', 'rg-other')
        @($results | ForEach-Object { $_.Result } | Select-Object -Unique) | Should -Be @('Deleted')
    }

    It 'removes one component together with its dependents' {
        $null = Invoke-Remove @{ Environment = 'dev'; Components = @('gateway'); Confirmation = 'dev'; Confirm = $false }
        @($FakeAz.Writes) | Should -Be @('group delete rg-shop-dev-orders', 'group delete rg-shop-dev-web', 'group delete rg-shop-dev-gateway')
    }

    It 'reports groups that are already gone and can be run again' {
        $null = $FakeAz.Groups.Remove('rg-shop-dev-web')
        $results = Invoke-Remove @{ Environment = 'dev'; Confirmation = 'dev'; Confirm = $false }
        @($results | Where-Object { $_.Result -eq 'AlreadyGone' } | ForEach-Object { $_.ResourceGroup }) | Should -Be @('rg-shop-dev-web')
        $FakeAz.Writes.Clear()
        $again = Invoke-Remove @{ Environment = 'dev'; Confirmation = 'dev'; Confirm = $false }
        $FakeAz.Writes | Should -BeNullOrEmpty
        @($again | ForEach-Object { $_.Result } | Select-Object -Unique) | Should -Be @('AlreadyGone')
    }

    It 'deletes nothing with -WhatIf, and needs no confirmation for it' {
        $results = Invoke-Remove @{ Environment = 'dev'; WhatIf = $true }
        $results | Should -BeNullOrEmpty
        $FakeAz.Writes | Should -BeNullOrEmpty
    }
}

Describe 'Locks' {
    BeforeEach {
        Reset-FakeAzure
        Add-FakeResourceGroup -Name $DevGroups
        Add-FakeLock -ResourceGroup 'rg-shop-dev-network' -Name 'keep-network'
    }

    It 'refuses before deleting anything, even a group that comes earlier in the order' {
        { Invoke-Remove @{ Environment = 'dev'; Confirmation = 'dev'; Confirm = $false } } | Should -Throw '*rg-shop-dev-network (keep-network:CanNotDelete)*Nothing was deleted*'
        $FakeAz.Writes | Should -BeNullOrEmpty
    }

    It 'deletes the lock first with -IgnoreLocks' {
        $null = Invoke-Remove @{ Environment = 'dev'; Confirmation = 'dev'; Confirm = $false; IgnoreLocks = $true }
        $FakeAz.Groups | Should -BeNullOrEmpty
        @($FakeAz.Writes)[-2] | Should -BeLike 'lock delete */locks/keep-network'
        @($FakeAz.Writes)[-1] | Should -BeExactly 'group delete rg-shop-dev-network'
    }
}

Describe 'Guards' {
    BeforeEach {
        Reset-FakeAzure
        Add-FakeResourceGroup -Name $DevGroups
    }

    It 'refuses <Environment> even with -WhatIf' -TestCases @(@{ Environment = 'prod' }, @{ Environment = 'acc' }) {
        { Invoke-Remove @{ Environment = $Environment; WhatIf = $true } } | Should -Throw '*protected*'
        { Invoke-Remove @{ Environment = $Environment; Confirmation = $Environment; Confirm = $false } } | Should -Throw '*protected*'
        $FakeAz.Writes | Should -BeNullOrEmpty
    }

    It 'refuses without the typed confirmation' {
        { Invoke-Remove @{ Environment = 'dev'; Confirm = $false } } | Should -Throw "*-Confirmation 'dev'*"
        { Invoke-Remove @{ Environment = 'dev'; Confirmation = 'test'; Confirm = $false } } | Should -Throw "*-Confirmation 'dev'*"
        $FakeAz.Writes | Should -BeNullOrEmpty
    }

    It 'refuses a production-like environment that the configuration allows to remove' {
        $raw = Get-SampleJson 'orchestration/system.json'
        $raw.environments['prd-copy'] = @{ subscriptionId = '00000000-0000-0000-0000-000000000015'; deployAll = $true; redeploy = $true; remove = $true }
        $path = New-TestJsonFile -Name 'prdcopy/system.json' -Content $raw
        { Invoke-Remove @{ Environment = 'prd-copy'; Confirmation = 'prd-copy'; Confirm = $false; SystemPath = $path } } | Should -Throw '*looks like a production environment*'
        $FakeAz.Writes | Should -BeNullOrEmpty
    }
}
