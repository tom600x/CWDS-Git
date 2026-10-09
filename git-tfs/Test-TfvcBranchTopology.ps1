[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'migration-config.psd1'),
    [Security.SecureString]$Pat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Configuration file '$ConfigPath' was not found."
}
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath

if (-not $Pat) {
    $Pat = Read-Host 'Azure DevOps PAT (Code: Read)' -AsSecureString
}

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Pat)
try {
    $plainPat = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $basicToken = [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes(":$plainPat")
    )
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $plainPat = $null
}

$headers = @{
    Authorization = "Basic $basicToken"
}
$basicToken = $null

function Get-TfvcBranch {
    param([Parameter(Mandatory)][string]$Path)

    $organizationUrl = $config.CollectionUrl.TrimEnd('/')
    $project = [Uri]::EscapeDataString($config.ProjectName)
    $branchPath = [Uri]::EscapeDataString($Path)
    $uri = "$organizationUrl/$project/_apis/tfvc/branches" +
        "?path=$branchPath&includeParent=true&includeChildren=true&api-version=7.1"

    try {
        return Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    }
    catch {
        throw "Could not read TFVC branch metadata for '$Path': $($_.Exception.Message)"
    }
}

function Get-OptionalProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

$branchesByPath = @{}
$queue = [System.Collections.Queue]::new()
foreach ($definition in $config.Branches) {
    $queue.Enqueue($definition.TfvcPath)
}

while ($queue.Count -gt 0) {
    $path = [string]$queue.Dequeue()
    if ($branchesByPath.ContainsKey($path)) {
        continue
    }

    $response = Get-TfvcBranch $path
    $branchPath = [string](Get-OptionalProperty $response 'path')
    if ([string]::IsNullOrWhiteSpace($branchPath) -or
        -not $branchPath.Equals($path, [StringComparison]::OrdinalIgnoreCase)) {
        throw "'$path' was not returned as an exact registered TFVC branch."
    }

    $parent = Get-OptionalProperty $response 'parent'
    $parentPath = [string](Get-OptionalProperty $parent 'path')
    $branch = [pscustomobject]@{
        Path = $branchPath
        ParentPath = $parentPath
        CreatedDate = Get-OptionalProperty $response 'createdDate'
    }
    $branchesByPath[$branchPath] = $branch

    if (-not [string]::IsNullOrWhiteSpace($parentPath)) {
        $queue.Enqueue($parentPath)
    }
}

$mainDefinitions = @($config.Branches | Where-Object GitBranch -eq 'main')
if ($mainDefinitions.Count -ne 1) {
    throw "Exactly one configured GitBranch must be named 'main'."
}
$mainPath = $mainDefinitions[0].TfvcPath

$results = [System.Collections.Generic.List[object]]::new()
$roots = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($definition in $config.Branches) {
    $branch = $branchesByPath[$definition.TfvcPath]
    $current = $branch
    $mainIsAncestor = $definition.TfvcPath.Equals(
        $mainPath,
        [StringComparison]::OrdinalIgnoreCase
    )

    while (-not [string]::IsNullOrWhiteSpace($current.ParentPath)) {
        $parentPath = $current.ParentPath
        if ($parentPath.Equals($mainPath, [StringComparison]::OrdinalIgnoreCase)) {
            $mainIsAncestor = $true
        }
        $current = $branchesByPath[$parentPath]
    }

    $roots.Add($current.Path) | Out-Null
    $results.Add([pscustomobject]@{
        GitBranch = $definition.GitBranch
        TfvcPath = $branch.Path
        Parent = $branch.ParentPath
        Root = $current.Path
        CreatedDate = $branch.CreatedDate
        MainIsAncestor = $mainIsAncestor
    })
}

$results | Format-Table -AutoSize

if ($roots.Count -ne 1) {
    throw "The configured branches do not have one registered TFVC root: $($roots -join ', ')"
}

$root = [string]($roots | Select-Object -First 1)
if (-not $root.Equals($config.RootTfvcPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "RootTfvcPath is '$($config.RootTfvcPath)', but Azure DevOps reports '$root'. Update the git-tfs POC configuration before cloning."
}

$unconnected = @($results | Where-Object { -not $_.MainIsAncestor })
if ($unconnected.Count -gt 0) {
    throw "These branches do not descend from the configured main TFVC path '$mainPath': $($unconnected.GitBranch -join ', ')"
}

$topologyPath = Join-Path $config.WorkRoot 'tfvc-topology.json'
$topology = [ordered]@{
    ValidatedAt = (Get-Date).ToUniversalTime().ToString('o')
    RootTfvcPath = $root
    IncludedTfvcPaths = @($branchesByPath.Keys | Sort-Object)
}
New-Item -ItemType Directory -Path $config.WorkRoot -Force | Out-Null
[IO.File]::WriteAllText(
    $topologyPath,
    ($topology | ConvertTo-Json -Depth 3),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "TFVC metadata validation passed. Registered root: $root" -ForegroundColor Green
Write-Host "Validated clone topology written to: $topologyPath"
Write-Host 'The import will include these registered branches to preserve ancestry:'
$topology.IncludedTfvcPaths | ForEach-Object { Write-Host "  $_" }
