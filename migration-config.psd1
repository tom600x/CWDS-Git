@{
    CollectionUrl       = 'https://dev.azure.com/PA-EBR/'
    GitTfPath           = 'C:\work-temp\gittf\git-tf.cmd'
    WorkRoot            = 'C:\work-temp\cwds-tfvc-migration'
    OutputRepository    = 'C:\work-temp\cwds-tfvc-migration\CWDS-Git'
    DestinationUrl      = ''
    LargeFileThresholdMB = 95

    Main = @{
        TfvcPath = '$/CWDS/apps/DEV-R19.5'
        GitBranch = 'main'
    }

    Branches = @(
        @{
            TfvcPath = '$/CWDS/apps/DEV-R20.1'
            GitBranch = 'DEV-R20.1'
        }
        @{
            TfvcPath = '$/CWDS/apps/DEV-R20.1.5'
            GitBranch = 'DEV-R20.1.5'
        }
        @{
            TfvcPath = '$/CWDS/apps/DEV-R20.2'
            GitBranch = 'DEV-R20.2'
        }
    )
}
