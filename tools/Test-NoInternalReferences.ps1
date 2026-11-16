<#
.SYNOPSIS
    Fails if any organisation-specific reference leaks into this repository.

.DESCRIPTION
    Everything published here must be generic: no organisation or product names, no internal
    hostnames, no work item numbers, no identifiers of real resources.

    Generic patterns are built in. The names of the organisation and product this playbook was
    extracted from are deliberately NOT in this file - listing them would publish them. They are
    loaded from:

      - tools/forbidden-terms.local.txt  (git-ignored; one regular expression per line, # comments)
      - the FORBIDDEN_TERMS environment variable (separated by newlines or semicolons), which CI
        fills from a repository secret

    GUIDs are forbidden, with two exceptions: zero-filled placeholders, and the short list of
    well-known identifiers below. Those are public constants published by Microsoft, identical in
    every Azure DevOps organisation, and the REST API needs them to create checks. They identify a
    product feature, not a tenant, a person or a resource.

.PARAMETER Path
    Root to scan. Defaults to the repository root.

.EXAMPLE
    pwsh ./tools/Test-NoInternalReferences.ps1
#>
[CmdletBinding()]
param(
    [string] $Path = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$binary = '\.(png|jpe?g|gif|ico|svg|pdf|zip|gz|7z|dll|exe|pdb|db|pfx|snk|woff2?|ttf)$'
$localTerms = Join-Path $PSScriptRoot 'forbidden-terms.local.txt'

# Zero-filled GUIDs such as 00000000-0000-0000-0000-000000000001 are obvious placeholders.
$placeholderGuid = '^0{8}-0{4}-0{4}-0{4}-0{8}[0-9a-f]{4}$'

# Public, well-known Microsoft identifiers (the same in every organisation). Keep this list short and
# explain every entry; never add an identifier of your own organisation here.
$wellKnownGuids = @{
    '499b84ac-1321-427f-aa17-267ca6975798' = 'Azure DevOps resource (token audience for az account get-access-token)'
    '2ef31ad6-baa0-403a-8b45-2cbc9b4e5563' = 'check type: Exclusive Lock'
    '8c6f20a7-a545-4486-9777-f762fafe0d4d' = 'check type: Approval'
    'fe1de3ee-a436-41b4-bb20-f6eb4cb879a7' = 'check type: Task Check (generic task-based check)'
    '86b05a0c-73e6-4f7d-b3cf-e38f3b39a75b' = 'check task: evaluate branch protection (Branch control)'
}

# Scan everything except binaries and build output: an extension allow-list would skip dotfiles, where stray references hide.
$files = @(Get-ChildItem -Path $Path -Recurse -File -Force |
        Where-Object {
            $_.FullName -notmatch '[\\/](\.git|bin|obj|TestResults|exported)[\\/]' -and
            $_.Extension -notmatch $binary -and
            $_.FullName -ne $PSCommandPath -and
            $_.FullName -ne $localTerms
        })

$forbidden = [Collections.Generic.List[hashtable]]::new()
@(
    @{ Name = 'Organisation URL';     Pattern = 'dev\.azure\.com/(?!<|example/)[A-Za-z0-9._-]+/[A-Za-z0-9._-]'; Why = 'Use dev.azure.com/<org>/<project>.' }
    @{ Name = 'Legacy org URL';       Pattern = '(?<![./-])\b(?!(code|marketplace|app)\.)[A-Za-z0-9-]+\.visualstudio\.com'; Why = 'Use dev.azure.com/<org>.' }
    @{ Name = 'Private feed';         Pattern = 'pkgs\.dev\.azure\.com/(?!<)[A-Za-z0-9._-]+/';            Why = 'Use <org> and <feed> placeholders.' }
    @{ Name = 'Internal mail domain'; Pattern = '@(?!example\.com)[A-Za-z0-9-]+\.(nl|local|internal)\b';  Why = 'Use example.com.' }
    @{ Name = 'Work item reference';  Pattern = '(?i)\b(PBI|task|feature|bug)\s*#?\s*\d{5,}\b|(?<!:\s{0,3})#\d{6,}\b'; Why = 'Internal tracking numbers.' }
    @{ Name = 'Tenant or object ID';  Pattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'; Why = 'GUIDs identify real resources and identities; use 00000000-0000-0000-0000-00000000000N placeholders.' }
    @{ Name = 'Real hostname';        Pattern = '(?i)\b[a-z0-9-]+\.(azurewebsites\.net|azconfig\.io|servicebus\.windows\.net|blob\.core\.windows\.net|database\.windows\.net|in\.applicationinsights\.azure\.com|monitor\.azure\.com)\b(?<!(my-[a-z0-9-]+|example)\.[a-z.]+)'; Why = 'Use placeholders such as my-app.azurewebsites.net.' }
    @{ Name = 'Partner hostname';     Pattern = '(?i)https?://(?!(localhost|127\.0\.0\.1|[a-z0-9.-]*example\.(com|org|net)|[a-z0-9.-]*\.example|my-[a-z0-9-]+\.(azurewebsites\.net|azconfig\.io|servicebus\.windows\.net|blob\.core\.windows\.net|database\.windows\.net)(?![a-z0-9-]|\.[a-z0-9])|(vssps\.)?dev\.azure\.com|learn\.microsoft\.com|github\.com|www\.w3\.org|json-schema\.org|aka\.ms|json\.schemastore\.org)\b)[a-z0-9.-]+\.[a-z]{2,}'; Why = 'Dependencies in examples use example.com or *.example; Azure endpoints use my-* placeholders.' }
    @{ Name = 'Windows user path';    Pattern = '(?i)C:\\Users\\(?!<)[A-Za-z0-9._-]+\\';                  Why = 'Personal paths identify people.' }
    @{ Name = 'Dutch text';           Pattern = '(?i)\b(werd|wordt|niet|geen|deze|zodat|omdat|waardoor|bijvoorbeeld|voorkomt|omgeving|goedkeuring)\b'; Why = 'Repository is English-only.' }
) | ForEach-Object { $forbidden.Add($_) }

$extra = @()
if (Test-Path $localTerms) { $extra += Get-Content $localTerms }
if ($env:FORBIDDEN_TERMS) { $extra += $env:FORBIDDEN_TERMS -split '[;\r\n]+' }
$extra = @($extra | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
foreach ($term in $extra) {
    $forbidden.Add(@{ Name = 'Organisation-specific term'; Pattern = "(?i)$term"; Why = 'Listed in forbidden-terms.local.txt or FORBIDDEN_TERMS.' })
}

Write-Host "Scanning $($files.Count) files under $Path"
if ($extra.Count -eq 0) {
    Write-Warning 'No organisation-specific terms loaded: create tools/forbidden-terms.local.txt or set FORBIDDEN_TERMS. Only generic patterns are checked.'
}
else {
    Write-Host "Loaded $($extra.Count) organisation-specific term(s)."
}

$findings = @()
foreach ($rule in $forbidden) {
    foreach ($hit in @($files | Select-String -Pattern $rule.Pattern -AllMatches -ErrorAction SilentlyContinue)) {
        $matched = @($hit.Matches | ForEach-Object { $_.Value.ToLowerInvariant() })
        if ($rule.Name -eq 'Tenant or object ID' -and
            -not ($matched | Where-Object { $_ -notmatch $placeholderGuid -and -not $wellKnownGuids.ContainsKey($_) })) {
            continue
        }

        $findings += [pscustomobject]@{
            Rule = $rule.Name
            File = [IO.Path]::GetRelativePath($Path, $hit.Path)
            Line = $hit.LineNumber
            # CI logs are public: never echo an organisation-specific match.
            Text = if ($rule.Name -eq 'Organisation-specific term') { '(match hidden)' } else { $hit.Line.Trim() }
            Why  = $rule.Why
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Host 'No internal references found.' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host "$($findings.Count) potential leak(s) found:" -ForegroundColor Red
foreach ($group in $findings | Group-Object Rule) {
    Write-Host ''
    Write-Host "  $($group.Name) - $($group.Group[0].Why)" -ForegroundColor Yellow
    foreach ($f in $group.Group) {
        $snippet = if ($f.Text.Length -gt 110) { $f.Text.Substring(0, 110) + '...' } else { $f.Text }
        Write-Host "    $($f.File):$($f.Line)  $snippet"
    }
}
Write-Host ''
exit 1
