$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'SilentlyContinue'

try {
    [Console]::BackgroundColor = 'Black'
    [Console]::ForegroundColor = 'White'
    [Console]::Clear()
} catch {}

# ------------------------------------------------------------------
# BOBA MILK TEA PALETTE (RGB ANSI CODES)
# ------------------------------------------------------------------
$esc        = [char]27
$cHeader    = "$esc[38;2;230;204;178m"  # ชานมพรีเมียม (#E6CCB2)
$cMain      = "$esc[38;2;221;184;146m"  # ชาไทยนมสด (#DDB892)
$cSub       = "$esc[38;2;166;138;110m"  # ไข่มุกบราวน์ซูการ์ (#A68A6E)
$cHighlight = "$esc[38;2;245;235;224m"  # ฟองนมนุ่มๆ (#F5EBE0)
$cSuccess   = "$esc[38;2;163;177;138m"  # ชาเขียวมัทฉะ (#A3B18A)
$cError     = "$esc[38;2;224;122;95m"   # ชาไทยส้มเข้ม (#E07A5F)
$reset      = "$esc[0m"

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
Write-Host "${cHeader}  ============================================================${reset}"
Write-Host "${cHeader}   B O B A   R E S H A D E   A U T O - I N S T A L L E R${reset}"
Write-Host "${cHeader}  ============================================================${reset}"
Write-Host ""

# -- Environment Check ----------------------------------------------
if (-not (Test-Path $fivemPath)) {
    Write-Host "  ${cError}[!] Error: FiveM Application Data not found.${reset}"
    Write-Host ""
    Pause
    [System.Environment]::Exit(0)
}

if (-not (Test-Path $pluginsPath)) {
    New-Item -ItemType Directory -Path $pluginsPath -Force | Out-Null
}

# -- Step 1: Downloading & Deploying Core Files ---------------------
Write-Host "  ${cMain}[1/3] Downloading & Extracting core files ... ${reset}" -NoNewline

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

    if (Test-Path "$tempExtract\plugins") {
        Get-ChildItem -Path "$tempExtract\plugins" | Copy-Item -Destination $pluginsPath -Recurse -Force -ErrorAction Stop
    } else {
        Get-ChildItem -Path $tempExtract | Copy-Item -Destination $pluginsPath -Recurse -Force -ErrorAction Stop
    }

    if (Test-Path "$pluginsPath\plugins") {
        Get-ChildItem -Path "$pluginsPath\plugins" | Copy-Item -Destination $pluginsPath -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$pluginsPath\plugins" -Recurse -Force -ErrorAction SilentlyContinue
    }

    Get-ChildItem -Path $pluginsPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    Get-ChildItem -Path $pluginsPath -Filter "*.ini" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match "plugins[\\/]reshade-shaders") {
            $fixedContent = $content -replace "plugins[\\/]reshade-shaders", "reshade-shaders"
            Set-Content -Path $_.FullName -Value $fixedContent -Encoding utf8 -ErrorAction SilentlyContinue
        }
    }

    Remove-Item $tempZip, $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "${cSuccess}Done${reset}"
} catch {
    Write-Host "${cError}Failed${reset}"
    Write-Host "      ${cSub}Could not download core files. Please check internet connection.${reset}"
    Write-Host ""
    Pause
    [System.Environment]::Exit(0)
}

# -- Step 2: Real-time Logging --------------------------------------
Write-Host "  ${cMain}[2/3] Real-time Log Verification${reset}"
Write-Host "          ${cSub}> Status : ${reset}${cHighlight}Waiting for FiveM launch...${reset}"
Write-Host "          ${cSub}> Action : Please launch FiveM now (or reconnect to a server).${reset}"
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
            Write-Host "          ${cSub}> FiveM session detected. Reading log stream...${reset}"
        }

        # ค้นหาไฟล์ Log รองรับรูปแบบ CitizenFX*.log ทุกกรณี
        $latestLog = Get-ChildItem -Path $fivemPath -Filter "*CitizenFX*.log" -Recurse -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending |
                     Select-Object -First 1

        if ($latestLog) {
            $fileStream = [System.IO.File]::Open($latestLog.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $streamReader = New-Object System.IO.StreamReader($fileStream)
            $logContent = $streamReader.ReadToEnd()
            $streamReader.Close()
            $fileStream.Close()

            # สแกนหา ReShade ID (รองรับทั้งเวอร์ชัน 5.x และ 6.x)
            if ($logContent -match "ReShade([0-9])=ID:([a-fA-F0-9]+)") {
                $majorVer = $Matches[1]
                $cleanId  = $Matches[2]
                $idString = "ReShade${majorVer}=ID:${cleanId}"
                $fullBypassLine = "$idString acknowledged that ReShade $majorVer.x has a bug that will lead to game crashes"

                Write-Host "          ${cSub}> Device ID : ${reset}${cHighlight}$cleanId${reset}"

                # -- Step 3: Patching CitizenFX.ini -----------------
                Write-Host ""
                Write-Host "  ${cMain}[3/3] Updating CitizenFX.ini ... ${reset}" -NoNewline

                if (Test-Path $iniPath) {
                    $iniContent = Get-Content $iniPath -Raw -ErrorAction SilentlyContinue
                    if ($iniContent -notmatch [regex]::Escape($idString)) {
                        if ($iniContent -notmatch "\[Addons\]") {
                            Add-Content -Path $iniPath -Value "`r`n[Addons]`r`n$fullBypassLine" -Encoding utf8 -ErrorAction SilentlyContinue
                        } else {
                            Add-Content -Path $iniPath -Value "`r`n$fullBypassLine" -Encoding utf8 -ErrorAction SilentlyContinue
                        }
                    }
                } else {
                    "[Addons]`r`n$fullBypassLine" | Set-Content -Path $iniPath -Encoding utf8 -ErrorAction SilentlyContinue
                }

                Write-Host "${cSuccess}Done${reset}"
                $idFound = $true
                break
            }
        }
    } catch {}

    Start-Sleep -Seconds 2
    $elapsed += 2
}

# -- Completion Status & Auto Close ---------------------------------
Write-Host ""
Write-Host "${cHeader}  ------------------------------------------------------------${reset}"

if ($idFound) {
    Write-Host "  ${cSub}STATUS : ${reset}${cSuccess}SUCCESSFULLY INSTALLED${reset}"
    Write-Host "  ${cSub}NOTE   : Press 'Home' in-game to open ReShade overlay.${reset}"
    Write-Host "${cHeader}  ------------------------------------------------------------${reset}"
    Write-Host ""
    for ($i = 5; $i -gt 0; $i--) {
        Write-Host "`r  ${cSub}Closing window in $i seconds...${reset}" -NoNewline
        Start-Sleep -Seconds 1
    }
    [System.Environment]::Exit(0)
} else {
    Write-Host "  ${cSub}STATUS : ${reset}${cError}TIMED OUT${reset}"
    Write-Host "  ${cSub}NOTE   : Log missing or ReShade not loaded. Please try again.${reset}"
    Write-Host "${cHeader}  ------------------------------------------------------------${reset}"
    Write-Host ""
    Pause
    [System.Environment]::Exit(0)
}
