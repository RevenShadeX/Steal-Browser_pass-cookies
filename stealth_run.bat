@echo off
REM Save as: stealth_run.bat
REM This runs the PowerShell script silently with no window flash

powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0stealth_extract.ps1"