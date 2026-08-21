<#
    Runner.psm1 - runs long jobs (DISM can take many minutes) in a background
    runspace so the WPF window keeps repainting, plus a process wrapper that
    turns dism.exe's carriage-return progress bar into ProgressBar updates.
#>

Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -DisableNameChecking

$script:Task = $null

function Start-WdTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [hashtable]$Arguments = @{},
        [string[]]$Modules = @()
    )

    if ($global:WdBus.Busy) { throw "Task '$($global:WdBus.TaskName)' is still running." }

    $global:WdBus.Busy = $true
    $global:WdBus.Cancel = $false
    $global:WdBus.Process = $null
    $global:WdBus.TaskName = $Name

    $rs = [runspacefactory]::CreateRunspace([initialsessionstate]::CreateDefault2())
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('WdBus', $global:WdBus)
    $rs.SessionStateProxy.SetVariable('WdModules', $Modules)
    $rs.SessionStateProxy.SetVariable('WdArgs', $Arguments)
    # scriptblocks are bound to the runspace that created them, so ship the text
    $rs.SessionStateProxy.SetVariable('WdBody', $ScriptBlock.ToString())

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $ErrorActionPreference = 'Stop'
        try {
            foreach ($m in $WdModules) { Import-Module $m -Force -DisableNameChecking }
            $body = [scriptblock]::Create($WdBody)
            & $body @WdArgs
            $WdBus.Queue.Enqueue([pscustomobject]@{ Type = 'done'; Ok = $true; Task = $WdBus.TaskName })
        } catch {
            $msg = $_.Exception.Message
            $WdBus.Queue.Enqueue([pscustomobject]@{ Type = 'log'; Level = 'ERROR'; Text = "[ERROR] $msg" })
            if ($_.ScriptStackTrace) {
                $WdBus.Queue.Enqueue([pscustomobject]@{ Type = 'log'; Level = 'ERROR'; Text = $_.ScriptStackTrace })
            }
            $WdBus.Queue.Enqueue([pscustomobject]@{ Type = 'done'; Ok = $false; Error = $msg; Task = $WdBus.TaskName })
        }
    })

    $script:Task = [pscustomobject]@{
        Shell    = $ps
        Runspace = $rs
        Handle   = $ps.BeginInvoke()
    }
    Write-WdLog "Task started: $Name" 'INFO'
}

function Stop-WdTask {
    if (-not $global:WdBus.Busy) { return }
    $global:WdBus.Cancel = $true
    Write-WdLog 'Cancel requested - waiting for the current step to unwind.' 'WARN'
    $p = $global:WdBus.Process
    if ($p -and -not $p.HasExited) {
        try { $p.Kill() } catch { }
    }
}

function Complete-WdTask {
    # called by the UI when it sees the 'done' message
    if ($script:Task) {
        try { [void]$script:Task.Shell.EndInvoke($script:Task.Handle) } catch { }
        try { $script:Task.Shell.Dispose() } catch { }
        try { $script:Task.Runspace.Close(); $script:Task.Runspace.Dispose() } catch { }
        $script:Task = $null
    }
    $global:WdBus.Busy = $false
    $global:WdBus.Process = $null
    $global:WdBus.TaskName = ''
}

function Get-WdMessages {
    # drain everything queued since the last tick
    $items = New-Object System.Collections.ArrayList
    $item = $null
    while ($global:WdBus.Queue.TryDequeue([ref]$item)) { [void]$items.Add($item) }
    return $items
}

function Read-WdNewText {
    param([string]$Path, [ref]$Position)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        if ($fs.Length -le $Position.Value) { return '' }
        [void]$fs.Seek($Position.Value, 'Begin')
        $count = $fs.Length - $Position.Value
        $buf = New-Object byte[] $count
        $read = $fs.Read($buf, 0, $count)
        $Position.Value += $read
        return [System.Text.Encoding]::Default.GetString($buf, 0, $read)
    } catch {
        return ''
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Invoke-WdProcess {
    <#
        Runs a console tool, streams its output into the log, and (optionally)
        scrapes dism.exe percentages into the progress bar. Returns the exit code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$ParseProgress,
        [double]$ProgressFloor = 0,
        [double]$ProgressCeiling = 100,
        [string]$Status = '',
        [int[]]$SuccessExitCodes = @(0),
        [switch]$IgnoreExitCode
    )

    Assert-WdNotCancelled

    $display = "$FilePath $($Arguments -join ' ')"
    Write-WdLog $display 'CMD'

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $pos = 0
    $errPos = 0

    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru `
                              -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # touching .Handle caches the process handle; without it ExitCode comes
        # back empty once the process has already exited
        try { $null = $proc.Handle } catch { }
        $global:WdBus.Process = $proc

        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 400
            $chunk = Read-WdNewText -Path $outFile -Position ([ref]$pos)
            if ($chunk) { Publish-WdProcessOutput $chunk $ParseProgress $ProgressFloor $ProgressCeiling $Status }
            if ((Test-WdCancelled) -and -not $proc.HasExited) {
                Write-WdLog "Killing $FilePath (cancelled)." 'WARN'
                try { $proc.Kill() } catch { }
                break
            }
        }
        $proc.WaitForExit()

        # flush whatever landed after the last poll
        $chunk = Read-WdNewText -Path $outFile -Position ([ref]$pos)
        if ($chunk) { Publish-WdProcessOutput $chunk $ParseProgress $ProgressFloor $ProgressCeiling $Status }
        $errChunk = Read-WdNewText -Path $errFile -Position ([ref]$errPos)
        if ($errChunk.Trim()) {
            foreach ($l in ($errChunk -split "[`r`n]+")) { if ($l.Trim()) { Write-WdLog $l.Trim() 'WARN' } }
        }

        $code = $proc.ExitCode
        $global:WdBus.Process = $null
        Assert-WdNotCancelled

        if (-not $IgnoreExitCode -and $SuccessExitCodes -notcontains $code) {
            throw "$([System.IO.Path]::GetFileName($FilePath)) failed with exit code $code. Command: $display"
        }
        return $code
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Publish-WdProcessOutput {
    param([string]$Chunk, [bool]$ParseProgress, [double]$Floor, [double]$Ceiling, [string]$Status)

    # dism repaints its bar with bare CRs, so split on both
    foreach ($raw in ($Chunk -split "[`r`n]")) {
        $line = $raw.Trim()
        if (-not $line) { continue }

        if ($ParseProgress -and $line -match '(\d{1,3}(?:[.,]\d+)?)\s*%') {
            $pct = [double]($Matches[1] -replace ',', '.')
            $scaled = $Floor + ($Ceiling - $Floor) * ($pct / 100.0)
            Write-WdProgress $scaled ("$Status $([math]::Round($pct))%").Trim()
            continue    # don't spam the log with 300 progress bars
        }
        if ($line -match '^[\[\]=\s%.\d]+$') { continue }
        Write-WdLog $line 'INFO'
    }
}

Export-ModuleMember -Function Start-WdTask, Stop-WdTask, Complete-WdTask, Get-WdMessages, `
                              Invoke-WdProcess, Publish-WdProcessOutput, Read-WdNewText
