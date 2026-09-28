using System.Diagnostics;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using JustRecorder.Core;
namespace JustRecorder.Windows;

internal static class Encoder
{
    public static string? Ffmpeg => new[] { Path.Combine(AppContext.BaseDirectory, "ffmpeg.exe") }.Concat((Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator).Where(x => x.Length > 0).Select(x => Path.Combine(x, "ffmpeg.exe"))).FirstOrDefault(File.Exists);
    public static async Task<(string path, AudioKind format, string? warning)> Encode(CaptureResult input, Settings settings, CancellationToken cancel)
    {
        var output = Path.ChangeExtension(input.Path, settings.Format is AudioKind.Aac or AudioKind.Alac ? "encoded.m4a" : settings.Format == AudioKind.Mp3 ? "encoded.mp3" : "encoded.wav");
        try
        {
            if (settings.Format == AudioKind.Alac)
            {
                var ffmpeg = Ffmpeg ?? throw new InvalidOperationException("Apple Lossless requires ffmpeg.exe beside JustRecorder or on PATH.");
                using var process = new Process { StartInfo = new ProcessStartInfo(ffmpeg) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true } };
                foreach (var arg in new[] { "-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", input.Path, "-c:a", "alac", output }) process.StartInfo.ArgumentList.Add(arg);
                if (!process.Start()) throw new IOException("Could not start FFmpeg.");
                var stderr = process.StandardError.ReadToEndAsync(cancel); var stdout = process.StandardOutput.ReadToEndAsync(cancel);
                using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel); limit.CancelAfter(TimeSpan.FromMinutes(2));
                try { await process.WaitForExitAsync(limit.Token); } catch { if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(CancellationToken.None); } throw; }
                await Task.WhenAll(stderr, stdout);
                if (process.ExitCode != 0) throw new IOException("FFmpeg could not encode Apple Lossless.");
            }
            else await Task.Run(() =>
            {
                cancel.ThrowIfCancellationRequested(); using var reader = new WaveFileReader(input.Path);
                var samples = reader.ToSampleProvider();
                switch (settings.Format)
                {
                    case AudioKind.Aac:
                        using (var stream = File.Create(output)) MediaFoundationEncoder.EncodeToAac(new SampleToWaveProvider16(samples), stream, settings.Bitrate * 1000);
                        break;
                    case AudioKind.Mp3: MediaFoundationEncoder.EncodeToMp3(new SampleToWaveProvider16(samples), output, settings.Mp3Bitrate * 1000); break;
                    case AudioKind.Wav16: WaveFileWriter.CreateWaveFile16(output, samples); break;
                    case AudioKind.Wav24:
                        using (var writer = new WaveFileWriter(output, new WaveFormat(settings.SampleRate, 24, 2)))
                        {
                            var buffer = new float[8192]; int count; while ((count = samples.Read(buffer, 0, buffer.Length)) > 0) { cancel.ThrowIfCancellationRequested(); writer.WriteSamples(buffer, 0, count); }
                        }
                        break;
                }
            }, cancel);
            cancel.ThrowIfCancellationRequested();
            if (!File.Exists(output) || new FileInfo(output).Length < 44) throw new IOException("The encoder produced an empty file.");
            return (output, settings.Format, null);
        }
        catch (Exception ex)
        {
            try { File.Delete(output); } catch (IOException) { }
            return (input.Path, AudioKind.Wav24, $"Encoding failed; the original float WAV was preserved. {ex.Message}");
        }
    }
}
