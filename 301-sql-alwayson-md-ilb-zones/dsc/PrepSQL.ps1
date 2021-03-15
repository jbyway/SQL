
configuration PrepSQL
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$SQLServicecreds,

        [UInt32]$DatabaseEnginePort = 1433,
        
        [UInt32]$DatabaseMirrorPort = 5022,

        [UInt32]$ProbePortNumber = 59999,

        [UInt32]$DiskAllocationSize = 65536,

        [Parameter()]
        [UInt32]$NumberOfDisks,

        [Parameter(Mandatory)]
        [String]$SQLUNCPath,

        [String]$SQLInstallFiles = "C:\SQLInstall\",

        [Parameter()]
        [String]$SQLInstance,

        [Parameter()]
        [String]$SqlCollation,

        [Parameter(Mandatory)]
        [String]$WorkloadType,

        [Parameter()]
        [array]$SQLDataLun,

        [Parameter()]
        [array]$SQLLogLun,

        [Parameter()]
        [array]$SQLTempdbLun,

        [String]$DomainNetbiosName = (Get-NetBIOSName -DomainName $DomainName),

        [string]$SQLTempdbDriveLetter = "F",
        [string]$SQLDataDriveLetter = "G",
        [string]$SQLLogDriveLetter = "H",

        [Int]$NumberOfColumns = 2,

        [Int]$RetryCount = 20,
        [Int]$RetryIntervalSec = 30
    )

    
    Import-DscResource -ModuleName xComputerManagement, CDisk, xActiveDirectory, xDisk, SqlServerDsc, xNetworking, xSql
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$DomainFQDNCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$SQLCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($SQLServicecreds.UserName)", $SQLServicecreds.Password)
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12


    
    $SQLInstance = "SQL001"
    $SqlCollation = "Latin1_General_CI_AS"
    $RebootVirtualMachine = $false

    #Get-DriveLetter -DriveLuns $SQLTempdbLun.lun -DiskAllocationSize $DiskAllocationSize -DiskNamePrefix "SQLTempdb"
    
    #Get-DriveLetter -DriveLuns $SQLDataLun.lun -DiskAllocationSize $DiskAllocationSize -DiskNamePrefix "SQLData"
    
    #Get-DriveLetter -DriveLuns $SQLLogLun.lun -DiskAllocationSize $DiskAllocationSize -DiskNamePrefix "SQLLog"
    

    if ($DomainName) {
        $RebootVirtualMachine = $true
    }

    $ScriptPath = [system.io.path]::GetDirectoryName($PSCommandPath)
    . (Join-Path $ScriptPath "CreateDisks.ps1")
    


    WaitForSqlSetup

    Node localhost
    {

        xSqlCreateVirtualDataDisk TempdbDrive {
            NumberOfDisks       = $SQLTempdbLun.Count
            StartingDeviceID    = $SQLTempdbLun[0].lun
            DiskLetter          = $SQLTempdbDriveLetter
            OptimizationType    = $OptimizationType
            NumberOfColumns     = $NumberOfColumns

        }

       
        File InstallationFolder {
            Ensure          = 'Present'
            Type            = 'Directory'
            SourcePath      = $SQLUNCPath
            DestinationPath = $SQLInstallFiles
            Recurse         = $true
            DependsOn       = '[xSqlCreateVirtualDataDisk]LogDrive'
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
            DependsOn = '[WindowsFeature]FailoverClusterTools'
        }

        WindowsFeature ADPS {
            Name   = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }

        Script SqlServerPowerShell {
            SetScript  = '[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; Install-PackageProvider -Name NuGet -Force; Install-Module -Name SqlServer -AllowClobber -Force; Import-Module -Name SqlServer -ErrorAction SilentlyContinue'
            TestScript = 'Import-Module -Name SqlServer -ErrorAction SilentlyContinue; if (Get-Module -Name SqlServer) { $True } else { $False }'
            GetScript  = 'Import-Module -Name SqlServer -ErrorAction SilentlyContinue; @{Ensure = if (Get-Module -Name SqlServer) {"Present"} else {"Absent"}}'
            DependsOn = '[xSqlCreateVirtualDataDisk]DataDrive'
        }

        xFirewall DatabaseEngineFirewallRule
        {
            Direction    = "Inbound"
            Name         = "SQL-Server-Database-Engine-TCP-In"
            DisplayName  = "SQL Server Database Engine (TCP-In)"
            Description  = "Inbound rule for SQL Server to allow TCP traffic for the Database Engine."
            DisplayGroup = "SQL Server"
            State        = "Enabled"
            Access       = "Allow"
            Protocol     = "TCP"
            LocalPort = $DatabaseEnginePort -as [String]
            Ensure       = "Present"
        }

        xFirewall DatabaseMirroringFirewallRule
        {
            Direction    = "Inbound"
            Name         = "SQL-Server-Database-Mirroring-TCP-In"
            DisplayName  = "SQL Server Database Mirroring (TCP-In)"
            Description  = "Inbound rule for SQL Server to allow TCP traffic for the Database Mirroring."
            DisplayGroup = "SQL Server"
            State        = "Enabled"
            Access       = "Allow"
            Protocol     = "TCP"
            LocalPort = $DatabaseMirrorPort -as [String]
            Ensure       = "Present"
        }
        
        SqlSetup 'InstallNamedInstance'
        {
            InstanceName          = $SqlInstance
            Features              = 'SQLENGINE'
            SQLCollation          = $SqlCollation
            SQLSvcAccount         = $SQLServiceCreds
            AgtSvcAccount         = $SqlAgentServiceCredential
            ASSvcAccount          = $SqlServiceCredential
            SQLSysAdminAccounts   = $SQLCreds.UserName, $AdminCreds.UserName
            #ASSysAdminAccounts    = 'COMPANY\SQL Administrators', $SqlAdministratorCredential.UserName
            InstallSharedDir      = 'C:\Program Files\Microsoft SQL Server'
            InstallSharedWOWDir   = 'C:\Program Files (x86)\Microsoft SQL Server'
            InstanceDir           = 'C:\Program Files\Microsoft SQL Server'
            InstallSQLDataDir     = $SQLDataPath.DriveLetter + ':\' + $SqlInstance + '_Data'
            SQLUserDBDir          = $SQLDataPath.DriveLetter + ':\' + $SqlInstance + '_Data'
            SQLUserDBLogDir       = $SQLLogPath.DriveLetter + ':\' + $SqlInstance + '_Logs'
            SQLTempDBDir          = $SQLTempdbPath.DriveLetter + ':\' + $SqlInstance + '_Tempdb_Data'
            SQLTempDBLogDir       = $SQLTempdbPath.DriveLetter + ':\' + $SqlInstance + '_Tempdb_Logs'
            SQLBackupDir          = $SQLDataPath.DriveLetter + ':\' + $SqlInstance + '_Backup'
            #ASConfigDir           = 'C:\MSOLAP13.INST2016\Config'
            #ASDataDir             = 'C:\MSOLAP13.INST2016\Data'
            #ASLogDir              = 'C:\MSOLAP13.INST2016\Log'
            #ASBackupDir           = 'C:\MSOLAP13.INST2016\Backup'
            #ASTempDir             = 'C:\MSOLAP13.INST2016\Temp'
            SourcePath            = $SQLUNCPath
            SourceCredential      = $DomainCreds
            UpdateEnabled         = 'False'
            ForceReboot           = $false
            BrowserSvcStartupType = 'Automatic'

            PsDscRunAsCredential  = $AdminCreds

            DependsOn             = '[Script]SqlServerPowerShell'
        }

        xSqlLogin AddDomainAdminAccountToSysadminServerRole
        {
            Name                 = $DomainCreds.UserName
            LoginType            = "WindowsUser"
            ServerRoles          = "sysadmin"
            Enabled              = $true
            Credential           = $Admincreds
            PsDscRunAsCredential = $Admincreds
            DependsOn            = "[SqlSetup]InstallNamedInstance"
        }

        xADUser CreateSqlServerServiceAccount
        {
            DomainAdministratorCredential = $DomainCreds
            DomainName                    = $DomainName
            UserName                      = $SQLServicecreds.UserName
            Password                      = $SQLServicecreds
            Ensure                        = "Present"
            DependsOn                     = "[xSqlLogin]AddDomainAdminAccountToSysadminServerRole"
        }

        xSqlLogin AddSqlServerServiceAccountToSysadminServerRole
        {
            Name                 = $SQLCreds.UserName
            LoginType            = "WindowsUser"
            ServerRoles          = "sysadmin"
            Enabled              = $true
            Credential           = $Admincreds
            PsDscRunAsCredential = $Admincreds
            DependsOn            = "[xADUser]CreateSqlServerServiceAccount"
        }
        
        xSqlTsqlEndpoint AddSqlServerEndpoint
        {
            InstanceName               = $SQLInstance
            PortNumber                 = $DatabaseEnginePort
            SqlAdministratorCredential = $Admincreds
            PsDscRunAsCredential       = $Admincreds
            DependsOn                  = "[xSqlLogin]AddSqlServerServiceAccountToSysadminServerRole"
        }

        xSQLServerStorageSettings AddSQLServerStorageSettings
        {
            InstanceName     = $SQLInstance
            OptimizationType = $WorkloadType
            DependsOn        = "[xSqlTsqlEndpoint]AddSqlServerEndpoint"
        }

        xSqlServer ConfigureSqlServerWithAlwaysOn
        {
            InstanceName                  = $env:COMPUTERNAME
            SqlAdministratorCredential    = $Admincreds
            ServiceCredential             = $SQLCreds
            MaxDegreeOfParallelism        = 1
            FilePath                      = "C:\DATA"
            LogPath                       = "C:\LOG"
            DomainAdministratorCredential = $DomainFQDNCreds
            EnableTcpIp                   = $true
            PsDscRunAsCredential          = $Admincreds
            DependsOn                     = "[xSqlLogin]AddSqlServerServiceAccountToSysadminServerRole"
        }

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
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

