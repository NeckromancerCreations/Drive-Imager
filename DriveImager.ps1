<#
    Drive Imager
    A WPF front end for imaging a running Windows drive.

    Engines
      WIM image      Takes a Volume Shadow Copy snapshot of the drive and captures it with
                     DISM into one .wim file that you can save anywhere, browse later, or
                     restore from a Windows install USB.
      System Image   Uses the Windows built in wbadmin System Image (VHDX), restorable from
                     Windows Recovery > Troubleshoot > System Image Recovery.

    Start it with "Drive Imager.bat" or right click this file > Run with PowerShell.
    Administrator rights are requested automatically.

    -Auto   Runs one backup with the saved settings and no window. The Schedule card on
            the Backup tab sets up a Windows scheduled task that uses this.
#>
param([switch]$Auto)

# ---------------------------------------------------------------- relaunch as admin / STA
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta   = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
if (-not $isAdmin -or -not $isSta -or $PSVersionTable.PSEdition -eq 'Core') {
    $argList = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    if ($Auto) { $argList += ' -Auto' }
    try {
        if ($isAdmin) { Start-Process -FilePath 'powershell.exe' -ArgumentList $argList }
        else          { Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs }
    } catch {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show('Drive Imager needs administrator rights to snapshot and image drives.', 'Drive Imager')
    }
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not ('DriveImagerNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DriveImagerNative {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool GetDiskFreeSpaceEx(string lpDirectoryName, out ulong lpFreeBytesAvailable, out ulong lpTotalNumberOfBytes, out ulong lpTotalNumberOfFreeBytes);
}
'@
}

# ---------------------------------------------------------------- paths
$AppDir       = Join-Path $env:APPDATA 'DriveImager'
$LogDir       = Join-Path $AppDir 'logs'
$SettingsFile = Join-Path $AppDir 'settings.json'
$PendingFile  = Join-Path $AppDir 'pending_snapshot.json'
$HistoryFile  = Join-Path $AppDir 'history.json'
$TaskName     = 'Drive Imager backup'
$TaskFolder   = '\DriveImager\'
$MountRoot    = Join-Path $env:SystemDrive 'DriveImagerMount'
New-Item -ItemType Directory -Force -Path $AppDir, $LogDir | Out-Null
$script:LogFile = Join-Path $LogDir ('DriveImager_{0}.log' -f (Get-Date).ToString('yyyy-MM-dd'))

# ---------------------------------------------------------------- XAML
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Drive Imager" Width="1060" Height="800" MinWidth="920" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#F3F4F6"
        FontFamily="Segoe UI" FontSize="13" Foreground="#111827">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#2563EB"/>
    <SolidColorBrush x:Key="Muted" Color="#6B7280"/>
    <SolidColorBrush x:Key="CardBorder" Color="#E5E7EB"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16,14"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,12,0,4"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="BorderBrush" Value="#D1D5DB"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="24,9"/>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#FCA5A5"/>
      <Setter Property="Foreground" Value="#B91C1C"/>
      <Setter Property="Padding" Value="18,9"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="BorderBrush" Value="#D1D5DB"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,5,0,0"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Margin" Value="0,4,0,0"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- header -->
    <Border Grid.Row="0" Background="#111827" Padding="20,14">
      <DockPanel>
        <Border DockPanel.Dock="Right" Background="#1F2937" CornerRadius="10" Padding="10,4" VerticalAlignment="Center">
          <TextBlock x:Name="tbAdmin" Text="Administrator" Foreground="#93C5FD" FontSize="12"/>
        </Border>
        <StackPanel>
          <TextBlock Text="Drive Imager" FontSize="22" FontWeight="Bold" Foreground="White"/>
          <TextBlock Text="Image a running Windows drive to a file you can browse or restore later." Foreground="#9CA3AF"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <TabControl x:Name="tabMain" Grid.Row="1" Margin="16,12,16,8" Background="Transparent" BorderThickness="0">
      <!-- BACKUP TAB -->
      <TabItem x:Name="tabBackup" Header="  Backup  ">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="0,12,0,0">
          <Grid x:Name="gridOptions">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0" Margin="0,0,8,0">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Source drive" Style="{StaticResource CardTitle}"/>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <ComboBox x:Name="cbSource" Height="30"/>
                    <Button x:Name="btnRescan" Grid.Column="1" Content="Rescan" Margin="8,0,0,0"/>
                  </Grid>
                  <ProgressBar x:Name="pbSourceUsage" Height="6" Margin="0,10,0,0" Maximum="100"
                               Foreground="{StaticResource Accent}" Background="#E5E7EB" BorderThickness="0"/>
                  <TextBlock x:Name="tbSourceInfo" Style="{StaticResource Hint}" Margin="0,6,0,0"/>
                </StackPanel>
              </Border>

              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Backup type" Style="{StaticResource CardTitle}"/>
                  <RadioButton x:Name="rbWim" GroupName="engine" Content="Single image file (.wim)   Recommended"/>
                  <TextBlock Style="{StaticResource Hint}" Margin="20,2,0,8"
                             Text="Snapshots the running drive and saves it as one compressed file, anywhere you like, including network shares. Pull single files out later, or restore the whole drive from a Windows USB."/>
                  <RadioButton x:Name="rbWsb" GroupName="engine" Content="Windows System Image (.vhdx)"/>
                  <TextBlock Style="{StaticResource Hint}" Margin="20,2,0,0"
                             Text="Uses the System Image built into Windows. Saves into a WindowsImageBackup folder at the root of the target drive or share. Restore with System Image Recovery from a Windows USB."/>
                </StackPanel>
              </Border>

              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Destination" Style="{StaticResource CardTitle}"/>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="txtDest" Height="30"/>
                    <Button x:Name="btnBrowse" Grid.Column="1" Content="Browse..." Margin="8,0,0,0"/>
                    <Button x:Name="btnNetwork" Grid.Column="2" Content="Network..." Margin="8,0,0,0"/>
                  </Grid>
                  <TextBlock x:Name="tbDestInfo" Style="{StaticResource Hint}" Margin="0,6,0,0"/>

                  <StackPanel x:Name="panelName">
                    <TextBlock Text="File name" Style="{StaticResource Label}"/>
                    <TextBox x:Name="txtName" Height="30"/>
                    <TextBlock x:Name="tbNamePreview" Style="{StaticResource Hint}" Margin="0,4,0,0"/>
                    <TextBlock Style="{StaticResource Hint}" Text="Tokens you can use: {vol} {date} {time} {computer}"/>
                    <TextBlock Text="Description (optional)" Style="{StaticResource Label}"/>
                    <TextBox x:Name="txtDesc" Height="30"/>
                  </StackPanel>
                </StackPanel>
              </Border>
            </StackPanel>

            <StackPanel Grid.Column="1" Margin="8,0,0,0">
              <Border x:Name="cardImage" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Image options" Style="{StaticResource CardTitle}"/>
                  <TextBlock Text="Compression" FontWeight="SemiBold" Margin="0,0,0,4"/>
                  <ComboBox x:Name="cbCompression" Height="30">
                    <ComboBoxItem Content="None     (fastest, largest file)"/>
                    <ComboBoxItem Content="Fast     (good balance, recommended)"/>
                    <ComboBoxItem Content="Maximum  (smallest file, slowest)"/>
                  </ComboBox>
                  <CheckBox x:Name="chkVerify" Content="Verify data while writing (slower)" Margin="0,10,0,0"/>
                  <CheckBox x:Name="chkIntegrity" Content="Embed an integrity table in the image"/>
                  <CheckBox x:Name="chkHash" Content="Write a SHA256 checksum file when finished"/>
                  <CheckBox x:Name="chkReadme" Content="Write restore instructions next to the image"/>
                </StackPanel>
              </Border>

              <Border x:Name="cardExclude" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Leave out" Style="{StaticResource CardTitle}"/>
                  <CheckBox x:Name="chkExTemp" Content="Temp folders (Windows and every user)" Margin="0"/>
                  <CheckBox x:Name="chkExWU" Content="Windows Update download cache"/>
                  <CheckBox x:Name="chkExDumps" Content="Crash dumps and error reports"/>
                  <CheckBox x:Name="chkExDO" Content="Delivery Optimization cache"/>
                  <TextBlock Style="{StaticResource Hint}" Margin="0,8,0,0"
                             Text="Page file, hibernation file, Recycle Bin and System Volume Information are always skipped. Folders stay in place, only their contents are skipped."/>
                  <TextBlock Text="Custom exclusions (one folder or file per line)" Style="{StaticResource Label}"/>
                  <TextBox x:Name="txtExCustom" Height="72" AcceptsReturn="True" VerticalContentAlignment="Top"
                           VerticalScrollBarVisibility="Auto" FontFamily="Consolas"/>
                  <TextBlock Style="{StaticResource Hint}" Margin="0,4,0,0" Text="Example: C:\Games\ShaderCache\*   or   \Users\YourName\Downloads"/>
                </StackPanel>
              </Border>

              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Housekeeping" Style="{StaticResource CardTitle}"/>
                  <StackPanel x:Name="panelRetention" Orientation="Horizontal">
                    <CheckBox x:Name="chkRetention" Content="Keep only the newest" VerticalAlignment="Center" Margin="0"/>
                    <TextBox x:Name="txtKeep" Width="44" Height="26" Margin="8,0" HorizontalContentAlignment="Center"/>
                    <TextBlock Text="images with this file name" VerticalAlignment="Center"/>
                  </StackPanel>
                  <CheckBox x:Name="chkAllCritical" Content="Include EFI and recovery partitions (System Image only)" Margin="0,10,0,0"/>
                  <TextBlock Text="When the backup succeeds" Style="{StaticResource Label}"/>
                  <ComboBox x:Name="cbAfter" Height="30">
                    <ComboBoxItem Content="Do nothing"/>
                    <ComboBoxItem Content="Sleep"/>
                    <ComboBoxItem Content="Shut down (2 minute warning)"/>
                  </ComboBox>
                  <TextBlock Style="{StaticResource Hint}" Margin="0,4,0,0" Text="Applies to scheduled backups too."/>
                </StackPanel>
              </Border>

              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Schedule" Style="{StaticResource CardTitle}"/>
                  <WrapPanel>
                    <ComboBox x:Name="cbSchedFreq" Width="130" Height="28" Margin="0,0,8,6">
                      <ComboBoxItem Content="Every day"/>
                      <ComboBoxItem Content="Every week"/>
                      <ComboBoxItem Content="Every 2 weeks"/>
                      <ComboBoxItem Content="Every 4 weeks"/>
                    </ComboBox>
                    <ComboBox x:Name="cbSchedDay" Width="120" Height="28" Margin="0,0,8,6">
                      <ComboBoxItem Content="on Sunday"/>
                      <ComboBoxItem Content="on Monday"/>
                      <ComboBoxItem Content="on Tuesday"/>
                      <ComboBoxItem Content="on Wednesday"/>
                      <ComboBoxItem Content="on Thursday"/>
                      <ComboBoxItem Content="on Friday"/>
                      <ComboBoxItem Content="on Saturday"/>
                    </ComboBox>
                    <TextBlock Text="at" VerticalAlignment="Center" Margin="0,0,8,6"/>
                    <TextBox x:Name="txtSchedTime" Width="74" Height="28" Margin="0,0,0,6" HorizontalContentAlignment="Center"/>
                  </WrapPanel>
                  <CheckBox x:Name="chkSchedWake" Content="Wake the PC from sleep to run it"/>
                  <TextBlock x:Name="tbSchedStatus" Style="{StaticResource Hint}" Margin="0,10,0,0"/>
                  <WrapPanel Margin="0,10,0,0">
                    <Button x:Name="btnSchedSave" Content="Save schedule" Margin="0,0,8,0"/>
                    <Button x:Name="btnSchedRun" Content="Test run now" Margin="0,0,8,0"/>
                    <Button x:Name="btnSchedRemove" Content="Remove" Foreground="#B91C1C"/>
                  </WrapPanel>
                  <TextBlock Style="{StaticResource Hint}" Margin="0,10,0,0"
                             Text="Scheduled backups run hidden with the settings on this page, while you are signed in to Windows. A notification pops up when each one finishes. Settings are saved when you start a backup or save the schedule."/>
                  <Border Background="#F9FAFB" CornerRadius="6" Padding="10,8" Margin="0,12,0,0">
                    <TextBlock x:Name="tbLastBackup" TextWrapping="Wrap" FontSize="12"/>
                  </Border>
                </StackPanel>
              </Border>
            </StackPanel>
          </Grid>
        </ScrollViewer>
      </TabItem>

      <!-- IMAGES TAB -->
      <TabItem x:Name="tabImages" Header="  Images  ">
        <Grid Margin="0,12,0,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="Folder" VerticalAlignment="Center" FontWeight="SemiBold" Margin="0,0,10,0"/>
            <TextBox x:Name="txtImgFolder" Grid.Column="1" Height="30"/>
            <Button x:Name="btnImgBrowse" Grid.Column="2" Content="Browse..." Margin="8,0,0,0"/>
            <Button x:Name="btnImgNetwork" Grid.Column="3" Content="Network..." Margin="8,0,0,0"/>
            <Button x:Name="btnImgRefresh" Grid.Column="4" Content="Refresh" Margin="8,0,0,0"/>
          </Grid>
          <Border Grid.Row="1" Margin="0,10,0,10" Background="White" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="8">
            <ListView x:Name="lvImages" BorderThickness="0" Margin="4" SelectionMode="Single">
              <ListView.View>
                <GridView>
                  <GridViewColumn Header="Image" Width="420" DisplayMemberBinding="{Binding Name}"/>
                  <GridViewColumn Header="Size" Width="110" DisplayMemberBinding="{Binding Size}"/>
                  <GridViewColumn Header="Created" Width="170" DisplayMemberBinding="{Binding Created}"/>
                  <GridViewColumn Header="Checksum" Width="90" DisplayMemberBinding="{Binding Checksum}"/>
                </GridView>
              </ListView.View>
            </ListView>
          </Border>
          <StackPanel Grid.Row="2">
            <WrapPanel x:Name="panelImageButtons">
              <Button x:Name="btnImgInfo" Content="Image details" Margin="0,0,8,6"/>
              <Button x:Name="btnImgVerify" Content="Verify checksum" Margin="0,0,8,6"/>
              <Button x:Name="btnImgMount" Content="Mount read only" Margin="0,0,8,6"/>
              <Button x:Name="btnImgUnmount" Content="Unmount all" Margin="0,0,8,6"/>
              <Button x:Name="btnImgOpen" Content="Show in Explorer" Margin="0,0,8,6"/>
              <Button x:Name="btnImgDelete" Content="Delete image" Margin="0,0,8,6" Foreground="#B91C1C"/>
            </WrapPanel>
            <TextBlock x:Name="tbImgCount" Style="{StaticResource Hint}"/>
            <TextBlock Style="{StaticResource Hint}"
                       Text="Mount read only lets you browse an image in Explorer and copy single files out. Images mount under C:\DriveImagerMount and stay mounted until you click Unmount all."/>
          </StackPanel>
        </Grid>
      </TabItem>

      <!-- LOG TAB -->
      <TabItem x:Name="tabLog" Header="  Log  ">
        <Grid Margin="0,12,0,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Border Background="#0F172A" CornerRadius="8" Padding="4">
            <TextBox x:Name="txtLog" IsReadOnly="True" Background="Transparent" Foreground="#E2E8F0" BorderThickness="0"
                     FontFamily="Consolas" FontSize="12" TextWrapping="NoWrap" VerticalContentAlignment="Top"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
          </Border>
          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,10,0,0">
            <Button x:Name="btnSaveLog" Content="Save log..." Margin="0,0,8,0"/>
            <Button x:Name="btnClearLog" Content="Clear" Margin="0,0,8,0"/>
            <Button x:Name="btnOpenLogs" Content="Open log folder"/>
          </StackPanel>
        </Grid>
      </TabItem>
    </TabControl>

    <!-- footer -->
    <Border Grid.Row="2" Background="White" BorderBrush="{StaticResource CardBorder}" BorderThickness="0,1,0,0" Padding="20,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center" Margin="0,0,20,0">
          <TextBlock x:Name="tbStatus" Text="Ready" FontWeight="SemiBold"/>
          <ProgressBar x:Name="pb" Height="8" Margin="0,6,0,4" Maximum="100" Foreground="{StaticResource Accent}" Background="#E5E7EB" BorderThickness="0"/>
          <TextBlock x:Name="tbProgressText" Style="{StaticResource Hint}"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="btnCancel" Content="Cancel" Style="{StaticResource Danger}" Margin="0,0,10,0" IsEnabled="False"/>
          <Button x:Name="btnStart" Content="Start backup" Style="{StaticResource Primary}"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$ui = @{}
$window = $null
if (-not $Auto) {
    [xml]$xamlXml = $xaml
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xamlXml))
    foreach ($node in $xamlXml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $n = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        if ($n) { $el = $window.FindName($n); if ($el) { $ui[$n] = $el } }
    }
}

$brushConv  = New-Object System.Windows.Media.BrushConverter
$brushMuted = $brushConv.ConvertFromString('#6B7280')
$brushWarn  = $brushConv.ConvertFromString('#B45309')

# ---------------------------------------------------------------- shared state
$sync = [hashtable]::Synchronized(@{})
$sync.Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$sync.Done = $true
$script:Busy = $false
$script:Job = $null
$script:JobKind = ''
$script:JobOnDone = $null
$script:CloseAfterJob = $false
$script:ForceClose = $false
$script:Volumes = @()

# ---------------------------------------------------------------- helpers (UI thread)
function Format-Bytes([double]$b) {
    if ($b -ge 1TB) { return '{0:N2} TB' -f ($b / 1TB) }
    if ($b -ge 1GB) { return '{0:N1} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N0} MB' -f ($b / 1MB) }
    return '{0:N0} KB' -f ($b / 1KB)
}

function Show-Msg([string]$Text, [string]$Icon = 'Information') {
    [void][System.Windows.MessageBox]::Show($window, $Text, 'Drive Imager', 'OK', $Icon)
}

function Ask([string]$Text) {
    return ([System.Windows.MessageBox]::Show($window, $Text, 'Drive Imager', 'YesNo', 'Question') -eq 'Yes')
}

function Write-UiLog([string]$Message) {
    $sync.Log.Enqueue(('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Message))
}

function Test-PathSafe([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return (Test-Path -LiteralPath $Path) } catch { return $false }
}

function Get-FreeSpace([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim()
    while ($p -and -not (Test-PathSafe $p)) {
        try { $parent = Split-Path -Path $p -Parent } catch { $parent = $null }
        if (-not $parent -or $parent -eq $p) { $p = $null; break }
        $p = $parent
    }
    if (-not $p) { return $null }
    if (-not $p.EndsWith('\')) { $p += '\' }
    [uint64]$free = 0; [uint64]$total = 0; [uint64]$tfree = 0
    if ([DriveImagerNative]::GetDiskFreeSpaceEx($p,[ref]$free, [ref]$total, [ref]$tfree)) {
        return [pscustomobject]@{ Free = $free; Total = $total }
    }
    return $null
}

function ConvertTo-VolumeInfo($d) {
    try {
        if (-not $d.IsReady) { return $null }
        $fsName = ''
        try { $fsName = [string]$d.DriveFormat } catch { }
        return [pscustomobject]@{
            DriveLetter     = $d.Name.Substring(0, 1).ToUpper()
            FileSystemLabel = [string]$d.VolumeLabel
            FileSystem      = $fsName
            Size            = [double]$d.TotalSize
            SizeRemaining   = [double]$d.TotalFreeSpace
            DriveType       = [string]$d.DriveType
        }
    } catch { return $null }
}

function Get-SourceVolumes {
    # Every drive with a letter that is ready: internal, USB, card readers, discs. Network drives are left out
    # because Windows can't snapshot them and an admin app can't see your mapped letters anyway.
    $list = foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ("$($d.DriveType)" -eq 'Network' -or "$($d.DriveType)" -eq 'NoRootDirectory') { continue }
        $v = ConvertTo-VolumeInfo $d
        if ($v -and $v.Size -gt 0) { $v }
    }
    return @($list | Sort-Object DriveLetter)
}

function Get-SourceVolume([string]$Letter) {
    if (-not $Letter) { return $null }
    try { return ConvertTo-VolumeInfo (New-Object System.IO.DriveInfo ($Letter.Substring(0, 1) + ':')) } catch { return $null }
}

function Test-CanSnapshot($Vol) { return ($Vol -and ($Vol.FileSystem -eq 'NTFS' -or $Vol.FileSystem -eq 'ReFS')) }

function Get-DriveTypeLabel($Vol) {
    switch ($Vol.DriveType) { 'Removable' { 'USB / removable' } 'CDRom' { 'disc' } 'Fixed' { 'internal' } default { "$($Vol.DriveType)".ToLower() } }
}

function Get-SelectedVolume {
    $i = $ui.cbSource.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:Volumes.Count) { return $script:Volumes[$i] }
    return $null
}

function Test-SameVolume([string]$Dest, $Vol) {
    if (-not $Vol) { return $false }
    if ($Dest -match '^([A-Za-z]):') { return ($Matches[1].ToUpper() -eq ("$($Vol.DriveLetter)").ToUpper()) }
    return $false
}

function Get-WsbTarget([string]$Dest) {
    $d = $Dest.Trim()
    if ($d.StartsWith('\\') -and (Get-ShareRoot $d)) { return $d.TrimEnd('\') }
    if ($d -match '^([A-Za-z]):') { return ($Matches[1].ToUpper() + ':') }
    return $null
}

# ---------------------------------------------------------------- network locations
# Drive Imager runs elevated. Windows keeps drives mapped in the normal (non admin) session
# out of elevated apps, so mapped letters like U: are invisible here. These helpers find the
# share behind each mapped letter and connect to it directly by its \\server\share path.
$script:NetCreds = @{}
$script:ReachableRoots = @{}

function Get-ShareRoot([string]$Path) {
    if ($Path -and $Path.Trim() -match '^(\\\\[^\\]+\\[^\\]+)') { return $Matches[1].TrimEnd('.', ' ') }
    return $null
}

function Test-IsUnc([string]$Path) { return [bool]($Path -and $Path.Trim().StartsWith('\\')) }

function Get-MappedDrives {
    $map = [ordered]@{}
    foreach ($k in @(Get-ChildItem -Path 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
        $rp = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).RemotePath
        if ($rp) { $map[$k.PSChildName.ToUpper()] = $rp }
    }
    try {
        foreach ($m in @(Get-SmbMapping -ErrorAction Stop)) {
            if ($m.LocalPath -match '^([A-Za-z]):$' -and -not $map.Contains($Matches[1].ToUpper())) { $map[$Matches[1].ToUpper()] = $m.RemotePath }
        }
    } catch { }
    $list = foreach ($l in ($map.Keys | Sort-Object)) { [pscustomobject]@{ Letter = $l; Remote = $map[$l] } }
    return @($list)
}

function Resolve-Destination([string]$Path) {
    # Turns a mapped letter that this admin session can't see (U:\Backups) into \\server\share\Backups
    $p = $Path.Trim().Trim('"')
    if ($p -match '^([A-Za-z]):(.*)$') {
        $letter = $Matches[1].ToUpper(); $rest = $Matches[2]
        if (-not [IO.Directory]::Exists("${letter}:\")) {
            $m = Get-MappedDrives | Where-Object { $_.Letter -eq $letter } | Select-Object -First 1
            if ($m) {
                $unc = $m.Remote.TrimEnd('\') + $(if ($rest -and -not $rest.StartsWith('\')) { '\' + $rest } else { $rest })
                return [pscustomobject]@{ Path = $unc.TrimEnd('\'); Note = "${letter}: is a mapped network drive. Using $($m.Remote) instead." }
            }
        }
    }
    return [pscustomobject]@{ Path = $p; Note = $null }
}

function Connect-Share([string]$Path, [string]$User, [string]$Pass, [bool]$Save) {
    # Returns $null when the share can be opened, otherwise an error message
    $root = Get-ShareRoot $Path
    if (-not $root) { return 'Type a network path that starts with \\server\share' }
    if (-not $User -and (Test-PathSafe $root)) { $script:ReachableRoots[$root.ToLower()] = $true; return $null }
    try {
        $smbArgs = @{ RemotePath = $root; ErrorAction = 'Stop' }
        if ($User) {
            Get-SmbMapping -RemotePath $root -ErrorAction SilentlyContinue | Remove-SmbMapping -Force -ErrorAction SilentlyContinue
            $smbArgs.UserName = $User
            $smbArgs.Password = $Pass
            if ($Save) { $smbArgs.SaveCredentials = $true }
        }
        New-SmbMapping @smbArgs | Out-Null
    } catch {
        $msg = $_.Exception.Message
        if (Test-PathSafe $root) { $script:ReachableRoots[$root.ToLower()] = $true; return $null }
        if ($msg -match '1219|multiple connections') {
            $msg = 'Windows is already connected to this server with a different account. Use that same account, or close the other connection and try again.'
        }
        elseif ($msg -match '1326|password|logon failure|user name') { $msg = 'The user name or password was not accepted.' }
        elseif ($msg -match '53|67|network path|network name') { $msg = 'The server or share name could not be found. Check the spelling and that the PC or NAS is on.' }
        return "Could not connect to $root`n$msg"
    }
    if (-not (Test-PathSafe $root)) { return "Connected, but $root still can't be opened." }
    if ($User) { $script:NetCreds[$root.ToLower()] = @{ User = $User; Pass = $Pass } }
    $script:ReachableRoots[$root.ToLower()] = $true
    Write-UiLog "Connected to $root$(if ($User) { " as $User" })"
    return $null
}

function Test-WriteAccess([string]$Folder) {
    try {
        if (-not (Test-PathSafe $Folder)) { New-Item -ItemType Directory -Path $Folder -Force -ErrorAction Stop | Out-Null }
        $probe = Join-Path $Folder ('.driveimager_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [IO.File]::WriteAllText($probe, 'test')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $null
    } catch { return "Connected, but can't write to $Folder`n$($_.Exception.Message)" }
}

$netXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Network location" Width="580" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="White" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#D1D5DB"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="Lbl">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,12,0,4"/>
    </Style>
  </Window.Resources>
  <StackPanel Margin="22,18,22,18">
    <TextBlock Text="Save to a network location" FontSize="17" FontWeight="SemiBold"/>
    <TextBlock TextWrapping="Wrap" Foreground="#6B7280" Margin="0,4,0,0"
               Text="Drive Imager runs as administrator, and Windows hides drives you mapped as a normal user from admin apps. Pick one of your mapped drives, or type the share path."/>

    <TextBlock Text="Your mapped drives" Style="{StaticResource Lbl}"/>
    <ListBox x:Name="lbMapped" Height="104" FontFamily="Consolas"/>
    <TextBlock x:Name="tbNoMapped" Foreground="#6B7280" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap"/>

    <TextBlock Text="Folder on the network" Style="{StaticResource Lbl}"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="txtUnc" Height="30" Padding="6,4" VerticalContentAlignment="Center" FontFamily="Consolas"/>
      <Button x:Name="btnNetBrowse" Grid.Column="1" Content="Browse..." Margin="8,0,0,0"/>
    </Grid>
    <TextBlock Foreground="#6B7280" FontSize="12" Margin="0,4,0,0" Text="Example: \\server\Backups   or   \\192.168.1.50\share\PC Images"/>

    <TextBlock Text="Sign in (leave blank to use your Windows account or saved sign in)" Style="{StaticResource Lbl}"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text="User name" Foreground="#6B7280" FontSize="12"/>
        <TextBox x:Name="txtUser" Height="30" Padding="6,4" VerticalContentAlignment="Center"/>
      </StackPanel>
      <StackPanel Grid.Column="2">
        <TextBlock Text="Password" Foreground="#6B7280" FontSize="12"/>
        <PasswordBox x:Name="pwPass" Height="30" Padding="6,4" VerticalContentAlignment="Center"/>
      </StackPanel>
    </Grid>
    <CheckBox x:Name="chkSaveCred" Content="Remember this sign in (stored in Windows Credential Manager)" Margin="0,10,0,0" IsChecked="True"/>

    <Border x:Name="bdNetStatus" Margin="0,14,0,0" Padding="10,8" CornerRadius="6" Background="#F3F4F6" Visibility="Collapsed">
      <TextBlock x:Name="tbNetStatus" TextWrapping="Wrap"/>
    </Border>

    <DockPanel Margin="0,18,0,0" LastChildFill="False">
      <Button x:Name="btnNetTest" Content="Test connection" DockPanel.Dock="Left"/>
      <Button x:Name="btnNetCancel" Content="Cancel" IsCancel="True" DockPanel.Dock="Right" Margin="8,0,0,0"/>
      <Button x:Name="btnNetOk" Content="Use this location" IsDefault="True" DockPanel.Dock="Right"
              Background="#2563EB" Foreground="White" BorderBrush="#2563EB" FontWeight="SemiBold"/>
    </DockPanel>
  </StackPanel>
</Window>
'@

function Set-NetStatus([string]$Text, [string]$Kind) {
    $n = $script:NetUi
    $n.bdNetStatus.Visibility = 'Visible'
    $colors = @{ ok = @('#ECFDF5', '#065F46'); err = @('#FEF2F2', '#991B1B'); busy = @('#F3F4F6', '#374151') }
    $c = $colors[$Kind]
    $n.bdNetStatus.Background = $brushConv.ConvertFromString($c[0])
    $n.tbNetStatus.Foreground = $brushConv.ConvertFromString($c[1])
    $n.tbNetStatus.Text = $Text
    $script:NetDlg.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Invoke-NetConnect([bool]$CheckWrite) {
    $n = $script:NetUi
    $path = $n.txtUnc.Text.Trim().Trim('"').TrimEnd('\')
    if (-not (Test-IsUnc $path)) { Set-NetStatus 'Type a path that starts with \\server\share' 'err'; return $null }
    Set-NetStatus "Connecting to $(Get-ShareRoot $path) ..." 'busy'
    $script:NetDlg.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $err = Connect-Share $path $n.txtUser.Text.Trim() $n.pwPass.Password ([bool]$n.chkSaveCred.IsChecked)
        if (-not $err -and $CheckWrite) { $err = Test-WriteAccess $path }
    } finally { $script:NetDlg.Cursor = $null }
    if ($err) { Set-NetStatus $err 'err'; return $null }
    $fs = Get-FreeSpace $path
    $txt = 'Connected.'
    if ($CheckWrite) { $txt += ' Drive Imager can save here.' }
    if ($fs) { $txt += "  Free space: $(Format-Bytes $fs.Free) of $(Format-Bytes $fs.Total)" }
    Set-NetStatus $txt 'ok'
    return $path
}

function Show-NetworkDialog([string]$Initial) {
    [xml]$nx = $netXaml
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $nx))
    $dlg.Owner = $window
    $n = @{}
    foreach ($name in 'lbMapped','tbNoMapped','txtUnc','btnNetBrowse','txtUser','pwPass','chkSaveCred','bdNetStatus','tbNetStatus','btnNetTest','btnNetOk','btnNetCancel') { $n[$name] = $dlg.FindName($name) }
    $script:NetDlg = $dlg
    $script:NetUi = $n
    $script:NetMapped = @(Get-MappedDrives)

    foreach ($m in $script:NetMapped) { [void]$n.lbMapped.Items.Add(('{0}:   {1}' -f $m.Letter, $m.Remote)) }
    $n.tbNoMapped.Text = $(if ($script:NetMapped.Count) { 'Click one to use it. You can change the \Backups subfolder in the path below.' } else { 'No mapped network drives were found. Type the share path below.' })

    $start = $(if ($Initial) { (Resolve-Destination $Initial).Path } else { '' })
    if (Test-IsUnc $start) { $n.txtUnc.Text = $start }

    $n.lbMapped.Add_SelectionChanged({
        $i = $script:NetUi.lbMapped.SelectedIndex
        if ($i -ge 0) {
            $t = $script:NetUi.txtUnc
            $t.Text = $script:NetMapped[$i].Remote.TrimEnd('\') + '\Backups'
            $t.Focus(); $t.CaretIndex = $t.Text.Length
        }
    })
    $n.btnNetTest.Add_Click({ [void](Invoke-NetConnect $true) })
    $n.btnNetBrowse.Add_Click({
        $p = Invoke-NetConnect $false
        if (-not $p) { return }
        $root = Get-ShareRoot $p
        $f = New-Object System.Windows.Forms.FolderBrowserDialog
        $f.Description = "Choose a folder on $root"
        $f.ShowNewFolderButton = $true
        $f.SelectedPath = $(if (Test-PathSafe $p) { $p } else { $root })
        if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $f.SelectedPath) { $script:NetUi.txtUnc.Text = $f.SelectedPath }
    })
    $n.btnNetOk.Add_Click({
        $p = Invoke-NetConnect $true
        if ($p) { $script:NetDlg.Tag = $p; $script:NetDlg.DialogResult = $true }
    })

    $ok = $dlg.ShowDialog()
    $script:NetDlg = $null; $script:NetUi = $null
    if ($ok) { return [string]$dlg.Tag }
    return $null
}

function Expand-NamePattern([string]$Pattern, [string]$Letter) {
    if ([string]::IsNullOrWhiteSpace($Pattern)) { $Pattern = 'Backup_{vol}_{date}_{time}' }
    $now = Get-Date
    $n = $Pattern.Replace('{vol}', $Letter).Replace('{date}', $now.ToString('yyyy-MM-dd')).Replace('{time}', $now.ToString('HHmm')).Replace('{computer}', $env:COMPUTERNAME)
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $n = $n.Replace([string]$c, '_') }
    $n = $n.Trim().TrimEnd('.')
    if ($n.ToLower().EndsWith('.wim')) { $n = $n.Substring(0, $n.Length - 4) }
    return $n
}

function Get-RetentionWildcard([string]$Pattern, [string]$Letter) {
    if ([string]::IsNullOrWhiteSpace($Pattern)) { $Pattern = 'Backup_{vol}_{date}_{time}' }
    $w = $Pattern.Replace('{vol}', $Letter).Replace('{computer}', $env:COMPUTERNAME).Replace('{date}', '*').Replace('{time}', '*')
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { if ($c -ne '*') { $w = $w.Replace([string]$c, '_') } }
    $w = ($w -replace '\*+', '*').Trim()
    if (($w -replace '[\*_\.\s-]', '').Length -lt 3) { return $null }   # too generic, never auto delete
    return $w
}

# ---------------------------------------------------------------- UI updates
$script:BitLockerCache = @{}
function Test-BitLocker([string]$Letter) {
    if ($script:BitLockerCache.ContainsKey($Letter)) { return $script:BitLockerCache[$Letter] }
    $on = $false
    try {
        $ev = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='${Letter}:'" -ErrorAction Stop
        $on = [bool]($ev -and $ev.ProtectionStatus -eq 1)
    } catch { }
    $script:BitLockerCache[$Letter] = $on
    return $on
}

function Fill-SourceList {
    $keep = $null
    $cur = Get-SelectedVolume
    if ($cur) { $keep = $cur.DriveLetter }
    $script:Volumes = @(Get-SourceVolumes)
    $ui.cbSource.Items.Clear()
    foreach ($v in $script:Volumes) {
        $label = $(if ($v.FileSystemLabel) { $v.FileSystemLabel } elseif ($v.DriveType -eq 'Removable') { 'USB Drive' } else { 'Local Disk' })
        [void]$ui.cbSource.Items.Add(('{0}:     {1}     ({2}, {3}, {4})' -f $v.DriveLetter, $label, $v.FileSystem, (Format-Bytes $v.Size), (Get-DriveTypeLabel $v)))
    }
    if (-not $script:Volumes.Count) {
        $seen = ([IO.DriveInfo]::GetDrives() | ForEach-Object { "$($_.Name) $($_.DriveType) ready=$($_.IsReady)" }) -join ', '
        Write-UiLog ("No drives were found. Drive letters Windows reports: " + $seen)
    }
    if ($keep) {
        for ($i = 0; $i -lt $script:Volumes.Count; $i++) { if ($script:Volumes[$i].DriveLetter -eq $keep) { $ui.cbSource.SelectedIndex = $i } }
    }
}

function Update-SourceInfo {
    $v = Get-SelectedVolume
    if (-not $v) { $ui.tbSourceInfo.Text = 'No drives found. Plug the drive in, then click Rescan.'; $ui.pbSourceUsage.Value = 0; return }
    $used = [double]($v.Size - $v.SizeRemaining)
    $txt = 'Used {0} of {1}  |  {2} free' -f (Format-Bytes $used), (Format-Bytes $v.Size), (Format-Bytes $v.SizeRemaining)
    $txt += "  |  $($v.FileSystem), $(Get-DriveTypeLabel $v)"
    if (("$($v.DriveLetter):") -eq $env:SystemDrive) { $txt += '  |  Windows is installed here' }
    if (-not (Test-CanSnapshot $v)) { $txt += "`n$($v.FileSystem) drives can't be snapshotted, so files are copied straight from the drive. Close anything using it while the backup runs." }
    if (Test-BitLocker "$($v.DriveLetter)") { $txt += "`nBitLocker is on for this drive. Images are NOT encrypted, so store them somewhere you trust." }
    $ui.tbSourceInfo.Text = $txt
    $ui.pbSourceUsage.Value = $(if ($v.Size) { $used * 100.0 / $v.Size } else { 0 })
    Update-NamePreview
    Update-DestInfo
}

function Update-NamePreview {
    $v = Get-SelectedVolume
    $letter = $(if ($v) { "$($v.DriveLetter)" } else { 'C' })
    $ui.tbNamePreview.Text = 'Saved as: ' + (Expand-NamePattern $ui.txtName.Text $letter) + '.wim'
}

function Update-DestInfo {
    $dest = $ui.txtDest.Text.Trim()
    $v = Get-SelectedVolume
    $isWsb = [bool]$ui.rbWsb.IsChecked
    if (-not $dest) {
        $ui.tbDestInfo.Text = 'Pick a folder on another drive, an external disk, or a network share like \\server\backups.'
        $ui.tbDestInfo.Foreground = $brushMuted
        return
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $warn = $false
    $r = Resolve-Destination $dest
    if ($r.Note) { $lines.Add($r.Note) }
    $dest = $r.Path
    $fs = $null
    if (Test-IsUnc $dest) {
        $root = Get-ShareRoot $dest
        if ($root -and $script:ReachableRoots[$root.ToLower()]) {
            $fs = Get-FreeSpace $dest
            if ($fs) { $lines.Add("Network location  |  free space: $(Format-Bytes $fs.Free) of $(Format-Bytes $fs.Total)") }
            else     { $lines.Add('Network location. The folder will be created when the backup starts.') }
        }
        else { $lines.Add('Network location. Click Network... to test it and sign in, or it connects when the backup starts.') }
    }
    else {
        $fs = Get-FreeSpace $dest
        if ($fs) { $lines.Add("Free space here: $(Format-Bytes $fs.Free) of $(Format-Bytes $fs.Total)") }
        else     { $lines.Add('Location not reachable yet. The folder will be created if possible.') }
    }
    if ($v) {
        $used = [double]($v.Size - $v.SizeRemaining)
        $factors = @(1.0, 0.7, 0.55)
        $ci = [math]::Max(0, $ui.cbCompression.SelectedIndex)
        $factor = $(if ($isWsb) { 0.9 } else { $factors[$ci] })
        $est = $used * $factor
        $lines.Add("Estimated image size: about $(Format-Bytes $est)")
        if ($fs -and $fs.Free -lt $est) { $lines.Add('Warning: this location may not have enough free space.'); $warn = $true }
        if (Test-SameVolume $dest $v) { $lines.Add('Warning: this is on the drive you are backing up. Use a different drive.'); $warn = $true }
    }
    if ($isWsb) {
        $t = Get-WsbTarget $dest
        if ($t) {
            $lines.Add("System Image always writes to $t\WindowsImageBackup")
            if (Test-IsUnc $t) { $lines.Add('On a network share Windows keeps only the latest System Image. Each run replaces the last one.') }
        }
        else    { $lines.Add('System Image needs a drive letter or a \\server\share path.'); $warn = $true }
    }
    $ui.tbDestInfo.Text = $lines -join "`n"
    $ui.tbDestInfo.Foreground = $(if ($warn) { $brushWarn } else { $brushMuted })
}

function Update-EngineUi {
    $wim = -not [bool]$ui.rbWsb.IsChecked
    $ui.cardImage.IsEnabled = $wim
    $ui.cardExclude.IsEnabled = $wim
    $ui.panelName.IsEnabled = $wim
    $ui.panelRetention.IsEnabled = $wim
    $ui.chkAllCritical.IsEnabled = -not $wim
    $ui.btnStart.Content = $(if ($wim) { 'Start backup' } else { 'Start System Image' })
    Update-DestInfo
}

function Set-BusyUi([bool]$Busy) {
    $ui.gridOptions.IsEnabled = -not $Busy
    $ui.panelImageButtons.IsEnabled = -not $Busy
    $ui.btnImgRefresh.IsEnabled = -not $Busy
    $ui.btnImgNetwork.IsEnabled = -not $Busy
    $ui.btnImgBrowse.IsEnabled = -not $Busy
    $ui.btnStart.IsEnabled = -not $Busy
    $ui.btnCancel.IsEnabled = $Busy
}

function Refresh-Images {
    $folder = $ui.txtImgFolder.Text.Trim()
    $items = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    if ($folder) {
        $r = Resolve-Destination $folder
        if ($r.Path -ne $folder) { $folder = $r.Path; $ui.txtImgFolder.Text = $folder }
        if (Test-IsUnc $folder) {
            $window.Cursor = [System.Windows.Input.Cursors]::Wait
            try { $err = Connect-Share $folder '' '' $false } finally { $window.Cursor = $null }
            if ($err) { $ui.tbImgCount.Text = "Can't reach $folder. Click Network... to sign in."; $ui.lvImages.ItemsSource = $items; return }
        }
    }
    if (Test-PathSafe $folder) {
        Get-ChildItem -LiteralPath $folder -Filter '*.wim' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | ForEach-Object {
                $items.Add([pscustomobject]@{
                    Name     = $_.Name
                    Size     = Format-Bytes $_.Length
                    Created  = $_.LastWriteTime.ToString('yyyy-MM-dd  HH:mm')
                    Checksum = $(if (Test-Path -LiteralPath ($_.FullName + '.sha256')) { 'Yes' } else { 'No' })
                    FullName = $_.FullName
                })
            }
    }
    $ui.lvImages.ItemsSource = $items
    $ui.tbImgCount.Text = $(if ($items.Count -eq 1) { '1 image found.' } else { "$($items.Count) images found." })
}

function Get-SelectedImage {
    $item = $ui.lvImages.SelectedItem
    if (-not $item) { Show-Msg 'Select an image in the list first.'; return $null }
    return $item.FullName
}

function Flush-Log {
    $line = $null
    $buf = New-Object System.Text.StringBuilder
    while ($sync.Log.TryDequeue([ref]$line)) { [void]$buf.AppendLine($line) }
    if ($buf.Length -gt 0) {
        $t = $buf.ToString()
        if ($ui.txtLog) { $ui.txtLog.AppendText($t); $ui.txtLog.ScrollToEnd() }
        try { [IO.File]::AppendAllText($script:LogFile, $t) } catch { }
    }
}

# ---------------------------------------------------------------- settings
function Get-DefaultSettings {
    $sysLetter = $env:SystemDrive.Substring(0, 1)
    $dest = ''
    $other = @(Get-SourceVolumes) | Where-Object {
        $_.DriveLetter -ne $sysLetter -and ($_.DriveType -eq 'Fixed' -or $_.DriveType -eq 'Removable')
    } | Sort-Object SizeRemaining -Descending | Select-Object -First 1
    if ($other) { $dest = "$($other.DriveLetter):\Backups" }
    return [ordered]@{
        Source = $sysLetter; Engine = 'WIM'; Destination = $dest; NamePattern = 'Backup_{vol}_{date}_{time}'
        Description = ''; Compression = 1; Verify = $false; Integrity = $false; Hash = $true; Readme = $true
        ExTemp = $true; ExWU = $true; ExDumps = $true; ExDO = $true; ExCustom = ''
        Retention = $false; KeepCount = '5'; After = 0; AllCritical = $true
        SchedFreq = 1; SchedDay = 0; SchedTime = '03:00'; SchedWake = $true
    }
}

function Read-SettingsFile {
    $s = Get-DefaultSettings
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { if ($s.Contains($p.Name)) { $s[$p.Name] = $p.Value } }
        } catch { }
    }
    return $s
}

function Load-Settings {
    $s = Read-SettingsFile
    $idx = -1
    for ($i = 0; $i -lt $script:Volumes.Count; $i++) {
        if ("$($script:Volumes[$i].DriveLetter)" -eq "$($s.Source)") { $idx = $i }
    }
    if ($idx -lt 0 -and $script:Volumes.Count) { $idx = 0 }
    $ui.cbSource.SelectedIndex = $idx
    if ($s.Engine -eq 'WSB') { $ui.rbWsb.IsChecked = $true } else { $ui.rbWim.IsChecked = $true }
    $ui.txtDest.Text = [string]$s.Destination
    $ui.txtName.Text = [string]$s.NamePattern
    $ui.txtDesc.Text = [string]$s.Description
    $ui.cbCompression.SelectedIndex = [int]$s.Compression
    $ui.chkVerify.IsChecked = [bool]$s.Verify
    $ui.chkIntegrity.IsChecked = [bool]$s.Integrity
    $ui.chkHash.IsChecked = [bool]$s.Hash
    $ui.chkReadme.IsChecked = [bool]$s.Readme
    $ui.chkExTemp.IsChecked = [bool]$s.ExTemp
    $ui.chkExWU.IsChecked = [bool]$s.ExWU
    $ui.chkExDumps.IsChecked = [bool]$s.ExDumps
    $ui.chkExDO.IsChecked = [bool]$s.ExDO
    $ui.txtExCustom.Text = [string]$s.ExCustom
    $ui.chkRetention.IsChecked = [bool]$s.Retention
    $ui.txtKeep.Text = [string]$s.KeepCount
    $ui.cbAfter.SelectedIndex = [int]$s.After
    $ui.chkAllCritical.IsChecked = [bool]$s.AllCritical
    $ui.txtImgFolder.Text = [string]$s.Destination
    $ui.cbSchedFreq.SelectedIndex = [int]$s.SchedFreq
    $ui.cbSchedDay.SelectedIndex = [int]$s.SchedDay
    $ui.txtSchedTime.Text = [string]$s.SchedTime
    $ui.chkSchedWake.IsChecked = [bool]$s.SchedWake
}

function Get-UiSettings {
    $v = Get-SelectedVolume
    return [ordered]@{
        Source      = $(if ($v) { "$($v.DriveLetter)" } else { '' })
        Engine      = $(if ($ui.rbWsb.IsChecked) { 'WSB' } else { 'WIM' })
        Destination = $ui.txtDest.Text
        NamePattern = $ui.txtName.Text
        Description = $ui.txtDesc.Text
        Compression = $ui.cbCompression.SelectedIndex
        Verify      = [bool]$ui.chkVerify.IsChecked
        Integrity   = [bool]$ui.chkIntegrity.IsChecked
        Hash        = [bool]$ui.chkHash.IsChecked
        Readme      = [bool]$ui.chkReadme.IsChecked
        ExTemp      = [bool]$ui.chkExTemp.IsChecked
        ExWU        = [bool]$ui.chkExWU.IsChecked
        ExDumps     = [bool]$ui.chkExDumps.IsChecked
        ExDO        = [bool]$ui.chkExDO.IsChecked
        ExCustom    = $ui.txtExCustom.Text
        Retention   = [bool]$ui.chkRetention.IsChecked
        KeepCount   = $ui.txtKeep.Text
        After       = $ui.cbAfter.SelectedIndex
        AllCritical = [bool]$ui.chkAllCritical.IsChecked
        SchedFreq   = $ui.cbSchedFreq.SelectedIndex
        SchedDay    = $ui.cbSchedDay.SelectedIndex
        SchedTime   = $ui.txtSchedTime.Text
        SchedWake   = [bool]$ui.chkSchedWake.IsChecked
    }
}

function Save-Settings {
    try { Get-UiSettings | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- history
function Read-History {
    if (-not (Test-Path -LiteralPath $HistoryFile)) { return @() }
    try {
        $j = Get-Content -LiteralPath $HistoryFile -Raw | ConvertFrom-Json
        return @(foreach ($x in $j) { $x })   # Windows PowerShell hands back a JSON array as one object
    } catch { return @() }
}

function Add-History([bool]$Ok, [string]$Kind, [string]$Trigger, [datetime]$Started) {
    $size = $null
    if ($Ok -and $sync.OutFile -and $Kind -eq 'WIM') { try { $size = (Get-Item -LiteralPath $sync.OutFile).Length } catch { } }
    $entry = [pscustomobject]@{
        Time     = $Started.ToString('yyyy-MM-dd HH:mm')
        Result   = $(if ($Ok) { 'Succeeded' } elseif ($sync.Cancel) { 'Cancelled' } else { 'Failed' })
        Kind     = $Kind
        Trigger  = $Trigger
        Target   = [string]$sync.OutFile
        Bytes    = $size
        Duration = ((Get-Date) - $Started).ToString('hh\:mm\:ss')
        Error    = [string]$sync.Error
    }
    $list = @(Read-History) + $entry | Select-Object -Last 100
    try { ConvertTo-Json -InputObject @($list) | Set-Content -LiteralPath $HistoryFile -Encoding UTF8 } catch { }
}

function Update-LastBackup {
    if (-not $ui.tbLastBackup) { return }
    $h = @(Read-History)
    if (-not $h.Count) { $ui.tbLastBackup.Text = 'Last backup: none yet'; return }
    $last = $h[-1]
    $t = "Last backup: $($last.Time)  |  $($last.Result)"
    if ($last.Bytes) { $t += "  |  $(Format-Bytes $last.Bytes)" }
    $t += "  |  took $($last.Duration)  |  $($last.Trigger.ToLower())"
    if ($last.Result -eq 'Failed' -and $last.Error) { $t += "`n$($last.Error)" }
    $okRuns = @($h | Where-Object { $_.Result -eq 'Succeeded' })
    if ($last.Result -ne 'Succeeded' -and $okRuns.Count) { $t += "`nLast good backup: $($okRuns[-1].Time)" }
    $ui.tbLastBackup.Text = $t
}

# ---------------------------------------------------------------- one backup at a time (window and scheduled runs)
$script:JobMutex = New-Object System.Threading.Mutex($false, 'Global\DriveImagerJob')
$script:HasLock = $false
function Enter-JobLock {
    try { $script:HasLock = $script:JobMutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $script:HasLock = $true }
    return $script:HasLock
}
function Exit-JobLock {
    if ($script:HasLock) { try { $script:JobMutex.ReleaseMutex() } catch { }; $script:HasLock = $false }
}

function Clear-StaleSnapshot {
    if (-not (Test-Path -LiteralPath $PendingFile)) { return }
    try {
        $p = Get-Content -LiteralPath $PendingFile -Raw | ConvertFrom-Json
        if ($p.Link) { & cmd.exe /c rmdir "$($p.Link)" 2>$null | Out-Null }
        if ($p.ShadowId) {
            Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $p.ShadowId } | Remove-CimInstance
            Write-UiLog "Removed a leftover snapshot from an earlier run that did not finish."
        }
    } catch { }
    Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue
}

# ================================================================ worker code (runs in a background runspace)
$WorkerCommon = {
    function Write-Log([string]$Message) { $sync.Log.Enqueue(('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Message)) }
    function Set-Status([string]$Text, [double]$Progress = -1) { $sync.Status = $Text; $sync.Progress = $Progress }
    function Assert-NotCancelled { if ($sync.Cancel) { throw 'Cancelled by user.' } }
    function Format-Bytes([double]$b) {
        if ($b -ge 1TB) { return '{0:N2} TB' -f ($b / 1TB) }
        if ($b -ge 1GB) { return '{0:N1} GB' -f ($b / 1GB) }
        if ($b -ge 1MB) { return '{0:N0} MB' -f ($b / 1MB) }
        return '{0:N0} KB' -f ($b / 1KB)
    }

    function Invoke-Tool {
        param([string]$File, [string]$Arguments, [switch]$Quiet)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $File
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $sync.Process = $p
        $errTask = $p.StandardError.ReadToEndAsync()
        $sb = New-Object System.Text.StringBuilder
        $last = ''
        while ($true) {
            $c = $p.StandardOutput.Read()
            if ($c -lt 0 -or $c -eq 10 -or $c -eq 13) {
                if ($sb.Length -gt 0) {
                    $line = $sb.ToString().Trim()
                    [void]$sb.Clear()
                    if ($line) {
                        $m = [regex]::Match($line, '(\d{1,3}(?:[\.,]\d+)?)\s*%')
                        if ($m.Success) {
                            $val = [double]::Parse($m.Groups[1].Value.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
                            if ($val -ge 0 -and $val -le 100) { $sync.Progress = $val }
                        }
                        elseif (-not $Quiet -and $line -ne $last) { Write-Log $line; $last = $line }
                    }
                }
                if ($c -lt 0) { break }
            }
            else { [void]$sb.Append([char]$c) }
        }
        $p.WaitForExit()
        $err = $errTask.Result
        if ($err) { foreach ($l in ($err -split "`r?`n")) { if ($l.Trim()) { Write-Log $l.Trim() } } }
        $code = $p.ExitCode
        $sync.Process = $null
        return $code
    }

    function Get-FileSha256([string]$Path) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'Read')
        try {
            $buf = New-Object byte[] (8MB)
            $total = $fs.Length
            $done = 0
            while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                Assert-NotCancelled
                [void]$sha.TransformBlock($buf, 0, $n, $null, 0)
                $done += $n
                if ($total -gt 0) { $sync.Progress = [math]::Round($done * 100.0 / $total, 1) }
            }
            [void]$sha.TransformFinalBlock($buf, 0, 0)
            return ([BitConverter]::ToString($sha.Hash) -replace '-', '')
        }
        finally { $fs.Dispose(); $sha.Dispose() }
    }

    function Remove-FileRetry([string]$Path) {
        for ($i = 0; $i -lt 10; $i++) {
            if (-not (Test-Path -LiteralPath $Path)) { return }
            try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 700 }
        }
        Write-Log "Could not delete $Path. You can remove it by hand."
    }

    $dism = Join-Path $env:windir 'System32\dism.exe'
}

# ---------------------------------------------------------------- WIM backup
$WimBody = {
    $src     = $cfg.SourceRoot
    $out     = $cfg.OutFile
    $destDir = Split-Path -Parent $out
    $shadowId = $null; $link = $null; $ini = $null; $captured = $false; $hash = $null

    Set-Status 'Preparing' -1
    Write-Log "Source: $src    Target: $out"
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Write-Log "Created folder $destDir"
    }

    # exclusion list (paths relative to the volume root)
    $ex = New-Object System.Collections.Generic.List[string]
    foreach ($e in @('\$ntfs.log', '\hiberfil.sys', '\pagefile.sys', '\swapfile.sys', '\DumpStack.log.tmp',
                     '\System Volume Information', '\RECYCLER', '\$Recycle.Bin', '\Windows\CSC')) { $ex.Add($e) }
    if ($cfg.ExTemp) {
        $ex.Add('\Windows\Temp\*')
        Get-ChildItem -LiteralPath (Join-Path $src 'Users') -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-Path -LiteralPath (Join-Path $_.FullName 'AppData\Local\Temp')) { $ex.Add("\Users\$($_.Name)\AppData\Local\Temp\*") }
        }
    }
    if ($cfg.ExWU)    { $ex.Add('\Windows\SoftwareDistribution\Download\*') }
    if ($cfg.ExDumps) { $ex.Add('\Windows\Minidump\*'); $ex.Add('\Windows\MEMORY.DMP'); $ex.Add('\ProgramData\Microsoft\Windows\WER\*') }
    if ($cfg.ExDO)    { $ex.Add('\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*') }
    foreach ($c in @($cfg.ExCustom)) {
        $p = ([string]$c).Trim().Trim('"')
        if (-not $p) { continue }
        if ($p -match '^[A-Za-z]:') { $p = $p.Substring(2) }
        if (-not $p.StartsWith('\')) { $p = '\' + $p }
        $p = $p.TrimEnd('\')
        if ($p) { $ex.Add($p) }
    }

    $ini = Join-Path $env:TEMP ('DriveImager_{0}.ini' -f [guid]::NewGuid().ToString('N'))
    $sbIni = New-Object System.Text.StringBuilder
    [void]$sbIni.AppendLine('[ExclusionList]')
    foreach ($e in $ex) { if ($e.Contains(' ')) { [void]$sbIni.AppendLine('"' + $e + '"') } else { [void]$sbIni.AppendLine($e) } }
    [void]$sbIni.AppendLine('')
    [void]$sbIni.AppendLine('[CompressionExclusionList]')
    foreach ($e in @('*.mp3', '*.mp4', '*.mkv', '*.zip', '*.7z', '*.rar', '*.cab', '*.jpg', '\WINDOWS\inf\*.pnf')) { [void]$sbIni.AppendLine($e) }
    [IO.File]::WriteAllText($ini, $sbIni.ToString(), (New-Object System.Text.UnicodeEncoding($false, $true)))
    Write-Log "Leaving out $($ex.Count) paths."

    try {
        $captureDir = $src
        if (-not $cfg.UseSnapshot) {
            Write-Log "$src is $($cfg.FileSystem). Windows can only snapshot NTFS drives, so files are copied straight from the drive."
        } else {
        # snapshot
        Assert-NotCancelled
        Set-Status 'Creating a snapshot of the drive' -1
        Write-Log "Creating a Volume Shadow Copy snapshot of $src"
        $r = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{ Volume = $src; Context = 'ClientAccessible' }
        if ($r.ReturnValue -ne 0) { throw "Snapshot failed (VSS code $($r.ReturnValue)). Check that the Volume Shadow Copy service is not disabled." }
        $shadowId = $r.ShadowID
        $shadow = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId }
        if (-not $shadow) { throw 'The snapshot was created but could not be found.' }
        $link = Join-Path $env:SystemDrive ('DriveImagerSnap_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        @{ ShadowId = $shadowId; Link = $link } | ConvertTo-Json | Set-Content -LiteralPath $cfg.PendingFile -Encoding UTF8
        $target = $shadow.DeviceObject + '\'
        $mk = & cmd.exe /c mklink /d $link $target 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not open the snapshot: $mk" }
        Write-Log "Snapshot ready: $($shadow.DeviceObject)"
        $captureDir = $link
        }

        # capture
        Assert-NotCancelled
        $comp = @('none', 'fast', 'max')[[int]$cfg.Compression]
        $imgName = ([string]$cfg.ImageName) -replace '"', ''
        $desc = ([string]$cfg.Description) -replace '"', ''
        $dArgs = "/Capture-Image /ImageFile:`"$out`" /CaptureDir:`"$captureDir`" /Name:`"$imgName`" /Compress:$comp /ConfigFile:`"$ini`""
        if ($desc) { $dArgs += " /Description:`"$desc`"" }
        if ($cfg.Verify) { $dArgs += ' /Verify' }
        if ($cfg.Integrity) { $dArgs += ' /CheckIntegrity' }
        Set-Status 'Capturing image' 0
        Write-Log "dism.exe $dArgs"
        $code = Invoke-Tool -File $dism -Arguments $dArgs
        Assert-NotCancelled
        if ($code -ne 0) { throw "DISM stopped with code $code. More detail is in C:\Windows\Logs\DISM\dism.log" }
        $captured = $true
        Write-Log ("Image written: {0}" -f (Format-Bytes (Get-Item -LiteralPath $out).Length))
    }
    finally {
        Set-Status 'Cleaning up' -1
        if ($link) { & cmd.exe /c rmdir $link 2>$null | Out-Null }
        if ($shadowId) {
            try {
                Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId } | Remove-CimInstance
                Write-Log 'Snapshot released.'
            } catch { Write-Log "Could not release snapshot $shadowId : $($_.Exception.Message)" }
        }
        Remove-Item -LiteralPath $cfg.PendingFile -Force -ErrorAction SilentlyContinue
        if ($ini) { Remove-Item -LiteralPath $ini -Force -ErrorAction SilentlyContinue }
        if (-not $captured -and (Test-Path -LiteralPath $out)) { Write-Log 'Removing the incomplete image file.'; Remove-FileRetry $out }
    }

    # checksum
    if ($cfg.Hash) {
        Set-Status 'Calculating SHA256 checksum' 0
        $hash = Get-FileSha256 $out
        Set-Content -LiteralPath ($out + '.sha256') -Value ("{0} *{1}" -f $hash, (Split-Path -Leaf $out)) -Encoding ASCII
        Write-Log "SHA256: $hash"
    }

    # restore notes
    if ($cfg.Readme) {
        try {
            $letter  = $cfg.SourceLetter
            $di      = New-Object System.IO.DriveInfo ($letter + ':')
            $vol     = [pscustomobject]@{ FileSystemLabel = $di.VolumeLabel; Size = $di.TotalSize }
            $part = $null; $disk = $null; $layout = @('  (partition layout not available for this drive)')
            try {
                $part   = Get-Partition -DriveLetter $letter -ErrorAction Stop
                $disk   = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
                $layout = foreach ($pp in (Get-Partition -DiskNumber $part.DiskNumber | Sort-Object PartitionNumber)) {
                    $dl = ("$($pp.DriveLetter)").Trim([char]0).Trim()
                    if ($dl) { $dl += ':' }
                    '  Partition {0}: {1,-12} {2,10}  {3}' -f $pp.PartitionNumber, $pp.Type, (Format-Bytes $pp.Size), $dl
                }
            } catch { }
            if (-not $disk) { $disk = [pscustomobject]@{ PartitionStyle = 'GPT'; Size = $di.TotalSize; FriendlyName = 'unknown disk' } }
            if (-not $part) { $part = [pscustomobject]@{ DiskNumber = '?' } }
            $isGpt   = ("$($disk.PartitionStyle)" -eq 'GPT')
            $leaf    = Split-Path -Leaf $out
            $hashTxt = $(if ($hash) { $hash } else { 'not calculated' })
            $netStep = ''
            if ($out.StartsWith('\\')) {
                $shareRoot = [regex]::Match($out, '^(\\\\[^\\]+\\[^\\]+)').Groups[1].Value
                $netStep = @"
    This image is on a network share. Connect to it first:
      wpeinit
      net use Z: $shareRoot /user:YourUserName
    The image is then under Z:\ (same folders as on the share). If the network
    does not come up, copy the image to a USB drive and restore from that instead.
"@
            }
            if ($isGpt) {
                $diskSteps = @'
      diskpart
      list disk
      select disk 0
      clean
      convert gpt
      create partition efi size=260
      format quick fs=fat32 label="System"
      assign letter=S
      create partition msr size=16
      create partition primary
      format quick fs=ntfs label="Windows"
      assign letter=W
      exit
'@
                $bootCmd = 'bcdboot W:\Windows /s S: /f UEFI'
            } else {
                $diskSteps = @'
      diskpart
      list disk
      select disk 0
      clean
      create partition primary size=500
      format quick fs=ntfs label="System"
      assign letter=S
      active
      create partition primary
      format quick fs=ntfs label="Windows"
      assign letter=W
      exit
'@
                $bootCmd = 'bcdboot W:\Windows /s S: /f BIOS'
            }
            $text = @"
DRIVE IMAGER RESTORE NOTES
==========================

Image file    : $leaf
Created       : $((Get-Date).ToString('yyyy-MM-dd HH:mm'))
Computer      : $env:COMPUTERNAME
Source drive  : ${letter}:  ($($vol.FileSystemLabel), $(Format-Bytes $vol.Size))
Image size    : $(Format-Bytes (Get-Item -LiteralPath $out).Length)
Compression   : $(@('none', 'fast', 'max')[[int]$cfg.Compression])
SHA256        : $hashTxt

Original disk layout (Disk $($part.DiskNumber), $($disk.PartitionStyle), $(Format-Bytes $disk.Size), $($disk.FriendlyName))
$($layout -join "`r`n")


GETTING SINGLE FILES BACK
Open Drive Imager, go to the Images tab, select this image and click "Mount read only".
Or from an administrator command prompt:
      mkdir C:\Mount
      dism /Mount-Image /ImageFile:"<path to>\$leaf" /Index:1 /MountDir:C:\Mount /ReadOnly
      (copy what you need, then)
      dism /Unmount-Image /MountDir:C:\Mount /Discard


RESTORING THE WHOLE DRIVE
The easy way: copy DriveImager_Restore.cmd to a Windows install USB (made with
Microsoft's Media Creation Tool), boot from it, press Shift+F10 at the first
screen, go to the USB drive letter and type DriveImager_Restore. The wizard
finds this image and does every step below for you.

Doing it by hand instead. This erases the target disk. Read every step first.

 1. Boot the PC from a Windows 10 or 11 install USB.
 2. At the first setup screen press Shift+F10 to open a command prompt.
 3. Find the drive that holds this image. Drive letters are different here,
    so try  dir D:\   dir E:\   and so on until you see it.
$netStep
 4. Prepare the target disk. In diskpart, "list disk" shows the disks.
    Make sure you select the right one before typing "clean".
$diskSteps
 5. Apply the image (replace E:\path with where the image really is):
      dism /Apply-Image /ImageFile:"E:\path\$leaf" /Index:1 /ApplyDir:W:\
 6. Clear the old drive letter records so Windows comes back as C:
      reg load HKLM\DI_SYS W:\Windows\System32\config\SYSTEM
      reg delete HKLM\DI_SYS\MountedDevices /va /f
      reg unload HKLM\DI_SYS
 7. Make the drive bootable:
      $bootCmd
 8. Remove the USB stick and restart.

If the new disk is bigger, Windows simply has more free space. If you want a
recovery partition again, Windows can recreate it later with reagentc.
"@
            $notes = Join-Path $destDir ([IO.Path]::GetFileNameWithoutExtension($out) + '_RESTORE.txt')
            Set-Content -LiteralPath $notes -Value $text -Encoding UTF8
            Write-Log "Restore notes written: $notes"
            if ($cfg.WizardPath -and (Test-Path -LiteralPath $cfg.WizardPath)) {
                Copy-Item -LiteralPath $cfg.WizardPath -Destination (Join-Path $destDir 'DriveImager_Restore.cmd') -Force
                Write-Log 'Restore wizard copied next to the image.'
            }
        } catch { Write-Log "Could not write restore notes: $($_.Exception.Message)" }
    }

    # retention
    if ($cfg.Retention -and -not $cfg.RetentionWildcard) { Write-Log 'Keep newest skipped: the file name pattern needs some fixed text (like Backup_) so other files are never deleted.' }
    if ($cfg.Retention -and $cfg.KeepCount -ge 1 -and $cfg.RetentionWildcard) {
        $all = @(Get-ChildItem -LiteralPath $destDir -Filter ($cfg.RetentionWildcard + '.wim') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        $old = @($all | Select-Object -Skip $cfg.KeepCount)
        foreach ($f in $old) {
            if ($f.FullName -eq $out) { continue }
            Remove-FileRetry $f.FullName
            Remove-FileRetry ($f.FullName + '.sha256')
            Remove-FileRetry (Join-Path $destDir ($f.BaseName + '_RESTORE.txt'))
            Write-Log "Removed old image $($f.Name)"
        }
    }

    $sync.OutFile = $out
    $sync.Result = "$out`n$(Format-Bytes (Get-Item -LiteralPath $out).Length)"
    Set-Status 'Finished' 100
}

# ---------------------------------------------------------------- Windows System Image
$WsbBody = {
    $wb = Join-Path $env:windir 'System32\wbadmin.exe'
    if (-not (Test-Path -LiteralPath $wb)) { throw 'wbadmin.exe is not available on this edition of Windows. Use the .wim backup type instead.' }
    $t = [string]$cfg.WsbTarget
    if ($t.Contains(' ')) { $t = "`"$t`"" }
    $a = "start backup -backupTarget:$t -include:$($cfg.SourceLetter): -quiet"
    if ($cfg.AllCritical) { $a += ' -allCritical' }
    $shown = $a
    if ($cfg.WsbUser) {
        $a += ' -user:"' + ($cfg.WsbUser -replace '"', '') + '" -password:"' + ($cfg.WsbPass -replace '"', '\"') + '"'
        $shown += ' -user:"' + $cfg.WsbUser + '" -password:********'
    }
    Set-Status 'Creating Windows System Image' 0
    Write-Log "wbadmin $shown"
    $code = Invoke-Tool -File $wb -Arguments $a
    Assert-NotCancelled
    if ($code -ne 0) { throw "wbadmin stopped with code $code. See the log above." }
    $where = (Join-Path $cfg.WsbTarget 'WindowsImageBackup') + "\$env:COMPUTERNAME"
    if ($cfg.Readme) {
        try {
            $notes = Join-Path $cfg.WsbTarget 'DriveImager_SystemImage_RESTORE.txt'
            $text = @"
DRIVE IMAGER RESTORE NOTES (Windows System Image)
=================================================

Created   : $((Get-Date).ToString('yyyy-MM-dd HH:mm'))
Computer  : $env:COMPUTERNAME
Saved in  : $where

TO RESTORE THE WHOLE PC
 1. Connect the drive that holds WindowsImageBackup.
 2. Boot from a Windows 10 or 11 install USB.
 3. Choose your language, then click "Repair your computer" (bottom left).
 4. Troubleshoot > System Image Recovery.
 5. Pick the latest image and follow the wizard. It recreates the partitions for you.

TO GET SINGLE FILES BACK
Inside $where there are .vhdx files. In Disk Management choose
Action > Attach VHD (tick Read only), pick the largest .vhdx, and it shows up
as a drive letter you can browse. Detach it when done.
"@
            Set-Content -LiteralPath $notes -Value $text -Encoding UTF8
            Write-Log "Restore notes written: $notes"
        } catch { Write-Log "Could not write restore notes: $($_.Exception.Message)" }
    }
    $sync.OutFile = $where
    $sync.Result = $where
    Set-Status 'Finished' 100
}

# ---------------------------------------------------------------- image tools
$InfoBody = {
    Set-Status 'Reading image details' -1
    $code = Invoke-Tool -File $dism -Arguments "/Get-ImageInfo /ImageFile:`"$($cfg.File)`" /Index:1"
    if ($code -ne 0) { throw "DISM could not read the image (code $code)." }
}

$VerifyBody = {
    $file = $cfg.File
    $sumFile = $file + '.sha256'
    Set-Status 'Calculating SHA256 checksum' 0
    $actual = Get-FileSha256 $file
    if (Test-Path -LiteralPath $sumFile) {
        $expected = (((Get-Content -LiteralPath $sumFile -TotalCount 1) -split '\s+')[0]).Trim().ToUpper()
        if ($actual -eq $expected) { Write-Log 'Checksum matches. The image file is intact.'; $sync.Result = 'match' }
        else { throw "Checksum MISMATCH. Expected $expected but the file is now $actual. The image is damaged." }
    } else {
        Set-Content -LiteralPath $sumFile -Value ("{0} *{1}" -f $actual, (Split-Path -Leaf $file)) -Encoding ASCII
        Write-Log "No checksum existed yet, so one was created: $actual"
        $sync.Result = 'created'
    }
}

$MountBody = {
    $dir = $cfg.MountDir
    if (Test-Path -LiteralPath $dir) {
        if (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Select-Object -First 1) {
            throw "The mount folder $dir is not empty. It may already be mounted, or click Unmount all first."
        }
    } else { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Status 'Mounting image' 0
    $code = Invoke-Tool -File $dism -Arguments "/Mount-Image /ImageFile:`"$($cfg.File)`" /Index:1 /MountDir:`"$dir`" /ReadOnly"
    Assert-NotCancelled
    if ($code -ne 0) { throw "DISM could not mount the image (code $code)." }
    $sync.Result = $dir
}

$UnmountBody = {
    $dirs = @(Get-ChildItem -LiteralPath $cfg.MountRoot -Directory -ErrorAction SilentlyContinue)
    if (-not $dirs.Count) { Write-Log 'Nothing is mounted.' }
    foreach ($d in $dirs) {
        Set-Status "Unmounting $($d.Name)" 0
        $code = Invoke-Tool -File $dism -Arguments "/Unmount-Image /MountDir:`"$($d.FullName)`" /Discard"
        if ($code -ne 0) {
            Write-Log "Unmount returned code $code, running DISM cleanup."
            Invoke-Tool -File $dism -Arguments '/Cleanup-Mountpoints' | Out-Null
        }
        try { [IO.Directory]::Delete($d.FullName, $false); Write-Log "Unmounted $($d.Name)" }
        catch { Write-Log "Folder $($d.FullName) is not empty yet. Restarting Windows will finish the cleanup." }
    }
}

# ---------------------------------------------------------------- job runner
function Reset-Sync([string]$Title) {
    $sync.Progress = -1; $sync.Status = $Title; $sync.Done = $false; $sync.Success = $false
    $sync.Cancel = $false; $sync.Process = $null; $sync.Error = $null; $sync.Result = $null; $sync.OutFile = $null
}

function New-WorkerRunspace([scriptblock]$Body, [hashtable]$Cfg) {
    $code = @"
$($WorkerCommon.ToString())
Write-Log ('Starting: ' + `$cfg.Title)
try {
$($Body.ToString())
    if (`$sync.Cancel) { Write-Log 'Cancelled.' } else { `$sync.Success = `$true; Write-Log 'Done.' }
}
catch {
    if (`$sync.Cancel) { Write-Log 'Cancelled by user.' }
    else { `$sync.Error = `$_.Exception.Message; Write-Log ('ERROR: ' + `$_.Exception.Message) }
}
finally {
    `$sync.Done = `$true
}
"@
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('cfg', $Cfg)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($code)
    return @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

function Start-Worker {
    param([string]$Title, [scriptblock]$Body, [hashtable]$Cfg, [scriptblock]$OnDone, [string]$Kind = 'Task')
    if ($script:Busy) { Show-Msg 'Another job is already running.'; return }
    if (-not (Enter-JobLock)) { Show-Msg 'A scheduled backup is running in the background right now. Try again once it finishes (you will get a notification).'; return }
    Reset-Sync $Title
    $Cfg.Title = $Title
    $script:JobKind = $Kind
    $script:JobOnDone = $OnDone
    $script:JobStart = Get-Date
    $script:PhaseStart = Get-Date
    $script:PhaseName = $Title
    $script:Busy = $true
    Set-BusyUi $true
    [void][DriveImagerNative]::SetThreadExecutionState([uint32]2147483649)   # keep the PC awake
    $ui.pb.Value = 0
    $ui.tbStatus.Text = $Title
    $script:Job = New-WorkerRunspace $Body $Cfg
}

function Complete-Worker {
    try { [void]$script:Job.PS.EndInvoke($script:Job.Handle) } catch { Write-UiLog "Worker error: $($_.Exception.Message)" }
    foreach ($e in $script:Job.PS.Streams.Error) { Write-UiLog "Worker error: $e" }
    try { $script:Job.PS.Dispose(); $script:Job.RS.Dispose() } catch { }
    $script:Job = $null
    Flush-Log
    Exit-JobLock
    $script:Busy = $false
    Set-BusyUi $false
    [void][DriveImagerNative]::SetThreadExecutionState([uint32]2147483648)
    $ok = [bool]$sync.Success
    $el = ((Get-Date) - $script:JobStart).ToString('hh\:mm\:ss')
    if ($ok)              { $ui.pb.IsIndeterminate = $false; $ui.pb.Value = 100; $ui.tbStatus.Text = 'Finished'; $ui.tbProgressText.Text = "Took $el" }
    elseif ($sync.Cancel) { $ui.pb.IsIndeterminate = $false; $ui.pb.Value = 0;   $ui.tbStatus.Text = 'Cancelled'; $ui.tbProgressText.Text = '' }
    else                  { $ui.pb.IsIndeterminate = $false; $ui.pb.Value = 0;   $ui.tbStatus.Text = 'Failed: ' + $sync.Error; $ui.tbProgressText.Text = 'See the Log tab for details.' }
    if ($script:JobKind -eq 'WIM' -or $script:JobKind -eq 'WSB') { Add-History $ok $script:JobKind 'Manual' $script:JobStart; Update-LastBackup }
    if ($script:CloseAfterJob) { $script:ForceClose = $true; $window.Close(); return }
    if ($script:JobOnDone) { & $script:JobOnDone $ok }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:TickCount = 0
$timer.Add_Tick({
    Flush-Log
    if (-not $script:Busy) {
        $script:TickCount++
        if ($script:TickCount % 100 -eq 0) { Update-LastBackup; try { Update-ScheduleUi } catch { } }   # every 30 seconds
        return
    }
    if ($sync.Status -ne $script:PhaseName) { $script:PhaseName = $sync.Status; $script:PhaseStart = Get-Date }
    $p = [double]$sync.Progress
    if ($p -lt 0) { $ui.pb.IsIndeterminate = $true }
    else { $ui.pb.IsIndeterminate = $false; $ui.pb.Value = $p }
    $total = (Get-Date) - $script:JobStart
    $txt = 'Elapsed ' + $total.ToString('hh\:mm\:ss')
    if ($p -ge 1 -and $p -lt 100) {
        $phase = ((Get-Date) - $script:PhaseStart).TotalSeconds
        $left = [TimeSpan]::FromSeconds([math]::Min(359999, $phase / $p * (100 - $p)))
        $txt = ('{0:N1}%   |   ' -f $p) + $txt + '   |   about ' + $left.ToString('hh\:mm\:ss') + ' left'
    }
    if (-not $sync.Cancel) { $ui.tbStatus.Text = $sync.Status }
    $ui.tbProgressText.Text = $txt
    if ($sync.Done) { Complete-Worker }
})

# ---------------------------------------------------------------- backup plan (shared by the window and scheduled runs)
function New-BackupPlan($S) {
    $letter = ([string]$S.Source).Trim().TrimEnd(':')
    $v = $null
    if ($letter) { $v = Get-SourceVolume $letter }
    if (-not $v) { return @{ Error = $(if ($letter) { "Drive ${letter}: isn't available. Plug it in or pick another source drive." } else { 'Pick a source drive first.' }) } }
    $dest = ([string]$S.Destination).Trim().Trim('"')
    if ($dest.Length -gt 3) { $dest = $dest.TrimEnd('\') }
    if (-not $dest) { return @{ Error = 'Choose where to save the image.' } }

    $r = Resolve-Destination $dest
    $dest = $r.Path
    if (Test-IsUnc $dest) {
        $err = Connect-Share $dest '' '' $false
        if (-not $err) { $err = Test-WriteAccess $dest }
        if ($err) { return @{ Error = $err + "`n`nClick Network... next to the destination to sign in to this share."; Dest = $dest } }
    }
    elseif ($dest -match '^([A-Za-z]):' -and -not [IO.Directory]::Exists($Matches[1] + ':\')) {
        return @{ Error = "Drive $($Matches[1].ToUpper()): isn't available to Drive Imager.`n`nIf it's a network drive, click Network... and pick it from the list." }
    }

    $isWsb = ($S.Engine -eq 'WSB')
    $plan = @{ Error = $null; Dest = $dest; Note = $r.Note; Letter = $letter; SameVolume = (Test-SameVolume $dest $v) }
    if ($plan.SameVolume -and $isWsb) { $plan.Error = "A System Image can't be saved onto the drive being backed up. Pick another drive."; return $plan }
    if ($isWsb -and -not (Test-CanSnapshot $v)) { $plan.Error = "Windows System Image only works with NTFS drives, and ${letter}: is $($v.FileSystem). Choose 'Single image file (.wim)' instead."; return $plan }

    $used = [double]($v.Size - $v.SizeRemaining)
    $factor = $(if ($isWsb) { 0.9 } else { @(1.0, 0.7, 0.55)[[math]::Min(2, [math]::Max(0, [int]$S.Compression))] })
    $plan.Estimate = $used * $factor
    $fs = Get-FreeSpace $dest
    $plan.Free = $(if ($fs) { $fs.Free } else { $null })
    $plan.LowSpace = [bool]($fs -and $fs.Free -lt $plan.Estimate)

    if ($isWsb) {
        $t = Get-WsbTarget $dest
        if (-not $t) { $plan.Error = 'System Image needs a drive letter (like E:) or a network share (like \\server\backups).'; return $plan }
        $cfg = @{ WsbTarget = $t; SourceLetter = $letter; AllCritical = [bool]$S.AllCritical; Readme = [bool]$S.Readme }
        $root = Get-ShareRoot $t
        if ($root -and $script:NetCreds[$root.ToLower()]) { $cfg.WsbUser = $script:NetCreds[$root.ToLower()].User; $cfg.WsbPass = $script:NetCreds[$root.ToLower()].Pass }
        $plan.Kind = 'WSB'; $plan.Body = $WsbBody; $plan.Title = "System Image of ${letter}:"; $plan.Cfg = $cfg
        return $plan
    }

    $keep = 0
    if ($S.Retention) {
        if (-not [int]::TryParse(([string]$S.KeepCount).Trim(), [ref]$keep) -or $keep -lt 1) { $plan.Error = 'Enter how many images to keep (1 or more).'; return $plan }
    }
    $base = Expand-NamePattern ([string]$S.NamePattern) $letter
    $out = Join-Path $dest ($base + '.wim')
    $n = 2
    while (Test-PathSafe $out) { $out = Join-Path $dest ("{0}_{1}.wim" -f $base, $n); $n++ }

    $plan.Cfg = @{
        SourceRoot        = "${letter}:\"
        SourceLetter      = $letter
        UseSnapshot       = (Test-CanSnapshot $v)
        FileSystem        = $v.FileSystem
        OutFile           = $out
        ImageName         = $base
        Description       = [string]$S.Description
        Compression       = [math]::Min(2, [math]::Max(0, [int]$S.Compression))
        Verify            = [bool]$S.Verify
        Integrity         = [bool]$S.Integrity
        Hash              = [bool]$S.Hash
        Readme            = [bool]$S.Readme
        ExTemp            = [bool]$S.ExTemp
        ExWU              = [bool]$S.ExWU
        ExDumps           = [bool]$S.ExDumps
        ExDO              = [bool]$S.ExDO
        ExCustom          = @(([string]$S.ExCustom) -split "`r?`n" | Where-Object { $_.Trim() })
        Retention         = [bool]$S.Retention
        KeepCount         = $keep
        RetentionWildcard = Get-RetentionWildcard ([string]$S.NamePattern) $letter
        PendingFile       = $PendingFile
        WizardPath        = (Join-Path $PSScriptRoot 'DriveImager_Restore.cmd')
    }
    $plan.Kind = 'WIM'; $plan.Body = $WimBody; $plan.Title = "Backing up ${letter}: to $out"
    return $plan
}

# ---------------------------------------------------------------- schedule (Windows Task Scheduler)
function Get-BackupTask { Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -ErrorAction SilentlyContinue }

function Update-ScheduleUi {
    $ui.cbSchedDay.IsEnabled = ($ui.cbSchedFreq.SelectedIndex -gt 0)
    $t = Get-BackupTask
    if (-not $t) {
        $ui.tbSchedStatus.Text = 'No schedule yet. Backups only run when you click Start.'
        $ui.btnSchedRemove.IsEnabled = $false
        $ui.btnSchedRun.IsEnabled = $false
        return
    }
    $ui.btnSchedRemove.IsEnabled = $true
    $ui.btnSchedRun.IsEnabled = $true
    $txt = $(if ("$($t.State)" -eq 'Running') { 'A scheduled backup is running right now.' } elseif ("$($t.State)" -eq 'Disabled') { 'The schedule is turned off in Task Scheduler.' } else { 'Schedule is on.' })
    try {
        $i = $t | Get-ScheduledTaskInfo -ErrorAction Stop
        if ($i.NextRunTime) { $txt += '  Next run: ' + $i.NextRunTime.ToString('ddd MMM d, h:mm tt') }
    } catch { }
    $ui.tbSchedStatus.Text = $txt
}

function Save-Schedule {
    $at = [datetime]::MinValue
    $formats = [string[]]@('H:mm', 'HH:mm', 'h:mm tt', 'h:mmtt', 'h tt', 'htt', 'H')
    if (-not [datetime]::TryParseExact($ui.txtSchedTime.Text.Trim().ToUpper(), $formats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$at)) {
        Show-Msg 'Type a time like 03:00, 23:30 or 2:15 AM.' 'Warning'; return
    }
    $at = (Get-Date).Date.Add($at.TimeOfDay)
    $day = [System.DayOfWeek][math]::Max(0, $ui.cbSchedDay.SelectedIndex)
    switch ([math]::Max(0, $ui.cbSchedFreq.SelectedIndex)) {
        0       { $trigger = New-ScheduledTaskTrigger -Daily -At $at }
        1       { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $at }
        2       { $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 2 -DaysOfWeek $day -At $at }
        default { $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek $day -At $at }
    }
    $plan = New-BackupPlan (Get-UiSettings)
    if ($plan.Error) {
        if (-not (Ask ("These settings would not work right now:`n`n$($plan.Error)`n`nSave the schedule anyway?"))) { return }
    }
    Save-Settings
    try {
        $exe = Join-Path $PSHOME 'powershell.exe'
        $action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`" -Auto"
        $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Hours 12) -WakeToRun:([bool]$ui.chkSchedWake.IsChecked)
        Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description 'Drive Imager backup using the settings saved in the Drive Imager window.' -Force -ErrorAction Stop | Out-Null
        Write-UiLog "Schedule saved: $($ui.cbSchedFreq.Text) $(if ($ui.cbSchedDay.IsEnabled) { $ui.cbSchedDay.Text }) at $($at.ToString('HH:mm'))"
        Update-ScheduleUi
        Show-Msg ("Schedule saved.`n`n" + $ui.tbSchedStatus.Text + "`n`nIf you move DriveImager.ps1 to another folder, open it and save the schedule again.")
    } catch { Show-Msg ("Could not save the schedule:`n`n" + $_.Exception.Message) 'Error' }
}

# ---------------------------------------------------------------- notifications for scheduled runs
function Show-Notification([string]$Title, [string]$Text, [bool]$IsError) {
    try {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = $(if ($IsError) { [System.Drawing.SystemIcons]::Error } else { [System.Drawing.SystemIcons]::Information })
        $ni.Text = 'Drive Imager'
        $ni.Visible = $true
        $ni.ShowBalloonTip(15000, $Title, $Text, $(if ($IsError) { 'Error' } else { 'Info' }))
        $until = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $until) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
        $ni.Visible = $false
        $ni.Dispose()
    } catch { }
}

# ---------------------------------------------------------------- headless run (-Auto)
function Invoke-AutoBackup {
    $started = Get-Date
    Write-UiLog '=== Scheduled backup starting ==='
    if (-not (Enter-JobLock)) { Write-UiLog 'Drive Imager is already running a job. This scheduled run was skipped.'; Flush-Log; return 2 }
    try {
        Clear-StaleSnapshot
        $s = Read-SettingsFile
        Reset-Sync 'Scheduled backup'
        $plan = New-BackupPlan $s
        $kind = $(if ($s.Engine -eq 'WSB') { 'WSB' } else { 'WIM' })
        if ($plan.Error) {
            $sync.Error = $plan.Error -replace "`n`nClick Network.*$", ''
            Write-UiLog "ERROR: $($sync.Error)"
        }
        else {
            if ($plan.Note) { Write-UiLog $plan.Note }
            if ($plan.SameVolume) { Write-UiLog 'Warning: the destination is on the drive being backed up.' }
            if ($plan.LowSpace) { Write-UiLog ("Warning: about {0} needed, {1} free. Trying anyway." -f (Format-Bytes $plan.Estimate), (Format-Bytes $plan.Free)) }
            [void][DriveImagerNative]::SetThreadExecutionState([uint32]2147483649)
            $plan.Cfg.Title = $plan.Title
            Reset-Sync $plan.Title
            $job = New-WorkerRunspace $plan.Body $plan.Cfg
            while (-not $job.Handle.IsCompleted) { Start-Sleep -Milliseconds 500; Flush-Log }
            try { [void]$job.PS.EndInvoke($job.Handle) } catch { Write-UiLog "Worker error: $($_.Exception.Message)" }
            try { $job.PS.Dispose(); $job.RS.Dispose() } catch { }
            [void][DriveImagerNative]::SetThreadExecutionState([uint32]2147483648)
        }
        $ok = [bool]$sync.Success
        Add-History $ok $kind 'Scheduled' $started
        Write-UiLog ("=== Scheduled backup {0} ===" -f $(if ($ok) { 'finished' } else { 'FAILED' }))
        Flush-Log
    }
    finally { Exit-JobLock }

    $after = [int]$s.After
    if ($ok) {
        $size = ''
        if ($sync.OutFile -and $kind -eq 'WIM') { try { $size = ' (' + (Format-Bytes (Get-Item -LiteralPath $sync.OutFile).Length) + ')' } catch { } }
        Show-Notification 'Backup finished' ("Saved $($sync.OutFile)$size") $false
        if ($after -eq 1) { [void][System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false) }
        elseif ($after -eq 2) { Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s /t 120 /c "Drive Imager finished. Shutting down in 2 minutes. Run shutdown /a to cancel."' -WindowStyle Hidden }
        return 0
    }
    Show-Notification 'Backup FAILED' ("$($sync.Error)`nOpen Drive Imager and check the Log tab.") $true
    return 1
}

if ($Auto) {
    $code = 1
    try { $code = Invoke-AutoBackup }
    catch { Write-UiLog "ERROR: $($_.Exception.Message)"; Flush-Log }
    exit $code
}

# ---------------------------------------------------------------- after backup
$AfterBackup = {
    param($ok)
    if (-not $ui.rbWsb.IsChecked) { $ui.txtImgFolder.Text = $ui.txtDest.Text; Refresh-Images }
    if ($ok) {
        switch ($ui.cbAfter.SelectedIndex) {
            1 {
                Write-UiLog 'Putting the PC to sleep.'
                [void][System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false)
            }
            2 {
                Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s /t 120 /c "Drive Imager finished. Shutting down in 2 minutes. Run shutdown /a to cancel."' -WindowStyle Hidden
                Show-Msg "Backup finished. Windows shuts down in 2 minutes.`n`nTo stop it, run:  shutdown /a"
            }
            default { Show-Msg ("Backup finished successfully.`n`n" + $sync.Result) }
        }
    }
    elseif (-not $sync.Cancel) {
        Show-Msg ("The backup did not finish.`n`n" + $sync.Error + "`n`nThe Log tab has the details.") 'Error'
    }
}

# ---------------------------------------------------------------- events
$ui.cbSource.Add_SelectionChanged({ Update-SourceInfo })
$ui.btnRescan.Add_Click({
    Fill-SourceList
    if ($ui.cbSource.SelectedIndex -lt 0 -and $script:Volumes.Count) { $ui.cbSource.SelectedIndex = 0 }
    Update-SourceInfo
    Write-UiLog "Found $($script:Volumes.Count) drive(s)."
})
$ui.rbWim.Add_Checked({ Update-EngineUi })
$ui.rbWsb.Add_Checked({ Update-EngineUi })
$script:DestTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DestTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:DestTimer.Add_Tick({ $script:DestTimer.Stop(); Update-DestInfo })
$ui.txtDest.Add_TextChanged({ $script:DestTimer.Stop(); $script:DestTimer.Start() })

$ui.btnNetwork.Add_Click({
    $p = Show-NetworkDialog $ui.txtDest.Text
    if ($p) { $ui.txtDest.Text = $p; $script:DestTimer.Stop(); Update-DestInfo }
})
$ui.btnImgNetwork.Add_Click({
    $p = Show-NetworkDialog $ui.txtImgFolder.Text
    if ($p) { $ui.txtImgFolder.Text = $p; Refresh-Images }
})
$ui.cbCompression.Add_SelectionChanged({ Update-DestInfo })
$ui.txtName.Add_TextChanged({ Update-NamePreview })

$ui.btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose where to save backup images'
    $dlg.ShowNewFolderButton = $true
    if (Test-PathSafe $ui.txtDest.Text) { $dlg.SelectedPath = $ui.txtDest.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ui.txtDest.Text = $dlg.SelectedPath }
})

$ui.btnStart.Add_Click({
    Save-Settings
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try { $plan = New-BackupPlan (Get-UiSettings) } finally { $window.Cursor = $null }
    if ($plan.Dest -and $plan.Dest -ne $ui.txtDest.Text.Trim()) { $ui.txtDest.Text = $plan.Dest; Save-Settings }
    if ($plan.Note) { Write-UiLog $plan.Note }
    if ($plan.Error) { Show-Msg $plan.Error 'Warning'; return }
    if ($plan.SameVolume) {
        if (-not (Ask "This saves the backup onto the same drive you are backing up.`nIf that drive dies, the backup goes with it.`n`nContinue anyway?")) { return }
    }
    if ($plan.LowSpace) {
        if (-not (Ask ("The destination has {0} free and the image may need about {1}.`n`nTry anyway?" -f (Format-Bytes $plan.Free), (Format-Bytes $plan.Estimate)))) { return }
    }
    $ui.tabMain.SelectedItem = $ui.tabLog
    Start-Worker -Title $plan.Title -Body $plan.Body -Cfg $plan.Cfg -OnDone $AfterBackup -Kind $plan.Kind
})

# schedule card
$ui.cbSchedFreq.Add_SelectionChanged({ $ui.cbSchedDay.IsEnabled = ($ui.cbSchedFreq.SelectedIndex -gt 0) })
$ui.btnSchedSave.Add_Click({ Save-Schedule })
$ui.btnSchedRemove.Add_Click({
    if (-not (Ask 'Remove the backup schedule? Your images are not touched.')) { return }
    try { Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -Confirm:$false -ErrorAction Stop; Write-UiLog 'Schedule removed.' }
    catch { Show-Msg $_.Exception.Message 'Error' }
    Update-ScheduleUi
})
$ui.btnSchedRun.Add_Click({
    if ($script:Busy) { Show-Msg 'Wait for the current job to finish first.'; return }
    Save-Settings
    try {
        Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -ErrorAction Stop
        Show-Msg "The scheduled backup is running in the background now, exactly as it will on schedule.`n`nYou get a notification when it finishes. Its log goes to the log folder (Log tab > Open log folder)."
    } catch { Show-Msg $_.Exception.Message 'Error' }
    Update-ScheduleUi
})

$ui.btnCancel.Add_Click({
    if (-not $script:Busy) { return }
    if (-not (Ask 'Stop the current job? Any partial image is deleted.')) { return }
    $sync.Cancel = $true
    $ui.tbStatus.Text = 'Cancelling, cleaning up...'
    try { $proc = $sync.Process; if ($proc -and -not $proc.HasExited) { $proc.Kill() } } catch { }
    if ($script:JobKind -eq 'WSB') { Start-Process -FilePath 'wbadmin.exe' -ArgumentList 'stop job -quiet' -WindowStyle Hidden }
})

# images tab
$ui.btnImgRefresh.Add_Click({ Refresh-Images })
$ui.btnImgBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Folder that holds your .wim images'
    if (Test-PathSafe $ui.txtImgFolder.Text) { $dlg.SelectedPath = $ui.txtImgFolder.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ui.txtImgFolder.Text = $dlg.SelectedPath; Refresh-Images }
})
$ui.btnImgInfo.Add_Click({
    $f = Get-SelectedImage; if (-not $f) { return }
    $ui.tabMain.SelectedItem = $ui.tabLog
    Start-Worker -Title "Image details: $(Split-Path -Leaf $f)" -Body $InfoBody -Cfg @{ File = $f }
})
$ui.btnImgVerify.Add_Click({
    $f = Get-SelectedImage; if (-not $f) { return }
    Start-Worker -Title "Verifying $(Split-Path -Leaf $f)" -Body $VerifyBody -Cfg @{ File = $f } -OnDone {
        param($ok)
        Refresh-Images
        if ($ok -and $sync.Result -eq 'match') { Show-Msg 'Checksum matches. The image file is intact.' }
        elseif ($ok) { Show-Msg 'There was no checksum file yet, so one was created. Future checks will compare against it.' }
        elseif (-not $sync.Cancel) { Show-Msg $sync.Error 'Error' }
    }
})
$ui.btnImgMount.Add_Click({
    $f = Get-SelectedImage; if (-not $f) { return }
    $dir = Join-Path $MountRoot ([IO.Path]::GetFileNameWithoutExtension($f))
    Start-Worker -Title "Mounting $(Split-Path -Leaf $f)" -Body $MountBody -Cfg @{ File = $f; MountDir = $dir } -OnDone {
        param($ok)
        if ($ok) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($sync.Result)`"" }
        elseif (-not $sync.Cancel) { Show-Msg $sync.Error 'Error' }
    }
})
$ui.btnImgUnmount.Add_Click({
    Start-Worker -Title 'Unmounting images' -Body $UnmountBody -Cfg @{ MountRoot = $MountRoot }
})
$ui.btnImgOpen.Add_Click({
    $f = Get-SelectedImage; if (-not $f) { return }
    Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$f`""
})
$ui.btnImgDelete.Add_Click({
    $f = Get-SelectedImage; if (-not $f) { return }
    $q = $(if (Test-IsUnc $f) { "Delete this image? It is on a network share, so it is removed permanently (no Recycle Bin)." } else { "Send this image to the Recycle Bin?" })
    if (-not (Ask "$q`n`n$f")) { return }
    try {
        foreach ($x in @($f, ($f + '.sha256'), (Join-Path (Split-Path -Parent $f) ([IO.Path]::GetFileNameWithoutExtension($f) + '_RESTORE.txt')))) {
            if (Test-Path -LiteralPath $x) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($x, 'AllDialogs', 'SendToRecycleBin')
            }
        }
        Write-UiLog "Deleted $f"
    } catch { Show-Msg $_.Exception.Message 'Error' }
    Refresh-Images
})

# log tab
$ui.btnClearLog.Add_Click({ $ui.txtLog.Clear() })
$ui.btnOpenLogs.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$LogDir`"" })
$ui.btnSaveLog.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'Text file (*.txt)|*.txt'
    $dlg.FileName = 'DriveImager_log_{0}.txt' -f (Get-Date).ToString('yyyy-MM-dd_HHmm')
    if ($dlg.ShowDialog($window)) { Set-Content -LiteralPath $dlg.FileName -Value $ui.txtLog.Text -Encoding UTF8 }
})

$window.Add_Closing({
    param($s, $e)
    if ($script:Busy -and -not $script:ForceClose) {
        $e.Cancel = $true
        if (Ask 'A job is still running. Cancel it and close once it has cleaned up?') {
            $sync.Cancel = $true
            $script:CloseAfterJob = $true
            try { $proc = $sync.Process; if ($proc -and -not $proc.HasExited) { $proc.Kill() } } catch { }
            if ($script:JobKind -eq 'WSB') { Start-Process -FilePath 'wbadmin.exe' -ArgumentList 'stop job -quiet' -WindowStyle Hidden }
        }
        return
    }
    Save-Settings
    $mounted = @(Get-ChildItem -LiteralPath $MountRoot -Directory -ErrorAction SilentlyContinue)
    if ($mounted.Count) {
        [void][System.Windows.MessageBox]::Show("$($mounted.Count) image(s) are still mounted under $MountRoot.`nThey stay mounted until you open Drive Imager and click Unmount all.", 'Drive Imager')
    }
})

# ---------------------------------------------------------------- start up
try {
    Fill-SourceList
    Load-Settings
    Update-EngineUi
    Update-SourceInfo
    Refresh-Images
    Update-DestInfo
    Update-ScheduleUi
    Update-LastBackup
    if (Enter-JobLock) { Exit-JobLock; Clear-StaleSnapshot }
    Write-UiLog "Drive Imager ready. Logs are kept in $LogDir"
    $timer.Start()

    $h = [DriveImagerNative]::GetConsoleWindow()
    if ($h -ne [IntPtr]::Zero) { [void][DriveImagerNative]::ShowWindow($h, 0) }

    [void]$window.ShowDialog()
}
catch {
    [void][System.Windows.MessageBox]::Show("Drive Imager hit an error while starting:`n`n$($_.Exception.Message)", 'Drive Imager')
}
finally {
    $timer.Stop()
    [void][DriveImagerNative]::SetThreadExecutionState([uint32]2147483648)
}
