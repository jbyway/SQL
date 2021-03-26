
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

        [Parameter(Mandatory)]
        [String]$SQLUNCPath,

        [String]$SQLInstallFiles = "C:\SQLInstall\",

        [Parameter()]
        [String]$SQLInstance,

        [Parameter()]
        [String]$SqlCollation,

        [Parameter()]
        [String]$WorkloadType,

        [Parameter()]
        [array]$SQLDataLun,

        [Parameter()]
        [array]$SQLLogLun,

        [Parameter()]
        [array]$SQLTempdbLun,

        [Parameter()]
        [string]$OUPath,

        [Parameter()]
        [string]$ClusterNetworkObject,

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
    [System.Management.Automation.PSCredential]$DomainCredsUPN = New-Object System.Management.Automation.PSCredential ("$($Admincreds.UserName)@${DomainName}", $Admincreds.Password)

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12


    [string]$OptimizationType = $WorkloadType
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
            UpdateEnabled         = 'True'
            UpdateSource          = $SQLInstallFiles + '\Updates'
            ForceReboot           = $false
            BrowserSvcStartupType = 'Automatic'

            PsDscRunAsCredential  = $DomainCredsUPN

            DependsOn             = '[Script]SqlServerPowerShell', '[WindowsFeature]NetFramework45'
        }

        SqlWindowsFirewall 'Create_Firewall_Rules' {
            Ensure               = 'Present'
            Features             = 'SQLENGINE'
            InstanceName         = $SqlInstance

            SourcePath           = $SQLInstallFiles

            PsDscRunAsCredential = $DomainCredsUPN
            DependsOn = '[SqlSetup]InstallNamedInstance'
        }
       
        SqlAlwaysonService 'EnableAlwaysOn' {
            Ensure               = 'Present'
            ServerName           = $env:COMPUTERNAME
            InstanceName         = $SQLInstance
            RestartTimeout       = 120

            PsDscRunAsCredential = $SQLCreds

            DependsOn            = '[SqlSetup]InstallNamedInstance'
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

