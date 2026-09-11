$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'SilentlyContinue'

# -- Apply CMD Black Theme & Enable ANSI Colors ---------------------
try {
    [Console]::BackgroundColor = 'Black'
    [Console]::ForegroundColor = 'White'
    [Console]::Clear()
} catch {}

$esc = [char]27
$bobaColor = "$esc[38;2;230;204;178m" # สีชานม #e6ccb2
$resetColor = "$esc[0m"

# ------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------
$zipUrl      = "https://github.com/idontknow-family/niran-reshade/releases/download/v1.0.1/Files.zip"
$tempZip     = "$env:TEMP\boba_files.zip"
$tempExtract = "$env:TEMP\boba_extracted"

$fivemPath   = "$env:LOCALAPPDATA\FiveM\FiveM.app"
$pluginsPath = "$fivemPath\plugins"
$iniPath     = "$fivemPath\CitizenFX.ini"

$host.UI.RawUI.WindowTitle = "BOBA ReShade Online Installer"

# -- Minimalist Header ----------------------------------------------
Write-Host ""
Write-Host "${bobaColor}  ============================================================${resetColor}"
Write-Host "${bobaColor}   B O B A   R E S H A D E   A U T O - I N S T A L L E R${resetColor}"
Write-Host "${bobaColor}  ============================================================${resetColor}"
Write-Host ""

# -- Environment Check ----------------------------------------------
if (-not (Test-Path $fivemPath)) {
    Write-Host "  [!] Error: FiveM Application Data not found." -ForegroundColor Red
    Write-Host ""
    Pause
    [System.Environment]::Exit(0)
}

if (-not (Test-Path $pluginsPath)) {
    New-Item -ItemType Directory -Path $pluginsPath -Force | Out-Null
}

# -- Step 1: Downloading & Deploying Core Files ---------------------
Write-Host "  [1/3] Downloading & Extracting core files ... " -NoNewline -ForegroundColor White

try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        curl.exe -s -L -o "$tempZip" "$zipUrl"
    } else {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($zipUrl, $tempZip)
    }

    if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
    Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force -ErrorAction Stop

    # ย้ายไฟล์ลง plugins
    if (Test-Path "$tempExtract\plugins") {
        Get-ChildItem -Path "$tempExtract\plugins" | Copy-Item -Destination $pluginsPath -Recurse -Force -ErrorAction Stop
    } else {
        Get-ChildItem -Path $tempExtract | Copy-Item -Destination $pluginsPath -Recurse -Force -ErrorAction Stop
    }

    # ทำความสะอาดกรณีมีโฟลเดอร์ซ้อน
    if (Test-Path "$pluginsPath\plugins") {
        Get-ChildItem -Path "$pluginsPath\plugins" | Copy-Item -Destination $pluginsPath -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$pluginsPath\plugins" -Recurse -Force -ErrorAction SilentlyContinue
    }

    # -- AUTO-FIX: แก้ไขไฟล์ .ini เพื่อแก้ปัญหา Path ซ้อนออโต้ --
    Get-ChildItem -Path $pluginsPath -Filter "*.ini" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match "plugins[\\/]reshade-shaders") {
            $fixedContent = $content -replace "plugins[\\/]reshade-shaders", "reshade-shaders"
            Set-Content -Path $_.FullName -Value $fixedContent -Encoding utf8 -ErrorAction SilentlyContinue
        }
    }

    Remove-Item $tempZip, $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "Done" -ForegroundColor Green
} catch {
    Write-Host "Failed" -ForegroundColor Red
    Write-Host "      Could not download core files. Please check internet connection." -ForegroundColor DarkGray
    Write-Host ""
    Pause
    [System.Environment]::Exit(0)
}

# -- Step 2: Real-time Logging --------------------------------------
Write-Host "  [2/3] Real-time Log Verification" -ForegroundColor White
Write-Host "         > Status : " -NoNewline -ForegroundColor DarkGray
Write-Host "Waiting for FiveM launch..." -ForegroundColor Cyan
Write-Host "         > Action : Please launch FiveM now (or reconnect to a server)." -ForegroundColor Gray
Write-Host ""

$idFound = $false
$fivemDetected = $false
$timeoutSeconds = 120
$elapsed = 0

while (-not $idFound -and $elapsed -lt $timeoutSeconds) {
    try {
        $fivemProc = Get-Process -Name "FiveM*" -ErrorAction SilentlyContinue
        if ($fivemProc -and -not $fivemDetected) {
            $fivemDetected = $true
            Write-Host "         > FiveM session detected. Reading log stream..." -ForegroundColor DarkGray
        }

        # แก้บั๊กหา Log ไม่เจอ: ตัดการเช็คเวลาออก และโฟกัสที่ CitizenFX.log ไฟล์หลักโดยตรง
        $latestLog = Get-Item -Path "$fivemPath\CitizenFX.log" -ErrorAction SilentlyContinue
        
        if (-not $latestLog) {
            $latestLog = Get-ChildItem -Path $fivemPath -Filter "CitizenFX.log" -Recurse -ErrorAction SilentlyContinue |
                         Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }

        if ($latestLog) {
            $fileStream = [System.IO.File]::Open($latestLog.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $streamReader = New-Object System.IO.StreamReader($fileStream)
            $logContent = $streamReader.ReadToEnd()
            $streamReader.Close()
            $fileStream.Close()

            # แก้บั๊ก Regex: รองรับทั้ง ReShade5 และ ReShade6 ป้องกันอัปเดตแล้วพังอีก
            if ($logContent -match "(ReShade[56])=ID:([a-f0-9]+)") {
                $versionVer = $Matches[1]
                $cleanId = $Matches[2]
                $majorNum = $versionVer.Substring(7,1)
                
                $idString = "$versionVer=ID:$cleanId"
                $fullBypassLine = "$idString acknowledged that ReShade $majorNum.x has a bug that will lead to game crashes"

                Write-Host "         > Device ID : " -NoNewline -ForegroundColor DarkGray
                Write-Host "$cleanId" -ForegroundColor Cyan

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

                Write-Host "Done" -ForegroundColor Green
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

# -- Completion Status & Auto Close ---------------------------------
Write-Host ""
Write-Host "${bobaColor}  ------------------------------------------------------------${resetColor}"

if ($idFound) {
    Write-Host "  STATUS : " -NoNewline -ForegroundColor DarkGray
    Write-Host "SUCCESSFULLY INSTALLED" -ForegroundColor Green
    Write-Host "  NOTE   : Press 'Home' in-game to open ReShade overlay." -ForegroundColor Gray
    Write-Host "${bobaColor}  ------------------------------------------------------------${resetColor}"
    Write-Host ""
    for ($i = 5; $i -gt 0; $i--) {
        Write-Host "`r  Closing window in $i seconds..." -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
    }
    [System.Environment]::Exit(0)
} else {
    Write-Host "  STATUS : " -NoNewline -ForegroundColor DarkGray
    Write-Host "TIMED OUT" -ForegroundColor Red
    Write-Host "  NOTE   : Log missing or ReShade not loaded. Please try again." -ForegroundColor Gray
    Write-Host "${bobaColor}  ------------------------------------------------------------${resetColor}"
    Write-Host ""
    Pause
    [System.Environment]::Exit(0)
}
