<#
    Logging.psm1 - message bus shared between the UI thread and worker runspaces.

    Everything a worker wants to say to the user goes through a ConcurrentQueue
    that lives on $global:WdBus. The UI drains it from a DispatcherTimer, so no
    worker ever touches a WPF control directly.
#>

function Initialize-WdBus {
    [CmdletBinding()]
    param(
        [string]$LogDirectory = (Join-Path $env:LOCALAPPDATA 'WinDeploy\logs')
    )

    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $logFile = Join-Path $LogDirectory ("WinDeploy_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

    $global:WdBus = [hashtable]::Synchronized(@{
        Queue    = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
        Cancel   = $false
        Process  = $null
        LogFile  = $logFile
        Busy     = $false
        TaskName = ''
    })

    Write-WdLog "WinDeploy started. Log: $logFile" 'INFO'
    return $logFile
}

function Write-WdLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'WARN', 'ERROR', 'CMD', 'OK')][string]$Level = 'INFO'
    )

    $stamp = (Get-Date).ToString('HH:mm:ss')
    $line = "[$stamp] [$Level] $Message"

    if ($global:WdBus) {
        if ($global:WdBus.LogFile) {
            try {
                Add-Content -LiteralPath $global:WdBus.LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
            } catch {
                # never let logging break the operation
            }
        }
        $global:WdBus.Queue.Enqueue([pscustomobject]@{ Type = 'log'; Text = $line; Level = $Level })
    } else {
        Write-Verbose $line
    }
}

function Write-WdProgress {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][double]$Percent = -1,
        [Parameter(Position = 1)][string]$Status = ''
    )
    if ($global:WdBus) {
        $global:WdBus.Queue.Enqueue([pscustomobject]@{ Type = 'progress'; Percent = $Percent; Status = $Status })
    }
}

function Publish-WdResult {
    <# Hand a finished object back to the UI thread by name. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [Parameter(Position = 1)]$Value
    )
    if ($global:WdBus) {
        $global:WdBus.Queue.Enqueue([pscustomobject]@{ Type = 'result'; Key = $Key; Value = $Value })
    }
}

function Test-WdCancelled {
    return [bool]($global:WdBus -and $global:WdBus.Cancel)
}

function Assert-WdNotCancelled {
    if (Test-WdCancelled) { throw 'Cancelled by user.' }
}

Export-ModuleMember -Function Initialize-WdBus, Write-WdLog, Write-WdProgress, Publish-WdResult,
                              Test-WdCancelled, Assert-WdNotCancelled
