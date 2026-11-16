#Requires -Version 7.2
<#
.SYNOPSIS
    Exports Azure DevOps environments and their checks to environments/<group>.json files.

.DESCRIPTION
    For adopting an existing project: export, review, add policy and security, commit, then let
    Set-Environments.ps1 manage them. Every environment named '<system> - <group>' or
    '<system> - <group> - <suffix>' is exported into <group>.json. Checks of types this playbook
    does not manage are reported, not exported. Existing files are only overwritten with -Force.

.EXAMPLE
    ./scripts/Export-Environments.ps1 -Organization my-org -Project my-project -System shop
#>
[CmdletBinding()]
param(
    [string] $Organization = $env:SYSTEM_COLLECTIONURI,
    [string] $Project = $env:SYSTEM_TEAMPROJECT,
    [Parameter(Mandatory)] [string] $System,
    [string[]] $Group = @(),
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '..' 'exported'),
    [switch] $Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($file in 'Common', 'AzureDevOps', 'Config', 'Environments', 'Export') { . (Join-Path $PSScriptRoot '..' 'lib' "$file.ps1") }

if (-not $Organization -or -not $Project) { throw 'Pass -Organization and -Project (or run in a pipeline, which sets them).' }

$connection = New-AzDevOpsConnection -Organization $Organization -Project $Project
$written = @(Export-EnvironmentGroup -Connection $connection -System $System -Group $Group -OutputDirectory $OutputDirectory -Force:$Force)
foreach ($path in $written) { Write-Host "Exported $path" }
$written
