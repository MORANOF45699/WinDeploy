@echo off
REM Right-click this file and choose "Run as administrator".
REM The script re-launches itself elevated and in STA mode if needed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0WinDeploy.ps1"
