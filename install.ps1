$ErrorActionPreference = 'SilentlyContinue'
$scriptStartTime = Get-Date

# ------------------------------------------------------------------
# CONFIGURATION (ใส่ URL ของไฟล์ zip บน GitHub ของคุณตรงนี้)
# ------------------------------------------------------------------
$zipUrl      = "https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/files.zip"
$tempZip     = "$env:TEMP\niran_files.zip"
$tempExtract = "$env:TEMP\niran_extracted"

$fivemPath   = "$env:LOCALAPPDATA\FiveM\FiveM.app"
$pluginsPath = "$fivemPath\plugins"
$iniPath     = "$fivemPath\CitizenFX.ini"

$host.UI.RawUI.WindowTitle = "Niran ReShade Online Installer"
Clear-Host

# -- Minimalist Header ----------------------------------------------
Write-Host ""
Write-Host "  NIRAN RESHADE " -NoNewline -ForegroundColor Cyan
Write-Host "| Online Auto-Installer" -ForegroundColor DarkGray
Write-Host "  ----------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# -- Environment Check ----------------------------------------------
if (-not (Test-Path $fivemPath)) {
    Write-Host "  [!] Error: FiveM Application Data not found." -ForegroundColor Red
    Write-Host ""
    Pause
    exit
}

if (-not (Test-Path $pluginsPath)) {
    New-Item -ItemType Directory -Path $pluginsPath -Force | Out-Null
}

# -- Step 1: Downloading & Deploying Core Files ---------------------
Write-Host "  [1/3] Downloading & Extracting core files ... " -NoNewline -ForegroundColor White

try {
    # 1. โหลดไฟล์ zip ลง Temp
    Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing -ErrorAction Stop

    # 2. แตกไฟล์ zip
    if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
    Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force -ErrorAction Stop

    # 3. ย้ายไฟล์เข้า plugins
    Get-ChildItem -Path $tempExtract | Copy-Item -Destination $pluginsPath -Recurse -Force -ErrorAction Stop

    # 4. ลบไฟล์ขยะใน Temp
    Remove-Item $tempZip, $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "Done" -ForegroundColor Cyan
} catch {
    Write-Host "Failed" -ForegroundColor Red
    Write-Host "      Could not download core files. Please check internet or GitHub URL." -ForegroundColor DarkGray
    Write-Host ""
    Pause
    exit
}

# -- Step 2: Real-time Logging --------------------------------------
Write-Host "  [2/3] Real-time Log Verification" -ForegroundColor White
Write-Host "        > Status: " -NoNewline -ForegroundColor DarkGray
Write-Host "Waiting for FiveM launch..." -ForegroundColor Cyan
Write-Host "        > Action: Please launch FiveM now." -ForegroundColor Gray
Write-Host ""

$idFound = $false
$fivemDetected = $false
$timeoutSeconds = 120
$elapsed = 0

while (-not $idFound -and $elapsed -lt $timeoutSeconds) {
    try {
        $fivemProc = Get-Process | Where-Object { $_.ProcessName -like "*FiveM*" } -ErrorAction SilentlyContinue
        if ($fivemProc -and -not $fivemDetected) {
            $fivemDetected = $true
            Write-Host "        > FiveM session detected. Reading log stream..." -ForegroundColor DarkGray
        }

        $latestLog = Get-ChildItem -Path $fivemPath -Filter "*CitizenFX*.log" -Recurse -ErrorAction SilentlyContinue |
                     Where-Object { $_.LastWriteTime -ge $scriptStartTime.AddSeconds(-5) } |
                     Sort-Object LastWriteTime -Descending |
                     Select-Object -First 1

        if ($latestLog) {
            $fileStream = [System.IO.File]::Open($latestLog.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $streamReader = New-Object System.IO.StreamReader($fileStream)
            $logContent = $streamReader.ReadToEnd()
            $streamReader.Close()
            $fileStream.Close()

            if ($logContent -match "ReShade5=ID:([a-f0-9]+)") {
                $idString = $Matches[0]
                $fullBypassLine = "$idString acknowledged that ReShade 5.x has a bug that will lead to game crashes"

                Write-Host "        > Unique Device ID: " -NoNewline -ForegroundColor DarkGray
                Write-Host "$idString" -ForegroundColor Cyan

                # -- Step 3: Patching CitizenFX.ini -----------------
                Write-Host ""
                Write-Host "  [3/3] Updating CitizenFX.ini ... " -NoNewline -ForegroundColor White

                if (Test-Path $iniPath) {
                    $iniContent = Get-Content $iniPath -Raw -ErrorAction SilentlyContinue
                    if ($iniContent -notmatch [regex]::Escape($idString)) {
                        if ($iniContent -notmatch "\[Addons\]") {
                            Add-Content -Path $iniPath -Value "`r`n[Addons]`r`n$fullBypassLine" -ErrorAction SilentlyContinue
                        } else {
                            Add-Content -Path $iniPath -Value "$fullBypassLine" -ErrorAction SilentlyContinue
                        }
                    }
                } else {
                    "[Addons]`r`n$fullBypassLine" | Set-Content -Path $iniPath -Encoding utf8 -ErrorAction SilentlyContinue
                }

                Write-Host "Done" -ForegroundColor Cyan
                $idFound = $true
                break
            }
        }
    } catch {
        # Catch lock errors
    }

    Start-Sleep -Seconds 2
    $elapsed += 2
}

# -- Completion Status ----------------------------------------------
Write-Host ""
Write-Host "  ----------------------------------------------------" -ForegroundColor DarkGray

if ($idFound) {
    Write-Host "  STATUS : " -NoNewline -ForegroundColor DarkGray
    Write-Host "SUCCESSFULLY INSTALLED" -ForegroundColor Cyan
    Write-Host "  NOTE   : Press 'Home' in-game to open ReShade overlay." -ForegroundColor Gray
} else {
    Write-Host "  STATUS : " -NoNewline -ForegroundColor DarkGray
    Write-Host "TIMED OUT" -ForegroundColor Red
    Write-Host "  NOTE   : Launch FiveM and rerun command." -ForegroundColor Gray
}

Write-Host "  ----------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Pause