# Selective TFVC-to-Git migration

## Recommendation

Use `git-tf` to deep-clone only the four required TFVC paths into separate local repositories, assemble them into one Git repository, reconstruct proven branch ancestry, convert oversized historical blobs to Git LFS, validate, and push to a new empty Azure Repos Git repository.

This avoids the Azure DevOps automatic TFVC import and does not migrate unrelated TFVC branches.

## Resulting branches

| TFVC path | Git branch |
|---|---|
| `$/CWDS/apps/DEV-R19.5` | `main` |
| `$/CWDS/apps/DEV-R20.1` | `DEV-R20.1` |
| `$/CWDS/apps/DEV-R20.1.5` | `DEV-R20.1.5` |
| `$/CWDS/apps/DEV-R20.2` | `DEV-R20.2` |

Change the Git branch names in `migration-config.psd1` if a different convention is desired.

## Why the branches are not simply fetched together

`git-tf clone --deep` creates one Git history for one TFVC path. Four independent clones therefore have four unrelated root commits even when the TFVC folders were created as branches.

The assembly phase handles this conservatively:

1. It imports each release history without importing conflicting `TFS_C*` tags.
2. It reads the TFVC changeset number from the `TFS_C*` tags created by `git-tf --tag`.
3. It finds an earlier commit on an already-connected branch whose complete tree exactly matches the imported branch's initial tree.
4. It recreates the imported root with that proven parent and rebases the remaining commits.
5. It stops if no exact tree match exists. It never guesses ancestry.

Process branches oldest to newest in `migration-config.psd1`. This allows, for example, `DEV-R20.1.5` to match a branch point on `DEV-R20.1` if that is its actual TFVC lineage. Every resulting branch remains descended from `main`.

## Prerequisites

- 64-bit Git for Windows.
- Git LFS.
- A Java runtime installed. The script refreshes its process `PATH` from the current machine and user environment variables before checking Java, which handles terminals opened before Java was installed.
- TFVC read permission for all four paths and their histories.
- Enough local free space for four TFVC clones, the assembled repository, rewrite temporary space, and working trees. Plan for at least three times the estimated source size, preferably more.
- A new empty Azure Repos Git repository.
- A stable machine and network connection. Deep clones can take many hours.

The installed `git-tf` launcher is configured in `migration-config.psd1` as `C:\work-temp\gittf\git-tf.cmd`.

## Runbook

Run from a 64-bit PowerShell prompt:

```powershell
Set-Location C:\Users\thordill\source\repos\CWDS-Git

.\Invoke-TfvcToGitMigration.ps1 -Phase Preflight
.\Invoke-TfvcToGitMigration.ps1 -Phase Clone
.\Invoke-TfvcToGitMigration.ps1 -Phase Assemble
.\Invoke-TfvcToGitMigration.ps1 -Phase Lfs
.\Invoke-TfvcToGitMigration.ps1 -Phase Validate
```

Each source clone is kept under `WorkRoot`. A completion marker is written only after a clone has valid TFVC metadata. The Clone phase skips repositories with that marker, so a later failure does not repeat earlier clones and an interrupted clone is never mistaken for a completed one. Use `-ForceReclone` only when an incomplete clone must be discarded and recreated.

After validation:

1. Create a new empty Git repository in Azure DevOps. Do not initialize it with a README.
2. Put its clone URL in `DestinationUrl` in `migration-config.psd1`.
3. Run:

```powershell
.\Invoke-TfvcToGitMigration.ps1 -Phase Push
```

Branches are pushed separately. Git LFS objects are pushed explicitly after the branches.

## Large-file handling

Azure Repos recommends files no larger than 100 MB and limits a command-line push to 5 GB of normal Git objects. The script uses a 95-MB safety threshold:

```powershell
git lfs migrate import --everything --above=95MB
```

Run this only after all branches are assembled. It rewrites commits across every branch and tag, so all commit IDs change. Do not publish or base new work on the temporary repository before this phase is complete.

Git LFS solves oversized-blob problems, but it is not a substitute for removing generated outputs, installers, database backups, and dependency caches. Review the `git lfs migrate info` output before accepting the migration. If those files should not be versioned at all, stop and define a history-cleaning policy before the LFS phase.

## Cutover

1. Announce a TFVC freeze window.
2. Complete a rehearsal migration and record total duration, repository size, LFS size, and any authentication prompts.
3. At the start of final cutover, prevent TFVC check-ins to the four paths.
4. Remove the rehearsal `WorkRoot` or point `WorkRoot` and `OutputRepository` to a fresh final location.
5. Repeat Clone through Validate.
6. Push to the empty destination.
7. Set `main` as the Azure Repos default branch.
8. Apply branch policies and permissions.
9. Have owners compare branch tips and build each supported release.
10. Keep TFVC read-only for an agreed retention period.

## Acceptance checks

- Exactly the four requested local branches exist.
- All release branches have `main` as an ancestor.
- Every assembled branch tip matched its source clone before the LFS rewrite.
- `git fsck --full` and `git lfs fsck` pass.
- No blob above the configured threshold remains outside LFS.
- Azure DevOps shows all branches and LFS files can be checked out on a clean test clone.
- The application builds from each supported branch.

## Important limitations

- Git commit IDs cannot match TFVC changeset IDs. Namespaced tags such as `tfvc/main/TFS_C12345` retain TFVC changeset traceability without collisions between independently cloned branches.
- TFVC branch/merge relationships are not represented automatically by independent `git-tf` clones. The script reconstructs only ancestry proven by identical trees.
- TFVC labels, shelvesets, gated builds, permissions, and branch policies require separate decisions; this workflow migrates source history.
- If a branch's initial tree has no exact match, investigate its true TFVC parent or changes made during branching. Do not use an arbitrary Git parent merely to force a connected graph.

## References

- [Import and migrate repositories from TFVC to Git](https://learn.microsoft.com/azure/devops/repos/git/import-from-tfvc)
- [Git limits in Azure Repos](https://learn.microsoft.com/azure/devops/repos/git/limits)
- [Manage large files in Git](https://learn.microsoft.com/azure/devops/repos/git/manage-large-files)
