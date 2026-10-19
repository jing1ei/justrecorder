using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using JustRecorder.Core;
using Windows.Media.Control;
namespace JustRecorder.Windows;

internal static class Platform
{
    public const string AppName = "JustRecorder";
    public const string LegacyAppName = "Riff";
    public static string DataFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName);
    public static string SettingsPath => Path.Combine(DataFolder, "settings.json");
    static string LogPath => Path.Combine(DataFolder, "justrecorder.log");

    /// <summary>
    /// One-time migration from the pre-rename build: settings folder, log, login-item
    /// registry value and stored credential. Each step is best-effort; a failure is
    /// logged and must never stop launch.
    /// </summary>
    public static void MigrateFromLegacyBuild()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var legacyFolder = Path.Combine(localAppData, LegacyAppName);
        try
        {
            if (Directory.Exists(legacyFolder))
            {
                if (!Directory.Exists(DataFolder))
                {
                    Directory.Move(legacyFolder, DataFolder);
                }
                else
                {
                    // Both folders exist: copy over only the files the new folder lacks.
                    foreach (var file in Directory.GetFiles(legacyFolder))
                    {
                        var target = Path.Combine(DataFolder, Path.GetFileName(file));
                        if (!File.Exists(target)) File.Move(file, target);
                    }
                }
                var oldLog = Path.Combine(DataFolder, "riff.log");
                if (File.Exists(oldLog) && !File.Exists(LogPath))
                {
                    try { File.Move(oldLog, LogPath); } catch (IOException) { }
                }
            }
        }
        catch (Exception ex) { Log(ex); }

        try
        {
            using var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", writable: true);
            if (run != null)
            {
                if (run.GetValue(LegacyAppName) is string command && run.GetValue(AppName) is null)
                    run.SetValue(AppName, command);
                run.DeleteValue(LegacyAppName, false);
            }
        }
        catch (Exception ex) { Log(ex); }

        try
        {
            var legacyKey = KeyRead(LegacyCredentialTarget);
            if (legacyKey.Length > 0 && KeyRead(CredentialTarget).Length == 0) KeyWrite(CredentialTarget, legacyKey);
            KeyDelete(LegacyCredentialTarget);
        }
        catch (Exception ex) { Log(ex); }
    }

    public static void Reveal(string path) { var p = new ProcessStartInfo("explorer.exe") { UseShellExecute = true }; p.ArgumentList.Add("/select," + path); Process.Start(p); }
    public static void OpenFolder(string path) { Directory.CreateDirectory(path); Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
    public static void Log(Exception ex) { try { Directory.CreateDirectory(DataFolder); File.AppendAllText(LogPath, $"{DateTime.Now:u} {ex.GetType().Name}: {ex.Message}\n"); } catch (IOException) { } }
    public static bool LaunchAtLogin
    {
        get { using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); return key?.GetValue(AppName) is string; }
        set { using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); if (value) key.SetValue(AppName, $"\"{Environment.ProcessPath}\""); else key.DeleteValue(AppName, false); }
    }
    const string CredentialTarget = "JustRecorder.AI";
    const string LegacyCredentialTarget = "Riff.AI";
    public static string KeyRead() => KeyRead(CredentialTarget);
    public static void KeyWrite(string value) => KeyWrite(CredentialTarget, value);
    static void KeyDelete(string target)
    {
        if (!CredDelete(target, 1, 0) && Marshal.GetLastWin32Error() != 1168) throw new System.ComponentModel.Win32Exception();
    }
    static string KeyRead(string target)
    {
        if (!CredRead(target, 1, 0, out var ptr)) { var error = Marshal.GetLastWin32Error(); if (error == 1168) return ""; throw new System.ComponentModel.Win32Exception(error); }
        try { var c = Marshal.PtrToStructure<Credential>(ptr); return Marshal.PtrToStringUni(c.Blob, (int)c.Size / 2) ?? ""; } finally { CredFree(ptr); }
    }
    static void KeyWrite(string target, string value)
    {
        if (value.Length == 0) { KeyDelete(target); return; }
        var bytes = Encoding.Unicode.GetBytes(value); if (bytes.Length > 2560) throw new ArgumentException("The API key is too long for Credential Manager.");
        var ptr = Marshal.AllocHGlobal(bytes.Length); try { Marshal.Copy(bytes, 0, ptr, bytes.Length); var c = new Credential { Type = 1, Target = target, User = AppName, Persist = 2, Size = (uint)bytes.Length, Blob = ptr }; if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(); } finally { Marshal.FreeHGlobal(ptr); }
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct Credential { public uint Flags, Type; public string Target; public string? Comment; public long LastWritten; public uint Size; public IntPtr Blob; public uint Persist, Count; public IntPtr Attributes; public string? Alias; public string User; }
    [DllImport("advapi32", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredWrite(ref Credential credential, uint flags);
    [DllImport("advapi32", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredDelete(string target, uint type, uint flags);
    [DllImport("advapi32")] static extern void CredFree(IntPtr buffer);
}
internal sealed class HotKey : NativeWindow, IDisposable
{
    const int Id = 7153; public event Action? Pressed; public bool Enabled { get; set; } = true;
    public HotKey() { CreateHandle(new CreateParams()); }
    public bool Register(uint key, uint modifiers) { UnregisterHotKey(Handle, Id); return RegisterHotKey(Handle, Id, modifiers | 0x4000, key); }
    protected override void WndProc(ref Message m) { if (m.Msg == 0x312 && Enabled) Pressed?.Invoke(); base.WndProc(ref m); }
    public void Dispose() { UnregisterHotKey(Handle, Id); DestroyHandle(); }
    [DllImport("user32", SetLastError = true)] static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32")] static extern bool UnregisterHotKey(IntPtr window, int id);
}
internal static class SourceDetector
{
    public static async Task<Source> Detect(bool metadata, CancellationToken cancel)
    {
        if (metadata) try
            {
                var manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync().AsTask(cancel);
                var sessions = manager.GetSessions().OrderByDescending(x => x == manager.GetCurrentSession());
                foreach (var session in sessions)
                {
                    if (session.GetPlaybackInfo().PlaybackStatus != GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing) continue;
                    var props = await session.TryGetMediaPropertiesAsync().AsTask(cancel);
                    if (!string.IsNullOrWhiteSpace(props.Title)) return new(session.SourceAppUserModelId, props.Title, props.Artist ?? "", props.Title);
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException) { Platform.Log(ex); }
        cancel.ThrowIfCancellationRequested();
        return await Task.Run(() => WindowSource(), cancel);
    }
    static Source WindowSource()
    {
        var active = new HashSet<int>();
        try
        {
            using var devices = new MMDeviceEnumerator(); using var output = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            var sessions = output.AudioSessionManager.Sessions;
            for (int i = 0; i < sessions.Count; i++) { using var session = sessions[i]; if (session.AudioMeterInformation.MasterPeakValue > 0.0005f) active.Add((int)session.GetProcessID); }
        }
        catch (Exception ex) { Platform.Log(ex); }
        var front = GetForegroundWindow(); Source? best = null; int bestScore = -1;
        EnumWindows((window, _) =>
        {
            if (!IsWindowVisible(window)) return true; GetWindowThreadProcessId(window, out var pid); if (pid == Environment.ProcessId) return true;
            var text = new StringBuilder(1024); GetWindowText(window, text, text.Capacity); if (text.Length == 0) return true;
            var score = (active.Contains((int)pid) ? 100 : 0) + (window == front ? 10 : 0); if (score <= bestScore || score == 0) return true;
            try { using var p = Process.GetProcessById((int)pid); var clean = Naming.Clean(text.ToString()); var parts = clean.Split(" - "); best = parts.Length == 2 ? new(p.ProcessName, text.ToString(), parts[0], parts[1]) : new(p.ProcessName, text.ToString()); bestScore = score; } catch (ArgumentException) { }
            return true;
        }, IntPtr.Zero);
        return best ?? new Source();
    }
    delegate bool EnumProc(IntPtr window, IntPtr param);
    [DllImport("user32")] static extern bool EnumWindows(EnumProc callback, IntPtr param);
    [DllImport("user32")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int max);
}
