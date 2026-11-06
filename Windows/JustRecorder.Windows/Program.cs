namespace JustRecorder.Windows;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        if (args.Contains("--self-test")) { Environment.ExitCode = NativeChecks.Run().GetAwaiter().GetResult(); return; }
        using var instance = new Mutex(true, @"Local\JustRecorder.Recorder", out var created);
        if (!created) { MessageBox.Show("JustRecorder is already running. Open its icon in the notification area.", "JustRecorder"); return; }
        Platform.MigrateFromLegacyBuild();
        ApplicationConfiguration.Initialize();
        Application.SetColorMode(SystemColorMode.System);
        Application.ThreadException += (_, e) => { Platform.Log(e.Exception); MessageBox.Show(e.Exception.Message, "JustRecorder", MessageBoxButtons.OK, MessageBoxIcon.Warning); };
        using var app = new TrayApp();
        Application.Run(app);
    }
}
