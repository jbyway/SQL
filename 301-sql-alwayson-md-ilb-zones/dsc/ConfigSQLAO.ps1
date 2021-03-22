#
# Copyright="© Microsoft Corporation. All rights reserved."
#

configuration ConfigSQLAO
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$SQLServiceCreds,

        [Parameter(Mandatory)]
        [String]$ClusterName,

        [Parameter(Mandatory)]
        [String]$SQLUNCPath,

        [String]$SQLInstallFiles = "C:\SQLInstall\",

        [Parameter(Mandatory)]
        [String]$vmNamePrefix,

        [Parameter(Mandatory)]
        [Int]$vmCount,

        [Parameter(Mandatory)]
        [String]$SqlAlwaysOnAvailabilityGroupName,

        [Parameter(Mandatory)]
        [String]$SqlAlwaysOnAvailabilityGroupListenerName,

        [Parameter(Mandatory)]
        [String]$ClusterIpAddresses,

        [Parameter(Mandatory)]
        [String]$AGListenerIpAddress,

        [Parameter(Mandatory)]
        [String]$SqlAlwaysOnEndpointName,

        [Parameter(Mandatory)]
        [String]$witnessStorageName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$witnessStorageKey,

        [UInt32]$DatabaseEnginePort = 1433,

        [UInt32]$DatabaseMirrorPort = 5022,

        [UInt32]$ProbePortNumber = 59999,

        [String]$DomainNetbiosName = (Get-NetBIOSName -DomainName $DomainName),

        [Parameter()]
        [string]$ClusterNetworkObject,

        [Parameter()]
        [array]$SQLDataLun,

        [Parameter()]
        [array]$SQLLogLun,

        [Parameter()]
        [array]$SQLTempdbLun,

        [Parameter()]
        [string]$OUPath,

        [string]$SQLTempdbDriveLetter = "F",
        [string]$SQLDataDriveLetter = "G",
        [string]$SQLLogDriveLetter = "H",

        [Parameter(Mandatory)]
        [String]$WorkloadType,

        [Int]$NumberOfColumns = 2,
        [Int]$RetryCount = 20,
        [Int]$RetryIntervalSec = 30

    )

    Import-DscResource -ModuleName xComputerManagement, CDisk, xActiveDirectory, xDisk, SqlServerDsc, xNetworking, xSql, xFailOverCluster
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$DomainFQDNCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$SQLCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($SQLServicecreds.UserName)", $SQLServicecreds.Password)
    [System.Management.Automation.PSCredential]$DomainCredsUPN = New-Object System.Management.Automation.PSCredential ("$($Admincreds.UserName)@${DomainName}", $Admincreds.Password)

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    Enable-CredSSPNTLM -DomainName $DomainName
    
    [string]$OptimizationType = $WorkloadType
    $SQLInstance = "SQL001"
    $SqlCollation = "Latin1_General_CI_AS"

    $RebootVirtualMachine = $false

    if ($DomainName) {
        $RebootVirtualMachine = $true
    }

    #Finding the next avaiable disk letter for Add disk
    $NewDiskLetter = ls function:[f-z]: -n | ? { !(test-path $_) } | select -First 1 
    $NextAvailableDiskLetter = $NewDiskLetter[0]

    [System.Collections.ArrayList]$Nodes = @()
    For ($count = 0; $count -lt $vmCount; $count++) {
        $Nodes.Add($vmNamePrefix + $Count.ToString())
    }

    $PrimaryReplica = $Nodes[0]
    
    WaitForSqlSetup

    Node localhost
    {
        xSqlCreateVirtualTempdbDisk TempdbDrive {
            NumberOfDisks    = $SQLTempdbLun.Count
            StartingDeviceID = ($SQLTempdbLun[0].lun + 2)
            DiskLetter       = $SQLTempdbDriveLetter
            OptimizationType = $OptimizationType
            NumberOfColumns  = $NumberOfColumns

        }

        xSqlCreateVirtualDataDisk DataDrive {
            NumberOfDisks    = $SQLDataLun.Count
            StartingDeviceID = ($SQLDataLun[0].lun + 2)
            DiskLetter       = $SQLDataDriveLetter
            OptimizationType = $OptimizationType
            NumberOfColumns  = $NumberOfColumns
            DependsOn        = '[xSqlCreateVirtualTempdbDisk]TempdbDrive'
        }

        xSqlCreateVirtualLogDisk LogDrive {
            NumberOfDisks    = $SQLLogLun.Count
            StartingDeviceID = ($SQLLogLun[0].lun + 2)
            DiskLetter       = $SQLLogDriveLetter
            OptimizationType = $OptimizationType
            NumberOfColumns  = $NumberOfColumns
            DependsOn        = '[xSqlCreateVirtualDataDisk]DataDrive'
        }

        File InstallationFolder {
            Ensure          = 'Present'
            Type            = 'Directory'
            SourcePath      = $SQLUNCPath
            DestinationPath = $SQLInstallFiles
            Recurse         = $true
            DependsOn       = '[xSqlCreateVirtualLogDisk]LogDrive'
        }

        WindowsFeature FC {
            Name      = "Failover-Clustering"
            Ensure    = "Present"
            DependsOn = '[File]InstallationFolder'
        }

        WindowsFeature FailoverClusterTools { 
            Ensure    = "Present" 
            Name      = "RSAT-Clustering-Mgmt"
            DependsOn = "[WindowsFeature]FC"
        } 

        WindowsFeature FCPS {
            Name      = "RSAT-Clustering-PowerShell"
            Ensure    = "Present"
            DependsOn = "[WindowsFeature]FC"
        }

        WindowsFeature ADPS {
            Name   = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }

        Script SqlServerPowerShell {
            SetScript  = '[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; Install-PackageProvider -Name NuGet -Force; Install-Module -Name SqlServer -AllowClobber -Force; Import-Module -Name SqlServer -ErrorAction SilentlyContinue'
            TestScript = 'Import-Module -Name SqlServer -ErrorAction SilentlyContinue; if (Get-Module -Name SqlServer) { $True } else { $False }'
            GetScript  = 'Import-Module -Name SqlServer -ErrorAction SilentlyContinue; @{Ensure = if (Get-Module -Name SqlServer) {"Present"} else {"Absent"}}'
            DependsOn  = '[xSqlCreateVirtualLogDisk]LogDrive'
        }

        WindowsFeature 'NetFramework45' {
            Name   = 'NET-Framework-45-Core'
            Ensure = 'Present'
        }

        

        SqlSetup 'InstallNamedInstance'
        {
            InstanceName          = $SqlInstance
            Features              = 'SQLENGINE'
            SQLCollation          = $SqlCollation
            SQLSvcAccount         = $SQLCreds
            AgtSvcAccount         = $SqlAgentServiceCredential
            ASSvcAccount          = $SqlServiceCredential
            SQLSysAdminAccounts   = $SQLServiceCreds.UserName, $DomainCredsUPN.UserName
            #ASSysAdminAccounts    = 'COMPANY\SQL Administrators', $SqlAdministratorCredential.UserName
            InstallSharedDir      = 'C:\Program Files\Microsoft SQL Server'
            InstallSharedWOWDir   = 'C:\Program Files (x86)\Microsoft SQL Server'
            InstanceDir           = 'C:\Program Files\Microsoft SQL Server'
            InstallSQLDataDir     = $SQLDataDriveLetter + ':\' + $SqlInstance + '_Data'
            SQLUserDBDir          = $SQLDataDriveLetter + ':\' + $SqlInstance + '_Data'
            SQLUserDBLogDir       = $SQLLogDriveLetter + ':\' + $SqlInstance + '_Logs'
            SQLTempDBDir          = $SQLTempdbDriveLetter + ':\' + $SqlInstance + '_Tempdb_Data'
            SQLTempDBLogDir       = $SQLTempdbDriveLetter + ':\' + $SqlInstance + '_Tempdb_Logs'
            SQLBackupDir          = $SQLDataDriveLetter + ':\' + $SqlInstance + '_Backup'
            #ASConfigDir           = 'C:\MSOLAP13.INST2016\Config'
            #ASDataDir             = 'C:\MSOLAP13.INST2016\Data'
            #ASLogDir              = 'C:\MSOLAP13.INST2016\Log'
            #ASBackupDir           = 'C:\MSOLAP13.INST2016\Backup'
            #ASTempDir             = 'C:\MSOLAP13.INST2016\Temp'
            SourcePath            = $SQLUNCPath
            SourceCredential      = $DomainCredsUPN
            UpdateEnabled         = 'False'
            ForceReboot           = $false
            BrowserSvcStartupType = 'Automatic'

            PsDscRunAsCredential  = $DomainCredsUPN

            DependsOn             = '[Script]SqlServerPowerShell', '[WindowsFeature]NetFramework45'
        }

       
        SqlWindowsFirewall 'Create_Firewall_Rules' {
            Ensure = 'Present'
            Features = 'SQLENGINE'
            InstanceName = $SqlInstance

            SourcePath = $SQLInstallFiles

            PsDscRunAsCredential = $DomainCredsUPN
            DependsOn = '[SqlSetup]InstallNamedInstance'
        }

        SqlAlwaysonService 'EnableAlwaysOn' {
            Ensure               = 'Present'
            ServerName           = $env:COMPUTERNAME
            InstanceName         = $SQLInstance
            RestartTimeout       = 120

            PsDscRunAsCredential = $SQLCreds

            DependsOn = '[SqlSetup]InstallNamedInstance'
        }

        xCluster FailoverCluster
        {
            Name                          = $ClusterName
            DomainAdministratorCredential = $DomainCreds
            PsDscRunAsCredential          = $DomainCredsUPN
            Nodes                         = $Nodes
            ClusterIPAddresses            = $ClusterIpAddresses
            DependsOn                     = "[WindowsFeature]FCPS"
        }

        Script CloudWitness {
            SetScript  = "Set-ClusterQuorum -CloudWitness -AccountName ${witnessStorageName} -AccessKey $($witnessStorageKey.GetNetworkCredential().Password)"
            TestScript = "(Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness'"
            GetScript  = "@{Ensure = if ((Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness') {'Present'} else {'Absent'}}"
            DependsOn  = "[xCluster]FailoverCluster"
        }

        SqlAG 'AddAG' 
        {
            Ensure                  = 'Present'
            Name                    = $SqlAlwaysOnAvailabilityGroupName
            InstanceName            = $SqlInstance
            ServerName              = $env:COMPUTERNAME
            ProcessOnlyOnActiveNode = $true

            BasicAvailabilityGroup  = $false
            DatabaseHealthTrigger   = $true
            DtcSupportEnabled       = $true

            AvailabilityMode        = 'SynchronousCommit'
            ConnectionModeInPrimaryRole = 'AllowAllConnections'
            ConnectionModeInSecondaryRole   = 'AllowNoConnections'
            FailoverMode            = 'Automatic'
            HealthCheckTimeout      = 15000
            AutomatedBackupPreference   = 'Primary'

            DependsOn               = '[Script]CloudWitness'

        }
      
       
           
        SqlAGListener 'AvailabilityGroupListenerWithDifferentNameAsVCO'
        {
            Ensure               = 'Present'
            ServerName           = $env:COMPUTERNAME
            InstanceName         = $SQLInstance
            AvailabilityGroup    = $SqlAlwaysOnAvailabilityGroupName
            Name                 = $SqlAlwaysOnAvailabilityGroupListenerName
            DHCP                 = $true
            Port                 = 5301

            PsDscRunAsCredential = $SqlAdministratorCredential

            DependsOn = '[Sql]AddAG'
        }




        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
        }

    }

}

function WaitForSqlSetup {
    # Wait for SQL Server Setup to finish before proceeding.
    while ($true) {
        try {
            Get-ScheduledTaskInfo "\ConfigureSqlImageTasks\RunConfigureImage" -ErrorAction Stop
            Start-Sleep -Seconds 5
        }
        catch {
            break
        }
    }
}

function Get-NetBIOSName { 
    [OutputType([string])]
    param(
        [string]$DomainName
    )

    if ($DomainName.Contains('.')) {
        $length = $DomainName.IndexOf('.')
        if ( $length -ge 16) {
            $length = 15
        }
        return $DomainName.Substring(0, $length)
    }
    else {
        if ($DomainName.Length -gt 15) {
            return $DomainName.Substring(0, 15)
        }
        else {
            return $DomainName
        }
    }
}

function Enable-CredSSPNTLM { 
    param(
        [Parameter(Mandatory = $true)]
        [string]$DomainName
    )
    
    # This is needed for the case where NTLM authentication is used

    Write-Verbose 'STARTED:Setting up CredSSP for NTLM'
   
    Enable-WSManCredSSP -Role client -DelegateComputer localhost, *.$DomainName -Force -ErrorAction SilentlyContinue
    Enable-WSManCredSSP -Role server -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation -ErrorAction SilentlyContinue)) {
        New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows -Name '\CredentialsDelegation' -ErrorAction SilentlyContinue
    }

    if ( -not (Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation -Name 'AllowFreshCredentialsWhenNTLMOnly' -ErrorAction SilentlyContinue)) {
        New-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation -Name 'AllowFreshCredentialsWhenNTLMOnly' -value '1' -PropertyType dword -ErrorAction SilentlyContinue
    }

    if (-not (Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation -Name 'ConcatenateDefaults_AllowFreshNTLMOnly' -ErrorAction SilentlyContinue)) {
        New-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation -Name 'ConcatenateDefaults_AllowFreshNTLMOnly' -value '1' -PropertyType dword -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly -ErrorAction SilentlyContinue)) {
        New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation -Name 'AllowFreshCredentialsWhenNTLMOnly' -ErrorAction SilentlyContinue
    }

    if (-not (Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly -Name '1' -ErrorAction SilentlyContinue)) {
        New-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly -Name '1' -value "wsman/$env:COMPUTERNAME" -PropertyType string -ErrorAction SilentlyContinue
    }

    if (-not (Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly -Name '2' -ErrorAction SilentlyContinue)) {
        New-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly -Name '2' -value "wsman/localhost" -PropertyType string -ErrorAction SilentlyContinue
    }

    if (-not (Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly -Name '3' -ErrorAction SilentlyContinue)) {
        New-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly -Name '3' -value "wsman/*.$DomainName" -PropertyType string -ErrorAction SilentlyContinue
    }

    Write-Verbose "DONE:Setting up CredSSP for NTLM"
}

