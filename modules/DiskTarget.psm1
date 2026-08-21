<#
    DiskTarget.psm1 - everything that touches partitions.

    This is the destructive half of the tool, so it is deliberately defensive:
    the disk holding the running Windows can be shrunk but never wiped, and the
    USB tab only ever lists removable USB media.
#>

Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Runner.psm1')  -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Models.psm1')  -DisableNameChecking

$script:EspGuid = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:BasicDataGuid = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

function Get-WdSystemDiskNumber {
    <# The disk the running Windows boots from. Never offered for wiping. #>
    $sysLetter = $env:SystemDrive.TrimEnd(':', '\')
    try {
        $p = Get-Partition -DriveLetter $sysLetter -ErrorAction Stop
        return [int]$p.DiskNumber
    } catch {
        return -1
    }
}

function Get-WdFreeDriveLetter {
    param([string[]]$Exclude = @())
    $used = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } |
              ForEach-Object { "$($_.DriveLetter)".ToUpperInvariant() })
    $used += ($Exclude | ForEach-Object { $_.TrimEnd(':').ToUpperInvariant() })
    foreach ($c in [char[]]'STUVWXYZDEFGHIJKLMNOPQR') {
        if ($used -notcontains "$c") { return "$c" }
    }
    throw 'No free drive letters left.'
}

function Get-WdDisks {
    [CmdletBinding()]
    param([switch]$UsbOnly)

    $sysDisk = Get-WdSystemDiskNumber
    $list = New-Object System.Collections.ObjectModel.ObservableCollection[WinDeploy.DiskItem]

    foreach ($d in (Get-Disk | Sort-Object Number)) {
        if ($UsbOnly -and $d.BusType -ne 'USB') { continue }

        $vols = @()
        $largestFree = 0L
        try {
            $vols = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |
                      Where-Object { $_.DriveLetter } |
                      ForEach-Object { "$($_.DriveLetter):" })
            $largestFree = Get-WdLargestFreeSpace -DiskNumber $d.Number
        } catch { }

        $item = New-Object WinDeploy.DiskItem
        $item.DiskNumber       = [int]$d.Number
        $item.FriendlyName     = $d.FriendlyName
        $item.BusType          = "$($d.BusType)"
        $item.PartitionStyle   = "$($d.PartitionStyle)"
        $item.SizeBytes        = [long]$d.Size
        $item.LargestFreeBytes = $largestFree
        $item.IsSystemDisk     = ($d.Number -eq $sysDisk)
        $item.IsRemovable      = ($d.BusType -eq 'USB')
        $item.Volumes          = ($vols -join ' ')
        $list.Add($item)
    }
    return , $list
}

function Get-WdLargestFreeSpace {
    <# Biggest unallocated gap on the disk, in bytes. #>
    param([Parameter(Mandatory)][int]$DiskNumber)

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Sort-Object Offset)

    # 1 MiB alignment at the front, 1 MiB reserve at the back for the GPT copy
    $cursor = 1MB
    $end = $disk.Size - 1MB
    $largest = 0L

    foreach ($p in $parts) {
        $gap = $p.Offset - $cursor
        if ($gap -gt $largest) { $largest = $gap }
        $tail = $p.Offset + $p.Size
        if ($tail -gt $cursor) { $cursor = $tail }
    }
    $gap = $end - $cursor
    if ($gap -gt $largest) { $largest = $gap }
    if ($largest -lt 0) { $largest = 0 }
    return [long]$largest
}

function Get-WdPartitions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$DiskNumber)

    $sysLetter = $env:SystemDrive.TrimEnd(':', '\').ToUpperInvariant()
    $list = New-Object System.Collections.ObjectModel.ObservableCollection[WinDeploy.PartitionItem]

    foreach ($p in (Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Sort-Object PartitionNumber)) {
        $vol = $null
        if ($p.DriveLetter) { $vol = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue }

        $item = New-Object WinDeploy.PartitionItem
        $item.DiskNumber      = [int]$p.DiskNumber
        $item.PartitionNumber = [int]$p.PartitionNumber
        $item.DriveLetter     = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { '' }
        $item.Label           = if ($vol) { $vol.FileSystemLabel } else { '' }
        $item.FileSystem      = if ($vol) { $vol.FileSystem } else { '' }
        $item.SizeBytes       = [long]$p.Size
        $item.FreeBytes       = if ($vol -and $vol.SizeRemaining) { [long]$vol.SizeRemaining } else { 0L }
        $item.IsSystemVolume  = ("$($p.DriveLetter)".ToUpperInvariant() -eq $sysLetter)
        $item.Type            = "$($p.Type)"
        $list.Add($item)
    }
    return , $list
}

function Invoke-WdDiskpart {
    <#
        A few operations (assigning a letter to an EFI System Partition, setting
        a partition active on MBR) are not reachable through the Storage module.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Lines)

    $file = Join-Path $env:TEMP ('wd_dp_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    Set-Content -LiteralPath $file -Value $Lines -Encoding ASCII
    foreach ($l in $Lines) { Write-WdLog "diskpart> $l" 'CMD' }
    try {
        Invoke-WdProcess -FilePath 'diskpart.exe' -Arguments @('/s', ('"' + $file + '"')) | Out-Null
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function New-WdTargetPartition {
    <#
        Makes the volume the new Windows will live on and returns its drive
        letter (e.g. 'E'). Shrinks an existing partition first when the disk has
        no free space.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][double]$SizeGB,
        [int]$ShrinkFromPartition = 0,
        [string]$Label = 'Windows-New'
    )

    $needed = [long]($SizeGB * 1GB)
    if ($needed -lt 25GB) { throw 'Give the new Windows at least 25 GB.' }

    $free = Get-WdLargestFreeSpace -DiskNumber $DiskNumber
    Write-WdLog ("Disk {0}: {1:N1} GB unallocated, need {2:N1} GB." -f $DiskNumber, ($free / 1GB), $SizeGB) 'INFO'

    if ($free -lt $needed) {
        if ($ShrinkFromPartition -le 0) {
            throw ("Not enough free space on disk $DiskNumber " +
                   ("({0:N1} GB free, {1:N1} GB needed). " -f ($free / 1GB), $SizeGB) +
                   'Pick a partition to shrink.')
        }
        Assert-WdNotCancelled
        Invoke-WdShrinkPartition -DiskNumber $DiskNumber -PartitionNumber $ShrinkFromPartition -ReleaseBytes ($needed - $free)
        $free = Get-WdLargestFreeSpace -DiskNumber $DiskNumber
        if ($free -lt $needed) {
            throw ("Shrink did not free enough space (now {0:N1} GB)." -f ($free / 1GB))
        }
    }

    $letter = Get-WdFreeDriveLetter
    Write-WdLog "Creating a $SizeGB GB partition on disk $DiskNumber as ${letter}: ..." 'INFO'
    Write-WdProgress 30 'Creating partition'

    $part = New-Partition -DiskNumber $DiskNumber -Size $needed -DriveLetter $letter -ErrorAction Stop
    Start-Sleep -Milliseconds 500
    Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false -Force -ErrorAction Stop | Out-Null

    Write-WdLog "Created ${letter}: ($($part.PartitionNumber) on disk $DiskNumber)." 'OK'
    return "$letter"
}

function Invoke-WdShrinkPartition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [Parameter(Mandatory)][long]$ReleaseBytes
    )

    $part = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
    $supported = Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
    $newSize = $part.Size - $ReleaseBytes

    if ($newSize -lt $supported.SizeMin) {
        $msg = 'Cannot shrink partition {0} that far: the minimum Windows allows is {1:N1} GB, this needs {2:N1} GB. Free up space, or run Disk Cleanup and defrag first.' -f
               $PartitionNumber, ($supported.SizeMin / 1GB), ($newSize / 1GB)
        throw $msg
    }

    if ($part.DriveLetter) {
        $bl = Get-WdBitLockerState "$($part.DriveLetter):"
        if ($bl) { Write-WdLog "$($part.DriveLetter): is BitLocker-protected ($bl). Suspend it before shrinking." 'WARN' }
    }

    Write-WdLog ('Shrinking disk {0} partition {1} from {2:N1} GB to {3:N1} GB...' -f
                 $DiskNumber, $PartitionNumber, ($part.Size / 1GB), ($newSize / 1GB)) 'INFO'
    Write-WdProgress 15 'Shrinking partition'
    Resize-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -Size $newSize -ErrorAction Stop
    Write-WdLog 'Shrink complete.' 'OK'
}

function Get-WdBitLockerState {
    param([string]$MountPoint)
    try {
        $v = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
        if ($v.ProtectionStatus -eq 'On') { return "$($v.VolumeStatus)" }
    } catch { }
    return $null
}

function Format-WdExistingPartition {
    <# Wipes a partition the user explicitly picked and returns its letter. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [string]$Label = 'Windows-New'
    )

    $part = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
    $sysLetter = $env:SystemDrive.TrimEnd(':', '\').ToUpperInvariant()
    if ("$($part.DriveLetter)".ToUpperInvariant() -eq $sysLetter) {
        throw 'Refusing to format the volume the running Windows is on.'
    }

    $letter = "$($part.DriveLetter)"
    if (-not $letter) {
        $letter = Get-WdFreeDriveLetter
        Set-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -NewDriveLetter $letter -ErrorAction Stop
    }

    Write-WdLog "Formatting ${letter}: (disk $DiskNumber partition $PartitionNumber) as NTFS..." 'WARN'
    Write-WdProgress 25 'Formatting target'
    Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false -Force -ErrorAction Stop | Out-Null
    Write-WdLog 'Format complete.' 'OK'
    return "$letter"
}

function Resolve-WdEspPartition {
    <#
        Finds the EFI System Partition on the target disk, creating one if the
        disk has none, and gives it a temporary drive letter for bcdboot.
        Returns @{ Letter = 'S'; Created = $bool; DiskNumber = n; PartitionNumber = n }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$DiskNumber)

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    if ($disk.PartitionStyle -ne 'GPT') {
        throw "Disk $DiskNumber is $($disk.PartitionStyle), not GPT. UEFI boot needs a GPT disk."
    }

    $esp = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
           Where-Object { $_.GptType -eq $script:EspGuid } | Select-Object -First 1
    $created = $false

    if (-not $esp) {
        Write-WdLog "Disk $DiskNumber has no EFI System Partition - creating a 300 MB one." 'INFO'
        if ((Get-WdLargestFreeSpace -DiskNumber $DiskNumber) -lt 320MB) {
            throw "No room on disk $DiskNumber for an EFI System Partition."
        }
        $esp = New-Partition -DiskNumber $DiskNumber -Size 300MB -GptType $script:EspGuid -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        $created = $true
    }

    $letter = Get-WdFreeDriveLetter
    Invoke-WdDiskpart -Lines @(
        "select disk $DiskNumber",
        "select partition $($esp.PartitionNumber)",
        "assign letter=$letter"
    )
    Start-Sleep -Milliseconds 500

    if ($created) {
        Write-WdLog "Formatting the new ESP (${letter}:) as FAT32..." 'INFO'
        Invoke-WdProcess -FilePath 'format.com' -Arguments @("${letter}:", '/FS:FAT32', '/Q', '/Y') | Out-Null
    }

    Write-WdLog "EFI System Partition mounted at ${letter}:" 'OK'
    return [pscustomobject]@{
        Letter = "$letter"; Created = $created
        DiskNumber = $DiskNumber; PartitionNumber = [int]$esp.PartitionNumber
    }
}

function Dismount-WdEspPartition {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Esp)
    if (-not $Esp) { return }
    try {
        Invoke-WdDiskpart -Lines @(
            "select disk $($Esp.DiskNumber)",
            "select partition $($Esp.PartitionNumber)",
            "remove letter=$($Esp.Letter)"
        )
    } catch {
        Write-WdLog "Could not release drive letter $($Esp.Letter): $($_.Exception.Message)" 'WARN'
    }
}

function Initialize-WdBootableUsb {
    <#
        Rufus-lite. GPT + FAT32 because that is what a Secure Boot firmware will
        actually boot; install.wim gets split into .swm when it busts the 4 GB
        FAT32 file limit. FAT32 is capped at 32 GB, so a bigger stick gets the
        remainder as a plain NTFS data partition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][string]$SourceRoot,
        [string]$Label = 'WINSETUP'
    )

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    if ($disk.BusType -ne 'USB') { throw "Disk $DiskNumber is $($disk.BusType), not USB. Refusing." }
    if ($DiskNumber -eq (Get-WdSystemDiskNumber)) { throw 'That is the system disk. Refusing.' }
    if ($disk.Size -lt 7GB) { throw 'Use a stick of at least 8 GB.' }

    Write-WdLog "ERASING disk $DiskNumber ($($disk.FriendlyName), $([math]::Round($disk.Size/1GB,1)) GB)." 'WARN'
    Write-WdProgress 2 'Erasing USB'

    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800

    $bootBytes = [math]::Min($disk.Size - 2MB, 32GB - 2MB)
    $bootLetter = Get-WdFreeDriveLetter
    Write-WdLog ("Creating a {0:N1} GB FAT32 boot partition as {1}: ..." -f ($bootBytes / 1GB), $bootLetter) 'INFO'

    $bootPart = New-Partition -DiskNumber $DiskNumber -Size $bootBytes -DriveLetter $bootLetter `
                              -GptType $script:BasicDataGuid -ErrorAction Stop
    Start-Sleep -Milliseconds 500
    # Format-Volume refuses FAT32 above 32 GB; format.com handles what it accepts
    Invoke-WdProcess -FilePath 'format.com' -Arguments @("${bootLetter}:", '/FS:FAT32', '/Q', '/Y', "/V:$Label") | Out-Null

    $remaining = $disk.Size - $bootBytes - 3MB
    if ($remaining -gt 2GB) {
        $dataLetter = Get-WdFreeDriveLetter -Exclude @($bootLetter)
        Write-WdLog ("Adding a {0:N1} GB NTFS data partition as {1}: ..." -f ($remaining / 1GB), $dataLetter) 'INFO'
        try {
            New-Partition -DiskNumber $DiskNumber -UseMaximumSize -DriveLetter $dataLetter -ErrorAction Stop | Out-Null
            Start-Sleep -Milliseconds 400
            Format-Volume -DriveLetter $dataLetter -FileSystem NTFS -NewFileSystemLabel 'DATA' -Confirm:$false -Force | Out-Null
        } catch {
            Write-WdLog "Could not create the data partition: $($_.Exception.Message)" 'WARN'
        }
    }

    Copy-WdSourceToUsb -SourceRoot $SourceRoot -TargetRoot "${bootLetter}:\"
    Write-WdProgress 100 'USB ready'
    Write-WdLog "Bootable USB ready on ${bootLetter}:" 'OK'
    return "$bootLetter"
}

function Copy-WdSourceToUsb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    $wim = Join-Path $SourceRoot 'sources\install.wim'
    $bigWim = (Test-Path -LiteralPath $wim) -and ((Get-Item -LiteralPath $wim).Length -gt 4000MB)

    Write-WdProgress 20 'Copying files to USB'
    Write-WdLog "Copying installation files to $TargetRoot ..." 'INFO'

    # robocopy: /XJ avoids junction loops, exit codes below 8 are success
    $roboArgs = @(('"' + $SourceRoot.TrimEnd('\') + '"'), ('"' + $TargetRoot.TrimEnd('\') + '"'),
              '/E', '/NFL', '/NDL', '/NJH', '/NP', '/R:1', '/W:1', '/XJ')
    if ($bigWim) { $roboArgs += @('/XF', 'install.wim') }
    Invoke-WdProcess -FilePath 'robocopy.exe' -Arguments $roboArgs -SuccessExitCodes @(0, 1, 2, 3, 4, 5, 6, 7) | Out-Null

    if ($bigWim) {
        Write-WdProgress 70 'Splitting install.wim for FAT32'
        Write-WdLog 'install.wim is over 4 GB - splitting into .swm files for FAT32.' 'INFO'
        $swm = Join-Path $TargetRoot 'sources\install.swm'
        Invoke-WdProcess -FilePath 'dism.exe' `
                         -Arguments @('/Split-Image', ('/ImageFile:"' + $wim + '"'),
                                      ('/SWMFile:"' + $swm + '"'), '/FileSize:3800') `
                         -ParseProgress -Status 'Splitting image' -ProgressFloor 70 -ProgressCeiling 98 | Out-Null
    }
}

Export-ModuleMember -Function Get-WdDisks, Get-WdPartitions, Get-WdSystemDiskNumber, Get-WdFreeDriveLetter,
                              Get-WdLargestFreeSpace, New-WdTargetPartition, Invoke-WdShrinkPartition,
                              Format-WdExistingPartition, Resolve-WdEspPartition, Dismount-WdEspPartition,
                              Initialize-WdBootableUsb, Copy-WdSourceToUsb, Invoke-WdDiskpart,
                              Get-WdBitLockerState
