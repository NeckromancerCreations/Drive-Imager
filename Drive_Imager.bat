@echo off
rem Starts Drive Imager. It asks for administrator rights on its own.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0DriveImager.ps1"
