# 🚀 WinFlexSetupModern

**WinFlexSetupModern** is a Windows optimization & setup tool written in PowerShell. It scans your PC's hardware and applies targeted optimizations based on your usage profile — with a System Restore Point, a full HTML report of every change, and one-click UNDO. A graphical app (WPF) with a winget app installer is built in as well.

---

## ⚡ Quick Start

1. Open **Windows PowerShell** as **Administrator**.
2. Paste the following command and press Enter:

```powershell
irm https://raw.githubusercontent.com/dor2500/WinFlexSetupModern/master/WinFlexSetupModern.ps1 | iex
```

The script audits your hardware and shows the profile menu:
- Pick one profile (`1`) or several (`1,8,12`).
- You then see exactly what will run and choose **Run**, **Preview only** (a report of what *would* change, nothing is touched) or **Cancel**.
- Press **G** to open the graphical app instead (apps installer, tweaks, profiles).

Everything is in this one file. If PowerShell is not running as Administrator, the script asks for elevation by itself.

You can also download `WinFlexSetupModern.ps1` from the [latest release](https://github.com/dor2500/WinFlexSetupModern/releases/latest) and run it directly.

### Advanced

```powershell
.\WinFlexSetupModern.ps1 -Gui                     # open the graphical app directly
.\WinFlexSetupModern.ps1 -ProfileId 1,8,12        # run profiles without the menu
.\WinFlexSetupModern.ps1 -ProfileId 7 -DryRun     # preview only - changes nothing, still writes the report
```

---

## 🛠️ Features

### 1. 🔍 Comprehensive Hardware Audit
Before any changes are made, the app performs a deep scan of your system, including:
- Form factor and OS build version.
- Motherboard model and BIOS version.
- Exact CPU specifications (Cores/Threads and Base Clock).
- Detailed RAM topology (Capacity, Speed, and Manufacturer per stick).
- GPU VRAM and driver version.
- Storage media types (NVMe / SSD).

### 2. 🎯 Usage Profiles
* **🎮 Gaming**: Ultimate Performance plan, zero mouse acceleration, lower network latency (Nagle off, TCP heuristics off), HPET/dynamic tick tuning, HAGS, Game Mode, and ASUS Armoury Crate taming when ASUS hardware is detected.
* **🌐 Office & Browsing**: Stability and the Balanced power plan.
* **🎬 Content Creation**: Stable `SystemResponsiveness` and High Performance power plan for faster exports.
* **🤖 AI & Machine Learning**: Long paths, compute-friendly settings and an AI toolchain/GPU scan.
* **🛡️ Privacy Shield, ☢️ Nuclear Debloat, 🧼 Deep Cleanup, 🔒 Security Hardening, 🔋 Battery Saver, 🚀 Network Supercharger** and more.

### 3. 🧾 Full Transparency
Every run creates an interactive HTML report on the Desktop listing each service, scheduled task, registry value and app that was changed — with its value before and after and how to revert it. Use `-DryRun` to preview everything without changing anything.

---

## ⚠️ Disclaimer & Safety
* **Restore Point**: A System Restore Point is created before any change. If it cannot be created, the engine asks before continuing.
* **UNDO**: Profile 6 restores every recorded change, even from a run that was interrupted. Removed apps get a direct Microsoft Store link in the report so they can be reinstalled in one click.
* **Restart**: when a change needs a restart, the script offers to restart (30-second countdown, cancel with `shutdown /a`).
* **Open Source**: The code is 100% transparent — read `WinFlexSetupModern.ps1` to see exactly which registry keys and services are modified.
* **Usage**: Use at your own risk. This tool is intended for advanced users who want to maximize their hardware's potential.
