<#
    IsoImage.psm1 - mounting the ISO and reading the editions inside it.

    Accepts either an .iso or an already-extracted folder, so a user who has the
    files unpacked on disk does not have to repack them.
#>

Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Models.psm1')  -DisableNameChecking

function Mount-WdSource {
    <#
        Returns a state object: @{ Root = 'D:\'; IsoPath = ...; Mounted = $bool }
        Always pair with Dismount-WdSource in a finally block.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Source not found: $Path" }
    $item = Get-Item -LiteralPath $Path

    if ($item.PSIsContainer) {
        Write-WdLog "Using extracted source folder: $($item.FullName)" 'INFO'
        return [pscustomobject]@{ Root = $item.FullName.TrimEnd('\') + '\'; IsoPath = $null; Mounted = $false }
    }

    if ($item.Extension -ne '.iso') { throw "Expected an .iso file or a folder, got: $($item.Name)" }

    Write-WdLog "Mounting $($item.FullName)..." 'INFO'
    $image = Mount-DiskImage -ImagePath $item.FullName -StorageType ISO -PassThru -ErrorAction Stop
    Start-Sleep -Milliseconds 700   # the volume takes a moment to surface
    $vol = $image | Get-Volume -ErrorAction Stop
    if (-not $vol.DriveLetter) { throw 'The ISO mounted but Windows gave it no drive letter.' }

    $root = "$($vol.DriveLetter):\"
    Write-WdLog "Mounted at $root" 'OK'
    return [pscustomobject]@{ Root = $root; IsoPath = $item.FullName; Mounted = $true }
}

function Dismount-WdSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Source)
    if ($Source -and $Source.Mounted -and $Source.IsoPath) {
        try {
            Dismount-DiskImage -ImagePath $Source.IsoPath -ErrorAction Stop | Out-Null
            Write-WdLog "Dismounted $($Source.IsoPath)" 'INFO'
        } catch {
            Write-WdLog "Could not dismount the ISO: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Test-WdWindowsSource {
    <# Cheap sanity check so the user finds out now, not after a 20 minute apply. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $problems = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'sources'))) { [void]$problems.Add('missing \sources') }
    if (-not (Get-WdInstallImagePath $Root))                       { [void]$problems.Add('missing sources\install.wim or install.esd') }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'boot')) -and
        -not (Test-Path -LiteralPath (Join-Path $Root 'efi')))     { [void]$problems.Add('missing \boot and \efi') }

    if ($problems.Count) {
        throw "This does not look like a Windows installation source: $($problems -join ', ')"
    }
    return $true
}

function Get-WdInstallImagePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    foreach ($name in @('install.wim', 'install.esd', 'install.swm')) {
        $p = Join-Path $Root "sources\$name"
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-WdInstallImages {
    <# Reads the edition table out of install.wim/.esd for the edition combo box. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $wim = Get-WdInstallImagePath $Root
    if (-not $wim) { throw "No install.wim or install.esd under $Root\sources" }

    Write-WdLog "Reading editions from $wim ..." 'INFO'
    Write-WdProgress 20 'Reading image index'

    $images = @(Get-WindowsImage -ImagePath $wim -ErrorAction Stop)
    $list = New-Object System.Collections.ObjectModel.ObservableCollection[WinDeploy.ImageItem]

    foreach ($img in $images) {
        $detail = $null
        try {
            $detail = Get-WindowsImage -ImagePath $wim -Index $img.ImageIndex -ErrorAction Stop
        } catch { }

        $entry = New-Object WinDeploy.ImageItem
        $entry.Index        = [int]$img.ImageIndex
        $entry.Name         = $img.ImageName
        $entry.Description  = $img.ImageDescription
        $entry.SizeBytes    = if ($img.ImageSize) { [long]$img.ImageSize } else { 0L }
        $entry.Version      = if ($detail) { "$($detail.Version)" } else { '' }
        $entry.Architecture = if ($detail) { Convert-WdArchitecture $detail.Architecture } else { '' }
        $list.Add($entry)
    }

    Write-WdProgress 100 "Found $($list.Count) editions"
    Write-WdLog "Found $($list.Count) editions in the image." 'OK'
    return , $list
}

function Convert-WdArchitecture {
    param($Value)
    switch ("$Value") {
        '0'     { 'x86' }
        '9'     { 'x64' }
        '5'     { 'arm' }
        '12'    { 'arm64' }
        default { "$Value" }
    }
}

function Get-WdImageFileSizeGB {
    param([Parameter(Mandatory)][string]$Root)
    $wim = Get-WdInstallImagePath $Root
    if (-not $wim) { return 0 }
    return [math]::Round((Get-Item -LiteralPath $wim).Length / 1GB, 2)
}

Export-ModuleMember -Function Mount-WdSource, Dismount-WdSource, Test-WdWindowsSource,
                              Get-WdInstallImages, Get-WdInstallImagePath, Get-WdImageFileSizeGB,
                              Convert-WdArchitecture
