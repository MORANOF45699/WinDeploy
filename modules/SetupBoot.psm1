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

    Write-WdProgress 100 'Setup entry ready'
    Write-WdLog "Reboot and pick `"$EntryName`" to run Windows Setup from the disk." 'OK'
    Write-WdLog "IMPORTANT: do not delete $drive in Setup - the installation files live there." 'WARN'

    return [pscustomobject]@{
        Id = $id; Folder = $target; HostDrive = $drive; BcdBackup = $backup; EntryName = $EntryName
    }
}

function Uninstall-WdSetupBootEntry {
    <# Removes the entry and, optionally, the copied files. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Folder = '',
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
}

function Install-WdSetupFromIso {
    <# One background task: mount, validate, copy, register. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$HostDrive,
        [string]$EntryName = 'Windows Setup (WinDeploy)',
        [switch]$OneShot
    )

    $src = $null
    try {
        Write-WdProgress 1 'Mounting source'
        $src = Mount-WdSource -Path $SourcePath
        Test-WdWindowsSource -Root $src.Root | Out-Null

        $result = Install-WdSetupBootEntry -SourceRoot $src.Root -HostDrive $HostDrive `
                                           -EntryName $EntryName -OneShot:$OneShot
        return $result
    } finally {
        Dismount-WdSource -Source $src
    }
}

Export-ModuleMember -Function Invoke-WdBcdEdit, Backup-WdBcd, Restore-WdBcd, Get-WdBcdBackups,
                              Get-WdSetupHostVolumes, Install-WdSetupBootEntry,
                              Uninstall-WdSetupBootEntry, Install-WdSetupFromIso
