using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Update Control Desktop")]
[assembly: AssemblyDescription("Windows update controls with Store Friendly mode and verified restore")]
[assembly: AssemblyCompany("Ajay Kareer")]
[assembly: AssemblyProduct("Update Control Desktop")]
[assembly: AssemblyVersion("4.2.0.0")]
[assembly: AssemblyFileVersion("4.2.0.0")]

internal static class Program
{
    private static readonly string[] Required = {
        "UpdateControl.GUI.ps1", "UpdateControl.xaml", "UpdateControl.Worker.ps1",
        "UpdateControl.ps1", "Repair-WindowsStore.ps1", "LICENSE", "READ-ME-FIRST.txt"
    };

    [STAThread]
    private static int Main(string[] args)
    {
        bool checkOnly = args.Length == 2 && args[0] == "--verify-package";
        try
        {
            if (args.Length != 0 && !checkOnly) throw new ArgumentException("Unknown command line. Double-click the EXE to open Update Control.");
            byte[] payload;
            using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream("UpdateControl.Payload.zip"))
            using (MemoryStream copy = new MemoryStream())
            {
                if (input == null) throw new InvalidDataException("The application payload is missing.");
                input.CopyTo(copy);
                payload = copy.ToArray();
            }
            if (Hash(payload) != BuildInfo.PayloadSha256) throw new InvalidDataException("Package integrity check failed. Download the EXE again.");
            var files = ReadPackage(payload);
            foreach (string required in Required)
                if (!files.ContainsKey(required)) throw new InvalidDataException("Missing component: " + required);

            // Extraction uses Program Files, where standard users cannot replace elevated scripts.
            string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string basePath = Path.Combine(programFiles, "Kareer Update Control");
            CheckParents(basePath);
            Directory.CreateDirectory(basePath);
            ProtectDirectory(basePath);
            string folder = Path.Combine(basePath, BuildInfo.Version + "-" + BuildInfo.PayloadSha256.Substring(0, 16));
            CheckParents(folder);
            Directory.CreateDirectory(folder);
            ProtectDirectory(folder);
            foreach (var item in files)
            {
                string target = Path.Combine(folder, item.Key);
                if (File.Exists(target))
                {
                    CheckParents(target);
                    // Never execute a changed cached script. Fail explicitly rather than trust it.
                    if (Hash(File.ReadAllBytes(target)) != Hash(item.Value))
                        throw new InvalidDataException("A cached component changed: " + target + ". Remove this version's folder as administrator and retry.");
                    ProtectFile(target);
                }
                else
                {
                    using (FileStream output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                        output.Write(item.Value, 0, item.Value.Length);
                    ProtectFile(target);
                }
            }
            if (checkOnly)
            {
                File.WriteAllText(Path.GetFullPath(args[1]), "PASS: embedded SHA-256, safe ZIP entries, required components, protected extraction and file hashes.\r\nVersion: " + BuildInfo.Version + "\r\nPath: " + folder + "\r\n", Encoding.UTF8);
                return 0;
            }
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string system = Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess ? "Sysnative" : "System32";
            string powershell = Path.Combine(windows, system, "WindowsPowerShell", "v1.0", "powershell.exe");
            var start = new ProcessStartInfo(powershell,
                "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + Path.Combine(folder, "UpdateControl.GUI.ps1") + "\"");
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WorkingDirectory = folder;
            using (Process gui = Process.Start(start))
            {
                gui.WaitForExit();
                return gui.ExitCode;
            }
        }
        catch (Exception error)
        {
            if (checkOnly) { try { File.WriteAllText(Path.GetFullPath(args[1]), "FAIL: " + error); } catch { } }
            else MessageBox.Show(error.Message, "Update Control could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static Dictionary<string, byte[]> ReadPackage(byte[] payload)
    {
        var files = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
        using (MemoryStream stream = new MemoryStream(payload))
        using (ZipArchive archive = new ZipArchive(stream, ZipArchiveMode.Read))
        {
            if (archive.Entries.Count > 32) throw new InvalidDataException("Unexpected package size.");
            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                string name = entry.FullName;
                if (string.IsNullOrWhiteSpace(name) || name != Path.GetFileName(name) || name.IndexOfAny(new[] { '/', '\\', ':' }) >= 0 || name.EndsWith(".") || name.EndsWith(" ") || entry.Length > 8 * 1024 * 1024)
                    throw new InvalidDataException("Unsafe package entry: " + name);
                using (Stream input = entry.Open())
                using (MemoryStream copy = new MemoryStream()) { input.CopyTo(copy); files.Add(name, copy.ToArray()); }
            }
        }
        return files;
    }

    private static string Hash(byte[] data)
    {
        using (SHA256 sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "").ToLowerInvariant();
    }

    private static void CheckParents(string path)
    {
        for (string current = Path.GetFullPath(path); !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
            if ((Directory.Exists(current) || File.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Refusing to load application code through a reparse point: " + current);
    }

    private static void ProtectDirectory(string path)
    {
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
        AddRules(security, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit);
        Directory.SetAccessControl(path, security);
    }

    private static void ProtectFile(string path)
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
        AddRules(security, InheritanceFlags.None);
        File.SetAccessControl(path, security);
    }

    private static void AddRules(FileSystemSecurity security, InheritanceFlags inherit)
    {
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null), FileSystemRights.ReadAndExecute, inherit, PropagationFlags.None, AccessControlType.Allow));
    }
}
