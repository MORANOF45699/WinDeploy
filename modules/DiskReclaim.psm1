<#
    DiskReclaim.psm1 - get the free space back after a reinstall.

    The problem this solves: Resize-Partition can only grow a partition into
    free space that sits immediately after it. A typical disk looks like

        [ESP] [MSR] [C:] [Recovery] [free space where the old partition was]

    so the free space is not adjacent to C: and Disk Management greys out
    "Extend Volume". The Recovery partition in the middle is the blocker.

    Deleting it outright breaks WinRE - no Reset this PC, no startup repair. The
    supported dance is: reagentc /disable (which copies winre.wim back into
    C:\Windows\System32\Recovery), delete the recovery partition, extend, create
    a fresh recovery partition at the end of the disk with the right GPT type
    and attributes, then reagentc /enable.

    Nothing here runs without an explicit plan being built and shown first.
#>

Import-Module (Join-Path $PSScriptRoot 'Logging.psm1')    -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Runner.psm1')     -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Models.psm1')     -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'DiskTarget.psm1') -DisableNameChecking

$script:RecoveryGpt = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$script:EspGpt      = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:MsrGpt      = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
$script:DataGpt     = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

# GPT_BASIC_DATA_ATTRIBUTE_NO_DRIVE_LETTER | GPT_ATTRIBUTE_PLATFORM_REQUIRED
$script:RecoveryAttributes = '0x8000000000000001'
$script:NewRecoveryBytes   = 1000MB

function Get-WdWinReState {
    <#
        Reads ReAgent.xml rather than parsing reagentc /info, whose labels are
        translated. InstallState 1 means WinRE is enabled.
    #>
    [CmdletBinding()]
    param()

    $path = Join-Path $env:SystemRoot 'System32\Recovery\ReAgent.xml'
    $result = [pscustomobject]@{
        Enabled = $false; ConfigFound = $false; LocationPath = ''
        LocationOffset = 0L; LocationGuid = ''
    }
    if (-not (Test-Path -LiteralPath $path)) { return $result }

    try {
        [xml]$xml = Get-Content -LiteralPath $path -Raw
        $result.ConfigFound = $true
        $result.Enabled = ("$($xml.WindowsRE.InstallState.state)" -eq '1')
        $result.LocationPath = "$($xml.WindowsRE.WinreLocation.path)"
        $result.LocationOffset = [long]"$($xml.WindowsRE.WinreLocation.offset)"
        $result.LocationGuid = "$($xml.WindowsRE.WinreLocation.guid)"
    } catch {
        Write-WdLog "Could not read ReAgent.xml: $($_.Exception.Message)" 'WARN'
    }
    return $result
}

function Test-WdRecoveryPartition {
    param($Partition, [string]$PartitionStyle)
    if ($PartitionStyle -eq 'GPT') {
        return ("$($Partition.GptType)".ToLowerInvariant() -eq $script:RecoveryGpt)
    }
    # MBR type 0x27 is the OEM/recovery type
    return ("$($Partition.MbrType)" -eq '39' -or "$($Partition.Type)" -eq 'Recovery')
}

function Get-WdDiskMap {
    <#
        Partitions and the unallocated gaps between them, in offset order, so
        the layout can be shown the way the disk actually looks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$DiskNumber)

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Sort-Object Offset)

    $map = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $cursor = 1MB
    $end = $disk.Size - 1MB          # GPT keeps a backup header at the tail

    $add = {
        param($kind, $num, $letter, $label, $offset, $size, $note)
        $map.Add([pscustomobject]@{
            Kind    = $kind
            Number  = $num
            Letter  = $letter
            Label   = $label
            Offset  = [long]$offset
            Size    = [long]$size
            SizeGB  = [math]::Round($size / 1GB, 2)
            Note    = $note
            Display = ('{0,-10} {1,10:N2} GB  {2}' -f $kind, ($size / 1GB), $note)
        })
    }

    foreach ($p in $parts) {
        if ($p.Offset - $cursor -gt 1MB) {
            & $add 'free' 0 '' '' $cursor ($p.Offset - $cursor) 'unallocated'
        }

        $vol = $null
        if ($p.DriveLetter) { $vol = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue }
        $isRecovery = Test-WdRecoveryPartition -Partition $p -PartitionStyle "$($disk.PartitionStyle)"

        $kind = if ($isRecovery) { 'recovery' }
                elseif ("$($p.GptType)" -eq $script:EspGpt) { 'esp' }
                elseif ("$($p.GptType)" -eq $script:MsrGpt) { 'msr' }
                else { 'partition' }

        $note = @()
        if ($p.DriveLetter) { $note += "$($p.DriveLetter):" }
        if ($vol -and $vol.FileSystemLabel) { $note += $vol.FileSystemLabel }
        if ($kind -eq 'recovery') { $note += 'WinRE' }
        if ($kind -eq 'esp') { $note += 'EFI system' }
        if ($kind -eq 'msr') { $note += 'reserved' }

        & $add $kind $p.PartitionNumber "$($p.DriveLetter)" $(if ($vol) { $vol.FileSystemLabel } else { '' }) `
              $p.Offset $p.Size ($note -join ' ')
        $cursor = $p.Offset + $p.Size
    }

    if ($end - $cursor -gt 1MB) {
        & $add 'free' 0 '' '' $cursor ($end - $cursor) 'unallocated'
    }
    return , $map
}

function Get-WdReclaimPlan {
    <#
        Works out what stands between a partition and the free space to its
        right, and whether that blocker is safe to remove.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [switch]$RecreateRecovery
    )

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop | Sort-Object Offset)
    $target = $parts | Where-Object { $_.PartitionNumber -eq $PartitionNumber } | Select-Object -First 1
    if (-not $target) { throw "Disk $DiskNumber has no partition $PartitionNumber." }

    $steps = New-Object System.Collections.ArrayList
    $blockers = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    $gain = 0L
    $stopped = ''

    $cursor = $target.Offset + $target.Size
    $end = $disk.Size - 1MB

    while ($true) {
        $next = $parts | Where-Object { $_.Offset -ge $cursor } | Sort-Object Offset | Select-Object -First 1
        if (-not $next) {
            if ($end -gt $cursor) { $gain += ($end - $cursor) }
            break
        }

        if ($next.Offset -gt $cursor) { $gain += ($next.Offset - $cursor) }

        if (Test-WdRecoveryPartition -Partition $next -PartitionStyle "$($disk.PartitionStyle)") {
            [void]$blockers.Add($next)
            $gain += $next.Size
            $cursor = $next.Offset + $next.Size
            continue
        }

        $what = if ("$($next.GptType)" -eq $script:EspGpt) { 'the EFI system partition' }
                elseif ("$($next.GptType)" -eq $script:MsrGpt) { 'the Microsoft reserved partition' }
                elseif ($next.DriveLetter) { "partition $($next.PartitionNumber) ($($next.DriveLetter):)" }
                else { "partition $($next.PartitionNumber)" }
        $stopped = "Stopped at $what - WinDeploy only removes recovery partitions, never data."
        break
    }

    # Alignment slack at the tail of a disk is a few hundred KB and can never be
    # used, so anything under 16 MB is not "free space" worth reporting.
    if ($gain -lt 16MB) { $gain = 0L }

    # what the extend can actually claim (the reserve is filled in once we know
    # whether a replacement recovery partition is really needed)
    $growBy = $gain

    $winre = Get-WdWinReState

    # Only touch reagentc if one of the partitions being deleted is the one this
    # machine's WinRE actually lives on. A recovery partition on some other disk
    # is just a partition - disabling the running system's WinRE for it would be
    # both pointless and destructive.
    $winreAffected = $false
    foreach ($b in $blockers) {
        if ($winre.Enabled -and $winre.LocationOffset -gt 0 -and [long]$b.Offset -eq $winre.LocationOffset) {
            $winreAffected = $true
        }
        if ($winre.LocationGuid -and "$($b.Guid)" -and
            "$($b.Guid)".Trim('{', '}') -eq "$($winre.LocationGuid)".Trim('{', '}')) {
            $winreAffected = $true
        }
    }

    if ($blockers.Count -gt 0) {
        if ($winreAffected) {
            [void]$steps.Add('reagentc /disable  - copies winre.wim back into C:\Windows\System32\Recovery')
        } elseif ($RecreateRecovery) {
            [void]$notes.Add("This machine's WinRE does not live on any of the partitions being deleted, " +
                             'so reagentc is left alone and no replacement recovery partition is created - ' +
                             'there is nothing for it to hold.')
        }
        foreach ($b in $blockers) {
            [void]$steps.Add(('Delete recovery partition {0} ({1:N2} GB)' -f $b.PartitionNumber, ($b.Size / 1GB)))
        }
    }

    $willRecreate = ($RecreateRecovery -and $winreAffected)
    if ($willRecreate) {
        $growBy = $gain - ($script:NewRecoveryBytes + 2MB)
        if ($growBy -lt 0) { $growBy = 0 }
    }

    if ($growBy -ge 16MB) {
        [void]$steps.Add(('Extend partition {0} ({1}) by {2:N2} GB' -f
                          $target.PartitionNumber,
                          $(if ($target.DriveLetter) { "$($target.DriveLetter):" } else { 'no letter' }),
                          ($growBy / 1GB)))
    }

    if ($willRecreate) {
        [void]$steps.Add(('Create a fresh {0} MB recovery partition at the end of the disk' -f
                          ($script:NewRecoveryBytes / 1MB)))
        [void]$steps.Add('reagentc /enable   - point WinRE at the new partition')
    } elseif ($winreAffected) {
        [void]$notes.Add('WinRE will stay disabled. Reset this PC and startup repair will not work until it is re-enabled.')
    }

    $canProceed = ($growBy -ge 16MB) -or ($blockers.Count -gt 0)
    $reason = ''
    if (-not $canProceed) {
        $reason = if ($stopped) { $stopped } else { 'There is no free space after this partition.' }
    }

    return [pscustomobject]@{
        DiskNumber       = $DiskNumber
        PartitionNumber  = $PartitionNumber
        DriveLetter      = "$($target.DriveLetter)"
        CurrentSizeBytes = [long]$target.Size
        ReclaimableBytes = [long]$gain
        GrowByBytes      = [long]$growBy
        Blockers         = @($blockers | ForEach-Object { $_.PartitionNumber })
        BlockerBytes     = [long](($blockers | Measure-Object -Property Size -Sum).Sum)
        RecreateRecovery = [bool]$willRecreate
        WinReEnabled     = $winre.Enabled
        WinReAffected    = $winreAffected
        Steps            = @($steps)
        Notes            = @($notes)
        StoppedBecause   = $stopped
        CanProceed       = $canProceed
        Reason           = $reason
    }
}

function Format-WdReclaimPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('Disk {0}, partition {1} {2}' -f $Plan.DiskNumber, $Plan.PartitionNumber,
                          $(if ($Plan.DriveLetter) { "($($Plan.DriveLetter):)" } else { '' })))
    [void]$sb.AppendLine(('Current size      {0:N2} GB' -f ($Plan.CurrentSizeBytes / 1GB)))
    [void]$sb.AppendLine(('Space to reclaim  {0:N2} GB' -f ($Plan.ReclaimableBytes / 1GB)))
    [void]$sb.AppendLine(('After this it is  {0:N2} GB' -f (($Plan.CurrentSizeBytes + $Plan.GrowByBytes) / 1GB)))
    [void]$sb.AppendLine('')

    if (-not $Plan.CanProceed) {
        [void]$sb.AppendLine('Nothing to do: ' + $Plan.Reason)
        return $sb.ToString()
    }

    [void]$sb.AppendLine('Steps:')
    $i = 0
    foreach ($s in $Plan.Steps) { $i++; [void]$sb.AppendLine("  $i. $s") }

    if ($Plan.StoppedBecause) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine($Plan.StoppedBecause)
    }
    foreach ($n in $Plan.Notes) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Note: ' + $n)
    }
    return $sb.ToString()
}

function Invoke-WdReagentc {
    param([Parameter(Mandatory)][ValidateSet('enable', 'disable', 'info')][string]$Action)
    # reagentc returns non-zero for plenty of harmless states, so failures are
    # reported rather than thrown, and verification is done through ReAgent.xml
    $code = Invoke-WdProcess -FilePath (Join-Path $env:SystemRoot 'System32\reagentc.exe') `
                             -Arguments @("/$Action") -IgnoreExitCode
    return $code
}

function Invoke-WdReclaimSpace {
    <#
        Runs a plan produced by Get-WdReclaimPlan. Re-derives the plan first so
        a stale plan from an earlier scan cannot delete the wrong partition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][int]$PartitionNumber,
        [switch]$RecreateRecovery,
        [switch]$DryRun
    )

    $plan = Get-WdReclaimPlan -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -RecreateRecovery:$RecreateRecovery
    if (-not $plan.CanProceed) { throw $plan.Reason }

    Write-WdLog '--- plan ---' 'INFO'
    foreach ($line in (Format-WdReclaimPlan -Plan $plan) -split "`r?`n") {
        if ($line.Trim()) { Write-WdLog $line 'INFO' }
    }
    Write-WdLog '------------' 'INFO'

    if ($DryRun) {
        Write-WdLog 'Dry run - nothing was changed.' 'OK'
        Write-WdProgress 100 'Dry run complete'
        return $plan
    }

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    $isGpt = ("$($disk.PartitionStyle)" -eq 'GPT')

    # 1. move WinRE out of the partition that is about to disappear
    if ($plan.WinReAffected) {
        Assert-WdNotCancelled
        Write-WdProgress 10 'Disabling WinRE'
        Write-WdLog 'Disabling WinRE so winre.wim moves back onto the system drive...' 'WARN'
        Invoke-WdReagentc -Action disable | Out-Null

        $state = Get-WdWinReState
        if ($state.Enabled) {
            throw 'reagentc /disable did not take effect - refusing to delete the recovery partition.'
        }
        Write-WdLog 'WinRE disabled.' 'OK'
    }

    # 2. delete the recovery partitions in the way
    $n = 0
    foreach ($num in $plan.Blockers) {
        Assert-WdNotCancelled
        $n++
        Write-WdProgress (20 + 20.0 * $n / [math]::Max($plan.Blockers.Count, 1)) "Deleting recovery partition $num"

        $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $num -ErrorAction Stop
        if (-not (Test-WdRecoveryPartition -Partition $p -PartitionStyle "$($disk.PartitionStyle)")) {
            throw "Partition $num is no longer a recovery partition - aborting before deleting anything."
        }
        Write-WdLog ('Deleting recovery partition {0} ({1:N2} GB)...' -f $num, ($p.Size / 1GB)) 'WARN'
        Remove-Partition -DiskNumber $DiskNumber -PartitionNumber $num -Confirm:$false -ErrorAction Stop
    }

    # 3. extend, leaving room at the tail for a new recovery partition
    Assert-WdNotCancelled
    Write-WdProgress 50 'Extending the partition'
    $supported = Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
    $newSize = $supported.SizeMax
    if ($plan.RecreateRecovery) {
        $newSize = $supported.SizeMax - $script:NewRecoveryBytes - 2MB
    }
    $current = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber).Size

    if ($newSize -gt $current) {
        Write-WdLog ('Extending partition {0} from {1:N2} GB to {2:N2} GB...' -f
                     $PartitionNumber, ($current / 1GB), ($newSize / 1GB)) 'INFO'
        Resize-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -Size $newSize -ErrorAction Stop
        Write-WdLog 'Extended.' 'OK'
    } else {
        Write-WdLog 'Nothing to extend - the partition is already at its maximum.' 'WARN'
    }

    # 4. put a recovery partition back at the end of the disk
    if ($plan.RecreateRecovery) {
        Assert-WdNotCancelled
        Write-WdProgress 70 'Creating the recovery partition'
        New-WdRecoveryPartition -DiskNumber $DiskNumber -IsGpt:$isGpt

        Write-WdProgress 90 'Re-enabling WinRE'
        Invoke-WdReagentc -Action enable | Out-Null
        $state = Get-WdWinReState
        if ($state.Enabled) {
            Write-WdLog "WinRE re-enabled at $($state.LocationPath)." 'OK'
        } else {
            Write-WdLog 'reagentc /enable did not report success. Run "reagentc /info" to check.' 'WARN'
        }
    }

    Write-WdProgress 100 'Done'
    Write-WdLog ('Reclaim finished. Partition {0} is now {1:N2} GB.' -f
                 $PartitionNumber,
                 ((Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber).Size / 1GB)) 'OK'
    return $plan
}

function New-WdRecoveryPartition {
    <#
        A recovery partition is not just a formatted volume: it needs the
        recovery GPT type and the platform-required / no-drive-letter
        attributes, or Windows will treat it as an ordinary volume and put a
        drive letter on it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [switch]$IsGpt
    )

    Write-WdLog ('Creating a {0} MB recovery partition...' -f ($script:NewRecoveryBytes / 1MB)) 'INFO'

    $free = Get-WdLargestFreeSpace -DiskNumber $DiskNumber
    if ($free -lt $script:NewRecoveryBytes) {
        throw ('Only {0:N0} MB unallocated - not enough for a recovery partition.' -f ($free / 1MB))
    }

    $part = New-Partition -DiskNumber $DiskNumber -Size $script:NewRecoveryBytes -ErrorAction Stop
    Start-Sleep -Milliseconds 500

    $letter = Get-WdFreeDriveLetter
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter $letter -ErrorAction Stop
    Start-Sleep -Milliseconds 400
    Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel 'Recovery' -Confirm:$false -Force -ErrorAction Stop | Out-Null

    if ($IsGpt) {
        Invoke-WdDiskpart -Lines @(
            "select disk $DiskNumber",
            "select partition $($part.PartitionNumber)",
            "remove letter=$letter",
            "set id=$($script:RecoveryGpt.Trim('{','}'))",
            "gpt attributes=$($script:RecoveryAttributes)"
        )
    } else {
        Invoke-WdDiskpart -Lines @(
            "select disk $DiskNumber",
            "select partition $($part.PartitionNumber)",
            "remove letter=$letter",
            'set id=27'
        )
    }

    Write-WdLog "Recovery partition created (partition $($part.PartitionNumber))." 'OK'
    return $part.PartitionNumber
}

Export-ModuleMember -Function Get-WdWinReState, Get-WdDiskMap, Get-WdReclaimPlan, Format-WdReclaimPlan,
                              Invoke-WdReclaimSpace, New-WdRecoveryPartition, Test-WdRecoveryPartition,
                              Invoke-WdReagentc
