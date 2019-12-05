[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [String]
    $OutputDir
)

#region Configuration
Configuration AWSPowerShellDemoConfig {
    #region Setup
    # AWS-ApplyDSCMofs will install these modules on your target machines automatically when it parses the MOF
    Import-DscResource -ModuleName xWebAdministration, PSDesiredStateConfiguration, NetworkingDsc, ComputerManagementDsc
    #endregion Setup

    #region Node
    Node 'localhost' {
        #region Execution Policy
        PowerShellExecutionPolicy 'PSExecutionPolicy' {
            ExecutionPolicyScope = 'LocalMachine'
            ExecutionPolicy      = 'Bypass'
        }
        #endregion Execution Policy

        #region Firewall
        Firewall 'ICMPv4-InFirewallRule' {
            Name        = 'FPS-ICMP4-ERQ-In'
            DisplayName = 'File and Printer Sharing (Echo Request - ICMPv4-In)'
            Enabled     = 'True'
            Profile     = @('Domain', 'Private', 'Public')
            Action      = 'Allow'
            Ensure      = 'Present'
        }
        #endregion Firewall

        #region TimeZone
        TimeZone 'PSTTimeZone' {
            IsSingleInstance = 'Yes'
            TimeZone         = 'Pacific Standard Time'
        }
        #endregion TimeZone

        #region Windows Features
        WindowsFeatureSet 'WindowsFeaturesEnabled' {
            Name   = @(
                'Web-Server'
                'Web-WebServer'
                'Web-Common-Http'
                'Web-Default-Doc'
                'Web-Static-Content'
                'Web-Http-Redirect'
                'Web-Health'
                'Web-Http-Logging'
                'Web-Http-Tracing'
                'Web-Performance'
                'Web-Stat-Compression'
                'Web-Security'
                'Web-Filtering'
                'Web-Basic-Auth'
                'Web-Mgmt-Tools'
                'Web-Mgmt-Console'
                'Web-Mgmt-Service'
                'PowerShellRoot'
                'PowerShell'
            )
            Ensure = 'Present'
        }
        #endregion Windows Features

        #region AppPools
        xWebAppPool 'RemoveNetv45Pool' {
            Name   = '.NET v4.5'
            Ensure = 'Absent'
        }

        xWebAppPool 'RemoveNetv45ClassicPool' {
            Name   = '.NET v4.5 Classic'
            Ensure = 'Absent'
        }

        xWebAppPool 'RemoveDefaultPool' {
            Name   = 'DefaultAppPool'
            Ensure = 'Absent'
        }

        xWebAppPool 'AWSPowerShellDemoAppPool' {
            Name                  = 'AWSPowerShellDemo'
            Ensure                = 'Present'
            autoStart             = $true
            managedRuntimeVersion = 'v4.0'
            managedPipelineMode   = 'Integrated'
        }
        #endregion AppPools

        #region Websites
        xWebsite 'DefaultSite' {
            Ensure = 'Absent'
            Name   = 'Default Web Site'
        }
        
        xWebsite 'AWSPowerShellDemoWebsite' {
            Name             = '{tagssm:WebsiteName}' # This is the token that will be replaced with the value of the encrypted string that we put in Parameter Store
            Ensure           = 'Present'
            SiteId           = 1
            PhysicalPath     = 'C:\AWSPowerShellDemo'
            ApplicationPool  = 'AWSPowerShellDemo'
            State            = 'Started'
            PreloadEnabled   = $false
            EnabledProtocols = 'http'
            DefaultPage      = 'index.html'
            BindingInfo      = @(
                MSFT_xWebBindingInformation {
                    Protocol  = 'http'
                    IPAddress = '*'
                    Port      = 80
                }
            )
        }
        #endregion Websites
    }
    #endregion Node
}
#endregion Configuration

AWSPowerShellDemoConfig -OutputPath $OutputDir