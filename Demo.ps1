$AWSProfileName = "MattBobkeAWS1"

#region Setup
try {
    Initialize-AWSDefaults -ProfileName $AWSProfileName -Region 'us-west-1' -ErrorAction 'Stop'
}
catch {
    $PSCmdlet.ThrowTerminatingError($_)
}
#endregion Setup

#region VPC

$vpc = New-EC2Vpc -CidrBlock '10.0.0.0/16'

#endregion VPC

#region Subnet

$subnet = New-EC2Subnet -CidrBlock "10.0.0.0/24" -VpcId $vpc.VpcID

#endregion Subnet

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

$sgIngress = Grant-EC2SecurityGroupIngress -GroupId $securityGroup.GroupId -IpPermission @( $httpIpPermission, $rdpIpPermission )

#endregion SecurityGroup