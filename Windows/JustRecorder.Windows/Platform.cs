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
    // Storage and credential identifiers remain stable for existing installations.
    public static string DataFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Riff");
    public static string SettingsPath => Path.Combine(DataFolder, "settings.json");
    public static void Reveal(string path) { var p = new ProcessStartInfo("explorer.exe") { UseShellExecute = true }; p.ArgumentList.Add("/select," + path); Process.Start(p); }
    public static void OpenFolder(string path) { Directory.CreateDirectory(path); Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
    public static void Log(Exception ex) { try { Directory.CreateDirectory(DataFolder); File.AppendAllText(Path.Combine(DataFolder, "riff.log"), $"{DateTime.Now:u} {ex.GetType().Name}: {ex.Message}\n"); } catch (IOException) { } }
    public static bool LaunchAtLogin
    {
        get { using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); return key?.GetValue("Riff") is string; }
        set { using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); if (value) key.SetValue("Riff", $"\"{Environment.ProcessPath}\""); else key.DeleteValue("Riff", false); }
    }
    public static string KeyRead()
    {
        if (!CredRead("Riff.AI", 1, 0, out var ptr)) { var error = Marshal.GetLastWin32Error(); if (error == 1168) return ""; throw new System.ComponentModel.Win32Exception(error); }
        try { var c = Marshal.PtrToStructure<Credential>(ptr); return Marshal.PtrToStringUni(c.Blob, (int)c.Size / 2) ?? ""; } finally { CredFree(ptr); }
    }
    public static void KeyWrite(string value)
    {
        if (value.Length == 0) { if (!CredDelete("Riff.AI", 1, 0) && Marshal.GetLastWin32Error() != 1168) throw new System.ComponentModel.Win32Exception(); return; }
        var bytes = Encoding.Unicode.GetBytes(value); if (bytes.Length > 2560) throw new ArgumentException("The API key is too long for Credential Manager.");
        var ptr = Marshal.AllocHGlobal(bytes.Length); try { Marshal.Copy(bytes, 0, ptr, bytes.Length); var c = new Credential { Type = 1, Target = "Riff.AI", User = "Riff", Persist = 2, Size = (uint)bytes.Length, Blob = ptr }; if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(); } finally { Marshal.FreeHGlobal(ptr); }
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
