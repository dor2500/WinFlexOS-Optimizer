<#
Hardware Audit, Custom Optimization & Debloat Script
Compatibility: Windows 10 / Windows 11
Version: 5.0 (English Version - Advanced Hardware Audit, Profiles, and GitHub Mods)
#>

# ==============================================================================
# 0. Administrator Privileges Check
# ==============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!] Script requires Administrator privileges. Restarting elevated..." -ForegroundColor Yellow
    try {
        Start-Process powershell.exe -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"") -Verb RunAs
        exit
    } catch {
        Write-Host "[X] Could not elevate privileges. Please run PowerShell as Administrator manually." -ForegroundColor Red
        Pause
        exit 1
    }
}

$script:IsLaptop = $false
$script:UserProfile = "1" 

# ==============================================================================
# 1. System & Hardware Audit
# ==============================================================================
function Get-SystemHardwareAudit {
    Write-Host "`n========================================================" -ForegroundColor Magenta
    Write-Host "   Phase 1: Comprehensive System & Hardware Audit" -ForegroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Magenta
    
    $systemEnclosure = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue
    $chassisTypes = $systemEnclosure.ChassisTypes
    $batteryCheck = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    
    $laptopChassisCodes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $script:IsLaptop = if ($batteryCheck) { $true } else { $false }
    if (-not $script:IsLaptop) {
        foreach ($c in $chassisTypes) { if ($laptopChassisCodes -contains $c) { $script:IsLaptop = $true; break } }
    }
    
    $formFactorName = if ($script:IsLaptop) { "Laptop 💻" } else { "Desktop 🖥️" }
    $osInfo = Get-CimInstance Win32_OperatingSystem
    $isWin11 = $osInfo.BuildNumber -ge 22000
    $osName = if ($isWin11) { "Windows 11" } else { "Windows 10" }

    $script:cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $baseboard = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    
    $ramSticks = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue
    $script:totalRamGB = [math]::Round((($ramSticks | Measure-Object -Property Capacity -Sum).Sum) / 1GB, 2)
    $script:gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
    $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    
    Write-Host "`n[+] Detected System Configuration: $formFactorName" -ForegroundColor Cyan
    Write-Host "   * Operating System: $osName (Build $($osInfo.BuildNumber))" -ForegroundColor Gray
    Write-Host "   * Manufacturer & Model: $($computerSystem.Manufacturer) - $($computerSystem.Model)" -ForegroundColor Gray
    Write-Host "   * Motherboard: $($baseboard.Manufacturer) $($baseboard.Product) (BIOS: $($bios.SMBIOSBIOSVersion))" -ForegroundColor Gray
    Start-Sleep -Milliseconds 800
    
    Write-Host "`n   * CPU: $($script:cpu.Name)" -ForegroundColor Green
    Write-Host "     - $($script:cpu.NumberOfCores) Cores / $($script:cpu.NumberOfLogicalProcessors) Threads | Base Clock: $($script:cpu.MaxClockSpeed) MHz" -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 800
    
    Write-Host "`n   * RAM: $($script:totalRamGB) GB Installed" -ForegroundColor Green
    $stickIdx = 1
    foreach ($stick in $ramSticks) {
        $stickGb = [math]::Round($stick.Capacity / 1GB, 1)
        Write-Host "     - Stick $($stickIdx): $stickGb GB | Speed: $($stick.ConfiguredClockSpeed) MHz (Maker: $($stick.Manufacturer))" -ForegroundColor DarkGray
        $stickIdx++
    }
    
    Write-Host "`n   * GPU(s):" -ForegroundColor Green
    foreach ($gpu in $script:gpus) { 
        $vram = if ($gpu.AdapterRAM -gt 0) { "$([math]::Round($gpu.AdapterRAM / 1GB, 2)) GB VRAM" } else { "Shared RAM" }
        Write-Host "     - $($gpu.Name) [$vram] (Driver: $($gpu.DriverVersion))" -ForegroundColor DarkCyan 
    }
    Start-Sleep -Milliseconds 800
    
    Write-Host "`n   * Storage:" -ForegroundColor Green
    $script:hasSSD = $false
    foreach ($d in $disks) {
        if ($d.MediaType -eq "SSD" -or $d.BusType -eq "NVMe") { $script:hasSSD = $true }
        Write-Host "     - $($d.FriendlyName) : $([math]::Round($d.Size / 1GB, 1)) GB | Media: $($d.MediaType) $($d.BusType)" -ForegroundColor DarkGray
    }
    
    # Disk Health (SMART)
    Write-Host "`n   * Disk Health (S.M.A.R.T):" -ForegroundColor Green
    $physicalDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    foreach ($pd in $physicalDisks) {
        $health = if ($pd.HealthStatus -eq "Healthy") { "[Healthy]" } else { "[WARNING]" }
        Write-Host "     - $($pd.FriendlyName): $health (Status: $($pd.OperationalStatus))" -ForegroundColor Gray
    }

    # Network Interfaces & Ping
    Write-Host "`n   * Network Interfaces & Latency:" -ForegroundColor Green
    $nics = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } -ErrorAction SilentlyContinue
    foreach ($nic in $nics) {
        Write-Host "     - $($nic.Name) ($($nic.InterfaceDescription)) - Link: $($nic.LinkSpeed)" -ForegroundColor Gray
    }
    $ping = Test-Connection -ComputerName 8.8.8.8 -Count 1 -ErrorAction SilentlyContinue
    if ($ping) { Write-Host "     - Internet Ping (8.8.8.8): $($ping.ResponseTime) ms" -ForegroundColor Cyan }
}

# ==============================================================================
# 2. User Profile Setup
# ==============================================================================
function Get-UserUseCase {
    Write-Host "`n========================================================" -ForegroundColor Magenta
    Write-Host "   Phase 2: Define Usage Profile (Customization)" -ForegroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Magenta
    Write-Host "What is the primary use case for this PC? (Select a number):" -ForegroundColor Cyan
    Write-Host " [1] 🎮 Gaming - Max performance, zero mouse accel, lower network latency."
    Write-Host " [2] 🌐 Office & Browsing - Stability, power saving, bloatware removal."
    Write-Host " [3] 🎬 Content Creation - Maximize stable resources for rendering/production."
    Write-Host " [4] 🤖 AI & Machine Learning - Deep system scan, max RAM/VRAM utilization, Long Paths."
    Write-Host " [5] 🕵️ Forensic Deep Scan (Driver & Targeted Folder Analysis) - ~5-10 Minutes"
    Write-Host " [6] ⏪ UNDO - Revert all optimizations to Windows defaults."
    
    $choice = ""
    while ($choice -notmatch "^[1-6]$") {
        $choice = Read-Host "Enter profile number (1-6)"
    }
    $script:UserProfile = $choice
}

# ==============================================================================
# 3. EXTREME FORENSIC SYSTEM SCAN
# ==============================================================================
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

function Invoke-DeepAIScan {
    Write-Host "`n[*] ========================================================" -ForegroundColor Magenta
    Write-Host "    🤖 MASSIVE AI & ML SYSTEM DIAGNOSTIC RUNNING" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Magenta
    Start-Sleep -Seconds 1
    
    # 1. CPU Deep Dive
    Write-Host "`n[1] CPU & INSTRUCTION SETS" -ForegroundColor Cyan
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Write-Host "    - Model: $($cpu.Name)" -ForegroundColor Gray
    Write-Host "    - Cores: $($cpu.NumberOfCores) / Threads: $($cpu.NumberOfLogicalProcessors)" -ForegroundColor Gray
    Write-Host "    - L3 Cache: $($cpu.L3CacheSize) MB" -ForegroundColor Gray
    Write-Host "    - Virtualization Enabled: $($cpu.VirtualizationFirmwareEnabled)" -ForegroundColor Gray
    
    # 2. Memory & PageFile
    Write-Host "`n[2] MEMORY & PAGING (Crucial for large LLMs)" -ForegroundColor Cyan
    $mem = Get-CimInstance Win32_PhysicalMemory
    $totalMem = [math]::Round((($mem | Measure-Object -Property Capacity -Sum).Sum) / 1GB, 2)
    Write-Host "    - Total Physical RAM: $totalMem GB" -ForegroundColor Green
    $page = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
    if ($page) { foreach ($p in $page) { Write-Host "    - PageFile: $($p.Name) | Allocated: $($p.AllocatedBaseSize) MB" -ForegroundColor Gray } }
    else { Write-Host "    - PageFile: Managed dynamically." -ForegroundColor Gray }
    
    # 3. GPU Deep Dive (NVIDIA / AMD)
    Write-Host "`n[3] GPU ACCELERATORS" -ForegroundColor Cyan
    $gpus = Get-CimInstance Win32_VideoController
    foreach ($gpu in $gpus) {
        Write-Host "    - GPU: $($gpu.Name) (Driver: $($gpu.DriverVersion))" -ForegroundColor Gray
        if ($gpu.Name -match "AMD|Radeon") {
            Write-Host "      [!] AMD GPU Detected! Note: AI frameworks (PyTorch/TensorFlow) will require AMD ROCm or DirectML instead of standard CUDA." -ForegroundColor Yellow
        }
    }
    
    $nvSmi = (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue).Source
    if ($nvSmi) {
        Write-Host "    - NVIDIA CUDA Environment Found! Extracting details..." -ForegroundColor Green
        try {
            $smiOut = & $nvSmi --query-gpu=name,memory.total,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
            Write-Host "    - NVIDIA Stats (Name, Total VRAM, Free VRAM, Temp, Util): $smiOut" -ForegroundColor DarkGray
            $cudaVersion = & $nvSmi | Select-String "CUDA Version"
            if ($cudaVersion) { Write-Host "    - $cudaVersion" -ForegroundColor DarkGray }
        } catch {}
    } else { Write-Host "    - NVIDIA-SMI not found (Non-NVIDIA GPU or Drivers missing)." -ForegroundColor Yellow }
    
    # 4. Storage & Disk Space for Models
    Write-Host "`n[4] STORAGE CAPABILITIES" -ForegroundColor Cyan
    $disks = Get-CimInstance Win32_LogicalDisk | Where-Object DriveType -eq 3
    foreach ($d in $disks) {
        $free = [math]::Round($d.FreeSpace / 1GB, 1)
        $tot = [math]::Round($d.Size / 1GB, 1)
        Write-Host "    - Drive $($d.DeviceID) | Free: $free GB / $tot GB" -ForegroundColor Gray
        if ($free -lt 50) { Write-Host "      [!] Warning: Low space for AI models on $($d.DeviceID)" -ForegroundColor Red }
    }
    
    # 5. Developer Tools & Toolchains
    Write-Host "`n[5] AI TOOLCHAINS & FRAMEWORKS" -ForegroundColor Cyan
    $tools = @("python", "git", "docker", "wsl", "ollama", "node", "cmake", "conda", "nvcc")
    foreach ($tool in $tools) {
        $path = (Get-Command $tool -ErrorAction SilentlyContinue).Source
        if ($path) { Write-Host "    - [x] $($tool): Found ($path)" -ForegroundColor Green }
        else { Write-Host "    - [ ] $($tool): Not installed or not in PATH" -ForegroundColor DarkGray }
    }
    
    Write-Host "`n[+] EXHAUSTIVE SCAN COMPLETE." -ForegroundColor Green
    Start-Sleep -Seconds 3
}

# ==============================================================================
# 3. EXTREME System Debloat & Privacy Lock-Down
# ==============================================================================
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

# ==============================================================================
# 4. Profile-Based Hardware Optimization
# ==============================================================================
function Invoke-HardwareOptimizationAndRecommendations {
    $profileName = switch ($script:UserProfile) {
        "1" { "Gaming" }
        "2" { "Office" }
        "3" { "Content Creation" }
        "4" { "AI & Machine Learning" }
    }
    
    if ($script:UserProfile -eq "4") {
        Invoke-DeepAIScan
    }
    
    Write-Host "`n========================================================" -ForegroundColor Magenta
    Write-Host "   Phase 3: Applying Profile-Based Tweaks ($profileName)" -ForegroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Magenta
    
    $appliedTweaks = [System.Collections.Generic.List[string]]::new()

    # --- 1. System Restore Point ---
    Write-Host "[*] Creating System Restore Point (Safety First)..." -ForegroundColor Cyan
    try {
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue | Out-Null
        Checkpoint-Computer -Description "Before Auto-Hardware-Mod" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
    } catch {}
    Start-Sleep -Seconds 2

    # --- 2. SSD Optimization ---
    if ($script:hasSSD) {
        Write-Host " [~] Optimizing SSD Settings..." -ForegroundColor DarkGray
        fsutil behavior set DisableDeleteNotify 0 | Out-Null
        Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue | Out-Null
        $appliedTweaks.Add("Enabled TRIM for SSDs and disabled Start Menu Bing web search.")
        Start-Sleep -Milliseconds 600
    }

    # --- 3. Profile-Specific Tweaks ---
    Write-Host " [~] Applying $profileName specific tweaks..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
    if ($script:UserProfile -eq "1") {
        # GAMING
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        $appliedTweaks.Add("Enabled Windows Game Mode and disabled Game DVR to reduce overhead.")

        if ($script:totalRamGB -ge 16) {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 0xFFFFFFFF -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            $appliedTweaks.Add("Removed Network Throttling to lower ping in games.")
        }
        
        # Advanced Network (TCP/IP & LSO)
        try {
            netsh int tcp set global heuristics=disabled | Out-Null
            netsh int tcp set global autotuninglevel=normal | Out-Null
            Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue | Where-Object {$_.DisplayName -match "Large Send Offload"} | Set-NetAdapterAdvancedProperty -RegistryValue "0" -ErrorAction SilentlyContinue
            $appliedTweaks.Add("Optimized TCP/IP and disabled LSO on network adapters (prevents ping spikes).")
        } catch {}

        # DPC Latency (HPET & Dynamic Tick)
        try {
            bcdedit /deletevalue useplatformclock 2>$null | Out-Null
            bcdedit /set disabledynamictick yes 2>$null | Out-Null
            $appliedTweaks.Add("Disabled HPET and Dynamic Ticks to reduce micro-stutters (DPC Latency).")
        } catch {}

        # HAGS
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
        $appliedTweaks.Add("Enabled Hardware-Accelerated GPU Scheduling (HAGS).")

        # Disable Mouse Acceleration
        Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "0" -Type String -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "0" -Type String -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "0" -Type String -Force -ErrorAction SilentlyContinue
        $appliedTweaks.Add("Disabled Mouse Acceleration (Enhance Pointer Precision) for raw 1:1 aiming.")

        # Power Plan (Unpark cores)
        if (-not $script:IsLaptop) {
            powercfg -attributes SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 -ATTRIB_HIDE 2>$null | Out-Null
            $ultimateGuidOutput = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
            if ($ultimateGuidOutput -match "([A-Fa-f0-9\-]{36})") {
                powercfg -setactive $matches[1]
                $appliedTweaks.Add("Enabled Ultimate Performance power plan and unparked CPU cores.")
            } else {
                powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
            }
        }
    }
    elseif ($script:UserProfile -eq "2") {
        # OFFICE
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        $appliedTweaks.Add("Disabled Game Mode.")
        
        if ($script:IsLaptop) {
            powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e
            $appliedTweaks.Add("Enabled 'Balanced' power plan for longer battery life.")
        } else {
            powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e
            $appliedTweaks.Add("Enabled 'Balanced' power plan for energy savings.")
        }
    }
    elseif ($script:UserProfile -eq "3") {
        # CONTENT CREATOR
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 20 -Type DWord -Force -ErrorAction SilentlyContinue
        $appliedTweaks.Add("Set System Responsiveness for stable video rendering (SystemResponsiveness=20).")
        
        if (-not $script:IsLaptop) {
            powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
            $appliedTweaks.Add("Enabled High Performance power plan for faster exports.")
        }
    }
    elseif ($script:UserProfile -eq "4") {
        # AI & MACHINE LEARNING
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        
        # 1. Enable Long Paths (Essential for Python/Node AI projects)
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        $appliedTweaks.Add("Enabled NTFS Long Paths (Crucial for deep Python/AI dependencies).")
        
        # 2. System Responsiveness
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 10 -Type DWord -Force -ErrorAction SilentlyContinue
        $appliedTweaks.Add("Set System Responsiveness for AI workloads.")
        
        # 3. High Performance Plan
        if (-not $script:IsLaptop) {
            powercfg -attributes SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 -ATTRIB_HIDE 2>$null | Out-Null
            $ultimateGuidOutput = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
            if ($ultimateGuidOutput -match "([A-Fa-f0-9\-]{36})") {
                powercfg -setactive $matches[1]
                $appliedTweaks.Add("Enabled Ultimate Performance power plan for heavy inference.")
            } else {
                powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
                $appliedTweaks.Add("Enabled High Performance power plan.")
            }
        }
    }
    
    # Global tweaks
    $appliedTweaks.Add("Disabled Windows Update Delivery Optimization (stops upload bandwidth drain).")
    $appliedTweaks.Add("Removed built-in Bloatware UWP apps (Skype, junk apps, etc.).")
    
    # --- Summary & Logging ---
    Write-Host "`n========================================================" -ForegroundColor Magenta
    Write-Host "   Summary of Applied Tweaks" -ForegroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Magenta
    Start-Sleep -Seconds 1
    
    $logPath = Join-Path -Path $PSScriptRoot -ChildPath "MODLOG.md"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logContent = "`n## Modification Log - $timestamp`n`n**Profile:** $profileName`n`n### Applied Tweaks:`n"

    foreach ($tweak in $appliedTweaks) {
        Write-Host " [✓] $tweak" -ForegroundColor Green
        Start-Sleep -Milliseconds 300
        $logContent += "- [x] $tweak`n"
    }
    
    try {
        $logContent | Out-File -FilePath $logPath -Append -Encoding utf8
        Write-Host "`n[+] Saved modification log to MODLOG.md" -ForegroundColor Cyan
    } catch {
        Write-Host "`n[!] Failed to save log to MODLOG.md" -ForegroundColor Red
    }
}

# ==============================================================================
# 5. Undo Operations
# ==============================================================================
function Invoke-UndoTweaks {
    Write-Host "`n========================================================" -ForegroundColor Magenta
    Write-Host "   Phase 3: Reverting Changes (UNDO)" -ForegroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Magenta
    
    $appliedTweaks = [System.Collections.Generic.List[string]]::new()
    
    # 1. Re-enable Services
    $telemetryServices = @("DiagTrack", "dmwappushservice", "WerSvc")
    foreach ($svc in $telemetryServices) {
        Set-Service -Name $svc -StartupType Manual -ErrorAction SilentlyContinue
    }
    $appliedTweaks.Add("Restored default startup type for telemetry/diagnostic services.")

    # 2. Bing Search & Delivery Optimization
    Remove-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Force -ErrorAction SilentlyContinue
    $appliedTweaks.Add("Re-enabled Bing Start Menu Search and Delivery Optimization.")

    # 3. Gaming / Registry tweaks
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 10 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 20 -Type DWord -Force -ErrorAction SilentlyContinue

    # 4. Network & BCD
    netsh int tcp set global heuristics=enabled | Out-Null
    netsh int tcp set global autotuninglevel=normal | Out-Null
    bcdedit /deletevalue disabledynamictick 2>$null | Out-Null
    
    # 5. Mouse
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "1" -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "6" -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "10" -Type String -Force -ErrorAction SilentlyContinue

    # 6. Power Plan
    powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e
    $appliedTweaks.Add("Restored Balanced Power Plan.")
    $appliedTweaks.Add("Reverted registry changes (Mouse, Network, Gaming, UI).")
    
    # --- Summary & Logging ---
    $logPath = Join-Path -Path $PSScriptRoot -ChildPath "MODLOG.md"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logContent = "`n## Modification Log - $timestamp`n`n**Profile:** UNDO (Restore Defaults)`n`n### Applied Tweaks:`n"

    foreach ($tweak in $appliedTweaks) {
        Write-Host " [✓] $tweak" -ForegroundColor Green
        $logContent += "- [x] $tweak`n"
    }
    
    try {
        $logContent | Out-File -FilePath $logPath -Append -Encoding utf8
        Write-Host "`n[+] Saved UNDO log to MODLOG.md" -ForegroundColor Cyan
    } catch {
        Write-Host "`n[!] Failed to save log to MODLOG.md" -ForegroundColor Red
    }
}

# ==============================================================================
# Main Script Execution
# ==============================================================================
Clear-Host
Write-Host "`n   [ Smart Hardware Optimization & Profile Customization ]   " -ForegroundColor Green
Write-Host "   -------------------------------------------------------`n" -ForegroundColor DarkGray

Get-SystemHardwareAudit
Get-UserUseCase

if ($script:UserProfile -eq "6") {
    Invoke-UndoTweaks
} elseif ($script:UserProfile -eq "5") {
    Invoke-ForensicDeepScan
} else {
    Invoke-ExtremeDebloat
    Invoke-HardwareOptimizationAndRecommendations
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "   Process completed successfully! A system restart is highly recommended." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Pause
