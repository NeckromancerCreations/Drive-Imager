# Drive Imager

A free backup app for Windows that images a running drive, like C:, into a single file you can browse, verify, schedule and restore later. One portable exe of about 140 KB. No installer, no ads, no telemetry.

## Features

* **Back up while you work.** Takes a Volume Shadow Copy snapshot of the drive, so files in use are captured cleanly.
* **Two backup types**
  * **Single image file (.wim):** one compressed file you can save anywhere, open later to pull out single files, or restore the whole drive from.
  * **Windows System Image (.vhdx):** the System Image built into Windows, restorable with System Image Recovery.
* **Save anywhere:** another drive, a USB disk, or a network share. The **Network...** button finds your mapped network drives (even though the app runs as administrator, where Windows normally hides them), signs in to shares that need a password, and tests that it can write there.
* **Compression:** none, fast or maximum, with a size estimate and a free space check before it starts.
* **Safety checks:** optional verify while writing, an embedded integrity table, and a SHA256 checksum file next to every image.
* **Leaves out junk:** temp folders, the Windows Update cache, crash dumps and the Delivery Optimization cache, plus any folders or files you list.
* **Keep only the newest** images, so old ones are cleaned up for you.
* **Scheduled backups:** every day, every week, every 2 weeks or every 4 weeks at the time you pick. Can wake the PC from sleep to run, and shows a notification when each one finishes.
* **Images tab:** see image details, verify a checksum, **mount an image read only** to browse it in Explorer and copy files out, or delete old images.
* **Restore notes** next to every image with your exact partition layout, plus a guided **restore wizard** (see below).
* **Any drive:** NTFS drives are snapshotted. FAT32 and exFAT drives (USB sticks, SD cards) are copied directly.
* Optional **sleep or shut down** when the backup finishes, and a full log of every run.

## Download

Grab `DriveImager.exe` from the [Releases](../../releases) page and run it. It uses the PowerShell and .NET Framework that already ship with Windows 10 and 11.

It asks for administrator rights when it starts, because Windows only lets admin programs snapshot drives.

Windows SmartScreen may warn about it because the exe is not code signed. Click **More info**, then **Run anyway**, or build it yourself from source (below).

## Making a backup

1. Pick the **Source drive** (usually C:).
2. Pick a **Destination** on a different drive, or click **Network...** for a network share.
3. Click **Start backup**. The **Log** tab shows progress.
4. Optional: set up the **Schedule** card, then click **Test run now** once to confirm it works.

## Restoring

### Single files

Open the **Images** tab, select an image and click **Mount read only**. It opens in Explorer, where you copy out what you need. Click **Unmount all** when done.

### The whole drive

1. Make a Windows install USB with Microsoft's [Media Creation Tool](https://www.microsoft.com/software-download/windows11). You will not reinstall Windows; you only use the command prompt on that USB.
2. Copy `DriveImager_Restore.cmd` to the root of the USB. Drive Imager also puts a copy next to every image it makes.
3. Boot from the USB. At the first setup screen press **Shift+F10**, switch to the USB drive letter (for example `D:`) and type `DriveImager_Restore`.

The wizard:

* finds your images on every drive, or on a network share
* checks that the image can be read
* shows each disk's details so you pick the right one, and refuses to erase the disk that holds the backup or the USB you booted from
* sets up the partitions for UEFI or older BIOS PCs, restores the image and makes the disk bootable
* clears old drive letter records so the restored Windows comes back as C:

Nothing is changed until you type `ERASE`, so it is safe to do a dry run now and quit with `Q`.

If no disks are listed, your PC's storage controller needs a driver in that USB environment. This is common with Intel RST or VMD.

## Good to know

* Images are **not encrypted**. If your drive uses BitLocker, keep the images somewhere you trust.
* A Windows System Image on a network share keeps only the latest backup. The .wim type keeps as many as you like.
* Scheduled backups run while you are signed in to Windows.
* Settings, backup history and logs live in `%APPDATA%\DriveImager`. The exe unpacks the app into `%LOCALAPPDATA%\DriveImager\app`, which is what scheduled backups run.

## Run it as a script instead

Put `DriveImager.ps1`, `Drive_Imager.bat` and `DriveImager_Restore.cmd` in one folder and double click `Drive_Imager.bat`.

## Build from source

No SDK or Visual Studio needed. Windows includes the C# compiler. Double click `build.bat`, or run:

```
%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /optimize+ /win32icon:app.ico /resource:DriveImager.ps1,DriveImager.ps1 /resource:DriveImager_Restore.cmd,DriveImager_Restore.cmd /out:DriveImager.exe DriveImager.cs
```

## Files

| File | What it is |
| --- | --- |
| `DriveImager.ps1` | The app itself (PowerShell with a WPF window) |
| `DriveImager_Restore.cmd` | Restore wizard for a Windows install USB |
| `DriveImager.cs` | Small launcher that becomes `DriveImager.exe` and carries the two files above |
| `Drive_Imager.bat` | Starts the script without the exe |
| `app.ico` | App icon |
| `build.bat` | One click build script |
