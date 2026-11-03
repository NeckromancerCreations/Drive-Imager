@echo off
rem ===========================================================================
rem  Drive Imager Restore wizard
rem  Run it from a Windows 10/11 install USB: at the first setup screen press
rem  Shift+F10, switch to the USB drive letter, and type DriveImager_Restore
rem ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion
title Drive Imager Restore
set "NETZ="
set "SELF=%~d0"
set "SELF=%SELF:~0,1%"

cls
echo ==============================================================
echo   DRIVE IMAGER RESTORE
echo   Puts a Drive Imager backup (.wim) back onto a disk.
echo   Type Q at any question to quit without changing anything.
echo ==============================================================
echo.

if /i not "%SystemDrive%"=="X:" (
    echo This only runs from a Windows install or recovery USB, not from inside Windows.
    echo.
    pause
    exit /b 1
)

wpeutil UpdateBootInfo >nul 2>&1
set "FW=UEFI"
for /f "tokens=3" %%a in ('reg query HKLM\System\CurrentControlSet\Control /v PEFirmwareType 2^>nul ^| find "PEFirmwareType"') do (
    if "%%a"=="0x1" set "FW=BIOS"
)
echo This PC started in %FW% mode, so the disk will be set up for %FW%.
echo.

rem ------------------------------------------------------------------ find images
:findimg
set /a N=0
echo Searching every drive for backup images. This can take a minute...
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist %%d:\ (
        call :scan "%%d:"
        for /d %%a in ("%%d:\*") do (
            call :scan "%%~fa"
            for /d %%b in ("%%~fa\*") do call :scan "%%~fb"
        )
    )
)

:menu
echo.
if %N%==0 (
    echo No backup images were found on the drives here.
) else (
    echo Backup images found:
    for /l %%i in (1,1,%N%) do (
        set "S=!SZ%%i!"
        set "GB=!S:~0,-9!"
        if not defined GB set "GB=under 1"
        echo   %%i.  !IMG%%i!     [about !GB! GB]
    )
)
echo.
echo   N.  Connect to a network share first
echo   P.  Type the path to an image myself
echo   R.  Search again
echo   Q.  Quit
echo.
set "CH="
set /p "CH=Your choice: "
if not defined CH goto menu
if /i "%CH%"=="Q" goto quit
if /i "%CH%"=="R" goto findimg
if /i "%CH%"=="N" goto network
if /i "%CH%"=="P" goto typepath
echo %CH%| findstr /r "^[0-9][0-9]*$" >nul || goto badchoice
if %CH% LSS 1 goto badchoice
if %CH% GTR %N% goto badchoice
set "IMG=!IMG%CH%!"
goto checkimg

:badchoice
echo That is not one of the choices.
goto menu

:typepath
set "IMG="
set /p "IMG=Full path to the .wim file: "
if not defined IMG goto menu
if /i "%IMG%"=="Q" goto quit
set "IMG=%IMG:"=%"
if not exist "!IMG!" (
    echo File not found: !IMG!
    goto menu
)
goto checkimg

rem ------------------------------------------------------------------ network
:network
echo.
echo Starting the network. This can take up to a minute...
wpeutil InitializeNetwork >nul 2>&1
wpeutil WaitForNetwork >nul 2>&1
ipconfig | find "IPv4"
echo.
echo If the server name does not work, use its IP address instead,
echo for example \\192.168.1.50\Backups
set "SHARE="
set /p "SHARE=Share path, like \\server\Backups : "
if not defined SHARE goto menu
if /i "%SHARE%"=="Q" goto quit
set "NUSER="
set /p "NUSER=User name for the share, or leave blank: "
net use Z: /delete /y >nul 2>&1
if defined NUSER (
    echo It will now ask for the password.
    net use Z: "%SHARE%" /user:%NUSER% *
) else (
    net use Z: "%SHARE%"
)
if errorlevel 1 (
    echo Could not connect. Check the path, the user name and the password.
    pause
    goto menu
)
set "NETZ=1"
echo Connected. The share is drive Z: now.
goto findimg

rem ------------------------------------------------------------------ check image
:checkimg
echo.
echo Checking %IMG% ...
dism /English /Get-ImageInfo /ImageFile:"%IMG%" /Index:1
if errorlevel 1 (
    echo This file could not be read as a Windows image. Pick another one.
    pause
    goto menu
)
set "ILTR=%IMG:~0,1%"
if "%IMG:~0,2%"=="\\" set "ILTR="
if defined NETZ if /i "%ILTR%"=="Z" set "ILTR="

rem ------------------------------------------------------------------ pick disk
:pickdisk
echo.
echo These are the disks in this PC:
> "%TEMP%\di_list.txt" echo list disk
diskpart /s "%TEMP%\di_list.txt" | findstr /r /c:"Disk [0-9]" /c:"Disk ###" /c:"--------"
echo.
echo Pick the disk that should get Windows back. Usually that is the disk
echo Windows was on before; match it by its size. If your disks are not
echo listed at all, this USB needs a storage driver for your PC.
echo EVERYTHING on the disk you pick will be erased.
echo.
set "DISK="
set /p "DISK=Disk number: "
if not defined DISK goto pickdisk
if /i "%DISK%"=="Q" goto quit
echo %DISK%| findstr /r "^[0-9][0-9]*$" >nul || (
    echo Type just the number, like 0.
    goto pickdisk
)
> "%TEMP%\di_detail.txt" (
    echo select disk %DISK%
    echo detail disk
)
diskpart /s "%TEMP%\di_detail.txt" > "%TEMP%\di_detail_out.txt"
if errorlevel 1 (
    echo There is no disk %DISK%.
    goto pickdisk
)
echo.
echo ---------------- Disk %DISK% ----------------
findstr /v /c:"Microsoft DiskPart" /c:"Copyright" /c:"On computer" /c:"is now the selected disk" "%TEMP%\di_detail_out.txt"
echo ---------------------------------------------

if defined ILTR (
    findstr /r /i /c:"Volume [0-9][0-9]*  *%ILTR% " "%TEMP%\di_detail_out.txt" >nul && (
        echo.
        echo STOP: the backup image is on this disk, drive %ILTR%:
        echo Erasing it would destroy the backup. Pick a different disk.
        pause
        goto pickdisk
    )
)
findstr /r /i /c:"Volume [0-9][0-9]*  *%SELF% " "%TEMP%\di_detail_out.txt" >nul && (
    echo.
    echo STOP: this is the USB stick you started from. Pick a different disk.
    pause
    goto pickdisk
)

echo.
echo   ***  ALL DATA ON DISK %DISK% WILL BE ERASED  ***
echo.
set "OK="
set /p "OK=Type ERASE to continue, or anything else to go back: "
if /i not "%OK%"=="ERASE" goto pickdisk

rem ------------------------------------------------------------------ partition
set "SL="
for %%L in (S P O N M) do if not defined SL if not exist %%L:\ set "SL=%%L"
set "WL="
for %%L in (W V T R Q) do if not defined WL if not exist %%L:\ set "WL=%%L"

if /i "%FW%"=="UEFI" (
    > "%TEMP%\di_part.txt" (
        echo select disk %DISK%
        echo clean
        echo convert gpt
        echo create partition efi size=260
        echo format quick fs=fat32 label="System"
        echo assign letter=%SL%
        echo create partition msr size=16
        echo create partition primary
        echo format quick fs=ntfs label="Windows"
        echo assign letter=%WL%
    )
) else (
    > "%TEMP%\di_part.txt" (
        echo select disk %DISK%
        echo clean
        echo convert mbr
        echo create partition primary size=500
        echo format quick fs=ntfs label="System"
        echo assign letter=%SL%
        echo active
        echo create partition primary
        echo format quick fs=ntfs label="Windows"
        echo assign letter=%WL%
    )
)
echo.
echo Preparing disk %DISK%...
diskpart /s "%TEMP%\di_part.txt"
if errorlevel 1 goto partfail
if not exist %WL%:\ goto partfail

rem ------------------------------------------------------------------ apply
echo.
echo Restoring the image. This usually takes 15 to 60 minutes. Do not turn off the PC.
dism /English /Apply-Image /ImageFile:"%IMG%" /Index:1 /ApplyDir:%WL%:\
if errorlevel 1 (
    echo.
    echo The restore failed. The messages above say why.
    pause
    goto quit
)

rem Old drive letter records point at the old partitions. Clearing them lets
rem Windows give itself C: again on first start.
reg load HKLM\DI_SYS "%WL%:\Windows\System32\config\SYSTEM" >nul 2>&1
if not errorlevel 1 (
    reg delete HKLM\DI_SYS\MountedDevices /va /f >nul 2>&1
    reg unload HKLM\DI_SYS >nul 2>&1
)

echo.
echo Making the disk bootable...
bcdboot %WL%:\Windows /s %SL%: /f %FW%
if errorlevel 1 (
    echo Could not make the disk bootable. The messages above say why.
    pause
    goto quit
)

echo.
echo ==============================================================
echo   RESTORE COMPLETE
echo   Remove the USB stick. Windows starts from the restored disk.
echo   Afterwards, check your other drive letters in Disk Management.
echo ==============================================================
echo.
set "R="
set /p "R=Press Enter to restart now, or type Q to stay here: "
if /i "%R%"=="Q" goto quit
wpeutil reboot
goto quit

:partfail
echo.
echo Setting up the disk failed. The messages above say why. Nothing was restored.
pause
goto quit

rem ------------------------------------------------------------------ helpers
:scan
for %%f in ("%~1\*.wim") do (
    set "SKIP="
    if /i "%%~nxf"=="boot.wim" set "SKIP=1"
    if /i "%%~nxf"=="install.wim" set "SKIP=1"
    if /i "%%~nxf"=="winre.wim" set "SKIP=1"
    if not defined SKIP (
        set /a N+=1
        set "IMG!N!=%%~ff"
        set "SZ!N!=%%~zf"
    )
)
exit /b

:quit
echo.
echo Leaving the restore wizard. Type exit to close this window.
endlocal
exit /b
