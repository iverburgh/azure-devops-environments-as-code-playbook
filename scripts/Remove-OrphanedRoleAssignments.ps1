#Requires -Version 7.2
<#
.SYNOPSIS
    Finds orphaned role assignments in the resource groups of an environment and, with -Execute,
    deletes them. Without -Execute it is a dry run that changes nothing.

.DESCRIPTION
    Recommended flow (see pipelines/cleanup.yml):
      1. dry run with -ReportPath: review the CSV
      2. -Execute -ApprovedReport <the reviewed CSV>: only those assignments are deleted, and only
         if they are still orphaned
    A circuit breaker stops everything when an implausibly high share of assignments looks orphaned.
    In a pipeline also pass -Confirm:$false with -Execute.

.EXAMPLE
    ./scripts/Remove-OrphanedRoleAssignments.ps1 -Environment test -ReportPath ./orphans-test.csv

.EXAMPLE
    ./scripts/Remove-OrphanedRoleAssignments.ps1 -Environment test -Execute -ApprovedReport ./orphans-test.csv
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $Environment,
    [switch] $Execute,
    [string] $ReportPath,
    [string] $ApprovedReport,
    [switch] $RemoveLocksTemporarily,
    [string] $SystemPath = (Join-Path $PSScriptRoot '..' 'orchestration' 'system.json'),
    [datetime] $Now = [datetime]::UtcNow
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($file in 'Common', 'AzureCli', 'Config', 'Orchestration', 'Cleanup') { . (Join-Path $PSScriptRoot '..' 'lib' "$file.ps1") }

$system = Read-SystemConfig -Path $SystemPath
if (-not $system.Environments.Contains($Environment)) { throw "Unknown environment '$Environment'. Known: $(@($system.Environments.Keys) -join ', ')." }
if ($null -eq $system.Cleanup) { throw 'system.json has no "cleanup" section.' }
if ($ApprovedReport -and -not $Execute) { throw '-ApprovedReport is only used with -Execute.' }

$subscriptionId = $system.Environments[$Environment].SubscriptionId
$result = Get-OrphanedRoleAssignment -Cleanup $system.Cleanup -Environment $Environment -SubscriptionId $subscriptionId -Now $Now
$rows = @($result.Rows)
Write-Host "Scanned $($result.ResourceGroups.Count) resource group(s), $($result.TotalAssignments) role assignment(s)."
foreach ($row in $rows) { Write-Host ("  {0,-13} {1,-28} {2,-26} {3}" -f $row.Status, $row.ResourceGroup, $row.RoleDefinitionName, $row.PrincipalId) }
if ($ReportPath) {
    # Always write the file (header only when clean), so a pipeline can publish it as an artifact.
    if ($rows.Count -gt 0) { $rows | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding utf8 }
    else { [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath), '"Id","ResourceGroup","Scope","RoleDefinitionName","PrincipalId","PrincipalType","CreatedOn","Status"' + "`n") }
    Write-Host "Report: $ReportPath"
}
Assert-OrphanRatio -Result $result -Cleanup $system.Cleanup

$orphaned = @($rows | Where-Object { $_.Status -eq 'Orphaned' })
if (-not $Execute) {
    Write-Host "Dry run: $($orphaned.Count) orphaned role assignment(s) would be deleted. Nothing was changed; pass -Execute to delete."
    return
}

$removal = @{ Rows = $rows; SubscriptionId = $subscriptionId; RemoveLocksTemporarily = $RemoveLocksTemporarily }
if ($ApprovedReport) { $removal.ApprovedId = [string[]]@(Import-Csv -LiteralPath $ApprovedReport | ForEach-Object { $_.Id }) }
$deleted = @(Remove-OrphanedRoleAssignment @removal)
Write-Host "Deleted $(@($deleted | Where-Object { $_.Result -eq 'Deleted' }).Count) role assignment(s)."
$deleted
