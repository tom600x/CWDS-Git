@{
    CollectionUrl        = 'https://dev.azure.com/PA-EBR/'
    ProjectName          = 'CWDS'
    GitTfsPath           = 'C:\work-temp\git-tfs\git-tfs.exe'
    RenameRepairGitTfsPath = 'C:\work-temp\git-tfs-rename-repair-v2\git-tfs.exe'
    RenameSourceOverrides = @{
        '41562_11781593' = @{
            Destination = '$/CWDS/Archive/DEV-R17.3/CWDS_OLTP/Programmability/Stored Procedures/Finance/dbo.USP_SEL_DUP_CONTRACT.proc.sql'
            Source = '$/CWDS/apps/DEV-R17.3/CWDS_OLTP/Programmability/Stored Procedures/Finance/dbo.USP_SEL_DUP_CONTRACT.proc.sql'
        }
        '41562_11797985' = @{
            Destination = '$/CWDS/Archive/DEV-R17.3/WebRoot/CWDSOnline/JavaScript/ckeditor/plugins/smiley/images/kiss.gif'
            Source = '$/CWDS/apps/DEV-R17.3/WebRoot/CWDSOnline/JavaScript/ckeditor/plugins/smiley/images/kiss.gif'
        }
    }
    RenameBranchOverrides = @{
        '41562' = @{
            Destination = '$/CWDS/Archive/DEV-R17.3'
            Source = '$/CWDS/apps/DEV-R17.3'
        }
    }
    TfsClientVersion     = '2017'
    GitIgnorePath        = 'tfvc-migration.gitignore'
    WorkRoot             = 'C:\work-temp\cwds-git-tfs-poc'
    OutputRepository     = 'C:\work-temp\cwds-git-tfs-poc\CWDS-Git'
    WorkspacePath        = 'C:\w2'
    ParallelDownloads    = $false
    DestinationUrl       = ''
    LargeFileThresholdMB = 95

    # Confirmed by the TFVC Branches REST API.
    RootTfvcPath         = '$/CWDS/Archive/DEV-R17.1'

    Branches = @(
        @{
            TfvcPath = '$/CWDS/apps/DEV-R19.5'
            GitBranch = 'main'
        }
        @{
            TfvcPath = '$/CWDS/apps/DEV-R20.1'
            GitBranch = 'DEV-R20.1'
        }
        @{
            TfvcPath = '$/CWDS/apps/DEV-R20.2'
            GitBranch = 'DEV-R20.2'
        }
    )
}
