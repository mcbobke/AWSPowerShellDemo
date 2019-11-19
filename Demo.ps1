$AWSProfileName = "MattBobkeAWS1"

#region Setup
try {
    Initialize-AWSDefaults -ProfileName $AWSProfileName -Region 'us-west-2' -ErrorAction 'Stop'
}
catch {
    $PSCmdlet.ThrowTerminatingError($_)
}
#endregion Setup