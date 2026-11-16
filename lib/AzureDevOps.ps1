Set-StrictMode -Version Latest

<#
    The only code that talks to the Azure DevOps REST API. Everything else calls Invoke-AzDevOps,
    so the tests can replace it with the in-memory fake in tests/FakeAzureDevOps.ps1.

    Credentials, in this order:
      1. AZURE_DEVOPS_EXT_PAT  - a personal access token (Basic authentication)
      2. SYSTEM_ACCESSTOKEN    - the job access token of a pipeline (Bearer)
      3. the signed-in Azure CLI identity (az login, or a service connection with workload identity
         federation via AzureCLI@2), which asks Entra ID for a token for Azure DevOps (Bearer)
#>

function New-AzDevOpsConnection {
    <#
    .SYNOPSIS
        Describes the organisation and project to talk to. -Organization takes a name or a URL,
        so $(System.CollectionUri) works in a pipeline.
    #>
    param(
        [Parameter(Mandatory)] [string] $Organization,
        [Parameter(Mandatory)] [string] $Project
    )
    $value = $Organization.Trim().TrimEnd('/')
    if ($value -match '^https://') {
        $url = $value
        $name = ($value -split '/')[-1]
    }
    else {
        $name = $value
        $url = 'https://dev.azure.com/' + $name
    }
    @{
        OrganizationUrl = $url
        OrganizationName = $name
        IdentityUrl = 'https://vssps.dev.azure.com/' + $name
        Project = $Project
    }
}

function Get-AzDevOpsAuthorizationHeader {
    if ($env:AZURE_DEVOPS_EXT_PAT) {
        $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $env:AZURE_DEVOPS_EXT_PAT))
        return @{ Authorization = "Basic $basic" }
    }
    if ($env:SYSTEM_ACCESSTOKEN) {
        return @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" }
    }
    # Well-known application ID of Azure DevOps: the same in every tenant.
    $token = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw 'No credentials for Azure DevOps: set AZURE_DEVOPS_EXT_PAT or SYSTEM_ACCESSTOKEN, or sign in with az login.'
    }
    @{ Authorization = "Bearer $token" }
}

function Invoke-AzDevOps {
    <#
    .SYNOPSIS
        Calls the Azure DevOps REST API.
    .PARAMETER Scope
        Project:      <organisation>/<project>/_apis/<Path>
        Organization: <organisation>/_apis/<Path>
        Identity:     the identity service of the organisation (vssps), for resolving names
    .PARAMETER Path
        Relative path including the query string, for example
        'distributedtask/environments?$top=500&api-version=7.1'.
    .PARAMETER All
        Follow continuation tokens and emit the items of 'value' one by one. Without -All the parsed
        response is returned as it is.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Connection,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')] [string] $Method = 'GET',
        [ValidateSet('Project', 'Organization', 'Identity')] [string] $Scope = 'Project',
        [Parameter(Mandatory)] [string] $Path,
        [object] $Body,
        [switch] $All
    )
    $base = switch ($Scope) {
        'Project' { "$($Connection.OrganizationUrl)/$([uri]::EscapeDataString($Connection.Project))/_apis" }
        'Organization' { "$($Connection.OrganizationUrl)/_apis" }
        'Identity' { "$($Connection.IdentityUrl)/_apis" }
    }
    $uri = "$base/$Path"
    $headers = Get-AzDevOpsAuthorizationHeader
    $continuation = $null
    $responseHeaders = $null

    do {
        $pageUri = $uri
        if ($continuation) {
            $separator = if ($uri.Contains('?')) { '&' } else { '?' }
            $pageUri = "$uri${separator}continuationToken=$([uri]::EscapeDataString($continuation))"
        }
        $request = @{
            Method = $Method
            Uri = $pageUri
            Headers = $headers
            ResponseHeadersVariable = 'responseHeaders'
            ErrorAction = 'Stop'
        }
        if ($PSBoundParameters.ContainsKey('Body')) {
            $request.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
            $request.ContentType = 'application/json'
        }
        $response = Invoke-RestMethod @request

        if (-not $All) { return $response }

        if ($null -ne $response -and $response.PSObject.Properties['value']) {
            foreach ($item in @($response.value)) { $PSCmdlet.WriteObject($item, $false) }
        }
        $continuation = $null
        if ($responseHeaders -and $responseHeaders.ContainsKey('x-ms-continuationtoken')) {
            $continuation = @($responseHeaders['x-ms-continuationtoken'])[0]
        }
    } while ($continuation)
}
