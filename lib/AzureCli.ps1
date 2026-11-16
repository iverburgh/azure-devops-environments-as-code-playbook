Set-StrictMode -Version Latest

<#
    The only code that talks to Azure Resource Manager and Entra ID (through the Azure CLI). Used by
    remove and cleanup. Tests replace Invoke-AzCli with the in-memory fake in tests/FakeAzure.ps1.

    Every call passes --subscription or a full resource ID; the default subscription of the Azure
    CLI is never relied on or changed.
#>

function Invoke-AzCli {
    <#
    .SYNOPSIS
        Runs az with JSON output and emits the parsed result; arrays are emitted item by item.
    .PARAMETER AllowFailure
        Do not throw on a non-zero exit code. Instead return one object with Succeeded, Output and
        Error, so the caller can tell 'not found' from other errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $AllowFailure
    )
    $raw = & az @Arguments --output json --only-show-errors 2>&1
    $exitCode = $LASTEXITCODE
    $stdout = (@($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n").Trim()
    $stderr = (@($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    $parsed = if ($stdout) { $stdout | ConvertFrom-Json } else { $null }

    if ($AllowFailure) {
        return [pscustomobject]@{ Succeeded = ($exitCode -eq 0); Output = $parsed; Error = $stderr }
    }
    if ($exitCode -ne 0) {
        throw "az $(@($Arguments | Select-Object -First 3) -join ' ') failed (exit code $exitCode): $stderr"
    }
    if ($null -eq $parsed) { return }
    foreach ($item in @($parsed)) { $PSCmdlet.WriteObject($item, $false) }
}
