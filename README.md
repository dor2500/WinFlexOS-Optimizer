# 🚀 WinFlexOS Smart Optimizer

**WinFlexOS Optimizer** is a powerful, automated PowerShell utility designed to intelligently scan your PC's hardware and apply targeted optimizations based on your specific usage profile. 

Built with the community's best practices, this script goes beyond standard debloating by directly interacting with system hardware configurations (like CPU core parking, network LSO, and HPET timers) to extract maximum performance and stability.

---

## ⚡ Quick Start

You can run the optimizer on any Windows 10 or Windows 11 machine directly from the internet. No downloading or installation required!

1. Open **Windows PowerShell** as **Administrator**.
2. Copy and paste the following command into the console and press Enter:

```powershell
irm https://raw.githubusercontent.com/dor2500/WinFlexOS-Optimizer/master/WinFlexOS-Optimizer.ps1 | iex
```

---

## 🛠️ Features

### 1. 🔍 Comprehensive Hardware Audit
Before any changes are made, the script performs a deep scan of your system and displays a highly detailed report, including:
- Form factor and OS build version.
- Motherboard model and BIOS version.
- Exact CPU specifications (Cores/Threads and Base Clock).
- Detailed RAM topology (Capacity, Speed, and Manufacturer per stick).
- GPU VRAM and driver version.
- Storage media types (NVMe / SSD).

### 2. 🎯 Usage Profiles
WinFlexOS adapts to *you*. Upon execution, you will be prompted to choose a profile:
* **[1] 🎮 Gaming**: Unparks CPU cores, disables mouse acceleration for 1:1 aiming, disables network heuristics and LSO (to eliminate ping spikes), disables HPET for lower DPC latency, and turns on Game Mode/HAGS.
* **[2] 🌐 Office & Browsing**: Focuses on stability, enables 'Balanced' power plans for laptop battery savings, and removes system overhead.
* **[3] 🎬 Content Creation**: Adjusts `SystemResponsiveness` for stable rendering pipelines, and enables High Performance power profiles to speed up video exports without crashing.

### 3. 🧹 Deep Debloat (GitHub Standard)
Regardless of the profile chosen, the script ensures a clean baseline by:
- Disabling Microsoft Telemetry services.
- Removing built-in UWP Bloatware (Skype, Bing News, Get Help, Clipchamp, etc.).
- Disabling Bing Web Search in the Start Menu (significantly speeding up local file searches).
- Disabling Windows Update Delivery Optimization (stops Windows from stealing your upload bandwidth to seed updates).

---

## ⚠️ Disclaimer & Safety
* **Restore Point**: The script automatically attempts to create a Windows System Restore Point before making any changes.
* **Open Source**: The code is 100% transparent. Feel free to read the `WinFlexOS-Optimizer.ps1` source code to see exactly which registry keys and services are being modified.
* **Usage**: Use at your own risk. This script is intended for advanced users who want to maximize their hardware's potential.
