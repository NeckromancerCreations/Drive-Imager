// Drive Imager launcher
// The app itself is DriveImager.ps1 (PowerShell + WPF). This exe carries it, and the
// restore wizard, as embedded resources. On start it writes them to
// %LOCALAPPDATA%\DriveImager\app and runs the script elevated, with no console window.
// The fixed location matters: a backup schedule saved in the app points at that copy.
//
// Build: see build.bat (uses the C# compiler that ships with Windows).

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Drive Imager")]
[assembly: AssemblyDescription("Image a running Windows drive to a file you can browse or restore later.")]
[assembly: AssemblyProduct("Drive Imager")]
[assembly: AssemblyCompany("NeckromancerCreations")]
[assembly: AssemblyCopyright("NeckromancerCreations")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class DriveImagerLauncher
{
    static readonly string[] Payload = { "DriveImager.ps1", "DriveImager_Restore.cmd" };

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string appDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DriveImager", "app");
            Directory.CreateDirectory(appDir);

            foreach (string name in Payload)
                WriteIfChanged(name, Path.Combine(appDir, name));

            string script = Path.Combine(appDir, "DriveImager.ps1");
            string extra = BuildArgs(args);

            var psi = new ProcessStartInfo
            {
                FileName = FindPowerShell(),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"" + extra,
                WorkingDirectory = appDir,
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            if (!IsAdmin()) psi.Verb = "runas";   // one UAC prompt; the app needs admin to snapshot drives

            Process.Start(psi);
            return 0;
        }
        catch (System.ComponentModel.Win32Exception ex)
        {
            if (ex.NativeErrorCode == 1223) return 1;   // UAC prompt was cancelled
            Fail(ex.Message);
            return 1;
        }
        catch (Exception ex)
        {
            Fail(ex.Message);
            return 1;
        }
    }

    static void WriteIfChanged(string resource, string target)
    {
        byte[] data;
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
        {
            if (s == null) throw new InvalidOperationException("This exe is missing " + resource + ". Download it again.");
            using (var ms = new MemoryStream()) { s.CopyTo(ms); data = ms.ToArray(); }
        }
        if (File.Exists(target))
        {
            byte[] old = File.ReadAllBytes(target);
            if (old.Length == data.Length && SameBytes(old, data)) return;
        }
        File.WriteAllBytes(target, data);
    }

    static bool SameBytes(byte[] a, byte[] b)
    {
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }

    static string BuildArgs(string[] args)
    {
        // Pass through switches the script understands, such as -Auto for a hidden scheduled run.
        var sb = new StringBuilder();
        foreach (string a in args)
        {
            if (a.Length > 1 && (a[0] == '-' || a[0] == '/') && a.IndexOfAny(new[] { '"', ' ', '&', '|', ';' }) < 0)
                sb.Append(' ').Append('-').Append(a.Substring(1));
        }
        return sb.ToString();
    }

    static string FindPowerShell()
    {
        string win = Environment.GetEnvironmentVariable("WINDIR") ?? @"C:\Windows";
        // A 32 bit process on 64 bit Windows must use Sysnative to reach the 64 bit PowerShell.
        string sysnative = Path.Combine(win, @"Sysnative\WindowsPowerShell\v1.0\powershell.exe");
        if (!Environment.Is64BitProcess && File.Exists(sysnative)) return sysnative;
        string system32 = Path.Combine(win, @"System32\WindowsPowerShell\v1.0\powershell.exe");
        return File.Exists(system32) ? system32 : "powershell.exe";
    }

    static bool IsAdmin()
    {
        using (WindowsIdentity id = WindowsIdentity.GetCurrent())
            return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }

    static void Fail(string message)
    {
        MessageBox.Show("Drive Imager could not start:\n\n" + message, "Drive Imager",
            MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
