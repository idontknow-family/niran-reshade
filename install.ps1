#Requires -Version 5.1
<#
    Niran ReShade Auto-Installer
    Repo: idontknow-family/niran-reshade

    Safe for both local execution and remote one-liner:
        irm https://raw.githubusercontent.com/idontknow-family/niran-reshade/main/install.ps1 | iex

    Design notes:
      - Never calls bare `exit` (would close the user's shell when run via `iex`
        pasted into an interactive terminal). Uses `return` from Invoke-Main instead.
      - Only $ErrorActionPreference = 'Stop' is used, scoped to try/catch blocks,
        so failures are never silently swallowed.
      - User config files (ReShade.ini / ReShadePreset.ini) are preserved on
        re-install; only dxgi.dll and the shader library are force-refreshed.
#>

param(
    [string]$FiveMPath,                 # optional override for custom install locations
    [int]$LogWaitTimeoutSeconds = 120
)

$ProgressPreference = 'SilentlyContinue'
$script:ScriptStartTime = Get-Date

# ------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------
$Config = @{
    ZipUrl        = "https://github.com/idontknow-family/niran-reshade/releases/download/v1.0.0/Files.zip"
    TempZip       = Join-Path $env:TEMP "niran_files_$([guid]::NewGuid().ToString('N')).zip"
    TempExtract   = Join-Path $env:TEMP "niran_extracted_$([guid]::NewGuid().ToString('N'))"
    # Files/folders deployed *as-is* every run (safe to force-overwrite)
    ForceItems    = @('dxgi.dll', 'reshade-shaders')
    # Files deployed only if missing (user config — never clobber on re-install)
    PreserveItems = @('ReShade.ini', 'ReShadePreset.ini')
    ProcessNames  = @('FiveM', 'FiveM_GTAProcess', 'GTA5', 'GTA5_Enhanced')
}

# ------------------------------------------------------------------
# UI HELPERS
# ------------------------------------------------------------------
function Set-ConsoleTheme {
    try {
        [Console]::BackgroundColor = 'Black'
        [Console]::ForegroundColor = 'White'
        [Console]::Clear()
    } catch { }
    try { $host.UI.RawUI.WindowTitle = "Niran ReShade Online Installer" } catch { }
}

function Write-Banner {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   N I R A N   R E S H A D E   A U T O - I N S T A L L E R" -ForegroundColor White
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Text)
    Write-Host "  $Text " -NoNewline -ForegroundColor White
}

function Write-Ok    { param([string]$Text = "Done") Write-Host $Text -ForegroundColor Cyan }
function Write-Fail  { param([string]$Text = "Failed") Write-Host $Text -ForegroundColor Red }
function Write-Warn2 { param([string]$Text) Write-Host "  [!] $Text" -ForegroundColor Yellow }
function Write-Err2  { param([string]$Text) Write-Host "  [!] $Text" -ForegroundColor Red }

function Wait-KeyIfInteractive {
    param([string]$Message = "Press any key to exit...")
    # Never hang non-interactive hosts (CI, redirected output, etc.)
    if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected) {
        Write-Host ""
        Write-Host "  $Message" -ForegroundColor DarkGray
        try { [void][System.Console]::ReadKey($true) } catch { Start-Sleep -Seconds 3 }
    } else {
        Start-Sleep -Seconds 2
    }
}

# ------------------------------------------------------------------
# CORE LOGIC
# ------------------------------------------------------------------

function Resolve-FiveMPath {
    param([string]$OverridePath)

    if ($OverridePath) {
        if (Test-Path $OverridePath) { return $OverridePath }
        Write-Warn2 "Custom path '$OverridePath' not found. Falling back to auto-detection."
    }

    $candidates = @(
        "$env:LOCALAPPDATA\FiveM\FiveM.app"
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Test-GameRunning {
    param([string[]]$Names)
    $running = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $Names -contains $_.ProcessName -or ($_.ProcessName -like "*FiveM*") }
    return $running
}

function Wait-ForGameExit {
    param([string[]]$Names, [int]$MaxWaitSeconds = 60)

    $procs = Test-GameRunning -Names $Names
    if (-not $procs) { return $true }

    Write-Warn2 "FiveM/GTA5 is currently running. Files are locked while the game is active."
    Write-Host "        > Close FiveM completely, then press any key to retry (or wait — I'll auto-check)..." -ForegroundColor Gray

    $elapsed = 0
    while ($elapsed -lt $MaxWaitSeconds) {
        Start-Sleep -Seconds 2
        $elapsed += 2
        if (-not (Test-GameRunning -Names $Names)) { return $true }
    }
    return $false
}

function Get-RemoteFile {
    param([string]$Url, [string]$Destination, [int]$Retries = 3)

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
    } catch {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                & curl.exe -s -f -L -o $Destination $Url
                if ($LASTEXITCODE -ne 0) { throw "curl.exe exited with code $LASTEXITCODE" }
            } else {
                Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
            }

            if (-not (Test-Path $Destination) -or (Get-Item $Destination).Length -eq 0) {
                throw "Downloaded file is empty or missing."
            }
            return $true
        } catch {
            if ($attempt -eq $Retries) { throw }
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Install-ReshadeFiles {
    param(
        [string]$ExtractedRoot,
        [string]$PluginsPath,
        [hashtable]$Config
    )

    # Some zip layouts wrap content in a 'plugins' subfolder — normalize either way.
    $sourceRoot = if (Test-Path (Join-Path $ExtractedRoot 'plugins')) {
        Join-Path $ExtractedRoot 'plugins'
    } else {
        $ExtractedRoot
    }

    # Force-refresh: dxgi.dll + full shader library (removes stale/renamed shader files)
    foreach ($item in $Config.ForceItems) {
        $src = Join-Path $sourceRoot $item
        $dst = Join-Path $PluginsPath $item
        if (-not (Test-Path $src)) {
            Write-Warn2 "Expected file/folder '$item' missing from release package — skipped."
            continue
        }
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force -ErrorAction Stop }
        Copy-Item -Path $src -Destination $dst -Recurse -Force -ErrorAction Stop
    }

    # Preserve user configs: only deploy if not already present (back up if replacing intentionally)
    foreach ($item in $Config.PreserveItems) {
        $src = Join-Path $sourceRoot $item
        $dst = Join-Path $PluginsPath $item
        if (-not (Test-Path $src)) { continue }

        if (Test-Path $dst) {
            # Already configured by the user — leave it alone.
            continue
        }
        Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
    }
}

function Update-CitizenFxIni {
    param([string]$IniPath, [string]$DeviceId)

    $bypassLine = "$DeviceId acknowledged that ReShade 5.x has a bug that will lead to game crashes"

    if (Test-Path $IniPath) {
        $content = Get-Content $IniPath -Raw -ErrorAction Stop
        if ($content -match [regex]::Escape($DeviceId)) {
            return  # already acknowledged
        }
        if ($content -notmatch "\[Addons\]") {
            Add-Content -Path $IniPath -Value "`r`n[Addons]`r`n$bypassLine" -Encoding utf8 -ErrorAction Stop
        } else {
            Add-Content -Path $IniPath -Value "$bypassLine" -Encoding utf8 -ErrorAction Stop
        }
    } else {
        "[Addons]`r`n$bypassLine" | Set-Content -Path $IniPath -Encoding utf8 -ErrorAction Stop
    }
}

function Watch-ForDeviceId {
    param([string]$FiveMPath, [string]$IniPath, [int]$TimeoutSeconds)

    Write-Host "  [3/3] Real-time Log Verification" -ForegroundColor White
    Write-Host "        > Status : " -NoNewline -ForegroundColor DarkGray
    Write-Host "Waiting for FiveM launch..." -ForegroundColor Cyan
    Write-Host "        > Action : Please launch FiveM now (or reconnect to a server)." -ForegroundColor Gray
    Write-Host ""

    $fivemDetected = $false
    $elapsed = 0

    while ($elapsed -lt $TimeoutSeconds) {
        try {
            if (-not $fivemDetected -and (Test-GameRunning -Names $Config.ProcessNames)) {
                $fivemDetected = $true
                Write-Host "        > FiveM session detected. Reading log stream..." -ForegroundColor DarkGray
            }

            # No time-window restriction: catches sessions already open before the script started.
            $latestLog = Get-ChildItem -Path $FiveMPath -Filter "*CitizenFX*.log" -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            if ($latestLog) {
                $logContent = $null
                try {
                    $fs = [System.IO.File]::Open($latestLog.FullName, 'Open', 'Read', 'ReadWrite')
                    $sr = New-Object System.IO.StreamReader($fs)
                    $logContent = $sr.ReadToEnd()
                    $sr.Close(); $fs.Close()
                } catch {
                    # log actively locked — retry next loop
                }

                if ($logContent -and $logContent -match "ReShade5=ID:([a-f0-9]+)") {
                    $deviceId = $Matches[1]   # bare hex ID, NOT the full "ReShade5=ID:" prefix
                    Write-Host "        > Device ID : " -NoNewline -ForegroundColor DarkGray
                    Write-Host "$deviceId" -ForegroundColor Cyan

                    Write-Host ""
                    Write-Step "[3/3] Updating CitizenFX.ini ..."
                    try {
                        Update-CitizenFxIni -IniPath $IniPath -DeviceId $deviceId
                        Write-Ok
                    } catch {
                        Write-Fail
                        Write-Err2 "Could not update CitizenFX.ini: $($_.Exception.Message)"
                        return $null
                    }
                    return $deviceId
                }
            }
        } catch {
            # transient read/lock errors — keep polling
        }

        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    return $null
}

# ------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------
function Invoke-Main {
    Set-ConsoleTheme
    Write-Banner

    $fivemPath = Resolve-FiveMPath -OverridePath $FiveMPath
    if (-not $fivemPath) {
        Write-Err2 "FiveM Application Data not found."
        Write-Host "        If you installed FiveM to a custom location, re-run with:" -ForegroundColor DarkGray
        Write-Host "        .\install.ps1 -FiveMPath `"C:\Your\Custom\FiveM.app`"" -ForegroundColor DarkGray
        Wait-KeyIfInteractive
        return
    }

    $pluginsPath = Join-Path $fivemPath 'plugins'
    $iniPath     = Join-Path $fivemPath 'CitizenFX.ini'

    if (-not (Test-Path $pluginsPath)) {
        try {
            New-Item -ItemType Directory -Path $pluginsPath -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Err2 "Could not create plugins folder: $($_.Exception.Message)"
            Wait-KeyIfInteractive
            return
        }
    }

    # -- Safety: refuse to touch a locked dxgi.dll ------------------
    if (Test-GameRunning -Names $Config.ProcessNames) {
        $closed = Wait-ForGameExit -Names $Config.ProcessNames -MaxWaitSeconds 60
        if (-not $closed) {
            Write-Err2 "FiveM/GTA5 is still running. Please close it and re-run the installer."
            Wait-KeyIfInteractive
            return
        }
    }

    # -- Write-access sanity check (catches silent permission issues) --
    try {
        $canary = Join-Path $pluginsPath ".niran_write_test"
        [System.IO.File]::WriteAllText($canary, "test")
        Remove-Item $canary -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Err2 "No write access to '$pluginsPath'."
        Write-Host "        Try running PowerShell as Administrator, or check antivirus/folder permissions." -ForegroundColor DarkGray
        Wait-KeyIfInteractive
        return
    }

    # -- Step 1: Download & Deploy -----------------------------------
    Write-Step "[1/3] Downloading & Extracting core files ..."
    try {
        if (Test-Path $Config.TempExtract) { Remove-Item $Config.TempExtract -Recurse -Force -ErrorAction Stop }

        Get-RemoteFile -Url $Config.ZipUrl -Destination $Config.TempZip -Retries 3 | Out-Null
        Expand-Archive -Path $Config.TempZip -DestinationPath $Config.TempExtract -Force -ErrorAction Stop

        Install-ReshadeFiles -ExtractedRoot $Config.TempExtract -PluginsPath $pluginsPath -Config $Config

        Write-Ok
    } catch {
        Write-Fail
        Write-Err2 "Setup failed: $($_.Exception.Message)"
        Write-Host "        Check your internet connection and try again." -ForegroundColor DarkGray
        Wait-KeyIfInteractive
        return
    } finally {
        Remove-Item $Config.TempZip, $Config.TempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }

    # -- Step 2/3: Wait for FiveM log + patch ini --------------------
    $deviceId = Watch-ForDeviceId -FiveMPath $fivemPath -IniPath $iniPath -TimeoutSeconds $LogWaitTimeoutSeconds

    # -- Completion ---------------------------------------------------
    Write-Host ""
    Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray

    if ($deviceId) {
        Write-Host "  STATUS : " -NoNewline -ForegroundColor DarkGray
        Write-Host "SUCCESSFULLY INSTALLED" -ForegroundColor Green
        Write-Host "  NOTE   : Press 'Home' in-game to open the ReShade overlay." -ForegroundColor Gray
        Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host ""
        for ($i = 5; $i -gt 0; $i--) {
            Write-Host "`r  Closing in $i seconds..." -NoNewline -ForegroundColor DarkGray
            Start-Sleep -Seconds 1
        }
        Write-Host ""
    } else {
        Write-Host "  STATUS : " -NoNewline -ForegroundColor DarkGray
        Write-Host "TIMED OUT" -ForegroundColor Red
        Write-Host "  NOTE   : Files were installed, but the CitizenFX.ini crash-bypass" -ForegroundColor Gray
        Write-Host "           wasn't confirmed. Launch FiveM and re-run this installer." -ForegroundColor Gray
        Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
        Wait-KeyIfInteractive
    }
}

Invoke-Main
