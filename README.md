# 🚀 WinFlexSetupModern

**WinFlexSetupModern** is a modern Windows setup & optimization app written in PowerShell (WPF GUI). It scans your PC's hardware, installs your apps with winget, and applies targeted optimizations based on your usage profile — with a System Restore Point, a full HTML report of every change, and one-click UNDO.

---

## ⚡ Quick Start

1. Open **Windows PowerShell** as **Administrator**.
2. Paste the following command and press Enter:

```powershell
irm https://raw.githubusercontent.com/dor2500/WinFlexSetupModern/master/WinFlexSetupModern.ps1 | iex
```

The app downloads its companion files (`menu.ps1`, `HardwareAuditAndPrivacy.ps1`) automatically.

Prefer the console engine only (no GUI)?

```powershell
irm https://raw.githubusercontent.com/dor2500/WinFlexSetupModern/master/HardwareAuditAndPrivacy.ps1 | iex
```

You can also download the files from the [latest release](https://github.com/dor2500/WinFlexSetupModern/releases/latest), keep them in one folder and run `WinFlexSetupModern.ps1`.

---

## 📁 Files

| File | Purpose |
|------|---------|
| `WinFlexSetupModern.ps1` | The main app (GUI): hardware overview, app installer, tweaks and profiles. |
| `menu.ps1` | The app's menu: categories, apps and tweak entries. |
| `HardwareAuditAndPrivacy.ps1` | The optimization engine: profiles 1–13, restore point, HTML report, crash-safe UNDO. Can also run on its own. |

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
* **UNDO**: Profile 6 restores every recorded change, even from a run that was interrupted.
* **Open Source**: The code is 100% transparent — read `HardwareAuditAndPrivacy.ps1` to see exactly which registry keys and services are modified.
* **Usage**: Use at your own risk. This tool is intended for advanced users who want to maximize their hardware's potential.
