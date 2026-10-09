# Branch-aware `git-tfs` migration

This folder is isolated from the original `git-tf` migration script. Use it first as a non-publishing proof of concept (POC). Promote it to the final migration only after every acceptance check passes.

`git-tfs` history migration is still expected to take a long time. Its important advantage for a clone that exceeds 30 hours is the `--resumable` option: rerun the same Clone phase after a failure to continue with the same parameters.

Parallel TFVC file downloads are disabled by default. Testing this repository with parallel downloads produced `TF400030` local-data-store lock failures inside PLINQ worker tasks. Keep `ParallelDownloads = $false` unless a separate test proves that the installed TFVC client can safely process this repository concurrently.

`TfsClientVersion` selects the installed TFVC client library through the
process-only `GIT_TFS_CLIENT` environment variable. The current POC uses the
2017 client because the 16.0 client repeatedly stopped returning after the
complete `C41562` workspace download. This setting does not omit files or
changesets and is cleared when the script exits.

Use `-UsePat` for a long-running clone so cached interactive authentication cannot pause for MFA. `git-tfs 0.34` natively reads `GIT_TFS_PAT`; the script securely prompts for the PAT, first validates it against the metadata-only TFVC Branches API, exposes it only in the current process environment while `git-tfs` runs, and clears it in `finally`. It is never placed in arguments, Git configuration, logs, or files. The script refuses persistent user- or machine-scoped `GIT_TFS_PAT` values.

## Ignoring checked-in dependency caches

`tfvc-migration.gitignore` contains migration-specific exclusions. Its initial
rule ignores a NuGet package cache named `PackagesFolder/packages` at any
directory depth, including:

```text
$/CWDS/Archive/DEV-R17.2/WebRoot/PackagesFolder/packages
```

Enable it only when starting a clean clone:

```powershell
.\Invoke-TfvcToGitTfsPoc.ps1 -Phase Clone -UsePat -UseGitIgnore
```

`git-tfs` commits the supplied file as `.gitignore` at the start of migrated
history and omits matching files from every imported changeset. Continue using
`-UseGitIgnore` on every retry of that clone. The script rejects adding it to a
partial clone that was originally started without it because changing file
filters midway would make the imported history inconsistent.

Do not use `-UseGitIgnore` to resume the current POC repository: that repository
already contains earlier changesets imported without the exclusion. Use it for
a new POC or the clean final migration only. Package manifests and application
source outside matching `PackagesFolder/packages` directories remain included.

## Before cloning

1. Download and install [`git-tfs`](https://github.com/git-tfs/git-tfs).
2. Put `git-tfs.exe` on `PATH`, or set `GitTfsPath` in `migration-config.psd1` to its full path.
3. Use a local SSD for `WorkRoot`, `OutputRepository`, and `WorkspacePath`; do not use a network share.
   Keep `WorkspacePath` close to the drive root. The default `C:\w` is intentional because the legacy TFVC client enforces a 259-character file-path limit even when Windows and Git long-path support are enabled.
4. Create a short-lived Azure DevOps PAT as described in [PAT authentication](#pat-authentication). Do not put it in this repository or configuration.
5. Run discovery:

   ```powershell
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Discover
   ```

Discovery must list the desired paths as real TFVC branches. Set `RootTfvcPath` to the top branch marked `[*]`, even if it is not one of the three final Git branches. `git-tfs` warns that cloning a child first prevents its parent from being initialized correctly later.

If the desired paths are ordinary folders rather than registered TFVC branches, stop using this POC. The existing `git-tf` script's exact-tree reconstruction is the safer approach for that layout.

## Targeted repair for the C41562 rename-history stall

Debugger stacks identified a blocked `QueryHistory` inside
`ChangeSieve.GetPathBeforeRename`, not a download of `WG.exe`. Visual Studio
confirmed that item `11797985`, `kiss.gif`, moved from `$/CWDS/apps/DEV-R17.3`
to `$/CWDS/Archive/DEV-R17.3` at C41562.

The configured overrides also cover item `11781593`,
`CWDS_OLTP/Programmability/Stored Procedures/Finance/dbo.USP_SEL_DUP_CONTRACT.proc.sql`.
Its source-side rename from the same apps branch was separately confirmed in
Visual Studio history at C41562. Configuration changes take effect only when
starting a new script invocation, not in an already running process.

`RenameBranchOverrides['41562']` also maps the entire destination branch
`$/CWDS/Archive/DEV-R17.3` to `$/CWDS/apps/DEV-R17.3`. For renamed files in
that changeset, the repair preserves the branch-relative path and verifies the
source file at C41561 before avoiding the history fallback. The destination
must match a complete directory prefix; similarly named branches do not match.
Existing item-specific overrides take precedence. No per-file configuration
is needed for other qualifying files in this branch move. Other changesets and
branches retain the original lookup behavior. This is not automatic discovery:
each additional branch move must have a separately confirmed source/destination
mapping before adding its changeset to `RenameBranchOverrides`.

The locally patched git-tfs 0.34 executable is installed separately at
`C:\work-temp\git-tfs-rename-repair-v2\git-tfs.exe`. The original installation is
unchanged. The source patch and regression tests are in
[git-tfs-rename-repair.patch](git-tfs-rename-repair.patch).

After detaching the debugger and stopping the old migration process, resume:

```powershell
.\Invoke-TfvcToGitTfsPoc.ps1 -Phase Clone -UsePat -UseRenameRepair
```

The flag selects `RenameRepairGitTfsPath` and supplies `RenameSourceOverrides`
through process-only environment variables, restoring their previous values
when the script exits. For the specified changeset/item only, if the ordinary
item-ID lookup returns no item, the patched executable retrieves the configured
source path at C41561. It requires an existing, undeleted file at that exact
source path before avoiding the fallback history query. A failed verification
throws an explicit error; no changeset or file is silently skipped.

All other rename lookups are unchanged. The log should show
`Verified rename source override` and then eventually a new C41562 Git commit.
The repair is not considered live-validated until the stalled branch advances;
another item may require separate investigation. Run the usual Validate and
Verify phases after the clone completes.

Do not add `-UseGitIgnore` to this existing partial clone. To move this repair
to another machine, also copy the patched installation and this configuration;
the source patch can be applied to a checkout of git-tfs tag `v0.34.0` and rebuilt.

## PAT authentication

Create the PAT from the `PA-EBR` Azure DevOps organization:

```text
https://dev.azure.com/PA-EBR/_usersSettings/tokens
```

Use the identity that already has TFVC Read access to `$/CWDS`. Give the PAT the shortest expiration that covers the Clone phase. **Code: Read** is sufficient for the metadata validator; testing with the legacy TFVC client may require a temporary **Full access** PAT for the history clone. Revoke it immediately after Clone completes.

First validate the PAT and branch access without cloning source:

```powershell
.\Test-TfvcBranchTopology.ps1
```

Paste the PAT at the hidden prompt. Then start or resume the clone with:

```powershell
.\Invoke-TfvcToGitTfsPoc.ps1 -Phase Clone -UsePat
```

Paste the PAT again at the hidden `Azure DevOps PAT` prompt. The script validates it against the TFVC Branches API before starting `git-tfs`. A rejected token fails immediately with a 401 explanation.

The script supplies an accepted token through the process-only `GIT_TFS_PAT` environment variable supported by `git-tfs 0.34`. It clears the variable when the process exits. Do not manually create a user- or machine-scoped `GIT_TFS_PAT`, and never put the PAT in:

- `migration-config.psd1`;
- a command argument such as `--password`;
- Git configuration;
- a remote URL;
- a checked-in or local script file.

Confirm PAT authentication in the log without exposing the token:

```powershell
Get-Content "$env:LOCALAPPDATA\git-tfs\git-tfs_log.txt" -Tail 30 -Wait
```

The log should contain:

```text
A GIT_TFS_PAT environment variable was detected.
PAT-based VSS Credentials created.
```

Press Ctrl+C only in the log-monitoring terminal to stop following the log.

## Validate Azure DevOps metadata without cloning

The metadata validator calls the Azure DevOps TFVC Branches REST API. It downloads no source files or changeset contents. It verifies that:

- all configured paths are registered TFVC branches;
- their complete parent chains lead to one root;
- `main` is an ancestor of both release branches;
- `RootTfvcPath` is the actual registered root required by `git-tfs`.
- every intermediate registered ancestor is included in the later clone.

Run:

```powershell
.\Test-TfvcBranchTopology.ps1
```

Enter a short-lived PAT with **Code: Read** when prompted. The PAT is read as a secure string and is not written to arguments, configuration, output, or disk. Revoke it after validation if it was created only for this test.

On success, the validator writes `tfvc-topology.json` under `WorkRoot`. It contains only branch paths, the validated root, and a timestamp—never the PAT. The Clone phase requires this file and uses its complete ancestor set to build the branch-ignore expression.

## POC run

The POC proves topology, completeness, resumability, elapsed time, and repository size. It must not push to the final Azure Repos repository.

1. Leave `DestinationUrl` empty.
2. Use the POC paths already configured under `C:\work-temp\cwds-git-tfs-poc`.
3. Validate the live TFVC topology:

   ```powershell
   .\Test-TfvcBranchTopology.ps1
   ```

4. Run each migration phase separately:

   ```powershell
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Preflight
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Discover
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Clone -UsePat
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Materialize
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Validate
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Verify
   ```

The Clone phase uses:

```text
git-tfs clone --branches=all --resumable --workspace=C:\w --no-parallel --ignore-branches-regex=...
```

The generated ignore expression limits branch initialization to the validated root, every intermediate ancestor, and the configured final branches. If cloning is interrupted, rerun the identical Clone command:

```powershell
.\Invoke-TfvcToGitTfsPoc.ps1 -Phase Clone -UsePat
```

Do not delete or move the partial `OutputRepository`; it contains the resumable state.

### Restart after changing clone parameters

The script writes both `git-tfs.workspace-dir` and `tfs-remote.*.noparallel=true` into an existing resumable repository before every clone attempt. This is required because `git-tfs --resumable` skips initialization when reopening an existing repository and otherwise may retain parallel access. After a `TF400030` failure, confirm no `git-tfs.exe` process remains and rerun:

```powershell
.\Invoke-TfvcToGitTfsPoc.ps1 -Phase Clone -UsePat
```

The retry uses `--no-parallel`, persists that setting on every existing git-tfs remote, recreates the configured short workspace, selects the configured TFVC client library, and prompts for the PAT. Do not delete `OutputRepository` when retrying. Delete and restart only if `git-tfs` reports that the existing repository is not resumable or validation later shows inconsistent history.

The POC retry after the repeatable `C41562` stall uses `C:\w2` rather than
reusing `C:\w`. Preserve `C:\w` until the migration is validated; it contains
the prior workspace snapshot, but it is no longer used by the retry.

Before invoking `git-tfs`, a retry detaches `HEAD` at the imported remote for
`RootTfvcPath`. This is required when an interrupted branch initialization
leaves the repository on an unborn local branch; otherwise `git-tfs` reports
`no tfs remote to use found in parent commits`. The retry does not delete or
rewind any imported `tfs/*` refs.

`git tfs verify --all` downloads branch-tip content again and can therefore take substantial time. It is required before accepting the POC.

5. Record the duration, final repository size, imported commit counts, branch tips, and any warnings.
6. Build or otherwise test all three final branches.
7. Do not run `Lfs` or `Push` during the POC. Preserve the POC directory until the results have been reviewed.

The `All` phase is non-publishing. It runs Discover through Validate, but deliberately excludes Verify, Lfs, and Push.

## Acceptance criteria

- Discovery shows the actual TFVC parent-child hierarchy.
- All three configured TFVC paths are represented by exactly one `git-tfs` remote.
- The final local branches are `main`, `DEV-R20.1`, and `DEV-R20.2`.
- All final branches have one shared Git root.
- `main` is an ancestor of both release branches.
- `git fsck --full` passes.
- `git tfs verify --all` passes before this approach replaces the existing migration workflow.

## Final migration run

Run the final migration only after the POC is accepted:

1. Announce the cutover window and prevent new check-ins to the three TFVC branches.
2. Create a new empty Azure Repos Git repository. Do not initialize it with a README or other files.
3. Change `WorkRoot`, `OutputRepository`, and `WorkspacePath` in `migration-config.psd1` to fresh final-migration paths. Keep the final workspace close to the drive root, such as `C:\f`, and do not reuse the POC directories.
4. Keep `DestinationUrl` empty while importing and validating.
5. Generate a new topology manifest against the frozen TFVC repository:

   ```powershell
   .\Test-TfvcBranchTopology.ps1
   ```

6. Perform a clean final import:

   ```powershell
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Preflight
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Discover
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Clone -UsePat
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Materialize
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Validate
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Verify
   ```

7. Convert blobs at or above `LargeFileThresholdMB` to Git LFS, then validate the rewritten repository:

   ```powershell
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Lfs
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Validate
   ```

   Run Verify before Lfs because Lfs rewrites commit IDs. Do not use `git-tfs` to fetch more TFVC changes after the Lfs phase.

8. Set `DestinationUrl` in `migration-config.psd1` to the empty Azure Repos Git clone URL.
9. Push exactly the configured final branches, tags, and all LFS objects:

   ```powershell
   .\Invoke-TfvcToGitTfsPoc.ps1 -Phase Push
   ```

   Push refuses any destination containing refs. `-AllowNonEmptyDestination` is available for an explicitly approved exception, but a new empty repository is strongly preferred.

10. In Azure Repos, set `main` as the default branch and apply branch policies and permissions.
11. Clone the destination into a new directory, run `git fsck --full` and `git lfs fsck`, and build/test all three branches.
12. Revoke the temporary Clone PAT, keep TFVC read-only, and retain the final local migration data until the agreed verification and rollback period ends.
