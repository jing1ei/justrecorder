using System.Diagnostics;
using JustRecorder.Core;
using NAudio.Wave;
namespace JustRecorder.Windows;

internal sealed class Recorder : IDisposable
{
    readonly CaptureEngine engine = new(); readonly SynchronizationContext ui; readonly System.Windows.Forms.Timer timer = new() { Interval = 250 };
    Settings settings; Settings? active; Task<Source>? source; CancellationTokenSource? detection;
    readonly CancellationTokenSource shutdown = new(); readonly HashSet<Task> finalizing = [];
    Stopwatch? clock; Task? stopping; bool closing; DateTime started; long lastDeviceCheck;
    public string Status { get; private set; } = "Ready to record system audio.";
    public string? LastSaved { get; private set; }
    public bool Recording { get; private set; }
    public bool Busy { get; private set; }
    public bool Attention { get; private set; }
    public double Seconds => engine.Seconds;
    public event Action? Changed;
    public event Action<string>? Notice;
    public Recorder(Settings settings)
    {
        this.settings = settings; ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        engine.Failed += (text, generation) => ui.Post(state =>
        {
            if (closing || generation != engine.Generation) return;
            if (Recording) _ = Stop(resetCapture: true);
            else engine.Disarm();
            Set(text, true);
            Notice?.Invoke(text);
        }, null);
        timer.Tick += async (_, _) =>
        {
            if (Recording)
            {
                Changed?.Invoke(); if (active!.AutoStopMinutes > 0 && (clock!.Elapsed.TotalMinutes >= active.AutoStopMinutes || Seconds >= active.AutoStopMinutes * 60)) await Stop();
            }
            if (closing || Busy || !engine.Armed || Stopwatch.GetElapsedTime(lastDeviceCheck) < TimeSpan.FromSeconds(2)) return;
            lastDeviceCheck = Stopwatch.GetTimestamp();
            try
            {
                if (!engine.DeviceChanged) return;
                if (Recording) await Stop(resetCapture: true);
                else { engine.Disarm(); ApplyCaptureSettings(); }
            }
            catch (Exception ex)
            {
                if (Recording) await Stop(resetCapture: true);
                else engine.Disarm();
                if (!closing) Set("Could not access the default Windows output: " + ex.Message, true);
            }
        };
        timer.Start();
    }
    public void Configure(Settings next)
    {
        settings = next;
        if (!Recording && !Busy) ApplyCaptureSettings();
    }
    void ApplyCaptureSettings()
    {
        if (closing || !settings.PreRoll)
        {
            if (engine.Armed) engine.Disarm();
            return;
        }
        try { engine.Arm(settings); }
        catch (Exception ex) { Set(ex.Message, true); }
    }
    public void Initialize() { Configure(settings); _ = Recover(settings.SaveFolder); }
    void Set(string text, bool warning = false) { Status = text; Attention = warning; Changed?.Invoke(); }
    public async Task Toggle() { if (Busy || closing) return; if (Recording) await Stop(); else Start(); }
    void Start()
    {
        try
        {
            Directory.CreateDirectory(settings.SaveFolder); active = settings with { }; started = DateTime.Now;
            var activePath = Path.Combine(settings.SaveFolder, $".justrecorder-{Environment.ProcessId}-{Guid.NewGuid():N}.wav");
            detection?.Dispose(); detection = new CancellationTokenSource(TimeSpan.FromSeconds(2)); source = Detect(detection.Token, settings.PlayerMetadata);
            // Endpoint loopback includes JustRecorder: start cues are omitted to keep clips clean.
            engine.Start(active, activePath); Recording = true; clock = Stopwatch.StartNew(); Set("Recording…");
        }
        catch (Exception ex) { detection?.Cancel(); engine.Disarm(); Set("Could not start: " + ex.Message, true); Notice?.Invoke(Status); }
    }
    static async Task<Source> Detect(CancellationToken ct, bool metadata) { try { return await SourceDetector.Detect(metadata, ct); } catch { return new Source(); } }
    Task Stop(bool resetCapture = false)
    {
        if (stopping is not null) return stopping;
        if (!Recording) return Task.CompletedTask;
        Recording = false; Busy = true; clock?.Stop(); Set("Saving…");
        var captured = engine.Stop(); var config = active!; var title = source; var at = started;
        if (resetCapture || closing || !settings.PreRoll) engine.Disarm();
        var operation = FinishStop(captured, config, title, at);
        stopping = operation.IsCompleted ? null : operation; return operation;
    }
    async Task FinishStop(Task<CaptureResult> capture, Settings config, Task<Source>? title, DateTime at)
    {
        try
        {
            var result = await capture;
            if (result.Seconds < 0.3) { File.Delete(result.Path); Set("Too short — discarded."); return; }
            Set(config.AiEnabled ? "Naming and encoding…" : "Encoding…");
            var work = Finalize(result, config, title, at); finalizing.Add(work); _ = work.ContinueWith(_ => ui.Post(_ => finalizing.Remove(work), null), TaskScheduler.Default);
            // Keep starting another capture available while naming and encoding run.
        }
        catch (Exception ex) { Set("Could not finish saving. The temporary WAV will be recovered on next launch. " + ex.Message, true); Platform.Log(ex); }
        finally
        {
            Busy = false;
            stopping = null;
            ApplyCaptureSettings();
            if (!closing && settings.Sounds && !settings.PreRoll) System.Media.SystemSounds.Asterisk.Play();
            Changed?.Invoke();
        }
    }
    async Task Finalize(CaptureResult result, Settings config, Task<Source>? detectionTask, DateTime at)
    {
        try
        {
            var info = detectionTask is null ? new Source() : await detectionTask; string? ai = null; string? namingWarning = null;
            if (config.AiEnabled && !closing) try { ai = await AiNamer.Suggest(config, Platform.KeyRead(), info, result.Seconds, shutdown.Token); } catch (Exception ex) { namingWarning = "AI naming unavailable; used the local title."; Platform.Log(ex); }
            var produced = await Encoder.Encode(result, config, shutdown.Token);
            var name = Naming.Render(config.Template, info, result.Seconds, produced.format, at, ai, produced.warning != null ? "WAV Float" : null);
            var final = Naming.MoveUnique(produced.path, name);
            if (produced.path != result.Path) try { File.Delete(result.Path); } catch (IOException ex) { Platform.Log(ex); }
            LastSaved = final;
            if (!Recording && !Busy) Set(Path.GetFileName(final) + (produced.warning != null ? " · original WAV kept" : ""), produced.warning != null);
            Changed?.Invoke();
            if (!closing) { if (config.Reveal) Platform.Reveal(final); if (produced.warning != null) Notice?.Invoke(produced.warning); else if (result.Silent) Notice?.Invoke("This recording was saved, but no sound was detected. Check the selected Windows output device."); else if (namingWarning != null) Notice?.Invoke(namingWarning); }
        }
        catch (Exception ex)
        {
            var message = "Captured audio remains in the save folder for recovery. " + ex.Message;
            if (!Recording && !Busy) Set(message, true);
            Platform.Log(ex);
            if (!closing) Notice?.Invoke(message);
        }
    }
    async Task Recover(string folder)
    {
        int recovery;
        try
        {
            recovery = await Task.Run(() =>
            {
                var recovered = 0; if (!Directory.Exists(folder)) return recovered;
                var pending = Directory.EnumerateFiles(folder, ".justrecorder-*.wav")
                    .Concat(Directory.EnumerateFiles(folder, ".riff-*.wav"))
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .Where(p => !p.EndsWith(".encoded.wav", StringComparison.OrdinalIgnoreCase));
                foreach (var path in pending)
                {
                    var parts = Path.GetFileName(path).Split('-');
                    if (parts.Length > 2 && int.TryParse(parts[1], out var pid)) try { using var process = Process.GetProcessById(pid); if (!process.HasExited) continue; } catch (ArgumentException) { }
                    try
                    {
                        double seconds; using (var wave = new WaveFileReader(path)) seconds = wave.TotalTime.TotalSeconds;
                        if (seconds < 0.3) { File.Delete(path); continue; }
                        Naming.MoveUnique(path, $"Recovered Snippet {Naming.Duration(seconds)}"); recovered++;
                        foreach (var ext in new[] { "encoded.wav", "encoded.mp3", "encoded.m4a" }) try { File.Delete(Path.ChangeExtension(path, ext)); } catch (IOException ex) { Platform.Log(ex); }
                    }
                    catch (Exception ex) { Platform.Log(ex); }
                }
                return recovered;
            });
        }
        catch (Exception ex) { Platform.Log(ex); if (!closing) Notice?.Invoke("The save folder could not be checked for interrupted recordings: " + ex.Message); return; }
        if (recovery > 0 && !closing) Notice?.Invoke($"Recovered {recovery} interrupted recording(s) in {folder}.");
    }
    public async Task Close()
    {
        closing = true; timer.Stop(); shutdown.Cancel(); detection?.Cancel();
        await Task.WhenAny(StopAndFinalize(), Task.Delay(TimeSpan.FromSeconds(3))); engine.Disarm();
    }
    async Task StopAndFinalize() { await Stop(); await Task.WhenAll(finalizing.ToArray()); }
    public void Dispose() { timer.Dispose(); engine.Dispose(); shutdown.Dispose(); detection?.Dispose(); }
}
