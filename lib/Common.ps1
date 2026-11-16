Set-StrictMode -Version Latest

<#
    Small helpers shared by the library. Configuration is read with ConvertFrom-Json -AsHashtable
    and REST responses arrive as objects; under Set-StrictMode a missing key or property throws, so
    optional values are always read through Get-OptionalValue.
#>

function Get-OptionalValue {
    <#
    .SYNOPSIS
        Reads a (dotted) key or property that may be missing, from hashtables or objects.
    .EXAMPLE
        Get-OptionalValue $check 'settings.inputs.allowedBranches' ''
    #>
    param(
        [AllowNull()] [object] $InputObject,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] [object] $Default = $null
    )
    $current = $InputObject
    foreach ($part in $Name -split '\.') {
        if ($null -eq $current) { return $Default }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($part)) { return $Default }
            $current = $current[$part]
        }
        elseif ($current.PSObject.Properties[$part]) {
            $current = $current.PSObject.Properties[$part].Value
        }
        else {
            return $Default
        }
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function ConvertTo-Bool {
    <# Accepts booleans and the 'true'/'false' strings the REST API uses for task inputs. #>
    param([AllowNull()] [object] $Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    return "$Value".Trim().ToLowerInvariant() -eq 'true'
}

function Resolve-ConfigFile {
    <# Expands directories to the *.json files in them, sorted, so results do not depend on the file system. #>
    param([Parameter(Mandatory)] [string[]] $Path)
    foreach ($item in $Path) {
        if (Test-Path -LiteralPath $item -PathType Container) {
            Get-ChildItem -LiteralPath $item -Filter '*.json' -File | Sort-Object Name | ForEach-Object { $_.FullName }
        }
        elseif (Test-Path -LiteralPath $item -PathType Leaf) {
            (Resolve-Path -LiteralPath $item).Path
        }
        else {
            throw "Configuration path '$item' does not exist."
        }
    }
}
