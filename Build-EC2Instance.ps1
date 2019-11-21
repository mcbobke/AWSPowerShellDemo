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
Register-IAMRolePolicy -RoleName 'AWSPowerShellDemo' -PolicyArn 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'

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

#region Build
# TODO: Create website file in UserData script
$userData = @"
<powershell>
Set-TimeZone -Name "Pacific Standard Time"
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
#endregion Build