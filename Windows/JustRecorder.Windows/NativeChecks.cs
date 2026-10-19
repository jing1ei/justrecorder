using NAudio.Wave;
using JustRecorder.Core;
namespace JustRecorder.Windows;
/// Synthetic Windows encoder tests; no capture device, credentials, or user settings.
internal static class NativeChecks
{
    public static async Task<int> Run()
    {
        var folder = Path.Combine(Path.GetTempPath(), "justrecorder-native-test-" + Guid.NewGuid()); Directory.CreateDirectory(folder);
        try
        {
            foreach (var kind in new[] { AudioKind.Aac, AudioKind.Mp3, AudioKind.Wav16, AudioKind.Wav24 })
            {
                var input = Path.Combine(folder, kind + ".wav"); Exception? failure = null;
                var session = new CaptureEngine.WriteSession(input, 48000, ex => failure = ex);
                var samples = new float[96000]; for (int n = 0; n < 48000; n++) samples[2 * n] = samples[2 * n + 1] = (float)(0.1 * Math.Sin(n * 2 * Math.PI * 440 / 48000));
                session.Push(samples); var captured = await session.Finish();
                if (failure != null || captured.Silent || Math.Abs(captured.Seconds - 1) > 0.001) throw new InvalidDataException("Synthetic writer failed.");
                var result = await Encoder.Encode(captured, new Settings { Format = kind }, CancellationToken.None);
                if (result.warning != null) throw new InvalidDataException(kind + ": " + result.warning);
                using var reader = new MediaFoundationReader(result.path);
                if (reader.TotalTime.TotalSeconds < 0.9 || reader.TotalTime.TotalSeconds > 1.2) throw new InvalidDataException(kind + " duration mismatch.");
                var data = new float[4096]; var count = reader.ToSampleProvider().Read(data, 0, data.Length); if (count == 0 || !data.Take(count).Any(x => Math.Abs(x) > 0.01)) throw new InvalidDataException(kind + " output is silent.");
                if (!File.Exists(input)) throw new IOException("Encoder removed the recoverable source too early.");
            }
            File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "native-checks.txt"), "PASS: synthetic capture writer and readable AAC, MP3, WAV16, WAV24 output. No live device tested.");
            return 0;
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "native-checks.txt"), "FAIL: " + ex); return 1; }
        finally { Directory.Delete(folder, true); }
    }
}
