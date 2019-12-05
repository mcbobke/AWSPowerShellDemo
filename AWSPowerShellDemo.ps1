# You will see me use what are called 'splats' numerous times in this code in order to save space
# Read about these funky parameter-to-argument mappings here: https://sqldbawithabeard.com/2018/03/11/easily-splatting-powershell-with-vs-code/

#region Setup
# Uncomment and run the following cmdlet with your own values to store your AWS API credentials in a local encrypted store
# Set-AWSCredential -StoreAs 'MattBobkeAWS1' -AccessKey 'ACCESSKEY' -SecretKey 'SECRETKEY'

# This block loads your stored credentials and sets a default region for the rest of this script
$AWSProfileName = "MattBobkeAWS1"
try {
    Initialize-AWSDefaults -ProfileName $AWSProfileName -Region 'us-west-1' -ErrorAction 'Stop'
} catch {
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

$routeTable = Get-EC2RouteTable | Where-Object { $_.VpcId -eq $vpc.VpcId } | Select-Object -First 1

# Route all packets that are destined for 0.0.0.0/0 (the internet/not the local subnet) to the Internet Gateway
$routeArgs = @{
    RouteTableId         = $routeTable.RouteTableId
    GatewayId            = $internetGateway.InternetGatewayId
    DestinationCidrBlock = "0.0.0.0/0"
}
$route = New-EC2Route @routeArgs
#endregion Gateway/Routing

### Don't need to run this, a NetworkACL is automatically created with desired settings (all in/out allowed)
#region NetworkACL
$networkACL = New-EC2NetworkAcl -VpcId $vpc.VpcId

# Allow everything to come in to the VPC
$networkInboundAclEntryArgs = @{
    NetworkAclId = $networkACL.NetworkAclId
    CidrBlock    = '0.0.0.0/0'
    Protocol     = '-1'
    RuleAction   = 'allow'
    RuleNumber   = 100
    Egress       = $false
}
$networkInboundAclEntry = New-EC2NetworkAclEntry @networkInboundAclEntryArgs

# Allow everything to go out of the VPC
$networkOutboundAclEntryArgs = @{
    NetworkAclId = $networkACL.NetworkAclId
    CidrBlock    = '0.0.0.0/0'
    Protocol     = '-1'
    RuleAction   = 'allow'
    RuleNumber   = 100
    Egress       = $true
}
$networkOutboundAclEntry = New-EC2NetworkAclEntry @networkOutboundAclEntryArgs
#endregion NetworkACL

#region SecurityGroup
$securityGroup = Get-EC2SecurityGroup | Where-Object { $_.GroupName -eq 'default' } | Select-Object -First 1

# Allow HTTP in to EC2 instances with this subnet
$httpIpPermission = @{
    IpProtocol = 'tcp'
    FromPort   = '80'
    ToPort     = '80'
    IpRanges   = '0.0.0.0/0'
}

# Allow RDP in to EC2 instances with this subnet (DO NOT EVER DO THIS EXCEPT FOR TESTING)
$rdpIpPermission = @{
    IpProtocol = 'tcp'
    FromPort   = '3389'
    ToPort     = '3389'
    IpRanges   = '0.0.0.0/0'
}

# Allow ping replies from EC2 instances with this subnet
$icmpReplyPermission = @{
    IpProtocol = 'icmp'
    FromPort   = '0' # ICMP Type 0 - Echo Reply https://www.iana.org/assignments/icmp-parameters/icmp-parameters.xhtml#icmp-parameters-types
    ToPort     = '0' # ICMP Code 0 - No Code
    IpRanges   = '0.0.0.0/0'
}

# Allow ping requests from EC2 instances with this subnet
$icmpRequestPermission = @{
    IpProtocol = 'icmp'
    FromPort   = '8' # ICMP Type 0 - Echo Request https://www.iana.org/assignments/icmp-parameters/icmp-parameters.xhtml#icmp-parameters-types
    ToPort     = '0' # ICMP Code 0 - No Code
    IpRanges   = '0.0.0.0/0'
}

$sgIngress = Grant-EC2SecurityGroupIngress -GroupId $securityGroup.GroupId -IpPermission @( $httpIpPermission, $rdpIpPermission, $icmpReplyPermission, $icmpRequestPermission )
#endregion SecurityGroup

#region IAM
# The following JSON defines a policy document that allows EC2 instances to assume the AWS role that we are creating
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

### WAIT for about 30 seconds - IAM role/instance profile need to propagate

#region EBSVolume
# Using Amazon-provided .NET objects from the module's binaries, create an EBS Block Device that will be used as the boot/storage volume for our instance
# These .NET objects are implicitly loaded once a cmdlet from the module is called, or if you explicitly import the module
$ebsVolume = New-Object Amazon.EC2.Model.EbsBlockDevice
$ebsVolume.VolumeSize = 30
$ebsVolume.VolumeType = 'standard'
$ebsVolume.DeleteOnTermination = $true

# Create the drive mount mapping using Linux formatting to define where the previously created SSD volume will be mounted
# The first partition of the first mount point
$ebsVolumeDeviceMapping = New-Object Amazon.EC2.Model.BlockDeviceMapping
$ebsVolumeDeviceMapping.DeviceName = '/dev/sda1'
$ebsVolumeDeviceMapping.Ebs = $ebsVolume
#endregion EBSVolume

#region BuildInstance
# This PowerShell script will be run as SYSTEM on instance creation
# https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/ec2-windows-user-data.html
$userData = @"
<powershell>
New-Item -ItemType Directory -Path C:\ -Name AWSPowerShellDemo
New-Item -ItemType File -Path C:\AWSPowerShellDemo -Name index.html
Add-Content -Value '<body><h1>Hello World!</h1></body>' -Path C:\AWSPowerShellDemo\index.html -Encoding UTF8
</powershell>
"@

# Grab the base Windows Server 2019 machine image from Amazon (I got the ID from the AWS Console)
$ami = Get-EC2Image -ImageId 'ami-05f5b1fdbdbc92ec7'

# The KeyName parameter wants the name of an EC2 Key Pair that you've generated, here it is used to get the Admin password for the machine if you ever want to RDP to it
#       For Linux instances, it is used to connect via SSH with private key auth
# MinCount/MaxCount are for defining how many instances you wish to deploy with these settings - we only want 1
# EncodeUserData tells the AWS cmdlet that your userdata script is in plaintext and needs to be encoded to base64
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
    Region               = 'us-west-1'
    AssociatePublicIp    = $true
}

$newInstanceReservation = New-EC2Instance @instanceArgs
# New-EC2Instance returns a Reservation object with an Instances attribute that contains the details of the one (or more) instances that were launched
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
# Writes an encrypted key-value pair to the Systems Manager parameter store
Write-SSMParameter -Name 'WebsiteName' -Type SecureString -Value 'AWSPowerShellDemo'
#endregion ParameterStore

#region BuildMof
# Create an output directory for the MOF, clean it if it already exists
$desiredOutputPath = '.\output'
if (-not (Test-Path -Path $desiredOutputPath)) {
    New-Item -Path '.' -Name 'output' -ItemType Directory
} else {
    Get-ChildItem -Path $desiredOutputPath | Remove-Item -Force
}

# Execute the provided script that contains the DSC configuration, outputted to the previously created directory
# Rename the output MOF to the same base name as the script
$configurationScript = Get-Item -Path '.\AWSPowerShellDemoConfig.ps1'
$fullPathToScript = $configurationScript.FullName
$mofBuildOutput = & $fullPathToScript -OutputDir $desiredOutputPath
Rename-Item -Path $mofBuildOutput.FullName -NewName "$($configurationScript.BaseName).mof"

# Upload the MOF to the dsc-mofs bucket that we created
foreach ($mof in (Get-ChildItem -Path $desiredOutputPath)) {
    Write-S3Object -BucketName $mofBucket.BucketName -File $mof.FullName
}
#endregion BuildMof

#region ApplyMof
# Visit the following gist for where I got most of this example from Andrew Pearce
# https://gist.github.com/austoonz/14ad194db6e55dcee96bf97ea07adb45

# Visit the following guide from AWS that explains the usage of the AWS-ApplyDSCMofs document
# https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-state-manager-using-mof-file.html

# The Target block tells Systems Manager to target the specific instance that we created above (by its ID)
# The ServicePath in this case is an S3 bucket prefix where reports and status information will be written (a folder in the target bucket)
# The ComplianceType is used when reporting compliance information
#       If you create multiple associations that run MOFs, use a different compliance type for each - otherwise, compliance data will be overwritten
#       https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_PutComplianceItems.html
#       For example, for a webserver association: "Custom:WebServerDSC" and for a domain controller association: "Custom:DomainControllerDSC"
# For SSM Associations, the shortest cron rate expression possible is every 30 minutes (https://docs.aws.amazon.com/systems-manager/latest/userguide/reference-cron-and-rate-expressions.html)
$dscAssociationArgs = @{
    AssociationName               = "AWSPowerShellDemoDSC"
    Target                        = @(
        @{
            Key    = 'InstanceIds'
            Values = @($newInstance.InstanceId)
        }
    )
    Name                          = 'AWS-ApplyDSCMofs'
    Parameter                     = @{
        MofsToApply                 = 's3:us-west-1:dsc-mofs:AWSPowerShellDemoConfig.mof'
        ServicePath                 = 'awsdsc'
        MofOperationMode            = 'Apply'
        ReportBucketName            = 'us-west-1:dsc-reports'
        StatusBucketName            = 'us-west-1:dsc-status'
        ModuleSourceBucketName      = 'NONE'
        AllowPSGalleryModuleSource  = 'True'
        ProxyUri                    = ''
        RebootBehavior              = 'AfterMof'
        UseComputerNameForReporting = 'False'
        EnableVerboseLogging        = 'True'
        EnableDebugLogging          = 'True'
        ComplianceType              = 'Custom:DSC'
        PreRebootScript             = ''
    }
    ScheduleExpression            = 'cron(0/30 * ? * * *)' # Every 30 minutes
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