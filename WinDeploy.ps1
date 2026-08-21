<#
    WinDeploy.ps1 - entry point.

    Point it at a Windows ISO and it applies the image to a partition you pick
    and adds the boot menu entry itself; it can also write a bootable USB, and
    back up / restore drivers the way Double Driver did.

    Run as Administrator. Windows PowerShell 5.1, STA (WPF needs it).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ---------------------------------------------------------------- elevation --
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta = ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')

if (-not $isAdmin -or -not $isSta) {
    $why = if (-not $isAdmin) { 'Administrator rights' } else { 'an STA thread (WPF)' }
    Write-Host "WinDeploy needs $why - relaunching..." -ForegroundColor Yellow
    $self = Join-Path $script:Root 'WinDeploy.ps1'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $self + '"')
        )
    } catch {
        Write-Host 'Elevation was refused. Right-click WinDeploy.cmd and choose Run as administrator.' -ForegroundColor Red
        Read-Host 'Press Enter to close'
    }
    return
}

# ------------------------------------------------------------------- loading --
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, Microsoft.VisualBasic

$script:ModulePaths = @(
    'Logging', 'Models', 'Runner', 'IsoImage', 'DiskTarget', 'DriverStore', 'ApplyImage'
) | ForEach-Object { Join-Path $script:Root "modules\$_.psm1" }

foreach ($m in $script:ModulePaths) {
    if (-not (Test-Path -LiteralPath $m)) { throw "Missing module: $m" }
    Import-Module $m -Force -DisableNameChecking
}

$script:LogFile = Initialize-WdBus
Write-WdLog "Firmware: $(Get-WdFirmwareType); PowerShell $($PSVersionTable.PSVersion)" 'INFO'

# ----------------------------------------------------------------------- UI --
$xamlPath = Join-Path $script:Root 'ui\MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))

$ui = @{}
foreach ($node in $xaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) { $ui[$name] = $window.FindName($name) }
}

# state that outlives a single click
$script:AllDrivers = $null
$script:Editions = $null
$script:Disks = $null
$script:OnDoneAction = $null
$script:ResultHandlers = @{}

# ------------------------------------------------------------------ helpers --
function Set-WdBusy {
    param([bool]$Busy)
    foreach ($n in @('BtnInstall', 'BtnMakeUsb', 'BtnScanDrivers', 'BtnBackupDrivers', 'BtnRestoreDrivers',
                     'BtnLoadIso', 'BtnRefreshDisks', 'BtnRefreshUsb', 'BtnRefreshBoot',
                     'BtnRenameEntry', 'BtnDeleteEntry', 'BtnDefaultEntry', 'BtnSetTimeout', 'BtnReboot')) {
        if ($ui[$n]) { $ui[$n].IsEnabled = -not $Busy }
    }
    $ui.BtnCancel.IsEnabled = $Busy
    $ui.Tabs.IsEnabled = $true
}

function Add-WdLogLine {
    param([string]$Text)
    $ui.TxtLog.AppendText($Text + "`r`n")
    $ui.TxtLog.ScrollToEnd()
}

function Show-WdError {
    param([string]$Message)
    [void][Windows.MessageBox]::Show($Message, 'WinDeploy', 'OK', 'Error')
}

function Show-WdInfo {
    param([string]$Message)
    [void][Windows.MessageBox]::Show($Message, 'WinDeploy', 'OK', 'Information')
}

function Confirm-WdDestructive {
    <#
        Anything that can eat data asks for the disk number to be typed out.
        A misread row in a grid should not cost somebody their photos.
    #>
    param([string]$Summary, [int]$DiskNumber)

    $answer = [Microsoft.VisualBasic.Interaction]::InputBox(
        "$Summary`r`n`r`nType the disk number ($DiskNumber) to confirm:", 'Confirm', '')
    if ("$answer".Trim() -ne "$DiskNumber") {
        Write-WdLog 'Confirmation did not match - nothing was changed.' 'WARN'
        return $false
    }
    return $true
}

function Invoke-WdJob {
    param(
        [string]$Name,
        [scriptblock]$Script,
        [hashtable]$Arguments = @{},
        [scriptblock]$OnDone = $null
    )
    if ($global:WdBus.Busy) { Show-WdError 'Another operation is still running.'; return }

    $script:OnDoneAction = $OnDone
    $ui.Progress.Value = 0
    $ui.TxtStatus.Text = $Name
    Set-WdBusy $true
    try {
        Start-WdTask -Name $Name -ScriptBlock $Script -Arguments $Arguments -Modules $script:ModulePaths
    } catch {
        Set-WdBusy $false
        Show-WdError $_.Exception.Message
    }
}

function Select-WdFile {
    param([string]$Filter = 'Windows ISO (*.iso)|*.iso|All files (*.*)|*.*', [string]$Title = 'Select a file')
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = $Filter
    $dlg.Title = $Title
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.FileName }
    return $null
}

function Select-WdFolder {
    param([string]$Description = 'Select a folder')
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath }
    return $null
}

# -------------------------------------------------------------- result sink --
$script:ResultHandlers['editions'] = {
    param($value)
    $script:Editions = $value
    $ui.CmbEdition.ItemsSource = $value
    if ($value.Count) { $ui.CmbEdition.SelectedIndex = 0 }
}
$script:ResultHandlers['disks'] = {
    param($value)
    $script:Disks = $value
    $ui.GridDisks.ItemsSource = $value
}
$script:ResultHandlers['usbdisks'] = {
    param($value)
    $ui.GridUsb.ItemsSource = $value
    if (-not $value -or $value.Count -eq 0) { Add-WdLogLine '        (no USB disks found)' }
}
$script:ResultHandlers['drivers'] = {
    param($value)
    $script:AllDrivers = $value
    Update-WdDriverGrid
}

function Update-WdDriverGrid {
    if (-not $script:AllDrivers) { return }
    $needle = "$($ui.TxtFilter.Text)".Trim()
    $view = $script:AllDrivers
    if ($needle) {
        $view = New-Object System.Collections.ObjectModel.ObservableCollection[WinDeploy.DriverItem]
        foreach ($d in $script:AllDrivers) {
            $hay = "$($d.Provider) $($d.ClassName) $($d.Devices) $($d.OemInf) $($d.OriginalName)"
            if ($hay -like "*$needle*") { $view.Add($d) }
        }
    }
    $ui.GridDrivers.ItemsSource = $view
    $sel = @($script:AllDrivers | Where-Object { $_.Selected }).Count
    $ui.TxtDriverCount.Text = "$($script:AllDrivers.Count) drivers, $sel selected"
}

# ------------------------------------------------------------- message pump --
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(180)
$timer.Add_Tick({
    foreach ($msg in (Get-WdMessages)) {
        switch ($msg.Type) {
            'log' { Add-WdLogLine $msg.Text }
            'progress' {
                if ($msg.Percent -ge 0) { $ui.Progress.Value = [math]::Min(100, [math]::Max(0, $msg.Percent)) }
                if ($msg.Status) { $ui.TxtStatus.Text = $msg.Status }
            }
            'result' {
                $h = $script:ResultHandlers[$msg.Key]
                if ($h) { & $h $msg.Value }
            }
            'done' {
                Complete-WdTask
                Set-WdBusy $false
                if ($msg.Ok) {
                    $ui.TxtStatus.Text = "$($msg.Task) - done."
                    $ui.Progress.Value = 100
                    if ($script:OnDoneAction) { & $script:OnDoneAction }
                } else {
                    $ui.TxtStatus.Text = "$($msg.Task) - failed."
                    $ui.Progress.Value = 0
                    Show-WdError "$($msg.Task) failed:`r`n`r`n$($msg.Error)"
                }
                $script:OnDoneAction = $null
            }
        }
    }
})
$timer.Start()

# ================================================================ INSTALL TAB =
$ui.TxtFirmware.Text = "This PC boots in $(Get-WdFirmwareType) mode."

$ui.BtnBrowseIso.Add_Click({
    $f = Select-WdFile
    if ($f) { $ui.TxtIso.Text = $f }
})

$ui.BtnLoadIso.Add_Click({
    $path = "$($ui.TxtIso.Text)".Trim()
    if (-not $path) { Show-WdError 'Pick an ISO file or an extracted folder first.'; return }

    Invoke-WdJob -Name 'Reading the ISO' -Arguments @{ Path = $path } -Script {
        param($Path)
        $src = $null
        try {
            $src = Mount-WdSource -Path $Path
            Test-WdWindowsSource -Root $src.Root | Out-Null
            $images = Get-WdInstallImages -Root $src.Root
            Publish-WdResult 'editions' $images
        } finally {
            Dismount-WdSource -Source $src
        }
    }
})

$ui.BtnRefreshDisks.Add_Click({
    Invoke-WdJob -Name 'Reading disks' -Script {
        Write-WdProgress 30 'Reading disks'
        Publish-WdResult 'disks' (Get-WdDisks)
        Write-WdProgress 100 'Disks read'
    }
})

$ui.GridDisks.Add_SelectionChanged({
    $disk = $ui.GridDisks.SelectedItem
    if (-not $disk) { return }
    try {
        $parts = Get-WdPartitions -DiskNumber $disk.DiskNumber
        $ui.GridPartitions.ItemsSource = $parts

        $shrinkable = New-Object System.Collections.ObjectModel.ObservableCollection[object]
        foreach ($p in $parts) {
            if ($p.SizeBytes -lt 20GB) { continue }
            if (-not $p.DriveLetter) { continue }
            $shrinkable.Add([pscustomobject]@{
                Display = "$($p.PartitionNumber): $($p.DriveLetter) $($p.Label) - $($p.SizeGB), $($p.FreeGB) free"
                Number  = $p.PartitionNumber
            })
        }
        $ui.CmbShrink.ItemsSource = $shrinkable
        if ($shrinkable.Count) { $ui.CmbShrink.SelectedIndex = 0 }
    } catch {
        Write-WdLog "Could not read partitions: $($_.Exception.Message)" 'WARN'
    }
})

$updateTargetMode = {
    $isNew = $ui.RadNewPart.IsChecked
    $ui.TxtSizeGB.IsEnabled = $isNew
    $ui.CmbShrink.IsEnabled = $isNew
}
$ui.RadNewPart.Add_Checked($updateTargetMode)
$ui.RadExistingPart.Add_Checked($updateTargetMode)

$ui.ChkInjectDrivers.Add_Click({
    $on = $ui.ChkInjectDrivers.IsChecked
    $ui.TxtInjectPath.IsEnabled = $on
    $ui.BtnBrowseInject.IsEnabled = $on
})
$ui.BtnBrowseInject.Add_Click({
    $f = Select-WdFolder 'Select a driver backup folder'
    if ($f) { $ui.TxtInjectPath.Text = $f }
})
$ui.ChkUnattend.Add_Click({
    $on = $ui.ChkUnattend.IsChecked
    $ui.TxtComputerName.IsEnabled = $on
    $ui.TxtUserName.IsEnabled = $on
})

$ui.BtnInstall.Add_Click({
    $isoPath = "$($ui.TxtIso.Text)".Trim()
    $edition = $ui.CmbEdition.SelectedItem
    $disk = $ui.GridDisks.SelectedItem

    if (-not $isoPath) { Show-WdError 'Pick a Windows source first.'; return }
    if (-not $edition) { Show-WdError 'Read the ISO and pick an edition.'; return }
    if (-not $disk)    { Show-WdError 'Pick a target disk.'; return }

    $mode = if ($ui.RadNewPart.IsChecked) { 'NewPartition' } else { 'ExistingPartition' }
    $sizeGB = 0.0
    $shrinkFrom = 0
    $existingPart = 0

    if ($mode -eq 'NewPartition') {
        if (-not [double]::TryParse("$($ui.TxtSizeGB.Text)".Trim(), [ref]$sizeGB) -or $sizeGB -lt 25) {
            Show-WdError 'Enter a partition size of at least 25 GB.'; return
        }
        if ($ui.CmbShrink.SelectedItem) { $shrinkFrom = [int]$ui.CmbShrink.SelectedItem.Number }
        $summary = "Disk $($disk.DiskNumber) ($($disk.FriendlyName)):`r`n" +
                   " - create a new $sizeGB GB partition" +
                   $(if ($shrinkFrom) { ", shrinking partition $shrinkFrom if there is not enough free space" } else { '' }) +
                   "`r`n - apply $($edition.Name)`r`n - add a boot menu entry named `"$($ui.TxtEntryName.Text)`""
    } else {
        $part = $ui.GridPartitions.SelectedItem
        if (-not $part) { Show-WdError 'Pick the partition to install onto.'; return }
        if ($part.IsSystemVolume) { Show-WdError 'That is the volume this Windows is running from.'; return }
        $existingPart = [int]$part.PartitionNumber
        $summary = "Disk $($disk.DiskNumber) partition $existingPart ($($part.DriveLetter) $($part.Label), $($part.SizeGB))`r`n" +
                   "WILL BE ERASED, then $($edition.Name) is installed onto it."
    }

    if (-not (Confirm-WdDestructive $summary $disk.DiskNumber)) { return }

    $unattendTemplate = ''
    if ($ui.ChkUnattend.IsChecked) { $unattendTemplate = Join-Path $script:Root 'assets\unattend.template.xml' }

    $jobArgs = @{
        SourcePath              = $isoPath
        ImageIndex              = [int]$edition.Index
        DiskNumber              = [int]$disk.DiskNumber
        TargetMode              = $mode
        NewPartitionGB          = $sizeGB
        ShrinkFromPartition     = $shrinkFrom
        ExistingPartitionNumber = $existingPart
        EntryName               = "$($ui.TxtEntryName.Text)".Trim()
        DriverBackupPath        = $(if ($ui.ChkInjectDrivers.IsChecked) { "$($ui.TxtInjectPath.Text)".Trim() } else { '' })
        UnattendTemplate        = $unattendTemplate
        ComputerName            = "$($ui.TxtComputerName.Text)".Trim()
        UserName                = "$($ui.TxtUserName.Text)".Trim()
    }

    Invoke-WdJob -Name 'Installing Windows' -Arguments $jobArgs -OnDone {
        Show-WdInfo "Done. Reboot and pick the new entry from the boot menu.`r`n`r`nThe Boot menu tab can rename it or set it as the default."
    } -Script {
        param($SourcePath, $ImageIndex, $DiskNumber, $TargetMode, $NewPartitionGB, $ShrinkFromPartition,
              $ExistingPartitionNumber, $EntryName, $DriverBackupPath, $UnattendTemplate, $ComputerName, $UserName)

        Install-WdWindows -SourcePath $SourcePath -ImageIndex $ImageIndex -DiskNumber $DiskNumber `
                          -TargetMode $TargetMode -NewPartitionGB $NewPartitionGB `
                          -ShrinkFromPartition $ShrinkFromPartition `
                          -ExistingPartitionNumber $ExistingPartitionNumber `
                          -EntryName $EntryName -DriverBackupPath $DriverBackupPath `
                          -UnattendTemplate $UnattendTemplate -ComputerName $ComputerName -UserName $UserName | Out-Null
    }
})

# ==================================================================== USB TAB =
$ui.BtnBrowseUsbIso.Add_Click({
    $f = Select-WdFile
    if ($f) { $ui.TxtUsbIso.Text = $f }
})
$ui.BtnCopyIsoPath.Add_Click({ $ui.TxtUsbIso.Text = $ui.TxtIso.Text })

$ui.BtnRefreshUsb.Add_Click({
    Invoke-WdJob -Name 'Looking for USB disks' -Script {
        Write-WdProgress 30 'Looking for USB disks'
        Publish-WdResult 'usbdisks' (Get-WdDisks -UsbOnly)
        Write-WdProgress 100 'Done'
    }
})

$ui.BtnMakeUsb.Add_Click({
    $isoPath = "$($ui.TxtUsbIso.Text)".Trim()
    $disk = $ui.GridUsb.SelectedItem
    if (-not $isoPath) { Show-WdError 'Pick a Windows source first.'; return }
    if (-not $disk)    { Show-WdError 'Pick a USB disk.'; return }

    $summary = "EVERYTHING on disk $($disk.DiskNumber) ($($disk.FriendlyName), $($disk.SizeGB)) will be erased" +
               "`r`nand replaced with a bootable Windows installer."
    if (-not (Confirm-WdDestructive $summary $disk.DiskNumber)) { return }

    Invoke-WdJob -Name 'Creating bootable USB' -Arguments @{
        IsoPath = $isoPath; DiskNumber = [int]$disk.DiskNumber; Label = "$($ui.TxtUsbLabel.Text)".Trim()
    } -OnDone { Show-WdInfo 'The USB stick is ready.' } -Script {
        param($IsoPath, $DiskNumber, $Label)
        $src = $null
        try {
            $src = Mount-WdSource -Path $IsoPath
            Test-WdWindowsSource -Root $src.Root | Out-Null
            Initialize-WdBootableUsb -DiskNumber $DiskNumber -SourceRoot $src.Root -Label $Label | Out-Null
        } finally {
            Dismount-WdSource -Source $src
        }
    }
})

# ================================================================ DRIVERS TAB =
$ui.TxtBackupDest.Text = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WinDeploy'

$ui.BtnScanDrivers.Add_Click({
    Invoke-WdJob -Name 'Scanning drivers' -Arguments @{ IncludeInbox = [bool]$ui.ChkIncludeInbox.IsChecked } -Script {
        param($IncludeInbox)
        Publish-WdResult 'drivers' (Get-WdInstalledDrivers -IncludeInbox:$IncludeInbox)
    }
})

$ui.TxtFilter.Add_TextChanged({ Update-WdDriverGrid })

$ui.BtnSelectAll.Add_Click({
    if (-not $script:AllDrivers) { return }
    foreach ($d in $ui.GridDrivers.ItemsSource) { $d.Selected = $true }
    Update-WdDriverGrid
})
$ui.BtnSelectNone.Add_Click({
    if (-not $script:AllDrivers) { return }
    foreach ($d in $ui.GridDrivers.ItemsSource) { $d.Selected = $false }
    Update-WdDriverGrid
})

$ui.BtnBrowseBackupDest.Add_Click({
    $f = Select-WdFolder 'Where should the driver backup go?'
    if ($f) { $ui.TxtBackupDest.Text = $f }
})

$ui.BtnBackupDrivers.Add_Click({
    if (-not $script:AllDrivers) { Show-WdError 'Scan the drivers first.'; return }
    $selected = @($script:AllDrivers | Where-Object { $_.Selected })
    if ($selected.Count -eq 0) { Show-WdError 'No drivers ticked.'; return }

    $dest = "$($ui.TxtBackupDest.Text)".Trim()
    if (-not $dest) { Show-WdError 'Pick a destination folder.'; return }

    Invoke-WdJob -Name "Backing up $($selected.Count) drivers" -Arguments @{
        Items = $selected; Destination = $dest; Compress = [bool]$ui.ChkZip.IsChecked
    } -OnDone { Show-WdInfo 'Driver backup finished. See the log for the exact folder.' } -Script {
        param($Items, $Destination, $Compress)
        Export-WdDrivers -Items $Items -Destination $Destination -Compress:$Compress | Out-Null
    }
})

$ui.BtnBrowseRestoreFolder.Add_Click({
    $f = Select-WdFolder 'Select the driver backup folder'
    if ($f) { $ui.TxtRestoreSrc.Text = $f }
})
$ui.BtnBrowseRestoreZip.Add_Click({
    $f = Select-WdFile 'Zip archive (*.zip)|*.zip' 'Select the driver backup zip'
    if ($f) { $ui.TxtRestoreSrc.Text = $f }
})

$ui.RadRestoreOffline.Add_Checked({
    $ui.CmbOfflineDrive.IsEnabled = $true
    $drives = New-Object System.Collections.ObjectModel.ObservableCollection[string]
    $sys = $env:SystemDrive.TrimEnd('\')
    foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter })) {
        $letter = "$($v.DriveLetter):"
        if ($letter -eq $sys) { continue }
        if (Test-Path -LiteralPath (Join-Path $letter 'Windows\System32')) { $drives.Add($letter) }
    }
    $ui.CmbOfflineDrive.ItemsSource = $drives
    if ($drives.Count) { $ui.CmbOfflineDrive.SelectedIndex = 0 }
})
$ui.RadRestoreOnline.Add_Checked({ $ui.CmbOfflineDrive.IsEnabled = $false })

$ui.BtnRestoreDrivers.Add_Click({
    $src = "$($ui.TxtRestoreSrc.Text)".Trim()
    if (-not $src) { Show-WdError 'Pick a driver backup folder or zip.'; return }

    if ($ui.RadRestoreOnline.IsChecked) {
        $answer = [Windows.MessageBox]::Show(
            "Install every driver in`r`n$src`r`ninto the Windows running right now?",
            'Confirm', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }

        Invoke-WdJob -Name 'Restoring drivers (online)' -Arguments @{ Source = $src } `
            -OnDone { Show-WdInfo 'Drivers installed. Reboot if anything still looks wrong.' } -Script {
            param($Source)
            Restore-WdDriversOnline -Source $Source | Out-Null
        }
    } else {
        $target = $ui.CmbOfflineDrive.SelectedItem
        if (-not $target) { Show-WdError 'Pick the Windows volume to inject into.'; return }

        Invoke-WdJob -Name "Injecting drivers into $target" -Arguments @{ Source = $src; Target = "$target" } `
            -OnDone { Show-WdInfo 'Drivers injected into the offline Windows.' } -Script {
            param($Source, $Target)
            Restore-WdDriversOffline -Source $Source -TargetDrive $Target
        }
    }
})

# ============================================================== BOOT MENU TAB =
function Update-WdBootGrid {
    try {
        $ui.GridBoot.ItemsSource = Get-WdBootEntries
    } catch {
        Show-WdError $_.Exception.Message
    }
}

$ui.BtnRefreshBoot.Add_Click({ Update-WdBootGrid })

$ui.BtnRenameEntry.Add_Click({
    $entry = $ui.GridBoot.SelectedItem
    if (-not $entry) { Show-WdError 'Pick an entry.'; return }
    $newName = [Microsoft.VisualBasic.Interaction]::InputBox('New name for this boot entry:', 'Rename', $entry.Description)
    if (-not "$newName".Trim()) { return }
    try {
        Set-WdBootEntryDescription -Id $entry.Id -Description "$newName".Trim()
        Update-WdBootGrid
    } catch { Show-WdError $_.Exception.Message }
})

$ui.BtnDefaultEntry.Add_Click({
    $entry = $ui.GridBoot.SelectedItem
    if (-not $entry) { Show-WdError 'Pick an entry.'; return }
    try {
        Set-WdDefaultBootEntry -Id $entry.Id
        Update-WdBootGrid
    } catch { Show-WdError $_.Exception.Message }
})

$ui.BtnDeleteEntry.Add_Click({
    $entry = $ui.GridBoot.SelectedItem
    if (-not $entry) { Show-WdError 'Pick an entry.'; return }
    $answer = [Windows.MessageBox]::Show(
        "Remove `"$($entry.Description)`" from the boot menu?`r`n`r`nThe files on that partition are left alone.",
        'Confirm', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    try {
        Remove-WdBootEntry -Id $entry.Id
        Update-WdBootGrid
    } catch { Show-WdError $_.Exception.Message }
})

$ui.BtnSetTimeout.Add_Click({
    $seconds = 0
    if (-not [int]::TryParse("$($ui.TxtTimeout.Text)".Trim(), [ref]$seconds) -or $seconds -lt 0 -or $seconds -gt 999) {
        Show-WdError 'Enter a timeout between 0 and 999 seconds.'; return
    }
    try { Set-WdBootTimeout -Seconds $seconds } catch { Show-WdError $_.Exception.Message }
})

$ui.BtnReboot.Add_Click({
    $answer = [Windows.MessageBox]::Show('Reboot this PC now?', 'Confirm', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') { Restart-Computer -Force }
})
$ui.BtnOpenLogFolder.Add_Click({ Start-Process explorer.exe (Split-Path -Parent $script:LogFile) })
$ui.BtnOpenDiskMgmt.Add_Click({ Start-Process 'diskmgmt.msc' })

# ================================================================ CHROME BITS =
$ui.BtnCancel.Add_Click({
    Stop-WdTask
    $ui.TxtStatus.Text = 'Cancelling...'
})

$ui.BtnToggleLog.Add_Click({
    if ($ui.LogPane.Visibility -eq 'Visible') {
        $ui.LogPane.Visibility = 'Collapsed'
        $ui.BtnToggleLog.Content = 'Show log'
    } else {
        $ui.LogPane.Visibility = 'Visible'
        $ui.BtnToggleLog.Content = 'Hide log'
    }
})

$window.Add_Closing({
    param($sender, $e)
    if ($global:WdBus.Busy) {
        $answer = [Windows.MessageBox]::Show(
            "`"$($global:WdBus.TaskName)`" is still running. Closing now could leave the disk half-written. Close anyway?",
            'Still working', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        Stop-WdTask
    }
    $timer.Stop()
})

$window.Add_ContentRendered({
    Add-WdLogLine "Log file: $script:LogFile"
    try {
        $ui.GridDisks.ItemsSource = Get-WdDisks
        Update-WdBootGrid
    } catch {
        Write-WdLog "Startup scan failed: $($_.Exception.Message)" 'WARN'
    }
})

[void]$window.ShowDialog()
$timer.Stop()
