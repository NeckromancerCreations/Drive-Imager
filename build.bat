@echo off
rem Rebuilds DriveImager.exe from source using the C# compiler built into Windows (.NET Framework 4).
cd /d "%~dp0"
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /optimize+ /win32icon:app.ico /resource:DriveImager.ps1,DriveImager.ps1 /resource:DriveImager_Restore.cmd,DriveImager_Restore.cmd /out:DriveImager.exe DriveImager.cs
pause
