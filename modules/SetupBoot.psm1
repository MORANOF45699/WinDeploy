<#
    SetupBoot.psm1 - boot into Windows Setup from the hard disk, no USB stick.

    Copies the ISO contents to a folder on an existing volume, then adds a
    ramdisk boot entry pointing at sources\boot.wim. On the next boot the
    firmware loads WinPE from that .wim and you get the ordinary Windows Setup
    wizard - which, unlike this tool running inside Windows, is free to wipe the
    system partition. That is the EasyBCD "add a WinPE entry" trick.

    The catch worth knowing: install.wim is read off the disk during the apply
    step, so the volume holding these files must survive whatever you delete in
    Setup. Put the files on a data partition, wipe C: only.
#>

Import-Module (Join-Path $PSScriptRoot 'Logging.psm1')    -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Runner.psm1')     -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Models.psm1')     -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'IsoImage.psm1')   -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ApplyImage.psm1') -DisableNameChecking

function Invoke-WdBcdEdit {
    <#
        bcdedit with its stdout handed back, because /create prints the GUID of
        the entry it just made and there is no other way to learn it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$IgnoreFailure
    )

    Write-WdLog "bcdedit $($Arguments -join ' ')" 'CMD'
    $out = & bcdedit.exe @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE

    foreach ($line in ($out -split "`r?`n")) {
        if ($line.Trim()) { Write-WdLog $line.Trim() $(if ($code -ne 0) { 'WARN' } else { 'INFO' }) }
    }
    if ($code -ne 0 -and -not $IgnoreFailure) {
        throw "bcdedit $($Arguments -join ' ') failed with exit code $code."
    }
    return $out
}

function Backup-WdBcd {
    <# Always call this before touching the store. #>
    [CmdletBinding()]
    param([string]$Directory = (Join-Path $env:LOCALAPPDATA 'WinDeploy\bcd-backups'))

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $file = Join-Path $Directory ("bcd_{0:yyyyMMdd_HHmmss}" -f (Get-Date))
    Invoke-WdBcdEdit -Arguments @('/export', ('"' + $file + '"')) | Out-Null
    Write-WdLog "BCD backed up to $file" 'OK'
    return $file
}

function Restore-WdBcd {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "BCD backup not found: $Path" }
    Write-WdLog "Restoring the boot store from $Path ..." 'WARN'
    Invoke-WdBcdEdit -Arguments @('/import', ('"' + $Path + '"')) | Out-Null
    Write-WdLog 'Boot store restored.' 'OK'
}

function Get-WdBcdBackups {
    param([string]$Directory = (Join-Path $env:LOCALAPPDATA 'WinDeploy\bcd-backups'))
    if (-not (Test-Path -LiteralPath $Directory)) { return @() }
    return @(Get-ChildItem -LiteralPath $Directory -File | Sort-Object LastWriteTime -Descending)
}

function Get-WdSetupHostVolumes {
    <#
        Volumes that could hold the setup files: fixed NTFS, not the ISO, with
        room to spare. The system volume is allowed but flagged, because wiping
        C: in Setup would take the source files with it.
    #>
    [CmdletBinding()]
    param([double]$NeededGB = 0)

    $sys = $env:SystemDrive.TrimEnd('\').ToUpperInvariant()
    $list = New-Object System.Collections.ObjectModel.ObservableCollection[object]

    foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
        if ($v.DriveType -ne 'Fixed') { continue }
        if ($v.FileSystem -ne 'NTFS') { continue }

        $letter = "$($v.DriveLetter):"
        $freeGB = [math]::Round($v.SizeRemaining / 1GB, 1)
        $isSys = ($letter.ToUpperInvariant() -eq $sys)
        $fits = ($NeededGB -le 0) -or ($v.SizeRemaining -gt ($NeededGB * 1GB * 1.1))

        $note = if ($isSys) { 'system volume - Setup cannot wipe C: if the files live here' }
                elseif (-not $fits) { 'not enough free space' }
                else { 'ok' }

        $list.Add([pscustomobject]@{
            Drive    = $letter
            Label    = $v.FileSystemLabel
            FreeGB   = $freeGB
            IsSystem = $isSys
            Fits     = $fits
            Note     = $note
            Display  = "$letter $($v.FileSystemLabel) - $freeGB GB free  [$note]"
        })
    }
    return , $list
}

function Install-WdSetupBootEntry {
    <#
        Copies the source tree to <HostDrive>\WinDeploySetup and registers the
        ramdisk entry. Returns the new entry's GUID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$HostDrive,
        [string]$FolderName = 'WinDeploySetup',
        [string]$EntryName = 'Windows Setup (WinDeploy)',
        [switch]$OneShot
    )

    $drive = $HostDrive.TrimEnd('\', ':') + ':'
    $target = Join-Path $drive $FolderName

    $bootWimSource = Join-Path $SourceRoot 'sources\boot.wim'
    if (-not (Test-Path -LiteralPath $bootWimSource)) {
        throw "sources\boot.wim is missing from $SourceRoot. This ISO cannot boot Setup."
    }

    Write-WdProgress 5 'Copying setup files'
    Write-WdLog "Copying the installation source to $target ..." 'INFO'
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

    Invoke-WdProcess -FilePath 'robocopy.exe' `
                     -Arguments @(('"' + $SourceRoot.TrimEnd('\') + '"'), ('"' + $target + '"'),
                                  '/E', '/NFL', '/NDL', '/NJH', '/NP', '/R:1', '/W:1', '/XJ') `
                     -SuccessExitCodes @(0, 1, 2, 3, 4, 5, 6, 7) | Out-Null

    $bootWim = Join-Path $target 'sources\boot.wim'
    $bootSdi = Join-Path $target 'boot\boot.sdi'
    if (-not (Test-Path -LiteralPath $bootWim)) { throw "Copy finished but $bootWim is missing." }
    if (-not (Test-Path -LiteralPath $bootSdi)) { throw "Copy finished but $bootSdi is missing." }

    Write-WdProgress 80 'Backing up the boot store'
    $backup = Backup-WdBcd

    Write-WdProgress 85 'Creating the ramdisk boot entry'

    # {ramdiskoptions} is a well-known id; it already exists on most machines
    Invoke-WdBcdEdit -Arguments @('/create', '{ramdiskoptions}', '/d', '"Ramdisk Options"') -IgnoreFailure | Out-Null
    Invoke-WdBcdEdit -Arguments @('/set', '{ramdiskoptions}', 'ramdisksdidevice', "partition=$drive") | Out-Null
    Invoke-WdBcdEdit -Arguments @('/set', '{ramdiskoptions}', 'ramdisksdipath', "\$FolderName\boot\boot.sdi") | Out-Null

    $created = Invoke-WdBcdEdit -Arguments @('/create', '/d', ('"' + $EntryName + '"'), '/application', 'osloader')
    $m = [regex]::Match($created, '\{[0-9a-fA-F-]{36}\}')
    if (-not $m.Success) { throw "bcdedit /create did not report a GUID. Output: $created" }
    $id = $m.Value
    Write-WdLog "Setup entry: $id" 'OK'

    $ramdisk = "ramdisk=[$drive]\$FolderName\sources\boot.wim,{ramdiskoptions}"
    $winload = if ((Get-WdFirmwareType) -eq 'UEFI') { '\windows\system32\boot\winload.efi' }
               else { '\windows\system32\boot\winload.exe' }

    Invoke-WdBcdEdit -Arguments @('/set', $id, 'device', $ramdisk) | Out-Null
    Invoke-WdBcdEdit -Arguments @('/set', $id, 'osdevice', $ramdisk) | Out-Null
    Invoke-WdBcdEdit -Arguments @('/set', $id, 'path', $winload) | Out-Null
    Invoke-WdBcdEdit -Arguments @('/set', $id, 'systemroot', '\windows') | Out-Null
    Invoke-WdBcdEdit -Arguments @('/set', $id, 'detecthal', 'yes') | Out-Null
    Invoke-WdBcdEdit -Arguments @('/set', $id, 'winpe', 'yes') | Out-Null
    Invoke-WdBcdEdit -Arguments @('/displayorder', $id, '/addlast') | Out-Null

    if ($OneShot) {
        # one-time boot: the next restart goes to Setup, every later boot is normal
        Invoke-WdBcdEdit -Arguments @('/bootsequence', $id) | Out-Null
        Write-WdLog 'Set as a one-time boot target - the next restart goes to Setup, after that the menu is back to normal.' 'OK'
    }

    Write-WdProgress 96 'Writing the partition cheat sheet'
    $cheatSheet = ''
    try {
        $cheatSheet = Write-WdSetupCheatSheet -HostDrive $drive -FolderName $FolderName
    } catch {
        Write-WdLog "Could not build the partition cheat sheet: $($_.Exception.Message)" 'WARN'
    }

    Write-WdProgress 100 'Setup entry ready'
    Write-WdLog "Reboot and pick `"$EntryName`" to run Windows Setup from the disk." 'OK'
    Write-WdLog "IMPORTANT: do not delete $drive in Setup - the installation files live there." 'WARN'

    return [pscustomobject]@{
        Id = $id; Folder = $target; HostDrive = $drive; BcdBackup = $backup
        EntryName = $EntryName; CheatSheet = $cheatSheet
    }
}

function Write-WdSetupCheatSheet {
    <#
        Windows Setup's custom-install screen lists partitions by number and
        size only - no drive letters, no labels. That makes it very easy to
        delete the partition holding the installation files by accident, which
        kills the install halfway through.

        So before rebooting, write down the layout with the sizes Setup will
        show, and mark the one that has to survive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostDrive,
        [string]$FolderName = 'WinDeploySetup'
    )

    $drive = $HostDrive.TrimEnd('\', ':') + ':'
    $letter = $drive.TrimEnd(':')

    $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
    $diskNumber = [int]$part.DiskNumber
    $keepNumber = [int]$part.PartitionNumber

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('WinDeploy - read this before you touch anything in Windows Setup')
    [void]$lines.Add('=================================================================')
    [void]$lines.Add('')
    [void]$lines.Add('Setup shows partitions by number and size only. Match on SIZE.')
    [void]$lines.Add('')
    [void]$lines.Add(('Disk {0} as it looks right now:' -f $diskNumber))
    [void]$lines.Add('')
    [void]$lines.Add('  Part  Size          What Setup calls it   Do this')
    [void]$lines.Add('  ----  ------------  --------------------  ----------------------------')

    foreach ($p in (Get-Partition -DiskNumber $diskNumber | Sort-Object PartitionNumber)) {
        $sizeMb = [math]::Round($p.Size / 1MB, 0)
        $sizeTxt = '{0:N0} MB' -f $sizeMb
        if ($p.Size -ge 1GB) { $sizeTxt = '{0:N1} GB' -f ($p.Size / 1GB) }

        $vol = $null
        if ($p.DriveLetter) { $vol = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue }

        $kind = switch ("$($p.Type)") {
            'System'   { 'System' }
            'Reserved' { 'MSR (Reserved)' }
            'Recovery' { 'Recovery' }
            default    { 'Primary' }
        }

        if ($p.PartitionNumber -eq $keepNumber) {
            $action = '*** KEEP - setup files live here ***'
        } elseif ("$($p.Type)" -eq 'Basic' -and $p.DriveLetter -and
                  "$($p.DriveLetter):" -ne $env:SystemDrive) {
            $action = 'your call - data partition'
        } else {
            $action = 'delete (Setup recreates it)'
        }

        [void]$lines.Add(('  {0,-4}  {1,-12}  {2,-20}  {3}' -f $p.PartitionNumber, $sizeTxt, $kind, $action))
    }

    $keep = Get-Partition -DiskNumber $diskNumber -PartitionNumber $keepNumber
    $keepSize = if ($keep.Size -ge 1GB) { '{0:N1} GB' -f ($keep.Size / 1GB) } else { '{0:N0} MB' -f ($keep.Size / 1MB) }

    [void]$lines.Add('')
    [void]$lines.Add(('THE ONE TO KEEP IS {0} - partition {1} on disk {2}, currently {3}.' -f
                      $drive, $keepNumber, $diskNumber, $keepSize))
    [void]$lines.Add('')
    [void]$lines.Add('In Setup:')
    [void]$lines.Add('  1. Choose "Custom: Install Windows only (advanced)".')
    [void]$lines.Add('  2. Delete the old Windows partition and its System / MSR / Recovery')
    [void]$lines.Add('     partitions. Setup builds fresh ones for you.')
    [void]$lines.Add('  3. Leave the partition above alone.')
    [void]$lines.Add('  4. Select the resulting "Unallocated Space" and press Next. Setup')
    [void]$lines.Add('     partitions it and installs.')
    [void]$lines.Add('')
    [void]$lines.Add('Afterwards, the Reclaim space tab can fold the leftover free space back')
    [void]$lines.Add('into the new C:, including moving the Recovery partition out of the way.')

    foreach ($l in $lines) { Write-WdLog $l 'INFO' }

    $file = Join-Path $drive 'WinDeploySetup-READ-ME-FIRST.txt'
    try {
        Set-Content -LiteralPath $file -Value $lines -Encoding UTF8
        Write-WdLog "Saved a copy to $file" 'OK'
    } catch {
        Write-WdLog "Could not save the note to $file : $($_.Exception.Message)" 'WARN'
    }
    return ($lines -join "`r`n")
}

function Uninstall-WdSetupBootEntry {
    <# Removes the entry and, optionally, the copied files. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Folder = '',
        [switch]$DeletePartition,
        [switch]$DeleteFiles
    )

    Backup-WdBcd | Out-Null
    Invoke-WdBcdEdit -Arguments @('/delete', $Id, '/f') | Out-Null
    Write-WdLog "Removed the setup boot entry $Id." 'OK'

    if ($DeleteFiles -and $Folder) {
        if (-not (Test-Path -LiteralPath (Join-Path $Folder 'sources\boot.wim'))) {
            throw "$Folder does not look like a WinDeploy setup folder - refusing to delete it."
        }
        Write-WdLog "Deleting $Folder ..." 'WARN'
        Remove-Item -LiteralPath $Folder -Recurse -Force
        Write-WdLog 'Setup files deleted.' 'OK'
    }

    if ($DeletePartition -and $Folder) {
        $letter = ($Folder -split ':')[0].TrimStart('\')
        Remove-WdSetupPartition -DriveLetter $letter
    }
}

function Remove-WdSetupPartition {
    <#
        Deletes a temporary setup partition, but only after checking the label
        this tool put on it. A volume somebody else made is never touched.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveLetter)

    $letter = $DriveLetter.TrimEnd(':', '\')
    $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $vol) {
        Write-WdLog "${letter}: is gone already - nothing to delete." 'INFO'
        return
    }
    if ($vol.FileSystemLabel -ne $script:TempLabel) {
        throw ("${letter}: is labelled '$($vol.FileSystemLabel)', not '$($script:TempLabel)' - " +
               'refusing to delete a partition WinDeploy did not create.')
    }

    $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
    Write-WdLog ('Deleting the temporary partition {0}: ({1:N1} GB) on disk {2}...' -f
                 $letter, ($part.Size / 1GB), $part.DiskNumber) 'WARN'
    Remove-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -Confirm:$false -ErrorAction Stop
    Write-WdLog ("Temporary partition removed. Use the Reclaim space tab to fold the free space " +
                 "back into the partition before it.") 'OK'
}

$script:TempLabel = 'WINSETUP-TEMP'

function New-WdSetupPartition {
    <#
        For a machine with a single partition: shrink it, carve out a small
        NTFS volume for the installation files, and hand back its drive letter.

        This is the one case where a partition really is the answer. Setup has
        to be able to delete the Windows partition, and it cannot do that while
        reading install.wim off it - so the files need somewhere else to live,
        and on a one-partition machine there is nowhere else. The partition is
        labelled so the cleanup step can recognise it later, and the Reclaim
        space tab folds the room back into C: when the install is done.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$ShrinkFromPartition,
        [Parameter(Mandatory)][double]$SizeGB
    )

    Write-WdLog ('Carving out a {0:N1} GB temporary partition for the setup files...' -f $SizeGB) 'INFO'
    $letter = New-WdTargetPartition -DiskNumber $DiskNumber -SizeGB $SizeGB `
                                    -ShrinkFromPartition $ShrinkFromPartition `
                                    -Label $script:TempLabel -MinimumGB 8
    Write-WdLog "Temporary setup partition is ${letter}:" 'OK'
    return "$letter"
}

function Get-WdSetupSizeGB {
    <# How much room the copied tree needs, with slack for the split .swm files. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IsoPath)

    if (-not (Test-Path -LiteralPath $IsoPath)) { return 16 }
    $item = Get-Item -LiteralPath $IsoPath
    if ($item.PSIsContainer) {
        $bytes = (Get-ChildItem -LiteralPath $IsoPath -Recurse -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
    } else {
        $bytes = $item.Length
    }
    $gb = [math]::Ceiling(($bytes / 1GB) * 1.25) + 1
    if ($gb -lt 10) { $gb = 10 }
    return [double]$gb
}

function Install-WdSetupFromIso {
    <#
        One background task: mount, validate, optionally carve out a temporary
        partition, copy, register the boot entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$HostDrive = '',
        [string]$EntryName = 'Windows Setup (WinDeploy)',
        [switch]$OneShot,
        [switch]$CreateTempPartition,
        [int]$TempDiskNumber = -1,
        [int]$TempShrinkPartition = 0,
        [double]$TempSizeGB = 0
    )

    $src = $null
    $createdLetter = ''
    try {
        Write-WdProgress 1 'Mounting source'
        $src = Mount-WdSource -Path $SourcePath
        Test-WdWindowsSource -Root $src.Root | Out-Null

        if ($CreateTempPartition) {
            if ($TempDiskNumber -lt 0) { throw 'No disk was chosen for the temporary partition.' }
            if ($TempSizeGB -le 0) { $TempSizeGB = Get-WdSetupSizeGB -IsoPath $SourcePath }

            Write-WdProgress 3 'Creating the temporary partition'
            $createdLetter = New-WdSetupPartition -DiskNumber $TempDiskNumber `
                                                  -ShrinkFromPartition $TempShrinkPartition `
                                                  -SizeGB $TempSizeGB
            $HostDrive = "${createdLetter}:"
        }

        if (-not $HostDrive) { throw 'No volume was chosen for the setup files.' }

        $result = Install-WdSetupBootEntry -SourceRoot $src.Root -HostDrive $HostDrive `
                                           -EntryName $EntryName -OneShot:$OneShot
        Add-Member -InputObject $result -NotePropertyName 'TempPartition' -NotePropertyValue ([bool]$createdLetter) -Force
        return $result
    } catch {
        if ($createdLetter) {
            Write-WdLog ("The temporary partition ${createdLetter}: was created before this failed. " +
                         'Remove it from Disk Management, or run the cleanup button.') 'WARN'
        }
        throw
    } finally {
        Dismount-WdSource -Source $src
    }
}

Export-ModuleMember -Function Invoke-WdBcdEdit, Backup-WdBcd, Restore-WdBcd, Get-WdBcdBackups,
                              Get-WdSetupHostVolumes, Install-WdSetupBootEntry,
                              Uninstall-WdSetupBootEntry, Install-WdSetupFromIso, Write-WdSetupCheatSheet,
                              New-WdSetupPartition, Remove-WdSetupPartition, Get-WdSetupSizeGB
