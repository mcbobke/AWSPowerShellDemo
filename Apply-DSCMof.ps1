# TODO: Create needed S3 buckets for this

$dscAssociationArgs = @{
    AssociationName = "AWSPowerShellDemoDSC"
    Target = @(
        @{
            Key = 'InstanceIds'
            Values= @($newInstance.InstanceId)
        }
    )
    Name = 'AWS-ApplyDSCMofs'
    Parameter = @{
        MofsToApply = 's3:us-west-1:dsc-mofs:AWSPowerShellDemo.mof'
        ServicePath = 'awsdsc'
        MofOperationMode = 'Apply'
        ReportBucketName = 'us-west-1:dsc-reports'
        StatusBucketName = 'us-west-1:dsc-status'
        ModuleSourceBucketName = 'NONE'
        AllowPSGalleryModuleSource = 'True'
        ProxyUri = ''
        RebootBehavior = 'AfterMof'
        UseComputerNameForReporting = 'False'
        EnableVerboseLogging = 'True'
        EnableDebugLogging = 'True'
        ComplianceType = 'Custom:DSC'
        PreRebootScript = ''
    }
    ScheduleExpression = 'cron(0/10 * ? * * *)' # Every 10 minutes
}
$null = New-SSMAssociation @dscAssociationArgs