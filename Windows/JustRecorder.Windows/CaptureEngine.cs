using System.Threading.Channels;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using JustRecorder.Core;
namespace JustRecorder.Windows;

internal sealed record CaptureResult(string Path, double Seconds, bool Silent);
internal sealed class CaptureEngine : IDisposable
{
    readonly object gate = new(); MMDevice? device; WasapiLoopbackCapture? capture; WasapiOut? keepAlive;
    FloatRing? ring; WriteSession? session; int rate = 48000; bool disposing; bool configuredPreRoll; int configuredSeconds;
    private Guid generation = Guid.NewGuid();
    public Guid Generation { get { lock (gate) return generation; } private set { lock (gate) generation = value; } }
    public event Action<string, Guid>? Failed;
    public bool Armed => capture != null;
    public string DeviceName => device?.FriendlyName ?? "Default Windows output";
    public double Seconds { get { lock (gate) return session?.Seconds ?? 0; } }
    public bool DeviceChanged
    {
        get { if (device == null) return false; using var devices = new MMDeviceEnumerator(); using var current = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia); return current.ID != device.ID; }
    }
    public void Arm(Settings settings)
    {
        if (capture != null)
        {
            if (rate == settings.SampleRate && configuredPreRoll == settings.PreRoll && configuredSeconds == settings.PreRollSeconds) return;
            lock (gate) { if (session != null) return; }
            Disarm();
        }
        rate = settings.SampleRate; configuredPreRoll = settings.PreRoll; configuredSeconds = settings.PreRollSeconds;
        try
        {
            using var devices = new MMDeviceEnumerator(); device = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            capture = new WasapiLoopbackCapture(device) { WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(rate, 2) };
            capture.DataAvailable += Data;
            var owned = capture;
            capture.RecordingStopped += (_, e) => { if (!disposing && ReferenceEquals(capture, owned)) Failed?.Invoke(e.Exception?.Message ?? "The audio capture stream stopped. Try again.", Generation); };
            ring = settings.PreRoll ? new FloatRing(rate * 2 * settings.PreRollSeconds) : null;
            // Keep the Windows audio engine delivering silent packets when playback stops.
            keepAlive = new WasapiOut(device, AudioClientShareMode.Shared, false, 100);
            keepAlive.Init(new SilenceProvider(WaveFormat.CreateIeeeFloatWaveFormat(rate, 2)));
            keepAlive.Play(); capture.StartRecording();
        }
        catch { Disarm(); throw; }
    }
    public void Start(Settings settings, string path)
    {
        Arm(settings);
        lock (gate) {
            if (session != null) throw new InvalidOperationException("A recording is already active.");
            Generation = Guid.NewGuid();
            var generation = Generation;
            session = new WriteSession(path, rate, ex => Failed?.Invoke(ex.Message, generation));
            var previous = ring?.Drain();
            if (previous?.Length > 0) session.Push(previous);
        }
    }
    public Task<CaptureResult> Stop()
    {
        lock (gate) { var stopped = session ?? throw new InvalidOperationException("No recording is active."); session = null; return stopped.Finish(); }
    }
    void Data(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded % 8 != 0) return;
        var floats = new float[e.BytesRecorded / 4]; Buffer.BlockCopy(e.Buffer, 0, floats, 0, e.BytesRecorded);
        lock (gate) { if (session != null) session.Push(floats); else ring?.Append(floats); }
    }
    public void Disarm()
    {
        disposing = true;
        Generation = Guid.NewGuid();
        try { capture?.StopRecording(); capture?.Dispose(); keepAlive?.Stop(); keepAlive?.Dispose(); device?.Dispose(); }
        finally { capture = null; keepAlive = null; device = null; lock (gate) ring = null; disposing = false; }
    }
    public void Dispose() => Disarm();
    internal sealed class WriteSession
    {
        readonly Channel<float[]> buffers = Channel.CreateBounded<float[]>(new BoundedChannelOptions(128) { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
        readonly Task<CaptureResult> writing; long samples; bool failed; readonly int rate; readonly Action<Exception> error;
        public double Seconds => Interlocked.Read(ref samples) / (2.0 * rate);
        public WriteSession(string path, int rate, Action<Exception> error)
        {
            this.rate = rate; this.error = error; writing = Task.Run(async () =>
            {
                var silent = true;
                using (var writer = new WaveFileWriter(path, WaveFormat.CreateIeeeFloatWaveFormat(rate, 2)))
                {
                    await foreach (var block in buffers.Reader.ReadAllAsync())
                    {
                        writer.WriteSamples(block, 0, block.Length); Interlocked.Add(ref samples, block.Length);
                        if (silent && block.Any(x => Math.Abs(x) > 0.0005f)) silent = false;
                        writer.Flush(); // Refresh WAV lengths so a crash leaves a recoverable file.
                    }
                }
                return new CaptureResult(path, Seconds, silent);
            });
            _ = writing.ContinueWith(t => { if (t.IsFaulted) this.error(t.Exception!.GetBaseException()); }, TaskScheduler.Default);
        }
        public void Push(float[] data) { if (failed) return; if (!buffers.Writer.TryWrite(data)) { failed = true; error(new IOException("The disk cannot keep up. Recording stopped; captured audio will be saved.")); } }
        public Task<CaptureResult> Finish() { buffers.Writer.TryComplete(); return writing; }
    }
}
