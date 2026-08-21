<#
    ApplyImage.psm1 - apply the image, then own the boot menu (the EasyBCD part).

    DISM /Apply-Image + bcdboot is exactly what Windows Setup itself does, so the
    result is a normal installation, not a clone. BCD is always written last:
    until bcdboot runs, the machine still boots the way it did before, which
    makes every earlier step safe to abort.
#>

Import-Module (Join-Path $PSScriptRoot 'Logging.psm1')    -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Runner.psm1')     -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Models.psm1')     -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'IsoImage.psm1')   -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'DiskTarget.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'DriverStore.psm1') -DisableNameChecking

$script:OsLoaderType = 0x10200003
$script:ElementDescription = 0x12000004

function Get-WdFirmwareType {
    if ($env:firmware_type) { return $env:firmware_type }    # 'UEFI' or 'Legacy'
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { return 'UEFI' }
    return 'Legacy'
}

function Install-WdImage {
    <# DISM /Apply-Image. TargetDrive is a bare letter, e.g. 'E'. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$TargetDrive,
        [double]$ProgressFloor = 0,
        [double]$ProgressCeiling = 100
    )

    $root = $TargetDrive.TrimEnd(':', '\') + ':\'
    if (-not (Test-Path -LiteralPath $root)) { throw "Target volume $root is not available." }

    $free = (Get-Volume -DriveLetter $TargetDrive.TrimEnd(':', '\')).SizeRemaining
    if ($free -lt 20GB) {
        throw ('Only {0:N1} GB free on {1} - Windows needs at least 20 GB.' -f ($free / 1GB), $root)
    }

    Write-WdLog "Applying image index $Index to $root (this takes a while)..." 'INFO'
    Invoke-WdProcess -FilePath 'dism.exe' `
                     -Arguments @('/Apply-Image', ('/ImageFile:"' + $WimPath + '"'), "/Index:$Index",
                                  ('/ApplyDir:"' + $root + '"')) `
                     -ParseProgress -Status 'Applying image' `
                     -ProgressFloor $ProgressFloor -ProgressCeiling $ProgressCeiling | Out-Null

    if (-not (Test-Path -LiteralPath (Join-Path $root 'Windows\System32\winload.exe'))) {
        throw "Apply finished but $root\Windows\System32 looks wrong. Aborting before touching the boot menu."
    }
    Write-WdLog 'Image applied.' 'OK'
}

function Get-WdBootEntryIds {
    <#
        GUIDs of the OS loader entries, used to spot which one bcdboot just
        created. /v matters: without it bcdedit prints the alias {current}
        instead of the real identifier.
    #>
    $ids = New-Object System.Collections.ArrayList
    try {
        $out = & bcdedit.exe /enum osloader /v 2>&1 | Out-String
        # only the identifier line, not recoverysequence and friends
        foreach ($m in [regex]::Matches($out, '(?m)^\s*identifier\s+(\{[0-9a-fA-F-]{36}\})')) {
            $id = $m.Groups[1].Value
            if ($ids -notcontains $id) { [void]$ids.Add($id) }
        }
        if ($ids.Count -eq 0) {
            # non-English Windows translates the key name; fall back to every GUID seen
            foreach ($m in [regex]::Matches($out, '\{[0-9a-fA-F-]{36}\}')) {
                if ($ids -notcontains $m.Value) { [void]$ids.Add($m.Value) }
            }
        }
    } catch {
        Write-WdLog "bcdedit /enum failed: $($_.Exception.Message)" 'WARN'
    }
    return $ids
}

function Get-WdCurrentBootEntryId {
    try {
        $out = & bcdedit.exe /enum '{current}' /v 2>&1 | Out-String
        $m = [regex]::Match($out, '(?m)^\s*identifier\s+(\{[0-9a-fA-F-]{36}\})')
        if ($m.Success) { return $m.Groups[1].Value }
        $m = [regex]::Match($out, '\{[0-9a-fA-F-]{36}\}')
        if ($m.Success) { return $m.Value }
    } catch { }
    return $null
}

function Get-WdBootEntries {
    <#
        Reads the boot menu through the WMI BCD provider, because bcdedit's
        field labels are translated and would break parsing on a non-English
        Windows. Falls back to text parsing if WMI is unavailable.
    #>
    [CmdletBinding()]
    param()

    $list = New-Object System.Collections.ObjectModel.ObservableCollection[WinDeploy.BootEntryItem]
    $currentId = Get-WdCurrentBootEntryId

    try {
        $store = [wmi]'root\wmi:BcdStore.FilePath=""'
        $result = $store.EnumerateObjects($script:OsLoaderType)

        foreach ($o in $result.Objects) {
            $desc = ''
            try {
                $obj = [wmi]"root\wmi:BcdObject.Id=`"$($o.Id)`",StoreFilePath=`"`""
                $desc = $obj.GetElement($script:ElementDescription).Element.String
            } catch { }

            $entry = New-Object WinDeploy.BootEntryItem
            $entry.Id = $o.Id
            $entry.Description = $desc
            $entry.Device = ''
            $entry.Path = ''
            $entry.IsCurrent = ($currentId -and $o.Id -eq $currentId)
            $list.Add($entry)
        }
        if ($list.Count) { return , $list }
        Write-WdLog 'The BCD WMI provider returned no OS loaders; falling back to bcdedit.' 'WARN'
    } catch {
        Write-WdLog "BCD WMI provider unavailable ($($_.Exception.Message)); falling back to bcdedit." 'WARN'
    }

    foreach ($id in (Get-WdBootEntryIds)) {
        $entry = New-Object WinDeploy.BootEntryItem
        $entry.Id = $id
        $entry.Description = Get-WdBootEntryDescription $id
        $entry.IsCurrent = ($currentId -and $id -eq $currentId)
        $list.Add($entry)
    }
    return , $list
}

function Get-WdBootEntryDescription {
    <# Last resort when WMI is not available: read the description off bcdedit. #>
    param([Parameter(Mandatory)][string]$Id)
    try {
        $obj = [wmi]"root\wmi:BcdObject.Id=`"$Id`",StoreFilePath=`"`""
        return $obj.GetElement($script:ElementDescription).Element.String
    } catch { }
    try {
        $out = & bcdedit.exe /enum $Id /v 2>&1 | Out-String
        $m = [regex]::Match($out, '(?m)^\s*description\s+(.+?)\s*$')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return '(unnamed)'
}

function Register-WdBootEntry {
    <#
        Writes the boot files and adds the menu entry. Returns the GUID of the
        entry that appeared, so it can be renamed straight away.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetDrive,
        [string]$EspDrive,
        [string]$Firmware = (Get-WdFirmwareType),
        [string]$Description
    )

    $winDir = $TargetDrive.TrimEnd(':', '\') + ':\Windows'
    if (-not (Test-Path -LiteralPath $winDir)) { throw "$winDir not found." }

    $before = Get-WdBootEntryIds

    $bcdArgs = @($winDir)
    if ($EspDrive) { $bcdArgs += @('/s', ($EspDrive.TrimEnd(':', '\') + ':')) }
    $bcdArgs += @('/f', $(if ($Firmware -eq 'UEFI') { 'UEFI' } else { 'BIOS' }))

    Write-WdLog "Registering the boot entry ($Firmware)..." 'INFO'
    Invoke-WdProcess -FilePath 'bcdboot.exe' -Arguments $bcdArgs | Out-Null

    $after = Get-WdBootEntryIds
    $new = @($after | Where-Object { $before -notcontains $_ -and $_ -notmatch 'current|default' })

    $newId = if ($new.Count -ge 1) { $new[0] } else { $null }
    if ($newId) {
        Write-WdLog "New boot entry: $newId" 'OK'
        if ($Description) { Set-WdBootEntryDescription -Id $newId -Description $Description }
    } else {
        Write-WdLog 'bcdboot succeeded but no new boot entry appeared (it may have updated an existing one).' 'WARN'
    }
    return $newId
}

function Set-WdBootEntryDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Description
    )
    Invoke-WdProcess -FilePath 'bcdedit.exe' -Arguments @('/set', $Id, 'description', ('"' + $Description + '"')) | Out-Null
    Write-WdLog "Renamed $Id to `"$Description`"." 'OK'
}

function Remove-WdBootEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)

    $cur = & bcdedit.exe /enum '{current}' 2>&1 | Out-String
    if ($cur -match [regex]::Escape($Id)) { throw 'Refusing to delete the entry this Windows is booted from.' }

    Invoke-WdProcess -FilePath 'bcdedit.exe' -Arguments @('/delete', $Id, '/f') | Out-Null
    Write-WdLog "Deleted boot entry $Id." 'OK'
}

function Set-WdBootTimeout {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Seconds)
    Invoke-WdProcess -FilePath 'bcdedit.exe' -Arguments @('/timeout', "$Seconds") | Out-Null
    Write-WdLog "Boot menu timeout set to $Seconds s." 'OK'
}

function Set-WdDefaultBootEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    Invoke-WdProcess -FilePath 'bcdedit.exe' -Arguments @('/default', $Id) | Out-Null
    Write-WdLog "Default boot entry set to $Id." 'OK'
}

function Write-WdUnattend {
    <# Optional: skip most of OOBE on the new install. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetDrive,
        [Parameter(Mandatory)][string]$TemplatePath,
        [string]$ComputerName = '',
        [string]$UserName = '',
        [string]$Locale = 'en-US',
        [string]$TimeZone = 'SE Asia Standard Time'
    )

    if (-not (Test-Path -LiteralPath $TemplatePath)) { throw "unattend template not found: $TemplatePath" }

    $pantherDir = Join-Path ($TargetDrive.TrimEnd(':', '\') + ':\') 'Windows\Panther'
    if (-not (Test-Path -LiteralPath $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }

    $xml = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    $xml = $xml.Replace('{{COMPUTERNAME}}', $ComputerName).
                Replace('{{USERNAME}}', $UserName).
                Replace('{{LOCALE}}', $Locale).
                Replace('{{TIMEZONE}}', $TimeZone)

    $dest = Join-Path $pantherDir 'unattend.xml'
    Set-Content -LiteralPath $dest -Value $xml -Encoding UTF8
    Write-WdLog "Wrote $dest" 'OK'
}

function Install-WdWindows {
    <#
        Full install flow, run as one background task.

        Ordering matters: everything reversible happens first, the boot menu is
        touched last. If anything throws before bcdboot, the machine still boots
        exactly as it did.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][int]$ImageIndex,
        [Parameter(Mandatory)][int]$DiskNumber,
        [ValidateSet('NewPartition', 'ExistingPartition')][string]$TargetMode = 'NewPartition',
        [double]$NewPartitionGB = 100,
        [int]$ShrinkFromPartition = 0,
        [int]$ExistingPartitionNumber = 0,
        [string]$EntryName = 'Windows (new)',
        [string]$DriverBackupPath = '',
        [string]$UnattendTemplate = '',
        [string]$ComputerName = '',
        [string]$UserName = ''
    )

    $source = $null
    $esp = $null
    $targetLetter = $null
    $formattedByUs = $false

    try {
        Write-WdProgress 1 'Mounting source'
        $source = Mount-WdSource -Path $SourcePath
        Test-WdWindowsSource -Root $source.Root | Out-Null
        $wim = Get-WdInstallImagePath $source.Root
        Write-WdLog "Source image: $wim (index $ImageIndex)" 'INFO'

        Assert-WdNotCancelled
        Write-WdProgress 5 'Preparing the target volume'
        if ($TargetMode -eq 'NewPartition') {
            $targetLetter = New-WdTargetPartition -DiskNumber $DiskNumber -SizeGB $NewPartitionGB `
                                                  -ShrinkFromPartition $ShrinkFromPartition
        } else {
            $targetLetter = Format-WdExistingPartition -DiskNumber $DiskNumber -PartitionNumber $ExistingPartitionNumber
        }
        $formattedByUs = $true
        Write-WdLog "Target volume: ${targetLetter}:" 'OK'

        Assert-WdNotCancelled
        Install-WdImage -WimPath $wim -Index $ImageIndex -TargetDrive $targetLetter `
                        -ProgressFloor 10 -ProgressCeiling 80

        if ($DriverBackupPath) {
            Assert-WdNotCancelled
            Write-WdProgress 82 'Injecting drivers'
            Restore-WdDriversOffline -Source $DriverBackupPath -TargetDrive ($targetLetter + ':')
        }

        if ($UnattendTemplate) {
            Write-WdProgress 88 'Writing unattend.xml'
            Write-WdUnattend -TargetDrive $targetLetter -TemplatePath $UnattendTemplate `
                             -ComputerName $ComputerName -UserName $UserName
        }

        Assert-WdNotCancelled
        Write-WdProgress 92 'Writing the boot entry'
        $firmware = Get-WdFirmwareType
        if ($firmware -eq 'UEFI') {
            $esp = Resolve-WdEspPartition -DiskNumber $DiskNumber
            $newId = Register-WdBootEntry -TargetDrive $targetLetter -EspDrive $esp.Letter `
                                          -Firmware $firmware -Description $EntryName
        } else {
            $newId = Register-WdBootEntry -TargetDrive $targetLetter -Firmware $firmware -Description $EntryName
        }

        Set-WdBootTimeout -Seconds 15

        Write-WdProgress 100 'Done'
        Write-WdLog "Installation staged. Reboot and pick `"$EntryName`" from the boot menu." 'OK'
        return [pscustomobject]@{ TargetDrive = "${targetLetter}:"; BootEntryId = $newId; EntryName = $EntryName }
    } catch {
        Write-WdLog "Install failed: $($_.Exception.Message)" 'ERROR'
        if ($formattedByUs -and $targetLetter) {
            Write-WdLog "The boot menu was NOT modified - the machine still boots as before. Leftover files are on ${targetLetter}:." 'WARN'
        }
        throw
    } finally {
        if ($esp) { Dismount-WdEspPartition -Esp $esp }
        if ($source) { Dismount-WdSource -Source $source }
    }
}

Export-ModuleMember -Function Install-WdImage, Register-WdBootEntry, Get-WdBootEntries, Get-WdBootEntryIds,
                              Set-WdBootEntryDescription, Remove-WdBootEntry, Set-WdBootTimeout,
                              Set-WdDefaultBootEntry, Write-WdUnattend, Install-WdWindows, Get-WdFirmwareType,
                              Get-WdCurrentBootEntryId, Get-WdBootEntryDescription
