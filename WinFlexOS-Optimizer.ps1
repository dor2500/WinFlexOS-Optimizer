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
    
    Write-Host "   * CPU: $($script:cpu.Name)" -ForegroundColor Green
    Write-Host "     - $($script:cpu.NumberOfCores) Cores / $($script:cpu.NumberOfLogicalProcessors) Threads | Base Clock: $($script:cpu.MaxClockSpeed) MHz" -ForegroundColor DarkGray
    
    Write-Host "   * RAM: $($script:totalRamGB) GB Installed" -ForegroundColor Green
    $stickIdx = 1
    foreach ($stick in $ramSticks) {
        $stickGb = [math]::Round($stick.Capacity / 1GB, 1)
        Write-Host "     - Stick $($stickIdx): $stickGb GB | Speed: $($stick.ConfiguredClockSpeed) MHz (Maker: $($stick.Manufacturer))" -ForegroundColor DarkGray
        $stickIdx++
    }
    
    Write-Host "   * GPU(s):" -ForegroundColor Green
    foreach ($gpu in $script:gpus) { 
        $vram = if ($gpu.AdapterRAM -gt 0) { "$([math]::Round($gpu.AdapterRAM / 1GB, 2)) GB VRAM" } else { "Shared RAM" }
        Write-Host "     - $($gpu.Name) [$vram] (Driver: $($gpu.DriverVersion))" -ForegroundColor DarkCyan 
    }
    
    Write-Host "   * Storage:" -ForegroundColor Green
    $script:hasSSD = $false
    foreach ($d in $disks) {
        if ($d.MediaType -eq "SSD" -or $d.BusType -eq "NVMe") { $script:hasSSD = $true }
        Write-Host "     - $($d.FriendlyName) : $([math]::Round($d.Size / 1GB, 1)) GB | Media: $($d.MediaType) $($d.BusType)" -ForegroundColor DarkGray
    }
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
    
    $choice = ""
    while ($choice -notmatch "^[1-3]$") {
        $choice = Read-Host "Enter profile number (1/2/3)"
    }
    $script:UserProfile = $choice
}

# ==============================================================================
# 3. Deep Debloat (GitHub Community Standard)
# ==============================================================================
function Invoke-DeepDebloat {
    Write-Host "`n[*] Performing Deep Debloat and removing telemetry (GitHub Standard)..." -ForegroundColor Cyan
    
    # 1. Disable Microsoft Telemetry Services
    $telemetryServices = @("DiagTrack", "dmwappushservice", "WerSvc")
    foreach ($svc in $telemetryServices) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    }
    
    # 2. Disable Bing Web Search in Start Menu (Improves search speed significantly)
    New-Item -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # 3. Disable Delivery Optimization (Prevents Windows from using upload bandwidth for P2P updates)
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

    # 4. Disable Windows Copilot and Windows Recall (Privacy & RAM saving)
    try {
        New-Item -Path "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "DisableRecall" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    } catch {}

    # 5. Remove UWP Bloatware
    $bloatware = @(
        "Microsoft.BingNews", "Microsoft.MicrosoftSolitaireCollection", "Microsoft.NetworkSpeedTest",
        "Microsoft.SkypeApp", "Microsoft.WindowsFeedbackHub", "Microsoft.ZuneVideo", "Microsoft.ZuneMusic",
        "SpotifyAB.SpotifyMusic", "Clipchamp.Clipchamp", "Microsoft.Todos", "Microsoft.YourPhone"
    )
    foreach ($app in $bloatware) {
        Get-AppxPackage -Name "*$app*" -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 4. Profile-Based Hardware Optimization
# ==============================================================================
function Invoke-HardwareOptimizationAndRecommendations {
    $profileName = switch ($script:UserProfile) {
        "1" { "Gaming" }
        "2" { "Office" }
        "3" { "Content Creation" }
    }
    
    Write-Host "`n========================================================" -ForegroundColor Magenta
    Write-Host "   Phase 3: Applying Profile-Based Tweaks ($profileName)" -ForegroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Magenta
    
    $appliedTweaks = [System.Collections.Generic.List[string]]::new()

    # --- 1. System Restore Point ---
    Write-Host "[*] Creating System Restore Point..." -ForegroundColor Cyan
    try {
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue | Out-Null
        Checkpoint-Computer -Description "Before Auto-Hardware-Mod" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
    } catch {}

    # --- 2. SSD Optimization ---
    if ($script:hasSSD) {
        fsutil behavior set DisableDeleteNotify 0 | Out-Null
        Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue | Out-Null
        
        # Disable SysMain (Superfetch) on SSDs to prevent high disk I/O spikes
        Stop-Service -Name "SysMain" -Force -ErrorAction SilentlyContinue
        Set-Service -Name "SysMain" -StartupType Disabled -ErrorAction SilentlyContinue
        
        $appliedTweaks.Add("Enabled TRIM for SSDs and disabled SysMain (Superfetch) to eliminate disk I/O spikes.")
    }

    # --- 3. Profile-Specific Tweaks ---
    if ($script:UserProfile -eq "1") {
        # GAMING
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        
        # Globally Disable Fullscreen Optimizations (Forces true FSE for lower input lag)
        Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehaviorMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_HonorUserFSEBehaviorMode" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehavior" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
        
        $appliedTweaks.Add("Enabled Windows Game Mode and forced true Full-Screen Exclusive (FSE) to eliminate input lag.")

        if ($script:totalRamGB -ge 16) {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 0xFFFFFFFF -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 10 -Type DWord -Force -ErrorAction SilentlyContinue
            
            # MMCSS Games Task Priority Tweaks
            try {
                New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name "GPU Priority" -Value 8 -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name "Priority" -Value 6 -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name "Scheduling Category" -Value "High" -Type String -Force -ErrorAction SilentlyContinue
            } catch {}
            
            $appliedTweaks.Add("Removed Network Throttling and optimized MMCSS GPU Priority for gaming.")
        }
        
        # Advanced Network (TCP/IP & LSO)
        try {
            # Disable Network Adapter Power Saving & EEE (Green Ethernet)
            Disable-NetAdapterPowerManagement -Name "*" -ErrorAction SilentlyContinue | Out-Null
            Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match "Energy Efficient|Green Ethernet" } | Set-NetAdapterAdvancedProperty -RegistryValue "0" -ErrorAction SilentlyContinue
            
            netsh int tcp set global heuristics=disabled | Out-Null
            netsh int tcp set global autotuninglevel=normal | Out-Null
            Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue | Where-Object {$_.DisplayName -match "Large Send Offload"} | Set-NetAdapterAdvancedProperty -RegistryValue "0" -ErrorAction SilentlyContinue
            $appliedTweaks.Add("Optimized TCP/IP, disabled LSO, and disabled Energy Efficient Ethernet (EEE) to prevent latency spikes.")
            
            # Disable Nagle's Algorithm (TCPNoDelay & TcpAckFrequency)
            $interfacesPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
            $interfaces = Get-ChildItem -Path $interfacesPath -ErrorAction SilentlyContinue
            foreach ($iface in $interfaces) {
                $hasIP = Get-ItemProperty -Path $iface.PSPath -Name "IPAddress" -ErrorAction SilentlyContinue
                $hasDHCP = Get-ItemProperty -Path $iface.PSPath -Name "DhcpIPAddress" -ErrorAction SilentlyContinue
                if ($hasIP -or $hasDHCP) {
                    Set-ItemProperty -Path $iface.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $iface.PSPath -Name "TCPNoDelay" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                }
            }
            $appliedTweaks.Add("Disabled Nagle's Algorithm to drastically reduce packet latency (Ping).")
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

        # VBS / Memory Integrity (HVCI) Disable for Win11 Gaming
        try {
            New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name "Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            $appliedTweaks.Add("Disabled VBS & Memory Integrity (HVCI) for maximum gaming performance.")
        } catch {}

        # Disable CPU Mitigations (Spectre/Meltdown) for raw CPU throughput
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "FeatureSettingsOverride" -Value 3 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "FeatureSettingsOverrideMask" -Value 3 -Type DWord -Force -ErrorAction SilentlyContinue
            $appliedTweaks.Add("Disabled CPU Mitigations (Spectre/Meltdown) to maximize processor throughput.")
        } catch {}

        # Disable Mouse Acceleration
        Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "0" -Type String -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "0" -Type String -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "0" -Type String -Force -ErrorAction SilentlyContinue
        $appliedTweaks.Add("Disabled Mouse Acceleration (Enhance Pointer Precision) for raw 1:1 aiming.")

        # Power Plan (Unpark cores) & Hibernation
        if (-not $script:IsLaptop) {
            powercfg -attributes SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 -ATTRIB_HIDE 2>$null | Out-Null
            $ultimateGuidOutput = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
            if ($ultimateGuidOutput -match "([A-Fa-f0-9\-]{36})") {
                powercfg -setactive $matches[1]
                $appliedTweaks.Add("Enabled Ultimate Performance power plan and unparked CPU cores.")
            } else {
                powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
            }
            
            # Disable Hibernation / Fast Startup on gaming desktops
            try {
                powercfg -h off 2>$null | Out-Null
                $appliedTweaks.Add("Disabled Hibernation and Fast Startup (freed up massive SSD space and ensures clean driver boots).")
            } catch {}
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
    
    # Global tweaks
    $appliedTweaks.Add("Disabled Windows Update Delivery Optimization (stops upload bandwidth drain).")
    $appliedTweaks.Add("Disabled Windows Copilot & Recall AI features for maximum privacy and RAM savings.")
    $appliedTweaks.Add("Removed built-in Bloatware UWP apps (Skype, junk apps, etc.).")
    
    # --- Summary ---
    Write-Host "`n========================================================" -ForegroundColor Magenta
    Write-Host "   Summary of Applied Tweaks" -ForegroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Magenta
    foreach ($tweak in $appliedTweaks) {
        Write-Host " [✓] $tweak" -ForegroundColor Green
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
Invoke-DeepDebloat
Invoke-HardwareOptimizationAndRecommendations

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "   Process completed successfully! A system restart is highly recommended." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Pause
