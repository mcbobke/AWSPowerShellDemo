#region Setup
$AWSProfileName = "MattBobkeAWS1"
try {
    Initialize-AWSDefaults -ProfileName $AWSProfileName -Region 'us-west-1' -ErrorAction 'Stop'
}
catch {
    $PSCmdlet.ThrowTerminatingError($_)
}
#endregion Setup

#region VPC/Subnet
$vpc = New-EC2Vpc -CidrBlock '10.0.0.0/16'
$subnet = New-EC2Subnet -CidrBlock "10.0.0.0/24" -VpcId $vpc.VpcID
#endregion VPC/Subnet

#region Gateway/Routing
$internetGateway = New-EC2InternetGateway
$null = Add-EC2InternetGateway -InternetGatewayId $internetGateway.InternetGatewayId -VpcId $vpc.VpcId

$routeTable = Get-EC2RouteTable | Where-Object {$_.VpcId -eq $vpc.VpcId} | Select-Object -First 1

$routeArgs = @{
    RouteTableId = $routeTable.RouteTableId
    GatewayId = $internetGateway.InternetGatewayId
    DestinationCidrBlock = "0.0.0.0/0"
}
$route = New-EC2Route @routeArgs
#endregion Gateway/Routing

### Don't need to run this, a NetworkACL is automatically created with desired settings
#region NetworkACL
$networkACL = New-EC2NetworkAcl -VpcId $vpc.VpcId

$networkInboundAclEntryArgs = @{
    NetworkAclId = $networkACL.NetworkAclId
    CidrBlock = '0.0.0.0/0'
    Protocol = '-1'
    RuleAction = 'allow'
    RuleNumber = 100
    Egress = $false
}
$networkInboundAclEntry = New-EC2NetworkAclEntry @networkInboundAclEntryArgs

$networkOutboundAclEntryArgs = @{
    NetworkAclId = $networkACL.NetworkAclId
    CidrBlock = '0.0.0.0/0'
    Protocol = '-1'
    RuleAction = 'allow'
    RuleNumber = 100
    Egress = $true
}
$networkOutboundAclEntry = New-EC2NetworkAclEntry @networkOutboundAclEntryArgs
#endregion NetworkACL

#region SecurityGroup
$securityGroup = Get-EC2SecurityGroup | Where-Object {$_.GroupName -eq 'default'} | Select-Object -First 1

$httpIpPermission = @{
    IpProtocol = 'tcp'
    FromPort = '80'
    ToPort = '80'
    IpRanges = '0.0.0.0/0'
}

$rdpIpPermission = @{
    IpProtocol = 'tcp'
    FromPort = '3389'
    ToPort = '3389'
    IpRanges = '0.0.0.0/0'
}

$icmpReplyPermission = @{
    IpProtocol = 'icmp'
    FromPort = '0' # ICMP Type 0 - Echo Reply https://www.iana.org/assignments/icmp-parameters/icmp-parameters.xhtml#icmp-parameters-types
    ToPort = '0' # ICMP Code 0 - No Code
    IpRanges = '0.0.0.0/0'
}

$icmpRequestPermission = @{
    IpProtocol = 'icmp'
    FromPort = '8' # ICMP Type 0 - Echo Request https://www.iana.org/assignments/icmp-parameters/icmp-parameters.xhtml#icmp-parameters-types
    ToPort = '0' # ICMP Code 0 - No Code
    IpRanges = '0.0.0.0/0'
}

$sgIngress = Grant-EC2SecurityGroupIngress -GroupId $securityGroup.GroupId -IpPermission @( $httpIpPermission, $rdpIpPermission, $icmpReplyPermission, $icmpRequestPermission )
#endregion SecurityGroup

#region IAM
$trustRelationshipJson = @"
{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "",
        "Effect": "Allow",
        "Principal": {
          "Service": "ec2.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }
"@
$iamRole = New-IAMRole -RoleName 'AWSPowerShellDemo' -AssumeRolePolicyDocument $trustRelationshipJson
Register-IAMRolePolicy -RoleName 'AWSPowerShellDemo' -PolicyArn 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore' # Core SSM functionality
Register-IAMRolePolicy -RoleName 'AWSPowerShellDemo' -PolicyArn 'arn:aws:iam::aws:policy/AmazonS3FullAccess' # S3 access for reading MOFs and writing output
Register-IAMRolePolicy -RoleName 'AWSPowerShellDemo' -PolicyArn 'arn:aws:iam::aws:policy/AmazonEC2FullAccess' # Gather instance details

# The instance profile must have the same name as the role
$instanceProfile = New-IAMInstanceProfile -InstanceProfileName 'AWSPowerShellDemo'
Add-IAMRoleToInstanceProfile -InstanceProfileName 'AWSPowerShellDemo' -RoleName 'AWSPowerShellDemo'
#endregion IAM

### WAIT - IAM role/instance profile need to propagate

#region EBSVolume
$ebsVolume = New-Object Amazon.EC2.Model.EbsBlockDevice
$ebsVolume.VolumeSize = 30
$ebsVolume.VolumeType = 'standard'
$ebsVolume.DeleteOnTermination = $true

$ebsVolumeDeviceMapping = New-Object Amazon.EC2.Model.BlockDeviceMapping
$ebsVolumeDeviceMapping.DeviceName = '/dev/sda1'
$ebsVolumeDeviceMapping.Ebs = $ebsVolume
#endregion EBSVolume

#region BuildInstance
$userData = @"
<powershell>
New-Item -ItemType Directory -Path C:\ -Name AWSPowerShellDemo
New-Item -ItemType File -Path C:\AWSPowerShellDemo -Name index.html
Add-Content -Value '<body><h1>Hello World!</h1></body>' -Path C:\AWSPowerShellDemo\index.html -Encoding UTF8
</powershell>
"@

$ami = Get-EC2Image -ImageId 'ami-05f5b1fdbdbc92ec7'

$instanceArgs = @{
    ImageId              = $ami.ImageId
    KeyName              = 'AWSPowerShellDemo'
    SecurityGroupID      = $securityGroup.GroupId
    InstanceType         = 't2.micro'
    InstanceProfile_Name = 'AWSPowerShellDemo'
    MinCount             = 1
    MaxCount             = 1
    SubnetId             = $subnet.SubnetId
    UserData             = $userData
    EncodeUserData       = $true
    BlockDeviceMapping   = @($ebsVolumeDeviceMapping)
    Region = 'us-west-1'
    AssociatePublicIp = $true
}

$newInstanceReservation = New-EC2Instance @instanceArgs
$newInstance = $newInstanceReservation.Instances[0]

Get-EC2Instance | Select-Object -ExpandProperty Instances | Select-Object -Property *
#endregion BuildInstance

#region S3Buckets
$mofBucket = New-S3Bucket -BucketName 'dsc-mofs'
$reportBucket = New-S3Bucket -BucketName 'dsc-reports'
$statusBucket = New-S3Bucket -BucketName 'dsc-status'
$outputBucket = New-S3Bucket -BucketName 'dsc-output'
#endregion S3Buckets

#region ParamterStore
Write-SSMParameter -Name 'WebsiteName' -Type SecureString -Value 'AWSPowerShellDemo'
#endregion ParameterStore

#region BuildMof
$desiredOutputPath = '.\output'
if (-not (Test-Path -Path $desiredOutputPath)) {
    New-Item -Path '.' -Name 'output' -ItemType Directory
}
else {
    Get-ChildItem -Path $desiredOutputPath | Remove-Item -Force
}

$configurationScript = Get-Item -Path '.\AWSPowerShellDemoConfig.ps1'
$fullPathToScript = $configurationScript.FullName
$mofBuildOutput = & $fullPathToScript -OutputDir $desiredOutputPath
Rename-Item -Path $mofBuildOutput.FullName -NewName "$($configurationScript.BaseName).mof"

foreach ($mof in (Get-ChildItem -Path $desiredOutputPath)) {
    Write-S3Object -BucketName $mofBucket.BucketName -File $mof.FullName
}
#endregion BuildMof

#region ApplyMof
# https://gist.github.com/austoonz/14ad194db6e55dcee96bf97ea07adb45
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
        MofsToApply = 's3:us-west-1:dsc-mofs:AWSPowerShellDemoConfig.mof'
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
    ScheduleExpression = 'cron(0/30 * ? * * *)' # Every 30 minutes
    S3Location_OutputS3BucketName = $outputBucket.BucketName
}

$ssmAssociation = New-SSMAssociation @dscAssociationArgs
#endregion ApplyMof

#region Cleanup
Remove-SSMAssociation -AssociationId $ssmAssociation.AssociationId -Force
Remove-SSMParameter -Name 'WebsiteName' -Force
Get-S3Bucket | Remove-S3Bucket -Force -DeleteBucketContent
Remove-EC2Instance -InstanceId $newInstance.InstanceId -Force
Remove-IAMRoleFromInstanceProfile -InstanceProfileName 'AWSPowerShellDemo' -RoleName 'AWSPowerShellDemo' -Force
Remove-IAMInstanceProfile -InstanceProfileName 'AWSPowerShellDemo' -Force
Unregister-IAMRolePolicy -PolicyArn 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore' -RoleName 'AWSPowerShellDemo' -Force
Unregister-IAMRolePolicy -PolicyArn 'arn:aws:iam::aws:policy/AmazonS3FullAccess' -RoleName 'AWSPowerShellDemo' -Force
Unregister-IAMRolePolicy -PolicyArn 'arn:aws:iam::aws:policy/AmazonEC2FullAccess' -RoleName 'AWSPowerShellDemo' -Force
Remove-IAMRole -RoleName 'AWSPowerShellDemo' -Force
# TODO: Remove VPC components, Security Group
#endregion Cleanup