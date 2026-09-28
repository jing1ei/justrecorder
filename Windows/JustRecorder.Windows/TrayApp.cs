using JustRecorder.Core;
using Microsoft.Win32;
namespace JustRecorder.Windows;

internal sealed class TrayApp : ApplicationContext
{
    readonly SynchronizationContext ui;
    bool disposed;
    readonly NotifyIcon tray; readonly ContextMenuStrip menu = new(); readonly HotKey hotkey = new(); readonly Recorder recorder;
    readonly ToolStripMenuItem primary = new(), status = new() { Enabled = false }, reveal = new("Reveal last recording");
    readonly Icon normalIcon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application;
    readonly System.Windows.Forms.Timer clock = new() { Interval = 500 }; Settings settings; SettingsForm? window; bool quitting;
    public TrayApp()
    {
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        ui = SynchronizationContext.Current!;
        var firstLaunch = !File.Exists(Platform.SettingsPath);
        string? warning = null; try { settings = Settings.Load(Platform.SettingsPath); } catch (Exception ex) { settings = new(); warning = "Settings could not be read. Defaults are in use; the original settings file has been left untouched. " + ex.Message; }
        recorder = new(settings); recorder.Changed += Refresh; recorder.Notice += Notice;
        primary.Click += async (_, _) => await recorder.Toggle(); reveal.Click += (_, _) => { if (recorder.LastSaved is string file && File.Exists(file)) Platform.Reveal(file); else Platform.OpenFolder(settings.SaveFolder); };
        menu.Items.AddRange([primary, status, new ToolStripSeparator(), reveal, new ToolStripMenuItem("Open save folder", null, (_, _) => Platform.OpenFolder(settings.SaveFolder)), new ToolStripSeparator(), new ToolStripMenuItem("Settings…", null, (_, _) => ShowSettings()), new ToolStripMenuItem("Quit JustRecorder", null, async (_, _) => await Quit())]);
        menu.Opening += (_, _) => { ApplySystemAppearance(); Refresh(); }; tray = new NotifyIcon { Icon = normalIcon, Text = "JustRecorder", ContextMenuStrip = menu, Visible = true }; tray.DoubleClick += (_, _) => ShowSettings();
        SystemEvents.UserPreferenceChanged += SystemAppearanceChanged;
        hotkey.Pressed += async () => await recorder.Toggle(); if (!hotkey.Register(settings.HotKey, settings.Modifiers)) warning = "The recording shortcut is already in use. Choose another in Settings.";
        clock.Tick += (_, _) => Refresh(); clock.Start(); recorder.Initialize(); Refresh(); if (warning != null) Notice(warning);
        if (firstLaunch) {
            MessageBox.Show("JustRecorder is in the notification area beside the clock (or under the hidden-icons arrow).\n\nPlay audio, press " + Shortcut(settings) + " to record, then press it again to save.\n\nRecordings go to:\n" + settings.SaveFolder + "\n\nRight-click the JustRecorder icon for recording actions. Double-click it for Settings.", "Ready to record with JustRecorder", MessageBoxButtons.OK, MessageBoxIcon.Information);
            ShowSettings();
        }
    }
    void SystemAppearanceChanged(object sender, UserPreferenceChangedEventArgs e) {
        ui.Post(_ => { if (!disposed) ApplySystemAppearance(); }, null);
    }
    void ApplySystemAppearance() {
        Application.SetColorMode(SystemColorMode.System);
        menu.Invalidate(true);
        if (window is { IsDisposed: false }) window.Invalidate(true);
    }
    void Refresh()
    {
        primary.Text = recorder.Busy ? "Saving…" : recorder.Recording ? "Stop and save" : "Start recording    " + Shortcut(settings); primary.Enabled = !recorder.Busy;
        status.Text = recorder.Status.Length > 80 ? recorder.Status[..77] + "…" : recorder.Status; status.ToolTipText = recorder.Status; reveal.Enabled = recorder.LastSaved != null;
        tray.Icon = recorder.Recording ? SystemIcons.Information : recorder.Attention ? SystemIcons.Warning : normalIcon;
        var text = recorder.Recording && settings.Timer ? $"JustRecorder — recording {Naming.Duration(recorder.Seconds)}" : "JustRecorder — " + recorder.Status; tray.Text = text.Length > 63 ? text[..60] + "…" : text;
    }
    public static string Shortcut(Settings s) => string.Join("+", new[] { (s.Modifiers & 2) != 0 ? "Ctrl" : null, (s.Modifiers & 1) != 0 ? "Alt" : null, (s.Modifiers & 4) != 0 ? "Shift" : null, (s.Modifiers & 8) != 0 ? "Win" : null, ((Keys)s.HotKey).ToString() }.Where(x => x != null));
    void Notice(string text) { if (quitting) return; tray.ShowBalloonTip(5000, "JustRecorder", text, ToolTipIcon.Info); }
    void ShowSettings() { if (window is { IsDisposed: false }) { window.Activate(); return; } window = new SettingsForm(settings, Save, hotkey); window.Show(); }
    void Save(Settings next, bool login, string key, bool keyChanged)
    {
        // Fail before replacing working preferences if Windows refuses the shortcut.
        if (!hotkey.Register(next.HotKey, next.Modifiers)) { hotkey.Register(settings.HotKey, settings.Modifiers); throw new InvalidOperationException("Windows refused this shortcut. Choose a different combination."); }
        try { if (keyChanged) Platform.KeyWrite(key); Platform.LaunchAtLogin = login; next.Save(Platform.SettingsPath); settings = next; recorder.Configure(next); Refresh(); }
        catch { hotkey.Register(settings.HotKey, settings.Modifiers); throw; }
    }
    async Task Quit() { if (quitting) return; if (window is { IsDisposed: false } && !window.TrySave()) return; quitting = true; hotkey.Enabled = false; await recorder.Close(); window?.CloseAfterSave(); tray.Visible = false; ExitThread(); }
    protected override void Dispose(bool disposing) { if (disposing) { disposed = true; SystemEvents.UserPreferenceChanged -= SystemAppearanceChanged; clock.Dispose(); tray.Dispose(); normalIcon.Dispose(); menu.Dispose(); hotkey.Dispose(); recorder.Dispose(); } base.Dispose(disposing); }
}
