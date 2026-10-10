# WinFlexSetupModern.ps1 - V4.1 Design
#Requires -Version 5.1

param(
    [switch]$SkipWelcome,
    [string]$MenuPath
)

Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue

$script:isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$scriptPath = $MyInvocation.MyCommand.Path

if (-not $scriptPath) {
    $script:scriptDir = $env:TEMP
} else {
    $script:scriptDir = Split-Path -Parent $scriptPath
}

if (-not $script:isAdmin) {
    if ($scriptPath) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", "`"$scriptPath`"") -WindowStyle Normal
    } else {
        $remoteCmd = "irm https://raw.githubusercontent.com/dor2500/WinFlexOS-Optimizer/master/WinFlexSetupModern.ps1 | iex"
        Start-Process powershell.exe -Verb RunAs -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-Command", $remoteCmd) -WindowStyle Normal
    }
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles() | Out-Null

$backgroundImagePath = "C:\MENU\Discovery+of+The+Lost+Vista+1+-+4K.jpg"
$audioPath = "C:\MENU\winflex.wav"
$script:LogPath = Join-Path $env:TEMP "winflex-setup.log"
function He([int[]]$codes){$s="";foreach($c in $codes){$s+=[char]$c};$s}

function Write-Log([string]$Message) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    try { Add-Content -Path $script:LogPath -Value "[$ts] $Message" -Encoding UTF8 } catch {}
}

$script:player = $null; $script:isMuted = $false
if (Test-Path -LiteralPath $audioPath) {
    try { $script:player = New-Object System.Media.SoundPlayer -ArgumentList $audioPath; $script:player.Load() } catch { $script:player = $null }
}
function Play-Sound { if ($script:player -and -not $script:isMuted) { try { $script:player.PlayLooping() } catch {} } }
function Toggle-Mute {
    if (-not $script:player) { return }
    if ($script:isMuted) { $script:isMuted = $false; try { $script:player.PlayLooping() } catch {} }
    else { $script:isMuted = $true; try { $script:player.Stop() } catch {} }
}

function Test-Winget { [bool](Get-Command winget -ErrorAction SilentlyContinue) }
function Install-Winget {
    if (Test-Winget) { return $true }
    $tmpDir = Join-Path $env:TEMP "winget-install"
    New-Item -ItemType Directory -Force -Path $tmpDir -ErrorAction SilentlyContinue | Out-Null
    $bundle = Join-Path $tmpDir "Microsoft.DesktopAppInstaller.msixbundle"
    try { (New-Object Net.WebClient).DownloadFile("https://aka.ms/getwinget", $bundle) } catch {}
    try { Add-AppxPackage -Path $bundle -ErrorAction SilentlyContinue | Out-Null } catch {}
    Start-Sleep -Seconds 2; return (Test-Winget)
}
function Invoke-WingetInstall([string]$Id, [bool]$IsExact=$true) {
    if ($IsExact) {
        $a = @("install","-e","--id",$Id,"--silent","--accept-package-agreements","--accept-source-agreements")
    } else {
        $a = @("install",$Id,"--silent","--accept-package-agreements","--accept-source-agreements")
    }
    $p = Start-Process -FilePath "winget" -ArgumentList $a -PassThru -Wait -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "winget failed for $Id (ExitCode=$($p.ExitCode))" }
}

# ===== ADDED HARDWARE AUDIT & TWEAKS =====
function Get-SystemHardwareAudit {
    $systemEnclosure = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue
    $chassisTypes = $systemEnclosure.ChassisTypes
    $batteryCheck = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    
    $laptopChassisCodes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $script:IsLaptop = if ($batteryCheck) { $true } else { $false }
    if (-not $script:IsLaptop) {
        foreach ($c in $chassisTypes) { if ($laptopChassisCodes -contains $c) { $script:IsLaptop = $true; break } }
    }
    
    $formFactorName = if ($script:IsLaptop) { "Laptop" } else { "Desktop" }
    $osInfo = Get-CimInstance Win32_OperatingSystem
    $isWin11 = $osInfo.BuildNumber -ge 22000
    $osName = if ($isWin11) { "Windows 11" } else { "Windows 10" }

    $script:cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $baseboard = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    
    $ramSticks = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue
    $script:totalRamGB = [math]::Round((($ramSticks | Measure-Object -Property Capacity -Sum).Sum) / 1GB, 2)
    $script:gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
    $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    
    $script:hasSSD = $false
    foreach ($d in $disks) {
        if ($d.MediaType -eq "SSD" -or $d.BusType -eq "NVMe") { $script:hasSSD = $true }
    }
    
    $auditText = "System: $osName (Build $($osInfo.BuildNumber)) - $formFactorName`n"
    $auditText += "Model: $($computerSystem.Manufacturer) $($computerSystem.Model)`n"
    $auditText += "CPU: $($script:cpu.Name)`n"
    $auditText += "RAM: $($script:totalRamGB) GB`n"
    if ($script:gpus) {
        $auditText += "GPU(s): " + (($script:gpus | ForEach-Object { $_.Name }) -join ", ") + "`n"
    }
    $auditText += "SSD Detected: $script:hasSSD"
    
    return $auditText
}

function Invoke-ExtremeDebloat {
    Write-Host "`n[*] Performing EXTREME System Debloat & Privacy Lock-Down..." -ForegroundColor Red
    Start-Sleep -Seconds 1
    
    # 1. Telemetry Services
    Write-Host " [~] Shredding Microsoft Telemetry Services..." -ForegroundColor DarkGray
    $telemetryServices = @("DiagTrack", "dmwappushservice", "WerSvc", "WaaSMedicSvc")
    foreach ($svc in $telemetryServices) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    }
    
    # 2. Cortana & Web Search
    Write-Host " [~] Nuking Cortana and Start Menu Web Search..." -ForegroundColor DarkGray
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "DisableWebSearch" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # 3. Privacy & Activity Tracking
    Write-Host " [~] Disabling Location, Activity Timeline, and Ad ID..." -ForegroundColor DarkGray
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "PublishUserActivities" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Name "DisableLocation" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # 4. Delivery Optimization
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # 5. Explorer Quality of Life (Show Extensions)
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # 6. SysMain (SuperFetch) for SSDs
    if ($script:hasSSD) {
        Write-Host " [~] SSD Detected: Disabling SysMain (SuperFetch)..." -ForegroundColor DarkGray
        Stop-Service -Name "SysMain" -Force -ErrorAction SilentlyContinue
        Set-Service -Name "SysMain" -StartupType Disabled -ErrorAction SilentlyContinue
    }
    
    # 7. UWP Bloatware
    Write-Host " [~] Purging UWP Bloatware Apps..." -ForegroundColor DarkGray
    $bloatware = @(
        "Microsoft.BingNews", "Microsoft.MicrosoftSolitaireCollection", "Microsoft.NetworkSpeedTest",
        "Microsoft.SkypeApp", "Microsoft.WindowsFeedbackHub", "Microsoft.ZuneVideo", "Microsoft.ZuneMusic",
        "SpotifyAB.SpotifyMusic", "Clipchamp.Clipchamp", "Microsoft.Todos", "Microsoft.YourPhone", "Microsoft.MixedReality.Portal", "Microsoft.GetHelp"
    )
    foreach ($app in $bloatware) {
        Get-AppxPackage -Name "*$app*" -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
}

function Invoke-ForensicDeepScan {
    Write-Host "`n[*] ========================================================" -ForegroundColor Magenta
    Write-Host "    🕵️ INITIATING FORENSIC DEEP SCAN (Estimated Time: 5-10 Minutes)" -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Magenta
    
    $reportPath = Join-Path $env:USERPROFILE "Desktop\Forensic_System_Report.txt"
    Write-Host "[!] A detailed forensic report will be saved to: $reportPath" -ForegroundColor Yellow
    "========================================================" | Out-File $reportPath -Encoding utf8
    " FORENSIC SYSTEM REPORT - $(Get-Date)" | Out-File $reportPath -Append -Encoding utf8
    "========================================================" | Out-File $reportPath -Append -Encoding utf8
    
    # 1. Driver Forensic Scan
    Write-Host "`n[~] 1/4 Scanning EVERY installed driver in the system..." -ForegroundColor Cyan
    "--- DRIVER AUDIT ---" | Out-File $reportPath -Append -Encoding utf8
    $drivers = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue
    $totalDrivers = $drivers.Count
    $dCount = 0
    foreach ($drv in $drivers) {
        $dCount++
        if ($dCount % 5 -eq 0) { Write-Progress -Activity "Scanning Drivers" -Status "$dCount / $totalDrivers" -PercentComplete (($dCount/$totalDrivers)*100) }
        $line = "Driver: $($drv.DeviceName) | Provider: $($drv.ProviderName) | Version: $($drv.DriverVersion) | Class: $($drv.DeviceClass) | Path: $($drv.Location)"
        $line | Out-File $reportPath -Append -Encoding utf8
    }
    Write-Progress -Activity "Scanning Drivers" -Completed
    Write-Host "    [✓] Scanned $totalDrivers active hardware drivers." -ForegroundColor Green
    
    # 2. Third Party / OEM Drivers (Driver Store)
    Write-Host "[~] 2/4 Analyzing Driver Store (OEM & 3rd Party Registry)..." -ForegroundColor Cyan
    "--- DRIVER STORE (OEM) ---" | Out-File $reportPath -Append -Encoding utf8
    pnputil /enum-drivers | Out-File $reportPath -Append -Encoding utf8
    
    # 3. Deep Folder & EXTREME REGISTRY Scan (Background Job)
    Write-Host "[~] 3/4 Launching Massive Registry & File Scan in the BACKGROUND..." -ForegroundColor Red
    Write-Host "    [!] This runs in the background so the console won't freeze. You will see a spinner." -ForegroundColor Yellow
    "--- FORENSIC REGISTRY & FILE SCAN ---" | Out-File $reportPath -Append -Encoding utf8
    
    $jobScript = {
        $aiExts = @(".safetensors", ".pt", ".bin", ".onnx", ".gguf", ".ckpt")
        $jnkExts = @(".tmp", ".log", ".dmp", ".bak")
        $aiFiles = [System.Collections.Generic.List[string]]::new()
        $junkSize = 0
        
        # Files
        $tDirs = @("$env:USERPROFILE", "C:\ProgramData", "C:\Program Files", "C:\Program Files (x86)")
        foreach ($d in $tDirs) {
            if (Test-Path $d) {
                $files = Get-ChildItem -Path $d -File -Recurse -Force -ErrorAction SilentlyContinue
                foreach ($f in $files) {
                    if ($aiExts -contains $f.Extension) { $aiFiles.Add("$($f.FullName) ($([math]::Round($f.Length/1MB, 2)) MB)") }
                    if ($jnkExts -contains $f.Extension) { $junkSize += $f.Length }
                }
            }
        }
        
        # Deep Recursive Registry Scan
        $suspiciousKeys = [System.Collections.Generic.List[string]]::new()
        $terms = @(
            "Telemetry", "Tracking", "Advertising", "Cortana", "DiagTrack",
            "GameDVR", "OneDrive", "Skype", "MixedReality", "YourPhone",
            "NewsAndInterests", "Widgets", "MapsBroker", "PeopleExperienceHost",
            "EdgePrelaunch", "PrintSpooler", "Fax"
        )
        $hives = @("HKCU:\Software", "HKLM:\SOFTWARE")
        foreach ($hive in $hives) {
            $allKeys = Get-ChildItem -Path $hive -Recurse -ErrorAction SilentlyContinue
            foreach ($k in $allKeys) {
                foreach ($t in $terms) {
                    if ($k.Name -match $t) {
                        $suspiciousKeys.Add("Found Bloat/Tracker Key ($t): $($k.Name)")
                        break
                    }
                }
            }
        }
        
        return @{ Ai = $aiFiles; Junk = $junkSize; Reg = $suspiciousKeys }
    }
    
    $job = Start-Job -ScriptBlock $jobScript
    $spinner = @('|', '/', '-', '\')
    $c = 0
    while ($job.State -eq 'Running') {
        Write-Host -NoNewline "`r    $($spinner[$c % 4]) Deep Scanning Registry & Files... (Running in Background)" -ForegroundColor Cyan
        $c++
        Start-Sleep -Milliseconds 100
    }
    Write-Host "`r    [✓] Background Registry & File Scan Completed!                     " -ForegroundColor Green
    
    $jobRes = Receive-Job -Job $job
    Remove-Job -Job $job
    
    $aiFiles = $jobRes.Ai
    $junkSize = $jobRes.Junk
    $suspiciousKeys = $jobRes.Reg
    
    # 4. Applications and Packages
    Write-Host "[~] 4/4 Extracting all installed software & deep Appx packages..." -ForegroundColor Cyan
    "--- INSTALLED SOFTWARE ---" | Out-File $reportPath -Append -Encoding utf8
    Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue | Select-Object DisplayName, DisplayVersion, InstallLocation | Out-File $reportPath -Append -Encoding utf8
    Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue | Select-Object DisplayName, DisplayVersion, InstallLocation | Out-File $reportPath -Append -Encoding utf8
    
    "--- UWP APPX PACKAGES ---" | Out-File $reportPath -Append -Encoding utf8
    Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Select-Object Name, PackageFullName, InstallLocation | Out-File $reportPath -Append -Encoding utf8
    
    # Finalize Report
    "--- SCAN SUMMARY ---" | Out-File $reportPath -Append -Encoding utf8
    "Total Drivers Audited: $totalDrivers" | Out-File $reportPath -Append -Encoding utf8
    
    "Found Suspicious Registry Keys ($($suspiciousKeys.Count)):" | Out-File $reportPath -Append -Encoding utf8
    foreach ($sk in $suspiciousKeys) { $sk | Out-File $reportPath -Append -Encoding utf8 }
    
    "Identified AI/ML Model Files ($($aiFiles.Count)):" | Out-File $reportPath -Append -Encoding utf8
    foreach ($ai in $aiFiles) { $ai | Out-File $reportPath -Append -Encoding utf8 }
    "Total Identifiable Junk/Temp/Dump Size: $([math]::Round($junkSize/1GB, 2)) GB" | Out-File $reportPath -Append -Encoding utf8
    
    Write-Host "`n[+] FORENSIC SCAN COMPLETE!" -ForegroundColor Green
    Write-Host "    - Found $($suspiciousKeys.Count) telemetry/tracking keys in the Registry." -ForegroundColor Green
    Write-Host "    - Found $($aiFiles.Count) AI Models / Weights on disk." -ForegroundColor Green
    Write-Host "    - Found $([math]::Round($junkSize/1GB, 2)) GB of Temp/Log/Dump Junk files." -ForegroundColor Green
    Write-Host "    - Full detailed report saved to: $reportPath" -ForegroundColor Yellow
    
    Start-Sleep -Seconds 5
}

# ===== PORTED FROM HardwareAuditAndPrivacy.ps1 (GUI-friendly: output goes to log + Desktop report) =====
function Invoke-HardwareAuditReport {
    if ($null -eq $script:hasSSD) { Get-SystemHardwareAudit | Out-Null }
    $reportPath = Join-Path $env:USERPROFILE "Desktop\Hardware_Audit_Report.txt"
    $r = New-Object System.Collections.Generic.List[string]
    $r.Add("HARDWARE AUDIT REPORT - $(Get-Date)")
    $r.Add("==========================================")
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    $r.Add("OS: $($os.Caption) (Build $($os.BuildNumber))  |  Form factor: $(if($script:IsLaptop){'Laptop'}else{'Desktop'})")
    $r.Add("Model: $($cs.Manufacturer) - $($cs.Model)")
    $r.Add("Motherboard: $($bb.Manufacturer) $($bb.Product) (BIOS: $($bios.SMBIOSBIOSVersion))")
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $r.Add("CPU: $($cpu.Name) - $($cpu.NumberOfCores) Cores / $($cpu.NumberOfLogicalProcessors) Threads | $($cpu.MaxClockSpeed) MHz | Virtualization: $($cpu.VirtualizationFirmwareEnabled)")
    $sticks = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue
    $r.Add("RAM: $($script:totalRamGB) GB")
    $n = 1; foreach ($s in $sticks) { $r.Add("  - Stick $($n): $([math]::Round($s.Capacity/1GB,1)) GB @ $($s.ConfiguredClockSpeed) MHz ($($s.Manufacturer))"); $n++ }
    $r.Add("GPU(s):")
    foreach ($g in (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
        $vram = if ($g.AdapterRAM -gt 0) { "$([math]::Round($g.AdapterRAM/1GB,2)) GB VRAM" } else { "Shared RAM" }
        $r.Add("  - $($g.Name) [$vram] Driver: $($g.DriverVersion)")
    }
    $r.Add("Storage / Health (S.M.A.R.T):")
    foreach ($d in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $h = if ($d.HealthStatus -eq "Healthy") { "[Healthy]" } else { "[WARNING]" }
        $r.Add("  - $($d.FriendlyName): $([math]::Round($d.Size/1GB,1)) GB | $($d.MediaType) $($d.BusType) | $h ($($d.OperationalStatus))")
    }
    $r.Add("Network:")
    foreach ($nic in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" })) {
        $r.Add("  - $($nic.Name) ($($nic.InterfaceDescription)) Link: $($nic.LinkSpeed)")
    }
    try { $p = Test-Connection -ComputerName 8.8.8.8 -Count 1 -ErrorAction Stop; $ms = if ($p.ResponseTime) { $p.ResponseTime } else { $p.Latency }; $r.Add("  - Ping 8.8.8.8: $ms ms") } catch { $r.Add("  - Ping 8.8.8.8: failed") }
    $r | Out-File $reportPath -Encoding utf8
    foreach ($line in $r) { Write-Log $line }
    Write-Log "Hardware audit report saved to: $reportPath"
}

function Invoke-RestorePointSafe {
    try {
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue | Out-Null
        Checkpoint-Computer -Description "WinFlexOS - Before tweaks" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Write-Log "Restore point created."
    } catch { Write-Log "Restore point skipped: $($_.Exception.Message)" }
}

function Invoke-PrivacyLockdown {
    foreach ($svc in @("DiagTrack", "dmwappushservice", "WerSvc")) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    }
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "DisableWebSearch" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    New-Item -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "PublishUserActivities" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Name "DisableLocation" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Log "Privacy lock-down applied (telemetry, Cortana/web search, activity, location, ad ID, delivery optimization)."
}

function Invoke-BloatRemoval {
    $bloatware = @(
        "Microsoft.BingNews", "Microsoft.MicrosoftSolitaireCollection", "Microsoft.NetworkSpeedTest",
        "Microsoft.SkypeApp", "Microsoft.WindowsFeedbackHub", "Microsoft.ZuneVideo", "Microsoft.ZuneMusic",
        "SpotifyAB.SpotifyMusic", "Clipchamp.Clipchamp", "Microsoft.Todos", "Microsoft.YourPhone", "Microsoft.MixedReality.Portal", "Microsoft.GetHelp"
    )
    foreach ($app in $bloatware) {
        Get-AppxPackage -Name "*$app*" -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    }
    Write-Log "Bloatware UWP apps removed."
}

function Invoke-NetworkLatencyTune {
    try { netsh int tcp set global heuristics=disabled | Out-Null; netsh int tcp set global autotuninglevel=normal | Out-Null } catch {}
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 0xFFFFFFFF -Type DWord -Force -ErrorAction SilentlyContinue
    Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match "Large Send Offload" } | Set-NetAdapterAdvancedProperty -RegistryValue "0" -ErrorAction SilentlyContinue
    Write-Log "Network tuned: TCP heuristics off, throttling removed, LSO disabled."
}

function Invoke-UndoTweaks {
    foreach ($svc in @("DiagTrack", "dmwappushservice", "WerSvc")) { Set-Service -Name $svc -StartupType Manual -ErrorAction SilentlyContinue }
    Remove-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "DisableWebSearch" -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 10 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 20 -Type DWord -Force -ErrorAction SilentlyContinue
    netsh int tcp set global heuristics=enabled | Out-Null
    netsh int tcp set global autotuninglevel=normal | Out-Null
    bcdedit /deletevalue disabledynamictick 2>$null | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "1" -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "6" -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "10" -Type String -Force -ErrorAction SilentlyContinue
    powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e
    Write-Log "UNDO complete: defaults restored (services, search, gaming, network, mouse, power plan)."
}
# ===== END PORTED FUNCTIONS =====

function Invoke-SystemTweak($tweakId) {
    if ($null -eq $script:hasSSD) { Get-SystemHardwareAudit | Out-Null }
    
    switch ($tweakId) {
        "ExtremeDebloat" {
            Invoke-ExtremeDebloat
        }
        "HardwareAudit" { Invoke-HardwareAuditReport }
        "RestorePoint"  { Invoke-RestorePointSafe }
        "PrivacyLock"   { Invoke-PrivacyLockdown }
        "BloatRemoval"  { Invoke-BloatRemoval }
        "NetworkTune"   { Invoke-NetworkLatencyTune }
        "UndoAll"       { Invoke-UndoTweaks }
        "ForensicScan" {
            Invoke-ForensicDeepScan
        }
        "ProfileGaming" {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            if ($script:totalRamGB -ge 16) {
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 0xFFFFFFFF -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            }
            try { netsh int tcp set global heuristics=disabled | Out-Null; netsh int tcp set global autotuninglevel=normal | Out-Null } catch {}
            try { bcdedit /deletevalue useplatformclock 2>$null | Out-Null; bcdedit /set disabledynamictick yes 2>$null | Out-Null } catch {}
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "0" -Type String -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "0" -Type String -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "0" -Type String -Force -ErrorAction SilentlyContinue
            if (-not $script:IsLaptop) {
                powercfg -attributes SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 -ATTRIB_HIDE 2>$null | Out-Null
                $uGuid = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
                if ($uGuid -match "([A-Fa-f0-9\-]{36})") { powercfg -setactive $matches[1] } else { powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }
            }
        }
        "ProfileOffice" {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e
        }
        "ProfileCreator" {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 20 -Type DWord -Force -ErrorAction SilentlyContinue
            if (-not $script:IsLaptop) { powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }
        }
        "ProfileAI" {
            # AI & MACHINE LEARNING
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 10 -Type DWord -Force -ErrorAction SilentlyContinue
            if (-not $script:IsLaptop) {
                powercfg -attributes SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 -ATTRIB_HIDE 2>$null | Out-Null
                $uGuid = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
                if ($uGuid -match "([A-Fa-f0-9\-]{36})") { powercfg -setactive $matches[1] } else { powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }
            }
            Write-Log "AI Profile applied: Long Paths, Ultimate Power, System Responsiveness adjusted."
            
            # Massive AI Scan in Log
            Write-Log "--- MASSIVE AI SYSTEM DIAGNOSTIC ---"
            $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
            Write-Log "CPU: $($cpu.Name) | Cores: $($cpu.NumberOfCores) | Threads: $($cpu.NumberOfLogicalProcessors) | L3: $($cpu.L3CacheSize)MB"
            $mem = Get-CimInstance Win32_PhysicalMemory
            $totalMem = [math]::Round((($mem | Measure-Object -Property Capacity -Sum).Sum) / 1GB, 2)
            Write-Log "RAM: $totalMem GB"
            $nvSmi = (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue).Source
            if ($nvSmi) {
                try {
                    $smiOut = & $nvSmi --query-gpu=name,memory.total,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
                    Write-Log "NVIDIA: $smiOut"
                } catch {}
            }
            $disks = Get-CimInstance Win32_LogicalDisk | Where-Object DriveType -eq 3
            foreach ($d in $disks) {
                $free = [math]::Round($d.FreeSpace / 1GB, 1)
                $tot = [math]::Round($d.Size / 1GB, 1)
                Write-Log "Drive $($d.DeviceID) | Free: $free GB / $tot GB"
            }
            $tools = @("python", "git", "docker", "wsl", "ollama", "node", "cmake", "conda", "nvcc")
            foreach ($tool in $tools) {
                $path = (Get-Command $tool -ErrorAction SilentlyContinue).Source
                if ($path) { Write-Log "Found $tool at $path" } else { Write-Log "$tool not found" }
            }
            Write-Log "--- END DIAGNOSTIC ---"
        }
        "SSDOptimize" {
            if ($script:hasSSD) {
                fsutil behavior set DisableDeleteNotify 0 | Out-Null
                Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
}
# ==========================================

# # -------- Software Lists (Loaded Dynamically) --------
# The software lists ($browsers, etc.) and $script:Categories are loaded dynamically from GitHub during the Preflight check.

$script:Lang = "he"
function L([string]$he, [string]$en) { if ($script:Lang -eq "he") { $he } else { $en } }

$script:Themes = @(
    @{ Name="Cosmic (Video)"; Bg="#AA040209"; Sidebar="#88080414"; Card="#66100520"; Card2="#440A0214"; Fg="#FFFFFF"; Sub="#A296D4"; Accent="#B122E5"; Border="#55442266" },
    @{ Name="Neon Cyan";    Bg="#0F0F0F"; Sidebar="#141414"; Card="#1E1E1E"; Card2="#181818"; Fg="#FFFFFF"; Sub="#B0B0B0"; Accent="#00BFFF"; Border="#2A2A2A" },
    @{ Name="Tokyo Night";  Bg="#1A1B26"; Sidebar="#16161E"; Card="#24283B"; Card2="#1F2335"; Fg="#C0CAF5"; Sub="#787C99"; Accent="#7AA2F7"; Border="#2A3240" }
)
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinFlexOS Setup" WindowStyle="None" ResizeMode="CanResize" WindowState="Maximized"
        AllowsTransparency="True" Background="Transparent" FontFamily="Bahnschrift, Segoe UI, sans-serif" FontSize="14">
  <Window.Resources>
    <SolidColorBrush x:Key="ThemeBg" Color="#0F0F0F"/><SolidColorBrush x:Key="ThemeSidebar" Color="#141414"/>
    <SolidColorBrush x:Key="ThemeCard" Color="#1E1E1E"/><SolidColorBrush x:Key="ThemeCard2" Color="#181818"/>
    <SolidColorBrush x:Key="ThemeFg" Color="#FFFFFF"/><SolidColorBrush x:Key="ThemeSub" Color="#B0B0B0"/>
    <SolidColorBrush x:Key="ThemeBorder" Color="#2A2A2A"/><SolidColorBrush x:Key="ThemeAccent" Color="#00BFFF"/>
    <CornerRadius x:Key="Rxl">22</CornerRadius><CornerRadius x:Key="Rl">18</CornerRadius>
    <CornerRadius x:Key="Rm">14</CornerRadius><CornerRadius x:Key="Rs">10</CornerRadius>
    <DropShadowEffect x:Key="CardShadow" BlurRadius="20" ShadowDepth="5" Direction="270" Color="Black" Opacity="0.2"/>
    <DropShadowEffect x:Key="SoftGlow" BlurRadius="25" ShadowDepth="0" Color="#B122E5" Opacity="0.7"/>
    <Style TargetType="ScrollBar"><Setter Property="Background" Value="Transparent"/><Setter Property="Width" Value="8"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Grid x:Name="G" Width="8" Background="Transparent"><Track x:Name="PART_Track" IsDirectionReversed="true"><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
          <Border x:Name="T" Background="#55888888" CornerRadius="4"/>
          <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="{DynamicResource ThemeAccent}"/></Trigger>
          <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Background" Value="{DynamicResource ThemeFg}"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track></Grid>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="G" Property="Width" Value="12"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter></Style>
    <Style TargetType="ComboBox"><Setter Property="Foreground" Value="{DynamicResource ThemeFg}"/><Setter Property="Background" Value="{DynamicResource ThemeCard}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource ThemeBorder}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Height" Value="32"/><Setter Property="FontSize" Value="14"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox"><Grid>
        <ToggleButton Name="ToggleButton" Focusable="false" IsChecked="{Binding Path=IsDropDownOpen,Mode=TwoWay,RelativeSource={RelativeSource TemplatedParent}}" ClickMode="Press">
          <ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="{DynamicResource ThemeCard}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="6">
            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="20"/></Grid.ColumnDefinitions>
            <Path Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center" Fill="{DynamicResource ThemeSub}" Data="M 0 0 L 4 4 L 8 0 Z"/></Grid>
          </Border></ControlTemplate></ToggleButton.Template></ToggleButton>
        <ContentPresenter Name="ContentSite" IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" Margin="10,0,23,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
        <Popup Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
          <Grid MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}"><Border Background="{DynamicResource ThemeCard}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="6"/>
            <ScrollViewer Margin="4,6" SnapsToDevicePixels="True"><StackPanel IsItemsHost="True"/></ScrollViewer></Grid></Popup>
      </Grid></ControlTemplate></Setter.Value></Setter></Style>
    <Style TargetType="ComboBoxItem"><Setter Property="Foreground" Value="{DynamicResource ThemeFg}"/><Setter Property="Background" Value="{DynamicResource ThemeCard}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
        <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="5" CornerRadius="4"><ContentPresenter/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource ThemeAccent}"/><Setter Property="Foreground" Value="White"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource ThemeBorder}"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
    <Style x:Key="WinCtrlBtn" TargetType="Button"><Setter Property="Width" Value="45"/><Setter Property="Height" Value="35"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#AAAAAA"/><Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="12"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#22888888"/><Setter Property="Foreground" Value="{DynamicResource ThemeFg}"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
    <Style x:Key="CloseBtn" TargetType="Button"><Setter Property="Width" Value="45"/><Setter Property="Height" Value="35"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#AAAAAA"/><Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="12"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="0,12,0,0"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#E81123"/><Setter Property="Foreground" Value="White"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
    <Style x:Key="PrimaryBtn" TargetType="Button"><Setter Property="Background" Value="{DynamicResource ThemeCard}"/><Setter Property="Foreground" Value="{DynamicResource ThemeFg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource ThemeAccent}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="{StaticResource Rs}" RenderTransformOrigin="0.5,0.5">
          <Border.RenderTransform><ScaleTransform x:Name="PS" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/></Border>
        <ControlTemplate.Triggers>
          <EventTrigger RoutedEvent="MouseEnter"><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="PS" Storyboard.TargetProperty="ScaleX" To="1.06" Duration="0:0:0.15"/><DoubleAnimation Storyboard.TargetName="PS" Storyboard.TargetProperty="ScaleY" To="1.06" Duration="0:0:0.15"/></Storyboard></BeginStoryboard></EventTrigger>
          <EventTrigger RoutedEvent="MouseLeave"><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="PS" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.2"/><DoubleAnimation Storyboard.TargetName="PS" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.2"/></Storyboard></BeginStoryboard></EventTrigger>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource ThemeAccent}"/><Setter TargetName="Bd" Property="BorderBrush" Value="Transparent"/><Setter Property="Foreground" Value="White"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
    <Style x:Key="SidebarBtn" TargetType="Button"><Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="{DynamicResource ThemeSub}"/>
      <Setter Property="Height" Value="40"/><Setter Property="FontSize" Value="14"/><Setter Property="Margin" Value="4,0"/><Setter Property="Padding" Value="16,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="20" Padding="{TemplateBinding Padding}">
          <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="Ic" Grid.Column="0" FontFamily="Segoe MDL2 Assets" FontSize="16" Text="{TemplateBinding Tag}" Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ContentPresenter Grid.Column="1" VerticalAlignment="Center" HorizontalAlignment="Center"/></Grid></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource ThemeCard}"/><Setter Property="Foreground" Value="{DynamicResource ThemeFg}"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  </Window.Resources>
  <Grid>
    <Grid>
      <Rectangle>
        <Rectangle.Fill>
          <RadialGradientBrush Center="0.5,0.5" RadiusX="1.2" RadiusY="1.2">
            <GradientStop Color="#0B0515" Offset="0"/>
            <GradientStop Color="#020105" Offset="1"/>
          </RadialGradientBrush>
        </Rectangle.Fill>
      </Rectangle>
      <!-- Orbs -->
      <Ellipse Width="1000" Height="1000" Margin="-400,-400,0,0" HorizontalAlignment="Left" VerticalAlignment="Top" IsHitTestVisible="False">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#220066FF" Offset="0"/><GradientStop Color="#00000000" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <Ellipse Width="1200" Height="1200" Margin="0,0,-500,-500" HorizontalAlignment="Right" VerticalAlignment="Bottom" IsHitTestVisible="False">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#22B122E5" Offset="0"/><GradientStop Color="#00000000" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <Image x:Name="BgImage" Stretch="UniformToFill" Opacity="0.1"/>
    </Grid>
    <Border x:Name="MainBorder" Background="{DynamicResource ThemeBg}" CornerRadius="{StaticResource Rxl}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" Margin="30,20" Effect="{StaticResource CardShadow}" Visibility="Collapsed" MaxWidth="1200" MaxHeight="850">
      <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Border Grid.Row="0" Background="{DynamicResource ThemeSidebar}" CornerRadius="22,22,0,0" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="0,0,0,1">
          <Grid Margin="20,15"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,30,0">
               <TextBlock x:Name="SideSub" Visibility="Collapsed"/><TextBlock x:Name="SideFooter" Visibility="Collapsed"/>
               <Border Width="36" Height="36" CornerRadius="10" Background="{DynamicResource ThemeAccent}" HorizontalAlignment="Center" Margin="0,0,10,0" Effect="{StaticResource SoftGlow}">
                 <TextBlock Text="&#xE7F4;" FontFamily="Segoe MDL2 Assets" FontSize="18" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
               <TextBlock FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"><Run Text="Win" Foreground="White"/><Run Text="Flex" Foreground="{DynamicResource ThemeAccent}"/><Run Text="OS" Foreground="White"/></TextBlock></StackPanel>
            <ScrollViewer Grid.Column="1" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled" VerticalAlignment="Center" Margin="0,0,20,0">
              <StackPanel x:Name="SideMenu" Orientation="Horizontal"/></ScrollViewer>
            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
              <ComboBox x:Name="CmbTheme" Width="170" Height="30" Margin="0,0,8,0" Padding="8,4"/>
              <Button x:Name="BtnLang" Content="EN" Margin="0,0,4,0" Width="40" Height="30" FontSize="12" Foreground="{DynamicResource ThemeSub}" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
              <Button x:Name="BtnMute" Content="Mute" Margin="0,0,4,0" Width="40" Height="30" FontSize="12" Foreground="{DynamicResource ThemeSub}" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
              <Button x:Name="BtnMin" Content="&#xE921;" Style="{StaticResource WinCtrlBtn}" Width="30" Height="30" FontSize="10"/>
              <Button x:Name="BtnMax" Content="&#xE922;" Style="{StaticResource WinCtrlBtn}" Width="30" Height="30" FontSize="10"/>
              <Button x:Name="BtnClose" Content="&#xE8BB;" Style="{StaticResource CloseBtn}" Width="30" Height="30" FontSize="10"/></StackPanel></Grid></Border>
        <Grid x:Name="MainArea" Grid.Row="1" Margin="30,20" IsEnabled="False" Opacity="0.6">
           <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
             <Grid Grid.Row="0" Margin="0,0,0,20"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
               <StackPanel><TextBlock x:Name="TopTitle" Visibility="Collapsed"/><TextBlock x:Name="TopSub" Visibility="Collapsed"/>
                 <TextBlock x:Name="PageTitle" Text="Welcome" Foreground="{DynamicResource ThemeFg}" FontSize="28" FontWeight="SemiBold"/>
                 <TextBlock x:Name="PageDesc" Text="Select" Foreground="{DynamicResource ThemeSub}" FontSize="14" Margin="0,4,0,0" TextWrapping="Wrap"/></StackPanel>
               <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Bottom">
                 <Button x:Name="BtnSelectAll" Content="Select All" Padding="16,8" Margin="0,0,10,0" FontSize="13" Background="Transparent" Foreground="{DynamicResource ThemeAccent}" BorderBrush="{DynamicResource ThemeAccent}" BorderThickness="1" Cursor="Hand"/>
                 <Button x:Name="BtnDeselectAll" Content="Deselect" Padding="16,8" FontSize="13" Background="Transparent" Foreground="{DynamicResource ThemeSub}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" Cursor="Hand"/></StackPanel></Grid>
             <Grid Grid.Row="1"><Grid x:Name="BrowsePanel"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                 <Border x:Name="SearchBoxBorder" Grid.Row="0" Background="{DynamicResource ThemeCard}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="10" Margin="0,0,0,16" Padding="12,8" Visibility="Collapsed">
                   <DockPanel><TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" Foreground="{DynamicResource ThemeSub}" VerticalAlignment="Center" Margin="5,0,12,0" FontSize="16"/>
                     <TextBox x:Name="TxtSearch" Background="Transparent" BorderThickness="0" Foreground="{DynamicResource ThemeFg}" VerticalContentAlignment="Center" FontSize="15" CaretBrush="{DynamicResource ThemeAccent}"/></DockPanel></Border>
                 <StackPanel Grid.Row="1">
                  <Border x:Name="AuditCard" Background="{DynamicResource ThemeCard2}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="12" Padding="16" Margin="6,0,6,16" Visibility="Collapsed">
                    <DockPanel>
                      <Border DockPanel.Dock="Left" Width="44" Height="44" CornerRadius="10" Background="{DynamicResource ThemeAccent}" VerticalAlignment="Top" Margin="0,0,16,0">
                        <TextBlock Text="&#xE9D9;" FontFamily="Segoe MDL2 Assets" FontSize="22" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                      <StackPanel>
                        <TextBlock x:Name="AuditTitle" Text="System Overview" Foreground="{DynamicResource ThemeFg}" FontSize="15" FontWeight="SemiBold"/>
                        <TextBlock x:Name="AuditText" Text="" Foreground="{DynamicResource ThemeSub}" FontSize="12.5" LineHeight="20" Margin="0,6,0,0" TextWrapping="Wrap" FlowDirection="LeftToRight" TextAlignment="Left"/></StackPanel></DockPanel></Border>
                  <Border x:Name="InternetBanner" Background="#14202B" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="{StaticResource Rm}" Padding="16" Margin="0,0,0,16" Visibility="Collapsed">
                   <DockPanel><ProgressBar IsIndeterminate="True" Width="140" Height="8" Margin="0,0,16,0" DockPanel.Dock="Left"/>
                     <TextBlock x:Name="InternetText" Text="Waiting..." Foreground="{DynamicResource ThemeFg}" VerticalAlignment="Center" FontSize="14"/></DockPanel></Border></StackPanel>
                 <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
                   <ItemsControl x:Name="ItemsList">
                     <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel Orientation="Horizontal" ItemWidth="280" ItemHeight="90"/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                     <ItemsControl.ItemTemplate><DataTemplate>
                         <CheckBox IsChecked="{Binding Selected}" Focusable="False" Margin="6" Cursor="Hand">
                           <CheckBox.Template><ControlTemplate TargetType="CheckBox">
                               <Border x:Name="CardBorder" Background="{DynamicResource ThemeCard2}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="12" Padding="16">
                                 <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                   <StackPanel Grid.Column="0" VerticalAlignment="Center">
                                     <TextBlock Text="{Binding Name}" Foreground="{DynamicResource ThemeFg}" FontSize="15" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                                     <TextBlock Text="{Binding Sub}" Foreground="{DynamicResource ThemeSub}" FontSize="12" Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/></StackPanel>
                                   <Grid Grid.Column="1" Width="36" Height="20" VerticalAlignment="Center" Margin="10,0" FlowDirection="LeftToRight">
                                     <Border x:Name="ToggleBg" Background="{DynamicResource ThemeCard}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="10"/>
                                     <Ellipse x:Name="ToggleKnob" Width="12" Height="12" Fill="{DynamicResource ThemeSub}" HorizontalAlignment="Left" Margin="4,0,0,0"/></Grid></Grid></Border>
                               <ControlTemplate.Triggers>
                                 <Trigger Property="IsChecked" Value="True"><Setter TargetName="ToggleBg" Property="Background" Value="{DynamicResource ThemeAccent}"/><Setter TargetName="ToggleBg" Property="BorderBrush" Value="{DynamicResource ThemeAccent}"/><Setter TargetName="ToggleKnob" Property="Fill" Value="White"/><Setter TargetName="ToggleKnob" Property="HorizontalAlignment" Value="Right"/><Setter TargetName="ToggleKnob" Property="Margin" Value="0,0,4,0"/><Setter TargetName="CardBorder" Property="BorderBrush" Value="{DynamicResource ThemeAccent}"/><Setter TargetName="CardBorder" Property="Background" Value="#11B122E5"/></Trigger>
                                 <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="CardBorder" Property="Background" Value="{DynamicResource ThemeCard}"/></Trigger>
                               </ControlTemplate.Triggers></ControlTemplate></CheckBox.Template></CheckBox>
                       </DataTemplate></ItemsControl.ItemTemplate></ItemsControl></ScrollViewer>
                 <Border Grid.Row="3" Background="#111318" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="{StaticResource Rm}" Padding="16,12" Margin="0,16,0,0">
                   <Grid>
                     <Grid.ColumnDefinitions>
                       <ColumnDefinition Width="Auto"/>
                       <ColumnDefinition Width="*"/>
                     </Grid.ColumnDefinitions>
                     <TextBlock x:Name="StatusText" Grid.Column="0" Text="Ready." Foreground="{DynamicResource ThemeSub}" VerticalAlignment="Center" FontSize="13" TextTrimming="CharacterEllipsis" Margin="0,0,16,0"/>
                     <ProgressBar x:Name="InstallProgress" Grid.Column="1" Height="8" Minimum="0" Maximum="100" Value="0" HorizontalAlignment="Stretch"/>
                   </Grid>
                 </Border></Grid>
               <Grid x:Name="InstallPanel" Visibility="Collapsed">
                 <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Width="600">
                   <Border Width="80" Height="80" CornerRadius="25" Background="{DynamicResource ThemeAccent}" HorizontalAlignment="Center" Margin="0,0,0,30" Effect="{StaticResource SoftGlow}">
                     <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="36" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                   <TextBlock x:Name="InstTitle" Text="Installing..." Foreground="{DynamicResource ThemeFg}" FontSize="32" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,0,0,10"/>
                   <TextBlock x:Name="InstAppName" Text="" Foreground="{DynamicResource ThemeAccent}" FontSize="24" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,0,0,8"/>
                   <TextBlock x:Name="InstCount" Text="0 / 0" Foreground="{DynamicResource ThemeSub}" FontSize="16" HorizontalAlignment="Center" Margin="0,0,0,30"/>
                   <Border Background="{DynamicResource ThemeCard2}" CornerRadius="12" Padding="6" Margin="0,0,0,16">
                     <ProgressBar x:Name="InstProgressBig" Height="16" Minimum="0" Maximum="100" Value="0"/></Border>
                   <TextBlock x:Name="InstPct" Text="0%" Foreground="{DynamicResource ThemeFg}" FontSize="42" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,0,0,16"/>
                   <TextBlock x:Name="InstStatus" Text="" Foreground="{DynamicResource ThemeSub}" FontSize="15" HorizontalAlignment="Center" TextWrapping="Wrap"/></StackPanel></Grid></Grid></Grid></Grid>
        <Border Grid.Row="2" Background="{DynamicResource ThemeCard}" CornerRadius="0,0,22,22" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="0,1,0,0" Padding="20,16">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnBack" Content="Back" Padding="24,10" Margin="0,0,12,0" Style="{StaticResource PrimaryBtn}" FontSize="15"/>
            <Button x:Name="BtnNext" Content="Next" Padding="24,10" Style="{StaticResource PrimaryBtn}" FontSize="15"/></StackPanel></Border></Grid></Border>
    <Border x:Name="StartupOverlay" Visibility="Visible" Panel.ZIndex="100" Background="{DynamicResource ThemeBg}" CornerRadius="{StaticResource Rxl}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" Margin="30,20" Effect="{StaticResource CardShadow}" MaxWidth="1200" MaxHeight="850">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0" Margin="20,15">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
            <Button x:Name="OvMute" Content="Mute" Margin="0,0,8,0" Height="30" FontSize="12" Foreground="{DynamicResource ThemeSub}" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
            <Button x:Name="OvMin" Content="&#xE921;" Style="{StaticResource WinCtrlBtn}" Width="30" Height="30" FontSize="10"/>
            <Button x:Name="OvClose" Content="&#xE8BB;" Style="{StaticResource CloseBtn}" Width="30" Height="30" FontSize="10"/>
          </StackPanel>
        </Grid>
        <Grid Grid.Row="1" Margin="60,0,60,40">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Margin="0,0,0,30">
            <TextBlock x:Name="WelcomeTitle" FontSize="54" FontWeight="Light" HorizontalAlignment="Center"><Run Text="Win" Foreground="White"/><Run Text="Flex" Foreground="{DynamicResource ThemeAccent}"/><Run Text="OS" Foreground="White"/></TextBlock>
            <TextBlock x:Name="WelcomeDesc" Text="F L E X I B L E   •   F A S T   •   Y O U R S" Foreground="{DynamicResource ThemeFg}" Opacity="0.7" FontSize="16" HorizontalAlignment="Center" Margin="0,8,0,0"/>
          </StackPanel>
          <Grid Grid.Row="1">
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="WelcomePanel" Grid.Row="0" Background="{DynamicResource ThemeCard2}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="16" Padding="40" Effect="{StaticResource CardShadow}">
              <Grid>
                <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" Margin="0,0,0,30" Padding="0,0,20,0">
                  <StackPanel>
                    <TextBlock x:Name="WelcomeBodyTitle" Text="Welcome" Foreground="{DynamicResource ThemeFg}" FontSize="36" FontWeight="SemiBold" Margin="0,0,0,16"/>
                    <TextBlock x:Name="WelcomeIntroText" Text="Loading..." Foreground="{DynamicResource ThemeSub}" TextWrapping="Wrap" FontSize="18" LineHeight="28" Margin="0,0,0,40"/>
                    <Border Background="{DynamicResource ThemeCard}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="14" Padding="24" Margin="0,0,0,24">
                      <StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,16">
                          <TextBlock Text="&#xE9D5;" FontFamily="Segoe MDL2 Assets" FontSize="20" Foreground="{DynamicResource ThemeAccent}" Margin="0,0,12,0" VerticalAlignment="Center"/>
                          <TextBlock x:Name="AboutTitleText" Text="About" Foreground="{DynamicResource ThemeFg}" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        </StackPanel>
                        <TextBlock x:Name="AboutBodyText" Text="Loading details..." Foreground="{DynamicResource ThemeSub}" TextWrapping="Wrap" FontSize="16" LineHeight="28"/>
                      </StackPanel>
                    </Border>
                    <Border Background="{DynamicResource ThemeCard}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="14" Padding="24" Margin="0,0,0,24">
                      <StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,16">
                          <TextBlock Text="&#xE9EE;" FontFamily="Segoe MDL2 Assets" FontSize="20" Foreground="{DynamicResource ThemeAccent}" Margin="0,0,12,0" VerticalAlignment="Center"/>
                          <TextBlock x:Name="UsageTitleText" Text="How to use" Foreground="{DynamicResource ThemeFg}" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        </StackPanel>
                        <TextBlock x:Name="UsageBodyText" Text="Loading steps..." Foreground="{DynamicResource ThemeSub}" TextWrapping="Wrap" FontSize="16" LineHeight="28"/>
                      </StackPanel>
                    </Border>
                    <TextBlock x:Name="HintText" Text="" Foreground="{DynamicResource ThemeSub}" TextWrapping="Wrap" FontSize="15" FontStyle="Italic" HorizontalAlignment="Center" Margin="0,10,0,10"/>
                  </StackPanel>
                </ScrollViewer>
                <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Center">
                  <Button x:Name="BtnContinue" Content="Continue" Padding="50,18" Margin="0,0,24,0" Style="{StaticResource PrimaryBtn}" FontSize="18" FontWeight="SemiBold"/>
                  <Button x:Name="BtnExitWelcome" Content="Exit" Padding="50,18" FontSize="18" Background="Transparent" Foreground="{DynamicResource ThemeSub}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" Cursor="Hand"/>
                </StackPanel>
              </Grid>
            </Border>
            <Border x:Name="PreflightPanel" Grid.Row="1" Background="{DynamicResource ThemeCard2}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="16" Padding="30" Margin="0,20,0,0" Visibility="Collapsed">
              <StackPanel>
                <TextBlock x:Name="PreflightHeader" Text="Pre-flight Check" Foreground="{DynamicResource ThemeFg}" FontSize="20" FontWeight="SemiBold"/>
                <TextBlock x:Name="PreflightStatus" Text="Verifying components..." Foreground="{DynamicResource ThemeSub}" Margin="0,12,0,0" TextWrapping="Wrap" FontSize="15"/>
                <ProgressBar x:Name="PreflightBar" Height="14" Margin="0,18,0,0" Minimum="0" Maximum="100" Value="0"/>
                <TextBlock x:Name="PreflightPct" Text="0%" Foreground="{DynamicResource ThemeSub}" FontSize="13" HorizontalAlignment="Right" Margin="0,6,0,0"/>
              </StackPanel>
            </Border>
          </Grid>
          <TextBlock Grid.Row="2" x:Name="WelcomeFoot" Visibility="Collapsed"/>
        </Grid>
      </Grid>
    </Border>
    <Grid x:Name="IntroOverlay" Panel.ZIndex="200" Background="Black" Visibility="Collapsed">
      <MediaElement x:Name="IntroVideo" LoadedBehavior="Manual" UnloadedBehavior="Stop" Stretch="Uniform"/>
      <Button x:Name="BtnSkipIntro" Content="Skip Intro" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="30" Padding="20,10" Background="#55000000" Foreground="White" BorderThickness="1" BorderBrush="White" Cursor="Hand" FontSize="16"/>
    </Grid>
  </Grid>
</Window>
"@

try {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch { throw "XAML load failed: $($_.Exception.Message)" }
function Find([string]$name) { $window.FindName($name) }

$BgImage=Find "BgImage"; $TopTitle=Find "TopTitle"; $TopSub=Find "TopSub"
$PageTitle=Find "PageTitle"; $PageDesc=Find "PageDesc"; $ItemsList=Find "ItemsList"
$InstallProgress=Find "InstallProgress"; $StatusText=Find "StatusText"
$InternetBanner=Find "InternetBanner"; $InternetText=Find "InternetText"; $AuditCard=Find "AuditCard"; $AuditTitle=Find "AuditTitle"; $AuditText=Find "AuditText"
$BtnBack=Find "BtnBack"; $BtnNext=Find "BtnNext"
$BtnLang=Find "BtnLang"; $BtnMute=Find "BtnMute"; $BtnMin=Find "BtnMin"
$BtnMax=Find "BtnMax"; $BtnClose=Find "BtnClose"; $SideMenu=Find "SideMenu"
$SideSub=Find "SideSub"; $SideFooter=Find "SideFooter"; $CmbTheme=Find "CmbTheme"
$MainBorder=Find "MainBorder"; $MainArea=Find "MainArea"; $StartupOverlay=Find "StartupOverlay"
$BrowsePanel=Find "BrowsePanel"; $InstallPanel=Find "InstallPanel"
$InstTitle=Find "InstTitle"; $InstAppName=Find "InstAppName"; $InstCount=Find "InstCount"
$InstProgressBig=Find "InstProgressBig"; $InstPct=Find "InstPct"; $InstStatus=Find "InstStatus"
$WelcomeTitle=Find "WelcomeTitle"; $WelcomeDesc=Find "WelcomeDesc"
$WelcomePanel=Find "WelcomePanel"; $WelcomeBodyTitle=Find "WelcomeBodyTitle"
$WelcomeIntroText=Find "WelcomeIntroText"; $AboutTitleText=Find "AboutTitleText"
$AboutBodyText=Find "AboutBodyText"; $UsageTitleText=Find "UsageTitleText"
$UsageBodyText=Find "UsageBodyText"; $HintText=Find "HintText"
$PreflightPanel=Find "PreflightPanel"
$PreflightHeader=Find "PreflightHeader"; $PreflightStatus=Find "PreflightStatus"
$PreflightBar=Find "PreflightBar"; $PreflightPct=Find "PreflightPct"
$BtnContinue=Find "BtnContinue"; $BtnExitWelcome=Find "BtnExitWelcome"; $WelcomeFoot=Find "WelcomeFoot"
$BtnSelectAll=Find "BtnSelectAll"; $BtnDeselectAll=Find "BtnDeselectAll"
$OvMin=Find "OvMin"; $OvClose=Find "OvClose"; $OvMute=Find "OvMute"
$TxtSearch=Find "TxtSearch"; $SearchBoxBorder=Find "SearchBoxBorder"
$IntroOverlay=Find "IntroOverlay"; $IntroVideo=Find "IntroVideo"; $BtnSkipIntro=Find "BtnSkipIntro"

if (Test-Path -LiteralPath $backgroundImagePath) {
    try { $bmp=New-Object System.Windows.Media.Imaging.BitmapImage; $bmp.BeginInit(); $bmp.CacheOption=[System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bmp.UriSource=[Uri]::new("file:///$backgroundImagePath"); $bmp.EndInit(); $BgImage.Source=$bmp } catch {} }
# Log labels removed

$MainBorder.Add_MouseLeftButtonDown({ try { if ($_.ClickCount -eq 2) { if ($window.WindowState -eq 'Maximized') { $window.WindowState='Normal' } else { $window.WindowState='Maximized' } } else { $window.DragMove() } } catch {} })
$BtnClose.Add_Click({ $window.Close() }); $OvClose.Add_Click({ $window.Close() })
$BtnMin.Add_Click({ $window.WindowState='Minimized' }); $OvMin.Add_Click({ $window.WindowState='Minimized' })
$BtnMax.Add_Click({ if ($window.WindowState -eq 'Maximized') { $window.WindowState='Normal' } else { $window.WindowState='Maximized' } })
$MuteHandler = { 
    Toggle-Mute
    $text = $(if ($script:isMuted) { (L (-join([char]0x05D1,[char]0x05D8,[char]0x05DC,[char]0x0020,[char]0x05D4,[char]0x05E9,[char]0x05EA,[char]0x05E7,[char]0x05D4)) "Unmute") } 
            else { (L (-join([char]0x05D4,[char]0x05E9,[char]0x05EA,[char]0x05E7)) "Mute") })
    $BtnMute.Content = $text
    $OvMute.Content = $text
}
$BtnMute.Add_Click($MuteHandler)
$OvMute.Add_Click($MuteHandler)

foreach ($t in $script:Themes) { [void]$CmbTheme.Items.Add($t.Name) }; $CmbTheme.SelectedIndex=0
function Apply-ThemeByName([string]$Name) {
    $t=$script:Themes|Where-Object{$_.Name -eq $Name}|Select-Object -First 1; if(-not $t){return}
    function SetBrush([string]$key,[string]$hex){$bc=New-Object System.Windows.Media.BrushConverter;$brush=[System.Windows.Media.Brush]$bc.ConvertFromString($hex);$brush.Freeze();$window.Resources[$key]=$brush}
    SetBrush "ThemeBg" $t.Bg; SetBrush "ThemeSidebar" $t.Sidebar; SetBrush "ThemeCard" $t.Card; SetBrush "ThemeCard2" $t.Card2
    SetBrush "ThemeFg" $t.Fg; SetBrush "ThemeSub" $t.Sub; SetBrush "ThemeAccent" $t.Accent; SetBrush "ThemeBorder" $t.Border
}
$CmbTheme.Add_SelectionChanged({ Apply-ThemeByName ([string]$CmbTheme.SelectedItem) }); Apply-ThemeByName ([string]$CmbTheme.SelectedItem)

function New-ItemVm($item) {
    $sub=if($item.IsTweak){"System Tweak"}elseif($item.WingetId){"winget: $($item.WingetId)"}elseif($item.Path){"file: $($item.Path)"}else{""}
    $sel=$false
    [pscustomobject]@{Name=$item.Name;Sub=$sub;Raw=$item;Selected=$sel}
}
$script:CurrentCategoryIndex=0; $script:CategoryVms=@(); $script:IsInstallPhase=$false
function Initialize-CategoryVms {
    $script:CategoryVms=@()
    foreach($cat in $script:Categories){$script:CategoryVms+=,(@($cat.Items|ForEach-Object{New-ItemVm $_}))}
}

function Get-CategorySelectedCount([int]$idx) { $c=0; foreach($vm in $script:CategoryVms[$idx]){if($vm.Selected){$c++}}; return $c }
function Get-TotalSelectedCount { $c=0; for($i=0;$i -lt $script:CategoryVms.Count;$i++){$c+=(Get-CategorySelectedCount $i)}; return $c }

function Apply-Language {
    $script:isHe = ($script:Lang -eq "he")
    $BtnLang.Content = $(if ($script:isHe) { "EN" } else { "HE" })
    
    $BtnMute.Content = $(if ($script:isMuted) { (L (He @(0x05D1,0x05D8,0x05DC,0x0020,0x05D4,0x05E9,0x05EA,0x05E7,0x05D4)) "Unmute") } else { (L (He @(0x05D4,0x05E9,0x05EA,0x05E7)) "Mute") })
    $BtnBack.Content = $(L (He @(0x05D4,0x05E7,0x05D5,0x05D3,0x05DD)) "Back")
    $BtnNext.Content = $(L (He @(0x05D4,0x05D1,0x05D0)) "Next")
    $TopSub.Text = $(L (He @(0x05D1,0x05D7,0x05E8,0x20,0x05EA,0x05D5,0x05DB,0x05E0,0x05D5,0x05EA,0x20,0x05DC,0x05D4,0x05EA,0x05E7,0x05E0,0x05D4)) "Choose apps to install")
    $SideSub.Text = $(L (He @(0x05EA,0x05E4,0x05E8,0x05D9,0x05D8,0x20,0x05D4,0x05EA,0x05E7,0x05E0,0x05D4)) "Installation menu")
    $StatusText.Text = $(L (He @(0x05DE,0x05D5,0x05DB,0x05DF,0x2E)) "Ready.")
    $InternetText.Text = $(L (He @(0x5DE,0x5DE,0x5EA,0x5D9,0x5E0,0x5D9,0x5DD,0x20,0x5DC,0x5D0,0x5D9,0x5E0,0x5D8,0x5E8,0x5E0,0x5D8,0x2E,0x2E,0x2E)) "Waiting for internet...")
    $BtnSelectAll.Content = $(L (He @(0x05D1,0x05D7,0x05E8,0x20,0x05D4,0x05DB,0x05DC)) "Select All")
    $BtnDeselectAll.Content = $(L (He @(0x05D1,0x05D8,0x05DC,0x05D4,0x05DB,0x05DC)) "Deselect All")
    $BtnContinue.Content = $(L (He @(0x05D4,0x05D1,0x05D0)) "Next")
    $BtnExitWelcome.Content = $(L (He @(0x05DC,0x05D0,0x20,0x05DE,0x05E2,0x05D5,0x05E0,0x05D9,0x05D9,0x05DF)) "No thanks")
    
    $userName = $env:USERNAME
    $wGreHe = (He @(0x05E9, 0x05DC, 0x05D5, 0x05DD, 0x20)) + $userName
    $wTitleHe = He @(0x05D1,0x05E8,0x05D5,0x05DB,0x05D9,0x05DD,0x20,0x05D4,0x05D1,0x05D0,0x05D9,0x05DD,0x20,0x05DC,0x2D,0x57,0x69,0x6E,0x46,0x6C,0x65,0x78,0x4F,0x53)
    $wDescHe = He @(0x05D4,0x05D2,0x05E8,0x05E1,0x05D4,0x20,0x05E9,0x05DC,0x05DA,0x2C,0x20,0x05D4,0x05E9,0x05DC,0x05D9,0x05D8,0x05D4,0x20,0x05E9,0x05DC,0x05DA,0x2E)
    # $WelcomeTitle.Text = $(L $wTitleHe "Welcome to WinFlexOS")
    $WelcomeDesc.Text = $(L $wGreHe ("Hello " + $userName))
    
    $window.FlowDirection = $(if ($script:isHe) { "RightToLeft" } else { "LeftToRight" })
}
$BtnLang.Add_Click({ $script:Lang=$(if($script:Lang -eq "he"){"en"}else{"he"}); Apply-Language; Render-SideMenu; Show-Category })

$TxtSearch.Add_KeyDown({
    if ($_.Key -eq 'Return' -or $_.Key -eq 'Enter') {
        $val = $TxtSearch.Text.Trim()
        if ($val -ne "") {
            $newItem = [pscustomobject]@{Name=$val; Sub="winget: $val"; Raw=@{Name=$val; WingetId=$val; IsCustom=$true}; Selected=$true}
            $script:CategoryVms[$script:CurrentCategoryIndex] += $newItem
            $ItemsList.ItemsSource = $null
            $ItemsList.ItemsSource = $script:CategoryVms[$script:CurrentCategoryIndex]
            $TxtSearch.Text = ""
            Render-SideMenu
        }
    }
})

$script:SideButtons=@()
function Render-SideMenu {
    $SideMenu.Children.Clear(); $script:SideButtons=@()
    for($i=0;$i -lt $script:Categories.Count;$i++){
        $cat=$script:Categories[$i]; $cnt=Get-CategorySelectedCount $i
        $label=(L $cat.TitleHe $cat.TitleEn); if($cnt -gt 0){$label+=" ($cnt)"}
        $btn=New-Object System.Windows.Controls.Button
        $btn.Content=$label; $ic=[string]$cat.Icon; if($ic -match '^&#x([0-9A-Fa-f]+);$'){$ic=[string][char][Convert]::ToInt32($Matches[1],16)}; $btn.Tag=$ic; $btn.Uid=$i.ToString(); $btn.Style=$window.FindResource("SidebarBtn")
        $btn.Add_Click({$script:CurrentCategoryIndex=[int]$this.Uid;Show-Category})
        $SideMenu.Children.Add($btn)|Out-Null; $script:SideButtons+=$btn
    }
    for($j=0;$j -lt $script:SideButtons.Count;$j++){
        $b=$script:SideButtons[$j]
        if($j -eq $script:CurrentCategoryIndex){$b.Foreground=$window.Resources["ThemeFg"];$b.Background=New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#15222E"))}
        else{$b.Foreground=$window.Resources["ThemeSub"];$b.Background=[System.Windows.Media.Brushes]::Transparent}
    }
}
function Show-AuditCard {
    if (-not $script:AuditSummary) {
        try { $script:AuditSummary = (Get-SystemHardwareAudit) } catch { $script:AuditSummary = "Hardware info unavailable." }
    }
    $AuditTitle.Text = (L "סקירת מערכת" "System Overview")
    $AuditText.Text = $script:AuditSummary
    $AuditCard.Visibility = 'Visible'
}
function Show-Category {
    $script:IsInstallPhase=$false; $cat=$script:Categories[$script:CurrentCategoryIndex]
    $PageTitle.Text=(L $cat.TitleHe $cat.TitleEn)
    $PageDesc.Text=(L (-join([char]0x05D1,[char]0x05D7,[char]0x05E8,[char]0x0020,[char]0x05DE,[char]0x05D4,[char]0x0020,[char]0x05DC,[char]0x05D4,[char]0x05EA,[char]0x05E7,[char]0x05D9,[char]0x05DF,[char]0x002E)) "Select what to install.")
    $ItemsList.ItemsSource=$script:CategoryVms[$script:CurrentCategoryIndex]
    if($cat.Key -eq "custom"){$SearchBoxBorder.Visibility='Visible'}else{$SearchBoxBorder.Visibility='Collapsed'}
    if($cat.Key -eq "audit"){Show-AuditCard}else{$AuditCard.Visibility='Collapsed'}
    $BrowsePanel.Visibility='Visible'; $InstallPanel.Visibility='Collapsed'
    $InstallProgress.Value=0; $StatusText.Text=(L (-join([char]0x05DE,[char]0x05D5,[char]0x05DB,[char]0x05DF,[char]0x002E)) "Ready.")
    $BtnBack.IsEnabled=$true; $BtnNext.IsEnabled=$true; Render-SideMenu
}
function Get-SelectedSoftware { $sel=New-Object System.Collections.Generic.List[object]; for($i=0;$i -lt $script:CategoryVms.Count;$i++){foreach($vm in $script:CategoryVms[$i]){if($vm.Selected){$sel.Add($vm.Raw)}}}; return $sel }

$BtnSelectAll.Add_Click({ foreach($vm in $script:CategoryVms[$script:CurrentCategoryIndex]){$vm.Selected=$true}; $ItemsList.ItemsSource=$null; $ItemsList.ItemsSource=$script:CategoryVms[$script:CurrentCategoryIndex]; Render-SideMenu })
$BtnDeselectAll.Add_Click({ foreach($vm in $script:CategoryVms[$script:CurrentCategoryIndex]){$vm.Selected=$false}; $ItemsList.ItemsSource=$null; $ItemsList.ItemsSource=$script:CategoryVms[$script:CurrentCategoryIndex]; Render-SideMenu })

function Start-InstallPhase {
    $selected=@(Get-SelectedSoftware)
    if($selected.Count -eq 0){$StatusText.Text=(L (-join([char]0x05DC,[char]0x05D0,[char]0x0020,[char]0x05E0,[char]0x05D1,[char]0x05D7,[char]0x05E8,[char]0x0020,[char]0x05DB,[char]0x05DC,[char]0x05D5,[char]0x05DD,[char]0x002E)) "Nothing selected.");return}
    $script:IsInstallPhase=$true; $BrowsePanel.Visibility='Collapsed'; $InstallPanel.Visibility='Visible'
    $PageTitle.Text=(L (-join([char]0x05DE,[char]0x05EA,[char]0x05E7,[char]0x05D9,[char]0x05DF,[char]0x0020,[char]0x05EA,[char]0x05D5,[char]0x05DB,[char]0x05E0,[char]0x05D5,[char]0x05EA,[char]0x002E,[char]0x002E,[char]0x002E)) "Installing..."); $PageDesc.Text=(L (-join([char]0x05D0,[char]0x05E0,[char]0x05D0,[char]0x0020,[char]0x05D4,[char]0x05DE,[char]0x05EA,[char]0x05DF,[char]0x002E,[char]0x002E,[char]0x002E)) "Please wait...")
    $InstTitle.Text=(L (-join([char]0x05DE,[char]0x05EA,[char]0x05E7,[char]0x05D9,[char]0x05DF,[char]0x0020,[char]0x05EA,[char]0x05D5,[char]0x05DB,[char]0x05E0,[char]0x05D5,[char]0x05EA,[char]0x002E,[char]0x002E,[char]0x002E)) "Installing software..."); $InstProgressBig.Value=0; $InstPct.Text="0%"
    $InstAppName.Text=""; $InstCount.Text=""; $InstStatus.Text=""
    $BtnBack.IsEnabled=$false; $BtnNext.IsEnabled=$false; $window.Dispatcher.Invoke([action]{},"Background")
    $hasWinget=[bool](Get-Command winget -ErrorAction SilentlyContinue)
    if(-not $hasWinget){
        Write-Log "winget missing"; $InstAppName.Text="Winget"
        $InstStatus.Text=(L (-join([char]0x05DE,[char]0x05EA,[char]0x05E7,[char]0x05D9,[char]0x05DF,[char]0x0020,[char]0x0057,[char]0x0069,[char]0x006E,[char]0x0067,[char]0x0065,[char]0x0074,[char]0x002E,[char]0x002E,[char]0x002E)) "Installing Winget..."); $window.Dispatcher.Invoke([action]{},"Background")
        $tmpDir=Join-Path $env:TEMP "winget-install"; New-Item -ItemType Directory -Force -Path $tmpDir -ErrorAction SilentlyContinue|Out-Null
        $bundle=Join-Path $tmpDir "Microsoft.DesktopAppInstaller.msixbundle"
        try{(New-Object Net.WebClient).DownloadFile("https://aka.ms/getwinget",$bundle)}catch{}
        try{Add-AppxPackage -Path $bundle -ErrorAction SilentlyContinue|Out-Null}catch{}; Start-Sleep -Seconds 2 }
    $total=$selected.Count
    for($i=0;$i -lt $total;$i++){
        $sw=$selected[$i]; $name=$sw.Name
        $InstAppName.Text=$name; $InstCount.Text="$($i+1) / $total"
        $InstPct.Text="$([int](($i*100)/$total))%"; $InstProgressBig.Value=[int](($i*100)/$total)
        $InstStatus.Text=(L ((-join([char]0x05DE,[char]0x05EA,[char]0x05E7,[char]0x05D9,[char]0x05DF,[char]0x003A,[char]0x0020))+$name) "Installing: $name"); $window.Dispatcher.Invoke([action]{},"Background")
        try{ Write-Log "Install start: $name"
            if($sw.IsTweak) { Invoke-SystemTweak $sw.TweakId }
            elseif($sw.IsCustom) { Invoke-WingetInstall $sw.WingetId $false }
            elseif($sw.WingetId){Invoke-WingetInstall $sw.WingetId}
            elseif($sw.Path){if(-not(Test-Path -LiteralPath $sw.Path)){throw "Not found: $($sw.Path)"};Start-Process -FilePath $sw.Path -Wait}
            else{throw "Unknown method"}; Write-Log "Install success: $name"
        }catch{Write-Log "Install failed: $name :: $($_.Exception.Message)"}
    }
    $InstProgressBig.Value=100; $InstPct.Text="100%"
    $InstTitle.Text=(L (-join([char]0x05D4,[char]0x05D5,[char]0x05E9,[char]0x05DC,[char]0x05DD,[char]0x05D5,[char]0x0021)) "Completed!"); $InstAppName.Text=(L (-join([char]0x05DB,[char]0x05DC,[char]0x0020,[char]0x05D4,[char]0x05EA,[char]0x05D5,[char]0x05DB,[char]0x05E0,[char]0x05D5,[char]0x05EA,[char]0x0020,[char]0x05D4,[char]0x05D5,[char]0x05EA,[char]0x05E7,[char]0x05E0,[char]0x05D5,[char]0x002E)) "All software installed.")
    $InstCount.Text="$total / $total"; $InstStatus.Text=(L (-join([char]0x05D1,[char]0x05D3,[char]0x05D5,[char]0x05E7,[char]0x0020,[char]0x05DC,[char]0x05D5,[char]0x05D2,[char]0x002E)) "Check log.")
    $PageTitle.Text=(L (-join([char]0x05D4,[char]0x05D5,[char]0x05E9,[char]0x05DC,[char]0x05DD,[char]0x05D5,[char]0x0021)) "Completed."); $PageDesc.Text=(L (-join([char]0x05DB,[char]0x05DC,[char]0x0020,[char]0x05D4,[char]0x05EA,[char]0x05D5,[char]0x05DB,[char]0x05E0,[char]0x05D5,[char]0x05EA,[char]0x05D4,[char]0x05D5,[char]0x05EA,[char]0x05E7,[char]0x05E0,[char]0x05D5,[char]0x002E)) "All software installed.")
    $BtnBack.IsEnabled=$true; $BtnNext.IsEnabled=$false
}

function Set-PreflightUI([int]$pct,[string]$msg) { if($pct -lt 0){$pct=0}; if($pct -gt 100){$pct=100}; $PreflightBar.Value=$pct; $PreflightPct.Text="$pct%"; $PreflightStatus.Text=$msg }
function Run-PreflightAsync {
    if($script:preflightTimer){try{$script:preflightTimer.Stop()}catch{};$script:preflightTimer=$null}
    $BtnContinue.IsEnabled=$false; $BtnExitWelcome.IsEnabled=$false
    $script:preflightPhase="ping"; $script:preflightPingIdx=0; $script:preflightPingOk=0
    $script:preflightWingetPs=$null; $script:preflightWingetAsync=$null; $script:preflightWingetTick=0
    Write-Log "Preflight: starting ICMP ping sequence"
    Set-PreflightUI 2 (L (-join([char]0x05E9,[char]0x05D5,[char]0x05DC,[char]0x05D7,[char]0x0020,[char]0x0070,[char]0x0069,[char]0x006E,[char]0x0067)) "Starting ping...")
    $script:preflightTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:preflightTimer.Interval = [TimeSpan]::FromMilliseconds(450)
    $script:preflightTimer.Add_Tick({
        try {
            if ($script:preflightPhase -eq "ping") {
                if ($script:preflightPingIdx -lt 4) {
                    $n=$script:preflightPingIdx+1; $pct=[int](5+[Math]::Round($n*30/4)); $line=""
                    $p=New-Object System.Net.NetworkInformation.Ping
                    try { $r=$p.Send("1.1.1.1",4000)
                        if($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success){$script:preflightPingOk++;$ttl=$(if($null -ne $r.Options){$r.Options.Ttl}else{"?"});$line="Reply: time=$($r.RoundtripTime)ms TTL=$ttl"}
                        else{$line="Ping $n/4: $($r.Status)"} } catch { $line="Ping error" } finally { $p.Dispose() }
                    Set-PreflightUI $pct "Ping ($n/4) - $line"; $script:preflightPingIdx++; return }
                if ($script:preflightPingOk -lt 1) { Set-PreflightUI 36 (L (-join([char]0x05D0,[char]0x05D9,[char]0x05DF,[char]0x0020,[char]0x05EA,[char]0x05E9,[char]0x05D5,[char]0x05D3,[char]0x05D4,[char]0x002E)) "No reply.") }
                else { Set-PreflightUI 36 (L (-join([char]0x0050,[char]0x0069,[char]0x006E,[char]0x0067,[char]0x0020,[char]0x05D4,[char]0x05E6,[char]0x05DC,[char]0x05D7,[char]0x05D3,[char]0x002E)) "Ping OK.") }
                $script:preflightPhase="menu"
                return
            }
            if ($script:preflightPhase -eq "menu") {
                Set-PreflightUI 40 (L (-join([char]0x05DE,[char]0x05D5,[char]0x05E8,0x05D9,0x05D3,0x20,0x05EA,0x05E4,0x05E8,0x05D9,0x05D8,0x2E,0x2E,0x2E)) "Loading local menu...")
                $tempMenuPath = Join-Path $script:scriptDir "menu.ps1"
                try {
                    if (Test-Path -LiteralPath $tempMenuPath) {
                        . $tempMenuPath
                        Initialize-CategoryVms
                        Render-SideMenu
                        Show-Category
                        Play-Sound
                        Write-Log "Preflight: menu loaded successfully"
                    } else {
                        throw "Local menu.ps1 not found in $($script:scriptDir)"
                    }
                    $script:preflightPhase="winget"
                    $ps=[PowerShell]::Create()
                    $ps.AddScript({param($LogPath);function Write-Log([string]$Message){$ts=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss");try{Add-Content -Path $LogPath -Value "[$ts] $Message" -Encoding UTF8}catch{}};function Test-Winget{[bool](Get-Command winget -ErrorAction SilentlyContinue)};function Install-Winget{if(Test-Winget){return $true};$tmpDir=Join-Path $env:TEMP "winget-install";New-Item -ItemType Directory -Force -Path $tmpDir|Out-Null;$bundle=Join-Path $tmpDir "Microsoft.DesktopAppInstaller.msixbundle";(New-Object Net.WebClient).DownloadFile("https://aka.ms/getwinget",$bundle);Add-AppxPackage -Path $bundle -ErrorAction Stop|Out-Null;Start-Sleep -Seconds 2;return(Test-Winget)};Write-Log "Preflight: ensuring winget...";if(-not(Install-Winget)){throw "winget installation failed"};Write-Log "Preflight: OK";return $true}).AddArgument($script:LogPath)|Out-Null
                    $script:preflightWingetPs=$ps; $script:preflightWingetAsync=$ps.BeginInvoke(); return
                } catch {
                    Set-PreflightUI 0 (L ((-join([char]0x05E9,[char]0x05D2,[char]0x05D9,[char]0x05D0,[char]0x05D4,[char]0x003A,[char]0x0020))+$_.Exception.Message) ("Error: "+$_.Exception.Message))
                    $script:preflightTimer.Stop()
                    $BtnContinue.IsEnabled=$true
                    return
                }
            }
            if ($script:preflightPhase -eq "winget") {
                $wa=$script:preflightWingetAsync; if(-not $wa){return}; $script:preflightWingetTick++
                $cap=[Math]::Min(94,38+[Math]::Min(50,$script:preflightWingetTick))
                Set-PreflightUI $cap (L (-join([char]0x05DE,[char]0x05DB,[char]0x05D9,[char]0x05DF,[char]0x0020,[char]0x0077,[char]0x0069,[char]0x0065,[char]0x0067)) "Preparing winget...")
                if($wa.IsCompleted){$script:preflightTimer.Stop()
                    try{$null=$script:preflightWingetPs.EndInvoke($script:preflightWingetAsync)
                        Set-PreflightUI 100 (L (-join([char]0x05D1,[char]0x05D3,[char]0x05D9,[char]0x05E7,[char]0x05D5,[char]0x05EA,[char]0x0020,[char]0x05D4,[char]0x05D5,[char]0x05E9,[char]0x05DC,[char]0x05DE,[char]0x05D5,[char]0x002E)) "Checks complete.")
                        $StartupOverlay.Visibility='Collapsed'; $MainBorder.Visibility='Visible'; $MainArea.IsEnabled=$true;$MainArea.Opacity=1
                    }catch{Set-PreflightUI 0 (L ((-join([char]0x05E9,[char]0x05D2,[char]0x05D9,[char]0x05D0,[char]0x05D4,[char]0x003A,[char]0x0020))+$_.Exception.Message) ("Error: "+$_.Exception.Message));$BtnContinue.IsEnabled=$true}
                    finally{if($script:preflightWingetPs){$script:preflightWingetPs.Dispose()};$script:preflightWingetPs=$null;$script:preflightWingetAsync=$null} } }
        } catch {} })
    $script:preflightTimer.Start()
}

$BtnContinue.Add_Click({$WelcomePanel.Visibility='Collapsed';$PreflightPanel.Visibility='Visible';$BtnContinue.IsEnabled=$false;Run-PreflightAsync})
$BtnExitWelcome.Add_Click({$window.Close()})
$BtnBack.Add_Click({if($script:IsInstallPhase){$script:CurrentCategoryIndex=$script:Categories.Count-1;Show-Category}elseif($script:CurrentCategoryIndex -gt 0){$script:CurrentCategoryIndex--;Show-Category}})
$BtnNext.Add_Click({
    if($script:IsInstallPhase){return}
    if($script:CurrentCategoryIndex -lt ($script:Categories.Count-1)){$script:CurrentCategoryIndex++;Show-Category}
    else{Start-InstallPhase}
})

Apply-Language
$userName = $env:USERNAME

# Helper to decode Hebrew numeric arrays (and emojis)
function He { 
    param($arr) 
    $out = ""
    foreach($v in $arr) {
        if ($v -gt 0xFFFF) { $out += [char]::ConvertFromUtf32($v) }
        else { $out += [char]$v }
    }
    return $out
}

# Title and Description
# 🚀 ברוכים הבאים ל-WinFlexOS
$wTitHe = He @(0x1F680, 0x20, 0x5D1, 0x5E8, 0x5D5, 0x5DB, 0x5D9, 0x5DD, 0x20, 0x5D4, 0x5D1, 0x5D0, 0x5D9, 0x5DD, 0x20, 0x5DC, 0x2D, 0x57, 0x69, 0x6E, 0x46, 0x6C, 0x65, 0x78, 0x4F, 0x53)
# $WelcomeTitle.Text = L $wTitHe "🚀 Welcome to WinFlexOS"

# הגרסה שלך. השליטה שלך.
$wDesHe = He @(0x5D4, 0x5D2, 0x5E8, 0x5E1, 0x5D4, 0x20, 0x5E9, 0x5DC, 0x5DA, 0x2E, 0x20, 0x5D4, 0x5E9, 0x5DC, 0x5D9, 0x5D8, 0x5D4, 0x20, 0x5E9, 0x5DC, 0x5DA, 0x2E)
# $WelcomeDesc.Text = L $wDesHe "Your version. Your control."

# שלום [משתמש]
$wGreHe = (He @(0x5E9, 0x5DC, 0x5D5, 0x5DD, 0x20)) + $userName
$WelcomeBodyTitle.Text = L $wGreHe "Hello $userName"

# Large Body Text - Broken into chunks for safety
$b1 = He @(0x05D1, 0x05E8, 0x05D5, 0x05DB, 0x05D9, 0x05DD, 0x0020, 0x05D4, 0x05D1, 0x05D0, 0x05D9, 0x05DD, 0x0020, 0x05DC, 0x002D, 0x0057, 0x0069, 0x006E, 0x0046, 0x006C, 0x0065, 0x0078, 0x004F, 0x0053, 0x0021, 0x000A)
$b2 = He @(0x05DC, 0x05E8, 0x05E9, 0x05D5, 0x05EA, 0x05DB, 0x05DD, 0x0020, 0x05EA, 0x05E4, 0x05E8, 0x05D9, 0x05D8, 0x0020, 0x05D4, 0x05EA, 0x05E7, 0x05E0, 0x05D5, 0x05EA, 0x0020, 0x05DE, 0x05D5, 0x05E8, 0x05D7, 0x05D1, 0x000A)
$b3 = He @(0x05E9, 0x05EA, 0x05E4, 0x05E7, 0x05D9, 0x05D3, 0x05D5, 0x0020, 0x05DC, 0x05D0, 0x05E4, 0x05E9, 0x05E8, 0x0020, 0x05DC, 0x05DB, 0x05DD, 0x0020, 0x05E9, 0x05DC, 0x05D9, 0x05D8, 0x05D4, 0x0020, 0x05DE, 0x05DC, 0x05D0, 0x05D4, 0x0020, 0x05E2, 0x05DC, 0x0020, 0x05DE, 0x05D4, 0x0020, 0x05E9, 0x05DE, 0x05D5, 0x05EA, 0x05E7, 0x05DF, 0x002E, 0x000A, 0x000A)
$b4 = He @(0xD83D, 0xDEE0, 0xFE0F, 0x0020, 0x05E2, 0x05DC, 0x0020, 0x05D4, 0x05DE, 0x05E2, 0x05E8, 0x05DB, 0x05EA, 0x000A, 0x000A)
$b5 = He @(0x0057, 0x0069, 0x006E, 0x0046, 0x006C, 0x0065, 0x0078, 0x004F, 0x0053, 0x0020, 0x05D4, 0x05D9, 0x05D0, 0x0020, 0x05DC, 0x05D0, 0x0020, 0x05E1, 0x05EA, 0x05DD, 0x0020, 0x05E2, 0x05D5, 0x05D3, 0x0020, 0x05D4, 0x05EA, 0x05E7, 0x05E0, 0x05D4, 0x002E, 0x0020, 0x05D4, 0x05D9, 0x05D0, 0x0020, 0x05E4, 0x05E8, 0x05D5, 0x05D9, 0x05E7, 0x05D8, 0x0020, 0x05E9, 0x05DC, 0x0020, 0x05D0, 0x05D5, 0x05E4, 0x05D8, 0x05D9, 0x05DE, 0x05D9, 0x05D6, 0x05E6, 0x05D9, 0x05D4, 0x0020, 0x05D5, 0x05D3, 0x05D9, 0x05D5, 0x05E7, 0x003A, 0x000A, 0x000A)
$b6 = He @(0x2022, 0x0020, 0x05D1, 0x05D9, 0x05E6, 0x05D5, 0x05E2, 0x05D9, 0x05DD, 0x0020, 0x05DE, 0x05E7, 0x05E1, 0x05D9, 0x05DE, 0x05DC, 0x05D9, 0x05D9, 0x05DD, 0x003A, 0x0020, 0x05D4, 0x05E1, 0x05E8, 0x05EA, 0x0020, 0x05E8, 0x05DB, 0x05D9, 0x05D1, 0x05D9, 0x05DD, 0x0020, 0x05DE, 0x05D9, 0x05D5, 0x05EA, 0x05E8, 0x05D9, 0x05DD, 0x0020, 0x0028, 0x0042, 0x006C, 0x006F, 0x0061, 0x0074, 0x0077, 0x0061, 0x0072, 0x0065, 0x0029, 0x0020, 0x05DB, 0x05D3, 0x05D9, 0x0020, 0x05DC, 0x05D4, 0x05D1, 0x05D8, 0x05D9, 0x05D7, 0x0020, 0x05DE, 0x05D4, 0x05D9, 0x05E8, 0x05D5, 0x05EA, 0x0020, 0x05EA, 0x05D2, 0x05D5, 0x05D1, 0x05D4, 0x0020, 0x05E9, 0x05D9, 0x05D0, 0x002E, 0x000A, 0x000A)
$b7 = He @(0x2022, 0x0020, 0x05DE, 0x05D9, 0x05E0, 0x05D9, 0x05DE, 0x05DC, 0x05D9, 0x05D6, 0x05DD, 0x0020, 0x05D7, 0x05DB, 0x05DD, 0x003A, 0x0020, 0x05DE, 0x05DE, 0x05E9, 0x05E7, 0x0020, 0x05E0, 0x05E7, 0x05D9, 0x0020, 0x05E9, 0x05DE, 0x05D0, 0x05E4, 0x05E9, 0x05E8, 0x0020, 0x05DC, 0x05DA, 0x0020, 0x05DC, 0x05D4, 0x05EA, 0x05E8, 0x05DB, 0x05D6, 0x0020, 0x05D1, 0x05DE, 0x05D4, 0x0020, 0x05E9, 0x05D7, 0x05E9, 0x05D5, 0x05D1, 0x002C, 0x0020, 0x05D1, 0x05DC, 0x05D9, 0x0020, 0x05D4, 0x05E4, 0x05E8, 0x05E2, 0x05D5, 0x05EA, 0x0020, 0x05E8, 0x05E7, 0x05E2, 0x002E, 0x000A, 0x000A)
$b7a = He @(0x2022, 0x0020, 0x05DB, 0x05DC, 0x05D9, 0x0020, 0x05D0, 0x05D1, 0x05D7, 0x05D5, 0x05DF, 0x0020, 0x05DE, 0x05D5, 0x05D1, 0x05E0, 0x05D9, 0x05DD, 0x003A, 0x0020, 0x05E9, 0x05D9, 0x05DC, 0x05D5, 0x05D1, 0x0020, 0x05E9, 0x05DC, 0x0020, 0x05E1, 0x05E7, 0x05E8, 0x05D9, 0x05E4, 0x05D8, 0x05D9, 0x05DD, 0x0020, 0x05DE, 0x05EA, 0x05E7, 0x05D3, 0x05DE, 0x05D9, 0x05DD, 0x0020, 0x0028, 0x05DB, 0x05DE, 0x05D5, 0x0020, 0x05D4, 0x002D, 0x0050, 0x006F, 0x0077, 0x0065, 0x0072, 0x0053, 0x0068, 0x0065, 0x006C, 0x006C, 0x0020, 0x0047, 0x0055, 0x0049, 0x0020, 0x05E9, 0x05E4, 0x05D9, 0x05EA, 0x05D7, 0x05E0, 0x05D5, 0x0029, 0x0020, 0x05DC, 0x05E0, 0x05D9, 0x05D4, 0x05D5, 0x05DC, 0x0020, 0x05D5, 0x05EA, 0x05E7, 0x05D9, 0x05E0, 0x05D5, 0x05EA, 0x0020, 0x05D4, 0x05DE, 0x05D7, 0x05E9, 0x05D1, 0x0020, 0x05D1, 0x05DC, 0x05D7, 0x05D9, 0x05E6, 0x05EA, 0x0020, 0x05DB, 0x05E4, 0x05EA, 0x05D5, 0x05E8, 0x002E, 0x000A, 0x000A)
$b7b = He @(0x2022, 0x0020, 0x05D2, 0x05DE, 0x05D9, 0x05E9, 0x05D5, 0x05EA, 0x0020, 0x0028, 0x0046, 0x006C, 0x0065, 0x0078, 0x0029, 0x003A, 0x0020, 0x05D4, 0x05DE, 0x05E2, 0x05E8, 0x05DB, 0x05EA, 0x0020, 0x05E0, 0x05D1, 0x05E0, 0x05EA, 0x05D4, 0x0020, 0x05DB, 0x05D3, 0x05D9, 0x0020, 0x05DC, 0x05D4, 0x05D9, 0x05D5, 0x05EA, 0x0020, 0x05D5, 0x05E8, 0x05E1, 0x05D8, 0x05D9, 0x05DC, 0x05D9, 0x05EA, 0x0020, 0x2013, 0x0020, 0x05D1, 0x05D9, 0x05DF, 0x0020, 0x05D0, 0x05DD, 0x0020, 0x05D6, 0x05D4, 0x0020, 0x05DC, 0x05E2, 0x05D1, 0x05D5, 0x05D3, 0x05D4, 0x0020, 0x05D1, 0x002D, 0x0056, 0x004D, 0x0020, 0x05D5, 0x05D1, 0x05D9, 0x05DF, 0x0020, 0x05D0, 0x05DD, 0x0020, 0x05DC, 0x05DE, 0x05DB, 0x05D5, 0x05E0, 0x05D4, 0x0020, 0x05E4, 0x05D9, 0x05D6, 0x05D9, 0x05EA, 0x002E, 0x000A)
$b8 = He @(0x000A)
$b9 = He @(0x05D0, 0x05D9, 0x05DA, 0x0020, 0x05DE, 0x05E9, 0x05EA, 0x05DE, 0x05E9, 0x05D9, 0x05DD, 0x0020, 0x05D1, 0x05EA, 0x05E4, 0x05E8, 0x05D9, 0x05D8, 0x0020, 0x05D4, 0x05D4, 0x05EA, 0x05E7, 0x05E0, 0x05D5, 0x05EA, 0x003F, 0x000A)
$b10 = He @(0x0031, 0x002E, 0x0020, 0x05D1, 0x05E8, 0x05D2, 0x05E2, 0x0020, 0x05E9, 0x05EA, 0x05DE, 0x05E9, 0x05D9, 0x05DB, 0x05D5, 0x002C, 0x0020, 0x05D4, 0x05DE, 0x05E2, 0x05E8, 0x05DB, 0x05EA, 0x0020, 0x05EA, 0x05D1, 0x05E6, 0x05E2, 0x0020, 0x05E1, 0x05E8, 0x05D9, 0x05E7, 0x05EA, 0x0020, 0x05E8, 0x05E9, 0x05EA, 0x002E, 0x000A)
$b11 = He @(0x0032, 0x002E, 0x0020, 0x05DC, 0x05D0, 0x05D7, 0x05E8, 0x0020, 0x05DE, 0x05DB, 0x05DF, 0x002C, 0x0020, 0x05D9, 0x05D5, 0x05E6, 0x05D2, 0x0020, 0x05DC, 0x05DB, 0x05DD, 0x0020, 0x05EA, 0x05E4, 0x05E8, 0x05D9, 0x05D8, 0x0020, 0x05E7, 0x05D8, 0x05D2, 0x05D5, 0x05E8, 0x05D9, 0x05D5, 0x05EA, 0x0020, 0x05E0, 0x05D5, 0x05D7, 0x0020, 0x05D1, 0x05D7, 0x05DC, 0x05E7, 0x05D5, 0x0020, 0x05D4, 0x05E6, 0x05D9, 0x05D3, 0x05D9, 0x0020, 0x05E9, 0x05DC, 0x0020, 0x05D4, 0x05DE, 0x05E1, 0x05DA, 0x002E, 0x000A)
$b12 = He @(0x0033, 0x002E, 0x0020, 0x05D1, 0x05D7, 0x05E8, 0x05D5, 0x0020, 0x05D0, 0x05EA, 0x0020, 0x05D4, 0x05E7, 0x05D8, 0x05D2, 0x05D5, 0x05E8, 0x05D9, 0x05D5, 0x05EA, 0x0020, 0x05D4, 0x05E9, 0x05D5, 0x05E0, 0x05D5, 0x05EA, 0x0020, 0x05D5, 0x05E1, 0x05DE, 0x05E0, 0x05D5, 0x0020, 0x05D0, 0x05D9, 0x05DC, 0x05D5, 0x0020, 0x05EA, 0x05D5, 0x05DB, 0x05E0, 0x05D5, 0x05EA, 0x0020, 0x05EA, 0x05E8, 0x05E6, 0x05D5, 0x0020, 0x05DC, 0x05D4, 0x05EA, 0x05E7, 0x05D9, 0x05DF, 0x002E, 0x000A)
$b13 = He @(0x0034, 0x002E, 0x0020, 0x05D1, 0x05E1, 0x05D9, 0x05D5, 0x05DD, 0x0020, 0x05D4, 0x05D1, 0x05D7, 0x05D9, 0x05E8, 0x05D4, 0x002C, 0x0020, 0x05DC, 0x05D7, 0x05E6, 0x05D5, 0x0020, 0x05E2, 0x05DC, 0x0020, 0x0027, 0x05D4, 0x05D1, 0x05D0, 0x0027, 0x002C, 0x0020, 0x05D5, 0x05D4, 0x05DE, 0x05E2, 0x05E8, 0x05DB, 0x05EA, 0x0020, 0x05EA, 0x05EA, 0x05D7, 0x05D9, 0x05DC, 0x0020, 0x05D1, 0x05D4, 0x05EA, 0x05E7, 0x05E0, 0x05D4, 0x0020, 0x05E9, 0x05E7, 0x05D8, 0x05D4, 0x0020, 0x05D1, 0x05E8, 0x05E7, 0x05E2, 0x0021, 0x000A)
$b14 = He @(0x000A)
$b15 = He @(0x05DC, 0x05D7, 0x05E6, 0x05D5, 0x0020, 0x05E2, 0x05DC, 0x0020, 0x0027, 0x05D4, 0x05D1, 0x05D0, 0x0027, 0x0020, 0x05DB, 0x05D3, 0x05D9, 0x0020, 0x05DC, 0x05D4, 0x05DE, 0x05E9, 0x05D9, 0x05DA, 0x002C, 0x0020, 0x05D0, 0x05D5, 0x0020, 0x05E2, 0x05DC, 0x0020, 0x0027, 0x05DC, 0x05D0, 0x0020, 0x05DE, 0x05E2, 0x05D5, 0x05E0, 0x05D9, 0x05D9, 0x05DF, 0x0027, 0x0020, 0x05DB, 0x05D3, 0x05D9, 0x0020, 0x05DC, 0x05E6, 0x05D0, 0x05EA, 0x0020, 0x05DE, 0x05DB, 0x05D0, 0x05DF, 0x002E)
$WelcomeIntroText.Text=(L ($b1+$b2+$b3) "").Trim();
$AboutTitleText.Text=(L (He @(0x05D7,0x05D5,0x05DE,0x05E8,0x05EA,0x0020,0x05D4,0x05DE,0x05E2,0x05E8,0x05DB,0x05EA)) "System Hardware")
$AboutBodyText.Text=Get-SystemHardwareAudit
$UsageTitleText.Text=(L $b9 "").Trim()
$UsageBodyText.Text=(L ($b10+$b11+$b12+$b13) "").Trim(); $HintText.Text=(L $b15 "").Trim()
Apply-Language

# Preflight
$phHe = He @(0x05D1, 0x05D5, 0x05D3, 0x05E7, 0x20, 0x05D7, 0x05D9, 0x05D1, 0x05D5, 0x05E8, 0x20, 0x2D, 0x57, 0x69, 0x6E, 0x67, 0x65, 0x74)
$psHe = He @(0x05DE, 0x05DE, 0x05EA, 0x05D9, 0x05E0, 0x05D9, 0x05DD, 0x2E, 0x2E, 0x2E)
$PreflightHeader.Text = L $phHe "Checking connectivity & Winget..."
$PreflightStatus.Text = L $psHe "Please wait..."

if ($SkipWelcome) {
    Write-Log "Starting in SkipWelcome mode"
    $StartupOverlay.Visibility = 'Collapsed'
    $MainBorder.Visibility = 'Visible'
    $MainArea.IsEnabled = $true
    $MainArea.Opacity = 1
    
    if ($MenuPath -and (Test-Path -LiteralPath $MenuPath)) {
        Write-Log "Loading menu from parameter path: $MenuPath"
        . $MenuPath
    } else {
        $tempMenuPath = Join-Path $script:scriptDir "menu.ps1"
        try {
            Write-Log "Loading local menu from $tempMenuPath"
            . $tempMenuPath
        } catch {
            Write-Log "Failed to download menu: $_"
            [System.Windows.MessageBox]::Show("Error loading menu from GitHub: " + $_.Exception.Message)
            $window.Close()
            exit
        }
    }
    Initialize-CategoryVms
    Render-SideMenu
    Show-Category
    Play-Sound
}
$window.Add_Loaded({
    $introPath = Join-Path $script:scriptDir "intro.mp4"
    if (Test-Path -LiteralPath $introPath) {
        $IntroOverlay.Visibility = 'Visible'
        $IntroVideo.Source = [Uri]::new($introPath)
        $IntroVideo.Play()
    }
})
$BtnSkipIntro.Add_Click({
    $IntroVideo.Stop()
    $IntroOverlay.Visibility = 'Collapsed'
})
$IntroVideo.Add_MediaEnded({
    $IntroOverlay.Visibility = 'Collapsed'
})

$window.ShowDialog()|Out-Null

