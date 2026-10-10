@echo off
title WinFlexOS Hardware Audit & Modder (CLI)
echo ========================================================
echo   WinFlexOS - Requesting Administrator Privileges...
echo ========================================================

:: Check for Administrator privileges
net session >nul 2>&1
if %errorLevel% == 0 (
    echo [OK] Administrator privileges detected. Launching CLI...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0HardwareAuditAndPrivacy.ps1"
) else (
    echo [!] Requesting Administrator privileges (UAC)...
    powershell.exe -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0HardwareAuditAndPrivacy.ps1\"' -Verb RunAs"
)
