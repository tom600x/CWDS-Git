[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'migration-config.psd1'),
    [ValidateSet('Preflight', 'Clone', 'Assemble', 'Lfs', 'Validate', 'Push', 'All')]
    [string]$Phase = 'Preflight',
    [switch]$ForceReclone,
    [switch]$AllowNonEmptyDestination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Sync-ProcessPath {
    $segments = @(
        ([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';')
        ([Environment]::GetEnvironmentVariable('Path', 'User') -split ';')
        ($env:Path -split ';')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $uniqueSegments = [System.Collections.Generic.List[string]]::new()
    foreach ($segment in $segments) {
        $normalized = $segment.Trim()
        if ($normalized -notin $uniqueSegments) {
            $uniqueSegments.Add($normalized)
        }
    }
    $env:Path = $uniqueSegments -join ';'
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $previousLocation = Get-Location
    try {
        if ($WorkingDirectory) {
            Set-Location $WorkingDirectory
        }

        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "'$FilePath $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Set-Location $previousLocation
    }
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $previousLocation = Get-Location
    try {
        if ($WorkingDirectory) {
            Set-Location $WorkingDirectory
        }

        $output = & $FilePath @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "'$FilePath $($Arguments -join ' ')' failed with exit code $LASTEXITCODE.`n$($output -join "`n")"
        }
        return @($output | ForEach-Object { "$_" })
    }
    finally {
        Set-Location $previousLocation
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    Invoke-Native -FilePath 'git' -Arguments (@('-C', $Repository) + $Arguments)
}

function Invoke-GitCapture {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    return Invoke-NativeCapture -FilePath 'git' -Arguments (@('-C', $Repository) + $Arguments)
}

function Get-Slug {
    param([Parameter(Mandatory)][string]$Value)
    return ($Value -replace '[^A-Za-z0-9._-]', '_')
}

function Get-ClonePath {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Definition
    )
    return Join-Path $Config.WorkRoot ('source-' + (Get-Slug $Definition.GitBranch))
}

function Get-CloneMarkerPath {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Definition
    )

    $stateDirectory = Join-Path $Config.WorkRoot 'state'
    return Join-Path $stateDirectory ((Get-Slug $Definition.GitBranch) + '.clone-complete')
}

function Assert-SafeClonePath {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ClonePath
    )

    $workRoot = [IO.Path]::GetFullPath($Config.WorkRoot).TrimEnd('\')
    $resolvedClonePath = [IO.Path]::GetFullPath($ClonePath)
    if (
        -not $resolvedClonePath.StartsWith("$workRoot\", [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($resolvedClonePath)).StartsWith('source-', [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "Refusing to remove unsafe clone path '$resolvedClonePath'."
    }
}

function Get-CurrentBranch {
    param([Parameter(Mandatory)][string]$Repository)
    return ([string](Invoke-GitCapture $Repository @('branch', '--show-current') | Select-Object -First 1)).Trim()
}

function Get-SingleRootCommit {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Ref
    )

    $roots = @(Invoke-GitCapture $Repository @('rev-list', '--max-parents=0', $Ref))
    if ($roots.Count -ne 1) {
        throw "Expected '$Ref' to have exactly one root commit, but found $($roots.Count)."
    }
    return $roots[0].Trim()
}

function Get-TfvcChangeset {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Commit
    )

    $changesets = @(
        Invoke-GitCapture $Repository @('tag', '--points-at', $Commit) |
            ForEach-Object {
                $match = [regex]::Match($_, '(?:^|/)TFS_C(\d+)$')
                if ($match.Success) {
                    [long]$match.Groups[1].Value
                }
            } |
            Sort-Object -Unique
    )

    if ($changesets.Count -ne 1) {
        throw "Expected one TFS_C changeset tag on commit $Commit, but found $($changesets.Count)."
    }
    return $changesets[0]
}

function Move-TfvcTagsToNamespace {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Namespace
    )

    $tags = @(Invoke-GitCapture $Repository @(
        'for-each-ref', '--format=%(refname:short)', 'refs/tags/TFS_C*'
    ))
    foreach ($tag in $tags) {
        $commit = ([string](Invoke-GitCapture $Repository @(
            'rev-parse', "$tag^{commit}"
        ) | Select-Object -First 1)).Trim()
        Invoke-Git $Repository @('tag', '-f', "tfvc/$Namespace/$tag", $commit)
        Invoke-Git $Repository @('tag', '-d', $tag)
    }
}

function Move-RewrittenTfvcTags {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string[]]$OldCommits,
        [Parameter(Mandatory)][string[]]$NewCommits
    )

    if ($OldCommits.Count -ne $NewCommits.Count) {
        throw "Rewriting '$Namespace' changed the commit count from $($OldCommits.Count) to $($NewCommits.Count)."
    }

    for ($index = 0; $index -lt $OldCommits.Count; $index++) {
        $tags = @(Invoke-GitCapture $Repository @('tag', '--points-at', $OldCommits[$index]))
        foreach ($tag in $tags | Where-Object { $_ -like "tfvc/$Namespace/TFS_C*" }) {
            Invoke-Git $Repository @('tag', '-f', $tag, $NewCommits[$index])
        }
    }
}

function Get-ExactTreeBranchPoint {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$ImportedRoot,
        [Parameter(Mandatory)][string[]]$CandidateRefs
    )

    $rootTree = ([string](Invoke-GitCapture $Repository @(
        'show', '-s', '--format=%T', $ImportedRoot
    ) | Select-Object -First 1)).Trim()
    $rootChangeset = Get-TfvcChangeset $Repository $ImportedRoot
    $candidates = [System.Collections.Generic.List[object]]::new()

    foreach ($ref in $CandidateRefs) {
        $lines = @(Invoke-GitCapture $Repository @('log', '--format=%H %T', $ref))
        foreach ($line in $lines) {
            $parts = $line.Trim().Split(' ')
            if ($parts.Count -ne 2 -or $parts[1] -ne $rootTree) {
                continue
            }

            $changeset = Get-TfvcChangeset $Repository $parts[0]
            if ($changeset -le $rootChangeset) {
                $candidates.Add([pscustomobject]@{
                    Commit = $parts[0]
                    Changeset = $changeset
                    Ref = $ref
                })
            }
        }
    }

    $selected = $candidates | Sort-Object Changeset -Descending | Select-Object -First 1
    if (-not $selected) {
        throw "No exact tree match was found for imported root $ImportedRoot (TFVC C$rootChangeset). Refusing to invent a branch point."
    }
    return $selected
}

function New-RootCommitWithParent {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$OriginalRoot,
        [Parameter(Mandatory)][string]$Parent
    )

    $metadataLine = [string](Invoke-GitCapture $Repository @(
        'show', '-s',
        '--format=%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI%x00%T',
        $OriginalRoot
    ) | Select-Object -First 1)
    $fields = $metadataLine.Split([char]0)

    if ($fields.Count -ne 7) {
        throw "Could not read author, committer, and tree metadata from $OriginalRoot."
    }

    $messagePath = Join-Path ([IO.Path]::GetTempPath()) ("tfvc-root-$([guid]::NewGuid().ToString('N')).txt")
    $message = (Invoke-GitCapture $Repository @('show', '-s', '--format=%B', $OriginalRoot)) -join "`n"
    [IO.File]::WriteAllText($messagePath, $message, [Text.UTF8Encoding]::new($false))

    $savedEnvironment = @{
        GIT_AUTHOR_NAME = $env:GIT_AUTHOR_NAME
        GIT_AUTHOR_EMAIL = $env:GIT_AUTHOR_EMAIL
        GIT_AUTHOR_DATE = $env:GIT_AUTHOR_DATE
        GIT_COMMITTER_NAME = $env:GIT_COMMITTER_NAME
        GIT_COMMITTER_EMAIL = $env:GIT_COMMITTER_EMAIL
        GIT_COMMITTER_DATE = $env:GIT_COMMITTER_DATE
    }

    try {
        $env:GIT_AUTHOR_NAME = $fields[0]
        $env:GIT_AUTHOR_EMAIL = $fields[1]
        $env:GIT_AUTHOR_DATE = $fields[2]
        $env:GIT_COMMITTER_NAME = $fields[3]
        $env:GIT_COMMITTER_EMAIL = $fields[4]
        $env:GIT_COMMITTER_DATE = $fields[5]

        return ([string](Invoke-GitCapture $Repository @(
            'commit-tree', $fields[6], '-p', $Parent, '-F', $messagePath
        ) | Select-Object -First 1)).Trim()
    }
    finally {
        foreach ($entry in $savedEnvironment.GetEnumerator()) {
            if ($null -eq $entry.Value) {
                Remove-Item -Path "Env:$($entry.Key)" -ErrorAction SilentlyContinue
            }
            else {
                Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
            }
        }
        Remove-Item -LiteralPath $messagePath -Force -ErrorAction SilentlyContinue
    }
}

function Assert-SameTipTree {
    param(
        [Parameter(Mandatory)][string]$SourceRepository,
        [Parameter(Mandatory)][string]$DestinationRepository,
        [Parameter(Mandatory)][string]$DestinationRef
    )

    $sourceTree = ([string](Invoke-GitCapture $SourceRepository @(
        'show', '-s', '--format=%T', 'HEAD'
    ) | Select-Object -First 1)).Trim()
    $destinationTree = ([string](Invoke-GitCapture $DestinationRepository @(
        'show', '-s', '--format=%T', $DestinationRef
    ) | Select-Object -First 1)).Trim()
    if ($sourceTree -ne $destinationTree) {
        throw "Tip tree mismatch: '$SourceRepository' does not match '$DestinationRef'."
    }
}

function Assert-Command {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$VersionArguments = @('--version')
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command '$Name' was not found on PATH."
    }
    Invoke-Native -FilePath $command.Source -Arguments $VersionArguments
}

function Invoke-Preflight {
    param([Parameter(Mandatory)][hashtable]$Config)

    Write-Step 'Checking prerequisites'
    Sync-ProcessPath
    Assert-Command 'git'
    Assert-Command 'java' @('-version')
    Invoke-Native -FilePath 'git' -Arguments @('lfs', 'version')

    if (-not (Test-Path -LiteralPath $Config.GitTfPath -PathType Leaf)) {
        throw "git-tf was not found at '$($Config.GitTfPath)'."
    }
    if ($Config.LargeFileThresholdMB -lt 1 -or $Config.LargeFileThresholdMB -ge 100) {
        throw 'LargeFileThresholdMB must be between 1 and 99 for the Azure Repos 100-MB recommendation.'
    }

    $definitions = @($Config.Main) + @($Config.Branches)
    $duplicateGitBranches = $definitions.GitBranch | Group-Object | Where-Object Count -gt 1
    $duplicateTfvcPaths = $definitions.TfvcPath | Group-Object | Where-Object Count -gt 1
    if ($duplicateGitBranches -or $duplicateTfvcPaths) {
        throw 'TFVC paths and Git branch names must each be unique.'
    }

    New-Item -ItemType Directory -Path $Config.WorkRoot -Force | Out-Null
    Write-Host "Preflight passed. Work root: $($Config.WorkRoot)"
}

function Invoke-ClonePhase {
    param([Parameter(Mandatory)][hashtable]$Config)

    Invoke-Preflight $Config
    foreach ($definition in @($Config.Main) + @($Config.Branches)) {
        $clonePath = Get-ClonePath $Config $definition
        $markerPath = Get-CloneMarkerPath $Config $definition
        if ($ForceReclone -and (Test-Path -LiteralPath $clonePath)) {
            Assert-SafeClonePath $Config $clonePath
            Remove-Item -LiteralPath $clonePath -Recurse -Force
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        }

        if (
            (Test-Path -LiteralPath (Join-Path $clonePath '.git')) -and
            (Test-Path -LiteralPath $markerPath -PathType Leaf)
        ) {
            Write-Host "Skipping completed clone: $($definition.TfvcPath)"
            continue
        }
        if (Test-Path -LiteralPath $clonePath) {
            throw "Clone path '$clonePath' is incomplete. Inspect it, then move it aside or use -ForceReclone."
        }

        Write-Step "Deep-cloning $($definition.TfvcPath)"
        Invoke-Native -FilePath $Config.GitTfPath -Arguments @(
            'clone',
            $Config.CollectionUrl,
            $definition.TfvcPath,
            $clonePath,
            '--deep',
            '--tag'
        )
        Get-TfvcChangeset $clonePath (Get-SingleRootCommit $clonePath 'HEAD') | Out-Null
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($markerPath)) -Force | Out-Null
        [IO.File]::WriteAllText($markerPath, (Get-Date).ToString('o'))
    }
}

function Invoke-AssemblePhase {
    param([Parameter(Mandatory)][hashtable]$Config)

    $mainSource = Get-ClonePath $Config $Config.Main
    if (-not (Test-Path -LiteralPath (Join-Path $mainSource '.git'))) {
        throw "Main clone '$mainSource' is missing. Run the Clone phase first."
    }
    if (Test-Path -LiteralPath $Config.OutputRepository) {
        throw "Output repository '$($Config.OutputRepository)' already exists. Move it aside before re-running Assemble."
    }

    Write-Step 'Creating the combined repository'
    Invoke-Native -FilePath 'git' -Arguments @('clone', '--no-hardlinks', $mainSource, $Config.OutputRepository)
    Invoke-Git $Config.OutputRepository @('branch', '-M', $Config.Main.GitBranch)
    Invoke-Git $Config.OutputRepository @('remote', 'remove', 'origin')
    Move-TfvcTagsToNamespace $Config.OutputRepository (Get-Slug $Config.Main.GitBranch)
    $integratedRefs = [System.Collections.Generic.List[string]]::new()
    $integratedRefs.Add($Config.Main.GitBranch)

    foreach ($definition in $Config.Branches) {
        $sourcePath = Get-ClonePath $Config $definition
        if (-not (Test-Path -LiteralPath (Join-Path $sourcePath '.git'))) {
            throw "Branch clone '$sourcePath' is missing. Run the Clone phase first."
        }

        $importRef = "refs/heads/import/$($definition.GitBranch)"
        Write-Step "Importing and connecting $($definition.GitBranch)"
        Invoke-Git $Config.OutputRepository @(
            'fetch', '--no-tags', $sourcePath, "+HEAD:$importRef"
        )
        $namespace = Get-Slug $definition.GitBranch
        Invoke-Git $Config.OutputRepository @(
            'fetch', '--no-tags', $sourcePath,
            "+refs/tags/TFS_C*:refs/tags/tfvc/$namespace/TFS_C*"
        )

        $root = Get-SingleRootCommit $Config.OutputRepository $importRef
        $branchPoint = Get-ExactTreeBranchPoint $Config.OutputRepository $root $integratedRefs.ToArray()
        Write-Host "Matched TFVC root to $($branchPoint.Ref) at C$($branchPoint.Changeset) ($($branchPoint.Commit))."

        $connectedRoot = New-RootCommitWithParent $Config.OutputRepository $root $branchPoint.Commit
        $oldCommits = @($root) + @(
            Invoke-GitCapture $Config.OutputRepository @('rev-list', '--reverse', "$root..$importRef")
        )
        Invoke-Git $Config.OutputRepository @('branch', $definition.GitBranch, $importRef)
        Invoke-Git $Config.OutputRepository @(
            'rebase', '--onto', $connectedRoot, $root, $definition.GitBranch,
            '--empty=keep', '--reapply-cherry-picks'
        )
        $newCommits = @($connectedRoot) + @(
            Invoke-GitCapture $Config.OutputRepository @(
                'rev-list', '--reverse', "$connectedRoot..$($definition.GitBranch)"
            )
        )
        Move-RewrittenTfvcTags $Config.OutputRepository $namespace $oldCommits $newCommits
        Assert-SameTipTree $sourcePath $Config.OutputRepository $definition.GitBranch
        Invoke-Git $Config.OutputRepository @('branch', '-D', "import/$($definition.GitBranch)")
        $integratedRefs.Add($definition.GitBranch)
    }

    Invoke-Git $Config.OutputRepository @('checkout', $Config.Main.GitBranch)
    Write-Host 'Assembly completed and every migrated branch tip matches its TFVC clone.'
}

function Invoke-LfsPhase {
    param([Parameter(Mandatory)][hashtable]$Config)

    if (-not (Test-Path -LiteralPath (Join-Path $Config.OutputRepository '.git'))) {
        throw 'Combined repository is missing. Run the Assemble phase first.'
    }

    $threshold = "$($Config.LargeFileThresholdMB)MB"
    Write-Step "Reporting blobs at or above $threshold"
    Invoke-Git $Config.OutputRepository @('lfs', 'migrate', 'info', '--everything', "--above=$threshold")

    Write-Step "Migrating blobs at or above $threshold to Git LFS"
    Invoke-Git $Config.OutputRepository @('lfs', 'install', '--local')
    Invoke-Git $Config.OutputRepository @(
        'lfs', 'migrate', 'import', '--everything', "--above=$threshold", '--yes'
    )
    Invoke-Git $Config.OutputRepository @('lfs', 'fsck')
}

function Invoke-ValidatePhase {
    param([Parameter(Mandatory)][hashtable]$Config)

    $repository = $Config.OutputRepository
    if (-not (Test-Path -LiteralPath (Join-Path $repository '.git'))) {
        throw 'Combined repository is missing.'
    }

    Write-Step 'Validating repository integrity and topology'
    $expectedBranches = @($Config.Main.GitBranch) + @($Config.Branches.GitBranch)
    $actualBranches = @(Invoke-GitCapture $repository @('for-each-ref', '--format=%(refname:short)', 'refs/heads/'))
    $missing = @($expectedBranches | Where-Object { $_ -notin $actualBranches })
    if ($missing.Count -gt 0) {
        throw "Missing expected branches: $($missing -join ', ')"
    }

    $roots = @(
        (Invoke-GitCapture $repository (@('rev-list', '--max-parents=0') + $expectedBranches)) |
            Sort-Object -Unique
    )
    if ($roots.Count -ne 1) {
        throw "Expected one shared root across migrated branches, but found $($roots.Count)."
    }

    foreach ($branch in $Config.Branches.GitBranch) {
        Invoke-Git $repository @('merge-base', '--is-ancestor', $Config.Main.GitBranch, $branch)
    }

    Invoke-Git $repository @('fsck', '--full')
    Invoke-Git $repository @('lfs', 'fsck')
    Invoke-Git $repository @('status', '--short')
    Invoke-Git $repository @('count-objects', '-vH')
    Invoke-Git $repository @(
        'lfs', 'migrate', 'info', '--everything',
        "--above=$($Config.LargeFileThresholdMB)MB"
    )
    Write-Host 'Validation passed.'
}

function Invoke-PushPhase {
    param([Parameter(Mandatory)][hashtable]$Config)

    if ([string]::IsNullOrWhiteSpace($Config.DestinationUrl)) {
        throw 'Set DestinationUrl in migration-config.psd1 before running the Push phase.'
    }

    $existingRefs = @(Invoke-NativeCapture -FilePath 'git' -Arguments @('ls-remote', '--heads', $Config.DestinationUrl))
    if ($existingRefs.Count -gt 0 -and -not $AllowNonEmptyDestination) {
        throw 'Destination contains branches. Use a new empty Azure Repos repository or explicitly pass -AllowNonEmptyDestination.'
    }

    $repository = $Config.OutputRepository
    $remotes = @(Invoke-GitCapture $repository @('remote'))
    if ('origin' -in $remotes) {
        Invoke-Git $repository @('remote', 'set-url', 'origin', $Config.DestinationUrl)
    }
    else {
        Invoke-Git $repository @('remote', 'add', 'origin', $Config.DestinationUrl)
    }

    Write-Step 'Pushing branches'
    Invoke-Git $repository @('push', '--set-upstream', 'origin', $Config.Main.GitBranch)
    foreach ($branch in $Config.Branches.GitBranch) {
        Invoke-Git $repository @('push', '--set-upstream', 'origin', $branch)
    }
    Invoke-Git $repository @('push', 'origin', '--tags')
    Invoke-Git $repository @('lfs', 'push', '--all', 'origin')
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Configuration file '$ConfigPath' was not found."
}
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath

switch ($Phase) {
    'Preflight' { Invoke-Preflight $config }
    'Clone' { Invoke-ClonePhase $config }
    'Assemble' { Invoke-AssemblePhase $config }
    'Lfs' { Invoke-LfsPhase $config }
    'Validate' { Invoke-ValidatePhase $config }
    'Push' { Invoke-PushPhase $config }
    'All' {
        Invoke-ClonePhase $config
        Invoke-AssemblePhase $config
        Invoke-LfsPhase $config
        Invoke-ValidatePhase $config
        Invoke-PushPhase $config
    }
}
