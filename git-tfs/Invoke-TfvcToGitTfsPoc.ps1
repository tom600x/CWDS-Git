[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'migration-config.psd1'),
    [ValidateSet('Preflight', 'Discover', 'Clone', 'Materialize', 'Validate', 'Verify', 'Lfs', 'Push', 'All')]
    [string]$Phase = 'Preflight',
    [switch]$UsePat,
    [Security.SecureString]$Pat,
    [switch]$UseGitIgnore,
    [switch]$UseRenameRepair,
    [switch]$AllowNonEmptyDestination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$FilePath $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = & $FilePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "'$FilePath $($Arguments -join ' ')' failed with exit code $LASTEXITCODE.`n$($output -join "`n")"
    }
    return @($output | ForEach-Object { "$_" })
}

function Invoke-NativeWithPat {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Security.SecureString]$Pat,
        [Parameter(Mandatory)][hashtable]$Config
    )

    foreach ($target in @(
        [EnvironmentVariableTarget]::Process,
        [EnvironmentVariableTarget]::User,
        [EnvironmentVariableTarget]::Machine
    )) {
        if (-not [string]::IsNullOrWhiteSpace(
            [Environment]::GetEnvironmentVariable('GIT_TFS_PAT', $target)
        )) {
            throw "A persistent GIT_TFS_PAT exists at $target scope. Remove it and use the secure process-only prompt."
        }
    }

    $securePat = $Pat
    if (-not $securePat) {
        $securePat = Read-Host 'Azure DevOps PAT' -AsSecureString
    }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePat)
    try {
        $plainPat = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim()
        if ([string]::IsNullOrWhiteSpace($plainPat)) {
            throw 'The Azure DevOps PAT is empty.'
        }

        $basicToken = [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes(":$plainPat")
        )
        $organizationUrl = $Config.CollectionUrl.TrimEnd('/')
        $project = [Uri]::EscapeDataString($Config.ProjectName)
        $rootPath = [Uri]::EscapeDataString($Config.RootTfvcPath)
        $validationUri = "$organizationUrl/$project/_apis/tfvc/branches" +
            "?path=$rootPath&api-version=7.1"
        try {
            Invoke-RestMethod -Method Get -Uri $validationUri -Headers @{
                Authorization = "Basic $basicToken"
            } | Out-Null
        }
        catch {
            throw "Azure DevOps rejected the PAT for organization/project '$organizationUrl/$($Config.ProjectName)'. Verify that the token is current, belongs to an identity with TFVC access, and has sufficient Code scope. $($_.Exception.Message)"
        }
        finally {
            $basicToken = $null
        }

        [Environment]::SetEnvironmentVariable(
            'GIT_TFS_PAT',
            $plainPat,
            [EnvironmentVariableTarget]::Process
        )
        Invoke-Native $FilePath $Arguments
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            'GIT_TFS_PAT',
            $null,
            [EnvironmentVariableTarget]::Process
        )
        Remove-Item Env:GIT_TFS_PAT -ErrorAction SilentlyContinue
        $plainPat = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    Invoke-Native 'git' (@('-C', $Repository) + $Arguments)
}

function Invoke-GitCapture {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    return Invoke-NativeCapture 'git' (@('-C', $Repository) + $Arguments)
}

function Invoke-Preflight {
    param([Parameter(Mandatory)][hashtable]$Config)

    Write-Step 'Checking git-tfs proof-of-concept prerequisites'
    if (
        $Config.ContainsKey('TfsClientVersion') -and
        $Config.TfsClientVersion -notin @('2022', '2019', '2017', '2015')
    ) {
        throw "TfsClientVersion must be 2022, 2019, 2017, or 2015."
    }
    if (
        $UseGitIgnore -and
        (
            -not $Config.ContainsKey('GitIgnorePath') -or
            -not (Test-Path -LiteralPath $Config.GitIgnorePath -PathType Leaf)
        )
    ) {
        throw "GitIgnorePath '$($Config.GitIgnorePath)' was not found."
    }
    foreach ($commandName in @('git', $Config.GitTfsPath)) {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            throw "Required command '$commandName' was not found."
        }
    }
    Invoke-Native 'git' @('lfs', 'version')

    $definitions = @($Config.Branches)
    if (($definitions.GitBranch | Group-Object | Where-Object Count -gt 1) -or
        ($definitions.TfvcPath | Group-Object | Where-Object Count -gt 1)) {
        throw 'TFVC paths and Git branch names must each be unique.'
    }
    if ($Config.RootTfvcPath -notin $definitions.TfvcPath) {
        Write-Warning 'RootTfvcPath is not one of the final branches. Its history will still be imported to preserve ancestry.'
    }
    if ($Config.LargeFileThresholdMB -lt 1 -or $Config.LargeFileThresholdMB -ge 100) {
        throw 'LargeFileThresholdMB must be between 1 and 99 for the Azure Repos 100-MB recommendation.'
    }

    $workspacePath = [IO.Path]::GetFullPath($Config.WorkspacePath).TrimEnd('\')
    $outputRepository = [IO.Path]::GetFullPath($Config.OutputRepository).TrimEnd('\')
    if (-not [IO.Path]::IsPathRooted($Config.WorkspacePath)) {
        throw 'WorkspacePath must be an absolute local path.'
    }
    if (
        $workspacePath.StartsWith("$outputRepository\", [StringComparison]::OrdinalIgnoreCase) -or
        $outputRepository.StartsWith("$workspacePath\", [StringComparison]::OrdinalIgnoreCase) -or
        $workspacePath.Equals($outputRepository, [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw 'WorkspacePath and OutputRepository must not contain one another.'
    }
    if ($workspacePath.Length -gt 20) {
        Write-Warning "WorkspacePath '$workspacePath' is longer than 20 characters. A path close to the drive root reduces TFVC path-length failures."
    }

    New-Item -ItemType Directory -Path $Config.WorkRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null
    Invoke-Native $Config.GitTfsPath @('--version')
}

function Invoke-Discover {
    param([Parameter(Mandatory)][hashtable]$Config)

    Invoke-Preflight $Config
    Write-Step 'Discovering registered TFVC branch relationships'
    Invoke-Native $Config.GitTfsPath @('list-remote-branches', $Config.CollectionUrl)
    Write-Host "RootTfvcPath must be a root branch marked [*]. Currently configured: $($Config.RootTfvcPath)"
}

function Get-IgnoredBranchRegex {
    param([Parameter(Mandatory)][hashtable]$Config)

    $topologyPath = Join-Path $Config.WorkRoot 'tfvc-topology.json'
    if (-not (Test-Path -LiteralPath $topologyPath -PathType Leaf)) {
        throw "Validated topology '$topologyPath' is missing. Run Test-TfvcBranchTopology.ps1 before cloning."
    }

    $topology = Get-Content -LiteralPath $topologyPath -Raw | ConvertFrom-Json
    if (-not $topology.RootTfvcPath.Equals(
        $Config.RootTfvcPath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Validated root '$($topology.RootTfvcPath)' does not match configured RootTfvcPath '$($Config.RootTfvcPath)'. Rerun Test-TfvcBranchTopology.ps1."
    }

    $includedPaths = @(
        @($topology.IncludedTfvcPaths) |
            Sort-Object -Unique |
            ForEach-Object { [regex]::Escape($_) }
    )
    if ($includedPaths.Count -eq 0) {
        throw "Validated topology '$topologyPath' contains no TFVC paths."
    }
    return "^(?!(?:$($includedPaths -join '|'))$).*"
}

function Set-ResumableCloneHead {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string[]]$RemoteConfigLines
    )

    $rootRemoteIds = @(
        foreach ($line in $RemoteConfigLines) {
            $match = [regex]::Match(
                $line,
                '^tfs-remote\.(.+)\.repository\s+(.+)$'
            )
            if (-not $match.Success) {
                throw "Could not parse git-tfs remote configuration line '$line'."
            }
            if ($match.Groups[2].Value.Trim().Equals(
                $Config.RootTfvcPath,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                $match.Groups[1].Value
            }
        }
    )
    if ($rootRemoteIds.Count -ne 1) {
        throw "Expected one git-tfs remote for root '$($Config.RootTfvcPath)', but found $($rootRemoteIds.Count)."
    }

    $rootRef = "refs/remotes/tfs/$($rootRemoteIds[0])"
    Invoke-Git $Config.OutputRepository @(
        'show-ref', '--verify', '--quiet', $rootRef
    )
    Invoke-Git $Config.OutputRepository @(
        'checkout', '--detach', $rootRef
    )
    Write-Host "Resuming from metadata-bearing root ref '$rootRef'."
    return $rootRef
}

function Invoke-Clone {
    param([Parameter(Mandatory)][hashtable]$Config)

    Invoke-Preflight $Config
    $gitDirectory = Join-Path $Config.OutputRepository '.git'
    if (
        (Test-Path -LiteralPath $Config.OutputRepository) -and
        -not (Test-Path -LiteralPath $gitDirectory)
    ) {
        throw "Output path '$($Config.OutputRepository)' exists but is not a resumable Git repository."
    }

    $rootRef = $null
    if (Test-Path -LiteralPath $gitDirectory) {
        Invoke-Git $Config.OutputRepository @(
            'config', 'git-tfs.workspace-dir', $Config.WorkspacePath
        )
        $remoteConfigLines = @(Invoke-GitCapture $Config.OutputRepository @(
            'config', '--get-regexp', '^tfs-remote\..*\.repository$'
        ))
        foreach ($line in $remoteConfigLines) {
            $match = [regex]::Match(
                $line,
                '^tfs-remote\.(.+)\.repository\s+'
            )
            if (-not $match.Success) {
                throw "Could not parse git-tfs remote configuration line '$line'."
            }
            Invoke-Git $Config.OutputRepository @(
                'config', "tfs-remote.$($match.Groups[1].Value).noparallel",
                (-not $Config.ParallelDownloads).ToString().ToLowerInvariant()
            )
        }

        $configuredWorkspace = ([string](Invoke-GitCapture $Config.OutputRepository @(
            'config', '--get', 'git-tfs.workspace-dir'
        ) | Select-Object -First 1)).Trim()
        if (-not $configuredWorkspace.Equals(
            $Config.WorkspacePath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Could not configure git-tfs workspace '$($Config.WorkspacePath)' in the resumable repository."
        }

        $rootRef = Set-ResumableCloneHead $Config $remoteConfigLines
        if ($UseGitIgnore) {
            & git -C $Config.OutputRepository cat-file -e "${rootRef}:.gitignore" 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw 'Cannot introduce the migration .gitignore midway through an existing clone. Use -UseGitIgnore only for a clean clone that was started with the same option.'
            }
        }
    }

    $ignoreBranches = Get-IgnoredBranchRegex $Config
    $cloneArguments = @(
        'clone',
        '--branches=all',
        '--resumable',
        "--workspace=$($Config.WorkspacePath)"
    )
    if (-not $Config.ParallelDownloads) {
        $cloneArguments += '--no-parallel'
    }
    if ($UseGitIgnore) {
        $cloneArguments += "--gitignore=$($Config.GitIgnorePath)"
    }
    $cloneArguments += @(
        "--ignore-branches-regex=$ignoreBranches",
        $Config.CollectionUrl,
        $Config.RootTfvcPath,
        $Config.OutputRepository
    )

    Write-Step 'Cloning registered TFVC branches with resumable history import'
    if ($UsePat) {
        Invoke-NativeWithPat $Config.GitTfsPath $cloneArguments $Pat $Config
    }
    else {
        Invoke-Native $Config.GitTfsPath $cloneArguments
    }
}

function Get-TfsRemoteMap {
    param([Parameter(Mandatory)][string]$Repository)

    $remoteMap = [System.Collections.Generic.List[object]]::new()
    $lines = @(Invoke-GitCapture $Repository @(
        'config', '--get-regexp', '^tfs-remote\..*\.repository$'
    ))
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^tfs-remote\.(.+)\.repository\s+(.+)$')
        if (-not $match.Success) {
            throw "Could not parse git-tfs remote configuration line '$line'."
        }

        $remoteId = $match.Groups[1].Value
        $fetchRef = ([string](Invoke-GitCapture $Repository @(
            'config', '--get', "tfs-remote.$remoteId.fetch"
        ) | Select-Object -First 1)).Trim()
        $remoteMap.Add([pscustomobject]@{
            Id = $remoteId
            TfvcPath = $match.Groups[2].Value.Trim()
            FetchRef = $fetchRef
        })
    }
    return $remoteMap
}

function Invoke-Materialize {
    param([Parameter(Mandatory)][hashtable]$Config)

    $repository = $Config.OutputRepository
    if (-not (Test-Path -LiteralPath (Join-Path $repository '.git'))) {
        throw 'The git-tfs clone is missing. Run the Clone phase first.'
    }

    Write-Step 'Creating final local branches from git-tfs remotes'
    $remoteMap = @(Get-TfsRemoteMap $repository)
    Invoke-Git $repository @('checkout', '--detach')

    foreach ($definition in $Config.Branches) {
        $matches = @($remoteMap | Where-Object {
            $_.TfvcPath.Equals($definition.TfvcPath, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -ne 1) {
            throw "Expected one git-tfs remote for '$($definition.TfvcPath)', but found $($matches.Count)."
        }

        Invoke-Git $repository @(
            'show-ref', '--verify', '--quiet', $matches[0].FetchRef
        )
        Invoke-Git $repository @(
            'branch', '-f', $definition.GitBranch, $matches[0].FetchRef
        )
    }

    $main = @($Config.Branches | Where-Object GitBranch -eq 'main')
    if ($main.Count -ne 1) {
        throw "Exactly one configured GitBranch must be named 'main'."
    }
    Invoke-Git $repository @('checkout', 'main')
}

function Invoke-Validate {
    param([Parameter(Mandatory)][hashtable]$Config)

    $repository = $Config.OutputRepository
    Write-Step 'Validating branch-aware proof of concept'
    $expectedBranches = @($Config.Branches.GitBranch)
    $actualBranches = @(Invoke-GitCapture $repository @(
        'for-each-ref', '--format=%(refname:short)', 'refs/heads/'
    ))
    $missing = @($expectedBranches | Where-Object { $_ -notin $actualBranches })
    if ($missing.Count -gt 0) {
        throw "Missing expected branches: $($missing -join ', ')"
    }

    $roots = @(
        Invoke-GitCapture $repository (@('rev-list', '--max-parents=0') + $expectedBranches) |
            Sort-Object -Unique
    )
    if ($roots.Count -ne 1) {
        throw "Expected one shared root across migrated branches, but found $($roots.Count)."
    }

    foreach ($branch in $expectedBranches | Where-Object { $_ -ne 'main' }) {
        Invoke-Git $repository @('merge-base', '--is-ancestor', 'main', $branch)
    }
    Invoke-Git $repository @('fsck', '--full')
    Invoke-Git $repository @('status', '--short')
    Write-Host 'Proof-of-concept topology validation passed.'
}

function Invoke-Verify {
    param([Parameter(Mandatory)][hashtable]$Config)

    Write-Step 'Verifying every git-tfs remote against TFVC'
    Push-Location $Config.OutputRepository
    try {
        Invoke-Native $Config.GitTfsPath @('verify', '--all')
    }
    finally {
        Pop-Location
    }
}

function Invoke-Lfs {
    param([Parameter(Mandatory)][hashtable]$Config)

    $repository = $Config.OutputRepository
    if (-not (Test-Path -LiteralPath (Join-Path $repository '.git'))) {
        throw 'The git-tfs clone is missing. Run the Clone phase first.'
    }

    $threshold = "$($Config.LargeFileThresholdMB)MB"
    Write-Step "Reporting blobs at or above $threshold"
    Invoke-Git $repository @(
        'lfs', 'migrate', 'info', '--everything', "--above=$threshold"
    )

    Write-Step "Migrating blobs at or above $threshold to Git LFS"
    Invoke-Git $repository @('lfs', 'install', '--local')
    Invoke-Git $repository @(
        'lfs', 'migrate', 'import', '--everything', "--above=$threshold", '--yes'
    )
    Invoke-Git $repository @('lfs', 'fsck')
}

function Invoke-Push {
    param([Parameter(Mandatory)][hashtable]$Config)

    if ([string]::IsNullOrWhiteSpace($Config.DestinationUrl)) {
        throw 'Set DestinationUrl in git-tfs\migration-config.psd1 before running the Push phase.'
    }

    $repository = $Config.OutputRepository
    if (-not (Test-Path -LiteralPath (Join-Path $repository '.git'))) {
        throw 'The final Git repository is missing.'
    }

    $expectedBranches = @($Config.Branches.GitBranch)
    foreach ($branch in $expectedBranches) {
        Invoke-Git $repository @(
            'show-ref', '--verify', '--quiet', "refs/heads/$branch"
        )
    }

    $existingRefs = @(
        Invoke-NativeCapture 'git' @('ls-remote', $Config.DestinationUrl)
    )
    if ($existingRefs.Count -gt 0 -and -not $AllowNonEmptyDestination) {
        throw 'Destination contains refs. Use a new empty Azure Repos repository or explicitly pass -AllowNonEmptyDestination.'
    }

    $remotes = @(Invoke-GitCapture $repository @('remote'))
    if ('origin' -in $remotes) {
        Invoke-Git $repository @('remote', 'set-url', 'origin', $Config.DestinationUrl)
    }
    else {
        Invoke-Git $repository @('remote', 'add', 'origin', $Config.DestinationUrl)
    }

    Write-Step 'Pushing final branches'
    foreach ($branch in $expectedBranches) {
        Invoke-Git $repository @(
            'push', '--set-upstream', 'origin',
            "refs/heads/${branch}:refs/heads/${branch}"
        )
    }
    Invoke-Git $repository @('push', 'origin', '--tags')
    Invoke-Git $repository @('lfs', 'push', '--all', 'origin')
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Configuration file '$ConfigPath' was not found."
}
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
if (
    $config.ContainsKey('GitIgnorePath') -and
    -not [IO.Path]::IsPathRooted($config.GitIgnorePath)
) {
    $config.GitIgnorePath = [IO.Path]::GetFullPath(
        (Join-Path (Split-Path -Parent $ConfigPath) $config.GitIgnorePath)
    )
}

$originalTfsClient = [Environment]::GetEnvironmentVariable(
    'GIT_TFS_CLIENT',
    [EnvironmentVariableTarget]::Process
)
$originalRenameSources = @{}
try {
    if ($UseRenameRepair) {
        if (
            -not $config.ContainsKey('RenameRepairGitTfsPath') -or
            -not (Test-Path -LiteralPath $config.RenameRepairGitTfsPath -PathType Leaf) -or
            -not $config.ContainsKey('RenameSourceOverrides') -or
            $config.RenameSourceOverrides.Count -eq 0
        ) {
            throw 'The patched git-tfs executable and verified RenameSourceOverrides must be configured before using -UseRenameRepair.'
        }
        foreach ($key in $config.RenameSourceOverrides.Keys) {
            $mapping = $config.RenameSourceOverrides[$key]
            if (
                $key -notmatch '^\d+_\d+$' -or
                $mapping.Destination -notlike '$/*' -or
                $mapping.Source -notlike '$/*' -or
                $mapping.Destination.Contains('|') -or
                $mapping.Source.Contains('|')
            ) {
                throw "Invalid rename source override '$key'."
            }
            $environmentKey = "GIT_TFS_RENAME_SOURCE_$key"
            $originalRenameSources[$environmentKey] = [Environment]::GetEnvironmentVariable(
                $environmentKey, [EnvironmentVariableTarget]::Process
            )
            [Environment]::SetEnvironmentVariable(
                $environmentKey, "$($mapping.Destination)|$($mapping.Source)",
                [EnvironmentVariableTarget]::Process
            )
        }
        if ($config.ContainsKey('RenameBranchOverrides')) {
            foreach ($key in $config.RenameBranchOverrides.Keys) {
                $mapping = $config.RenameBranchOverrides[$key]
                if (
                    $key -notmatch '^\d+$' -or
                    $mapping.Destination -notlike '$/*' -or
                    $mapping.Source -notlike '$/*' -or
                    $mapping.Destination.Contains('|') -or
                    $mapping.Source.Contains('|') -or
                    $mapping.Destination.EndsWith('/') -or
                    $mapping.Source.EndsWith('/')
                ) {
                    throw "Invalid rename branch override '$key'."
                }
                $environmentKey = "GIT_TFS_RENAME_BRANCH_$key"
                $originalRenameSources[$environmentKey] = [Environment]::GetEnvironmentVariable(
                    $environmentKey, [EnvironmentVariableTarget]::Process
                )
                [Environment]::SetEnvironmentVariable(
                    $environmentKey, "$($mapping.Destination)|$($mapping.Source)",
                    [EnvironmentVariableTarget]::Process
                )
            }
        }
        $config.GitTfsPath = $config.RenameRepairGitTfsPath
        Write-Warning 'Using the locally patched git-tfs with explicitly configured, server-verified rename source overrides.'
    }
    if (
        $config.ContainsKey('TfsClientVersion') -and
        -not [string]::IsNullOrWhiteSpace($config.TfsClientVersion)
    ) {
        [Environment]::SetEnvironmentVariable(
            'GIT_TFS_CLIENT',
            $config.TfsClientVersion,
            [EnvironmentVariableTarget]::Process
        )
    }

    switch ($Phase) {
        'Preflight' { Invoke-Preflight $config }
        'Discover' { Invoke-Discover $config }
        'Clone' { Invoke-Clone $config }
        'Materialize' { Invoke-Materialize $config }
        'Validate' { Invoke-Validate $config }
        'Verify' { Invoke-Verify $config }
        'Lfs' { Invoke-Lfs $config }
        'Push' { Invoke-Push $config }
        'All' {
            Invoke-Discover $config
            Invoke-Clone $config
            Invoke-Materialize $config
            Invoke-Validate $config
        }
    }
}
finally {
    foreach ($environmentKey in $originalRenameSources.Keys) {
        [Environment]::SetEnvironmentVariable(
            $environmentKey, $originalRenameSources[$environmentKey],
            [EnvironmentVariableTarget]::Process
        )
        if ($null -eq $originalRenameSources[$environmentKey]) {
            Remove-Item -LiteralPath "Env:$environmentKey" -ErrorAction SilentlyContinue
        }
    }
    [Environment]::SetEnvironmentVariable(
        'GIT_TFS_CLIENT',
        $originalTfsClient,
        [EnvironmentVariableTarget]::Process
    )
    if ($null -eq $originalTfsClient) {
        Remove-Item Env:GIT_TFS_CLIENT -ErrorAction SilentlyContinue
    }
}
