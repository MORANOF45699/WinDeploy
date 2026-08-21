<#
    DriverStore.psm1 - the Double Driver half of the tool.

    Enumerate third-party drivers, let the user tick the ones worth keeping,
    export each into its own folder, and push them back either into the running
    Windows (online) or into a freshly applied image before its first boot
    (offline). Offline is the good one: the new install comes up with network
    and display drivers already in place.
#>

Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Runner.psm1')  -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Models.psm1')  -DisableNameChecking

# Everything listed is already third-party - Microsoft's inbox drivers are
# filtered out before we get here - so the default is to keep all of it. An
# earlier class whitelist quietly dropped chipset (System), the vendor
# SoftwareComponent packages that audio and chipset drivers depend on, and
# AMD fTPM, which is exactly the stuff people notice missing after a reinstall.
# Untick what you do not want; the whole set is only a few hundred MB.

function Get-WdInstalledDrivers {
    <#
        Uses Get-WindowsDriver instead of parsing pnputil text: it returns real
        objects, and pnputil's labels are localized on non-English Windows.
    #>
    [CmdletBinding()]
    param([switch]$IncludeInbox)

    Write-WdLog 'Enumerating driver store...' 'INFO'
    Write-WdProgress 5 'Reading driver store'

    $drivers = @(Get-WindowsDriver -Online -All:$IncludeInbox.IsPresent | Where-Object {
        $IncludeInbox.IsPresent -or -not $_.Inbox
    })

    Write-WdProgress 40 'Mapping drivers to devices'
    $deviceMap = @{}
    try {
        foreach ($d in Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop) {
            if (-not $d.InfName) { continue }
            $key = $d.InfName.ToLowerInvariant()
            if (-not $deviceMap.ContainsKey($key)) { $deviceMap[$key] = New-Object System.Collections.ArrayList }
            if ($d.DeviceName -and $deviceMap[$key] -notcontains $d.DeviceName) {
                [void]$deviceMap[$key].Add($d.DeviceName)
            }
        }
    } catch {
        Write-WdLog "Could not read Win32_PnPSignedDriver: $($_.Exception.Message)" 'WARN'
    }

    $items = New-Object System.Collections.ObjectModel.ObservableCollection[WinDeploy.DriverItem]
    $n = 0
    foreach ($d in $drivers) {
        $n++
        Write-WdProgress (40 + 55.0 * $n / [math]::Max($drivers.Count, 1)) "Reading driver $n/$($drivers.Count)"

        $inf = [System.IO.Path]::GetFileName($d.Driver)
        $key = $inf.ToLowerInvariant()

        $size = 0L
        if ($d.OriginalFileName) {
            $folder = Split-Path -Parent $d.OriginalFileName
            if (Test-Path -LiteralPath $folder) {
                try {
                    $sum = (Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue |
                            Measure-Object -Property Length -Sum).Sum
                    if ($sum) { $size = [long]$sum }
                } catch { $size = 0L }
            }
        }

        $item = New-Object WinDeploy.DriverItem
        $item.OemInf       = $inf
        $item.OriginalName = if ($d.OriginalFileName) { [System.IO.Path]::GetFileName($d.OriginalFileName) } else { '' }
        $item.Provider     = $d.ProviderName
        $item.ClassName    = $d.ClassName
        $item.Version      = $d.Version
        $item.DriverDate   = if ($d.Date) { ([datetime]$d.Date).ToString('yyyy-MM-dd') } else { '' }
        $item.SignerName   = $d.DriverSignature
        $item.Devices      = if ($deviceMap.ContainsKey($key)) { ($deviceMap[$key] | Select-Object -First 3) -join '; ' } else { '' }
        $item.SizeBytes    = $size
        $item.Selected     = -not $d.Inbox

        $items.Add($item)
    }

    $preselected = @($items | Where-Object { $_.Selected }).Count
    Write-WdProgress 100 "Found $($items.Count) drivers"
    Write-WdLog "Found $($items.Count) third-party drivers ($preselected pre-selected)." 'OK'
    return , $items
}

function Get-WdSafeName {
    param([string]$Text, [string]$Fallback = 'unknown')
    if (-not $Text) { return $Fallback }
    $clean = ($Text -replace '[\\/:*?"<>|]', '_').Trim()
    if (-not $clean) { return $Fallback }
    if ($clean.Length -gt 40) { $clean = $clean.Substring(0, 40).Trim() }
    return $clean
}

function Get-WdDriverStorePath {
    <#
        FileRepository folders are named after the vendor's original .inf
        (rt25cx21x64.inf_amd64_...), not after the oem##.inf alias, so the
        original name is what we have to search for.
    #>
    param([string]$OriginalName, [string]$OemInf)

    $repo = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    foreach ($name in @($OriginalName, $OemInf)) {
        if (-not $name) { continue }
        $base = $name -replace '\.inf$', ''
        $hit = Get-ChildItem -LiteralPath $repo -Directory -Filter "$base.inf_*" -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Export-WdDrivers {
    <#
        One folder per driver, same as Double Driver, so a single vendor package
        can be restored on its own later. DISM /Export-Driver is all-or-nothing
        and cannot do that.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Compress
    )

    if (-not $Items -or $Items.Count -eq 0) { throw 'No drivers selected.' }
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $root = Join-Path $Destination "DriverBackup_${env:COMPUTERNAME}_$stamp"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Write-WdLog "Backing up $($Items.Count) drivers to $root" 'INFO'

    $records = New-Object System.Collections.ArrayList
    $failed = 0
    $n = 0

    foreach ($item in $Items) {
        Assert-WdNotCancelled
        $n++
        $pct = 90.0 * $n / $Items.Count
        Write-WdProgress $pct "Exporting $n/$($Items.Count): $($item.Provider) $($item.ClassName)"

        $folderName = '{0}_{1}_{2}_{3}' -f (Get-WdSafeName $item.Provider 'vendor'),
                                           (Get-WdSafeName $item.ClassName 'class'),
                                           (Get-WdSafeName $item.Version '0'),
                                           ($item.OemInf -replace '\.inf$', '')
        $target = Join-Path $root $folderName
        New-Item -ItemType Directory -Path $target -Force | Out-Null

        $ok = $false
        try {
            Invoke-WdProcess -FilePath 'pnputil.exe' -Arguments @('/export-driver', $item.OemInf, ('"' + $target + '"')) | Out-Null
            $ok = $true
        } catch {
            Write-WdLog "pnputil export failed for $($item.OemInf), copying the DriverStore folder instead." 'WARN'
            $src = Get-WdDriverStorePath -OriginalName $item.OriginalName -OemInf $item.OemInf
            if ($src) {
                try {
                    Copy-Item -Path (Join-Path $src '*') -Destination $target -Recurse -Force -ErrorAction Stop
                    $ok = $true
                } catch {
                    Write-WdLog "Copy failed for $($item.OemInf): $($_.Exception.Message)" 'ERROR'
                }
            }
        }

        if ($ok -and -not (Get-ChildItem -LiteralPath $target -Filter *.inf -Recurse -ErrorAction SilentlyContinue)) {
            Write-WdLog "$($item.OemInf) exported without an .inf - treating as failed." 'ERROR'
            $ok = $false
        }

        if ($ok) {
            [void]$records.Add([ordered]@{
                oemInf       = $item.OemInf
                originalName = $item.OriginalName
                provider     = $item.Provider
                className    = $item.ClassName
                version      = $item.Version
                date         = $item.DriverDate
                devices      = $item.Devices
                folder       = $folderName
            })
        } else {
            $failed++
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $manifest = [ordered]@{
        tool         = 'WinDeploy'
        version      = 1
        computerName = $env:COMPUTERNAME
        os           = (Get-CimInstance Win32_OperatingSystem).Caption
        osBuild      = [string][System.Environment]::OSVersion.Version
        created      = (Get-Date).ToString('s')
        driverCount  = $records.Count
        drivers      = $records
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'manifest.json') -Encoding UTF8

    $result = $root
    if ($Compress) {
        Write-WdProgress 95 'Compressing...'
        $zip = "$root.zip"
        Compress-Archive -Path (Join-Path $root '*') -DestinationPath $zip -Force
        Remove-Item -LiteralPath $root -Recurse -Force
        $result = $zip
    }

    Write-WdProgress 100 'Backup complete'
    Write-WdLog "Backup complete: $($records.Count) exported, $failed failed. -> $result" 'OK'
    return $result
}

function Resolve-WdBackupSource {
    param([string]$Source)
    if (-not (Test-Path -LiteralPath $Source)) { throw "Backup not found: $Source" }
    if ((Get-Item -LiteralPath $Source).PSIsContainer) { return (Resolve-Path -LiteralPath $Source).Path }

    if ([System.IO.Path]::GetExtension($Source) -eq '.zip') {
        $tmp = Join-Path $env:TEMP ('WinDeployDrv_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Write-WdLog "Extracting $Source to $tmp" 'INFO'
        Expand-Archive -LiteralPath $Source -DestinationPath $tmp -Force
        return $tmp
    }
    throw "Unsupported backup source: $Source"
}

function Restore-WdDriversOnline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source)

    $dir = Resolve-WdBackupSource $Source
    $infs = @(Get-ChildItem -LiteralPath $dir -Filter *.inf -Recurse -ErrorAction SilentlyContinue)
    if ($infs.Count -eq 0) { throw "No .inf files found under $dir" }

    Write-WdLog "Installing $($infs.Count) driver packages into the running Windows..." 'INFO'
    Write-WdProgress 10 'Installing drivers'

    # 3010 means installed-but-reboot-required, which is a success
    $pattern = '"' + (Join-Path $dir '*.inf') + '"'
    $code = Invoke-WdProcess -FilePath 'pnputil.exe' `
                             -Arguments @('/add-driver', $pattern, '/subdirs', '/install') `
                             -SuccessExitCodes @(0, 259, 3010) `
                             -Status 'Installing drivers' -ProgressFloor 10 -ProgressCeiling 95

    Write-WdProgress 100 'Drivers installed'
    if ($code -eq 3010) {
        Write-WdLog 'Drivers installed - a reboot is required.' 'OK'
    } else {
        Write-WdLog 'Drivers installed.' 'OK'
    }
    return $code
}

function Restore-WdDriversOffline {
    <#
        Injects into an applied-but-never-booted Windows. TargetDrive is the
        volume that holds \Windows, e.g. 'E:'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$TargetDrive
    )

    $dir = Resolve-WdBackupSource $Source
    $root = $TargetDrive.TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Join-Path $root 'Windows\System32'))) {
        throw "$root does not look like a Windows installation."
    }

    Write-WdLog "Injecting drivers from $dir into $root offline..." 'INFO'
    Invoke-WdProcess -FilePath 'dism.exe' `
                     -Arguments @("/Image:$root\", '/Add-Driver', ('/Driver:"' + $dir + '"'), '/Recurse') `
                     -ParseProgress -Status 'Injecting drivers' -SuccessExitCodes @(0, 3010) | Out-Null
    Write-WdProgress 100 'Drivers injected'
    Write-WdLog 'Offline driver injection complete.' 'OK'
}

function Get-WdBackupSummary {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Resolve-WdBackupSource $Path
    $manifestPath = Join-Path $dir 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        return (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    $infCount = @(Get-ChildItem -LiteralPath $dir -Filter *.inf -Recurse -ErrorAction SilentlyContinue).Count
    return [pscustomobject]@{
        computerName = '(no manifest)'; created = ''; driverCount = $infCount; drivers = @()
    }
}

Export-ModuleMember -Function Get-WdInstalledDrivers, Export-WdDrivers, Restore-WdDriversOnline,
                              Restore-WdDriversOffline, Get-WdBackupSummary, Resolve-WdBackupSource,
                              Get-WdDriverStorePath, Get-WdSafeName
