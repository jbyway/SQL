    param(
        [array]$DriveLuns,
        [string]$DiskNamePrefix,
        [UInt32]$DiskAllocationSize
    )
    
    #Find the next disk letter
    $AvailableDiskLetters = ls function:[f-z]: -n | ? { !(test-path $_) } 
    $NextDriveLetter = $AvailableDiskLetters.Substring(0, 1).ForEach( { "$PSItem" })

    #Initialise any unnattached disks that are not yet formatted
    Get-Disk | where partitionstyle -eq 'raw' | sort number | Initialize-Disk -PartitionStyle GPT -PassThru 

    if ($DriveLuns.Length -eq 1) {
        #Create Normal Volume for 1 drive
        $PhysicalDisks = Get-PhysicalDisk | where PhysicalLocation -match ("Lun " + $DriveLuns.lun)
        New-Partition -DriveLetter $NextDriveLetter[0] -UseMaximumSize -DiskId $PhysicalDisks.UniqueId | Format-Volume -FileSystem NTFS -AllocationUnitSize $DiskAllocationSize -NewFileSystemLabel ($DiskNamePrefix + "_Disk") -Confirm:$false
        Start-Sleep -Seconds 10
        if ($DiskNamePrefix -eq 'SQLTempDB') {
            $SQLTempdbPath = $NextDriveLetter[0]
            #return $SQLTempdbPath
        }
        elseif ($DiskNamePrefix -eq 'SQLData') {
            $SQLDataPath = $NextDriveLetter[0]
            #return $SQLDataPath
        }
        elseif ($DiskNamePrefix -eq 'SQLLog') {
            $SQLLogPath = $NextDriveLetter[0]
            #return $SQLLogPath
        }
    }
    elseif ($DriveLuns.Length -ige 2) {
        #Create Striped Volume
        $PhysicalDisks = $DriveLuns.ForEach( { Get-PhysicalDisk -CanPool $true | where PhysicalLocation -match ("Lun " + $PSItem) })
        
        New-StoragePool -FriendlyName ($DiskNamePrefix + "_SPool") -StorageSubSystemFriendlyName "Windows Storage*" -PhysicalDisks $PhysicalDisks
        New-VirtualDisk -StoragePoolFriendlyName ($DiskNamePrefix + "_SPool") -FriendlyName ($DiskNamePrefix + "_Striped") -ResiliencySettingName Simple -UseMaximumSize -ProvisioningType Fixed -Interleave $DiskAllocationSize -AutoNumberOfColumns | get-disk | Initialize-Disk -passthru | New-Partition -DriveLetter $NextDriveLetter[0] -UseMaximumSize | Format-Volume -AllocationUnitSize $DiskAllocationSize -FileSystem NTFS -NewFileSystemLabel ($DiskNamePrefix + "_StripedDisk")
        Start-Sleep -Seconds 10
        
        if ($DiskNamePrefix -eq 'SQLTempDB') {
            $SQLTempdbPath = $NextDriveLetter[0]
            #return $SQLTempdbPath
        }
        elseif ($DiskNamePrefix -eq 'SQLData') {
            $SQLDataPath = $NextDriveLetter[0]
            #return $SQLDataPath
        }
        elseif ($DiskNamePrefix -eq 'SQLLog') {
            $SQLLogPath = $NextDriveLetter[0]
            #return $SQLLogPath
        }
    }
    else {
        return "No Data Drives Found"
    }
