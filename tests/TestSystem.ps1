Set-StrictMode -Version Latest

<#
    Shared setup for the Pester tests: loads the library and the fakes, and offers helpers to run the
    entry scripts in-process (so the mocks apply) and to build an Azure DevOps project that matches
    the sample configuration.
#>

$global:PlaybookRoot = Split-Path -Parent $PSScriptRoot

foreach ($file in 'Common', 'AzureDevOps', 'AzureCli', 'Config', 'Orchestration', 'Environments', 'Export', 'Rollout', 'Removal', 'Cleanup') {
    . (Join-Path $global:PlaybookRoot "lib/$file.ps1")
}
. (Join-Path $PSScriptRoot 'FakeAzureDevOps.ps1')
. (Join-Path $PSScriptRoot 'FakeAzure.ps1')

$global:TestNow = [datetime]::SpecifyKind([datetime]'2026-03-02T10:00:00', [DateTimeKind]::Utc)

function Invoke-TestScript {
    <# Runs scripts/<Name>.ps1 in-process with the given parameters; host output is discarded. #>
    param([Parameter(Mandatory)] [string] $Name, [hashtable] $Parameters = @{})
    $script = Join-Path $global:PlaybookRoot "scripts/$Name.ps1"
    & $script @Parameters 6>$null
}

function Get-TestConnection { New-AzDevOpsConnection -Organization 'my-org' -Project 'my-project' }

function Get-SampleEnvironmentPath { param([string] $Group) if ($Group) { Join-Path $global:PlaybookRoot "environments/$Group.json" } else { Join-Path $global:PlaybookRoot 'environments' } }

function Get-SampleGroup { param([string] $Group) @(Read-EnvironmentConfig -Path (Get-SampleEnvironmentPath $Group)) }

function Get-SampleSystem { Read-SystemConfig -Path (Join-Path $global:PlaybookRoot 'orchestration/system.json') }

function New-TestJsonFile {
    <# Writes a hashtable as JSON into the test drive and returns the path. #>
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [object] $Content)
    $path = Join-Path $TestDrive $Name
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Content -Depth 20))
    $path
}

function Get-SampleJson {
    <# A sample configuration file as a hashtable, to modify in a test. #>
    param([Parameter(Mandatory)] [string] $RelativePath)
    Get-Content -LiteralPath (Join-Path $global:PlaybookRoot $RelativePath) -Raw | ConvertFrom-Json -AsHashtable
}

function Get-WriteCount { @($global:Fake.Writes).Count }
