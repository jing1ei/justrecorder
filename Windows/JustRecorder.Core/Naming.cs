using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
namespace JustRecorder.Core;

public sealed record Source(string App = "", string Raw = "", string Artist = "", string Track = "")
{
    public string Title => Track.Length > 0 ? Track : Naming.Clean(Raw).Length > 0 ? Naming.Clean(Raw) : App.Length > 0 ? App : "Snippet";
}
public static class Naming
{
    public static string Duration(double seconds) { var n = (int)Math.Clamp(Math.Round(seconds), 0, int.MaxValue); return n >= 3600 ? $"{n / 3600}h{n % 3600 / 60}m{n % 60}s" : n >= 60 ? $"{n / 60}m{n % 60}s" : $"{n}s"; }
    public static string Clean(string raw)
    {
        var text = Regex.Replace(raw.Trim(), @"^(?:\(\d+\)|\[\d+\]|[▶►🔊🎵🎶]+)\s*", "");
        for (var i = 0; i < 4; i++) text = Regex.Replace(text, @"\s*[-–—|·]\s*(YouTube Music|YouTube|Spotify|Apple Music|Google Chrome|Microsoft Edge|Mozilla Firefox|Firefox|Brave|Bilibili|SoundCloud|\u7F51\u6613\u4E91\u97F3\u4E50|QQ\u97F3\u4E50)\s*$", "", RegexOptions.IgnoreCase);
        return text.Trim();
    }
    public static string Safe(string value, int limit = 150)
    {
        var s = Regex.Replace(value, @"[\x00-\x1F/\\:*?""<>|]", "-");
        s = Regex.Replace(s, @"\s+", " ").Trim().TrimStart('.').TrimEnd(' ', '.');
        var output = new StringBuilder();
        foreach (var rune in s.EnumerateRunes()) { if (output.Length + rune.Utf16SequenceLength > Math.Max(0, limit)) break; output.Append(rune); }
        s = output.ToString().TrimEnd(' ', '.');
        if (Regex.IsMatch(s.Split('.')[0], @"^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$", RegexOptions.IgnoreCase)) s = "_" + s;
        return s;
    }
    public static string Render(string template, Source source, double seconds, AudioKind format, DateTime time, string? ai = null, string? formatLabel = null)
    {
        var values = new Dictionary<string, string>
        {
            ["title"] = Safe(ai ?? source.Title, 70),
            ["raw_title"] = Safe(source.Raw, 70),
            ["artist"] = Safe(source.Artist, 40),
            ["track"] = Safe(source.Track, 70),
            ["app"] = Safe(source.App, 40),
            ["duration"] = Duration(seconds),
            ["seconds"] = Math.Round(seconds).ToString(CultureInfo.InvariantCulture),
            ["format"] = formatLabel ?? Label(format),
            ["date"] = time.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            ["time"] = time.ToString("HH-mm-ss", CultureInfo.InvariantCulture),
            ["datetime"] = time.ToString("yyyy-MM-dd HH-mm-ss", CultureInfo.InvariantCulture)
        };
        string Expand(string text) => Regex.Replace(text, @"\{([a-zA-Z_]+)\}", m => values.GetValueOrDefault(m.Groups[1].Value, m.Value));
        var output = new StringBuilder();
        for (var index = 0; index < template.Length; index++) {
            if (template[index] == ']') continue;
            if (template[index] != '[') { output.Append(template[index]); continue; }
            var end = template.IndexOf(']', index + 1);
            if (end < 0) end = template.Length;
            var group = template[(index + 1)..end];
            if (!Regex.Matches(group, @"\{([a-zA-Z_]+)\}").Any(t => values.TryGetValue(t.Groups[1].Value, out var value) && value.Length == 0))
                output.Append(group);
            index = end;
        }
        var name = Safe(Expand(output.ToString()).Trim(' ', '-', '–', '—', '|', '·', ':', '_'));
        return name.Length > 0 ? name : Safe($"{source.Title} {Duration(seconds)}");
    }
    public static string Label(AudioKind k) => k switch { AudioKind.Aac => "AAC", AudioKind.Mp3 => "MP3", AudioKind.Alac => "ALAC", AudioKind.Wav24 => "WAV 24", _ => "WAV 16" };
    public static string Extension(AudioKind k) => k switch { AudioKind.Aac or AudioKind.Alac => "m4a", AudioKind.Mp3 => "mp3", _ => "wav" };
    public static string MoveUnique(string source, string name)
    {
        var folder = Path.GetDirectoryName(source)!; var ext = Path.GetExtension(source);
        for (var n = 1; n < 10000; n++)
        {
            var target = Path.Combine(folder, $"{Safe(name)}{(n == 1 ? "" : " " + n)}{ext}");
            try { File.Move(source, target); return target; } catch (IOException) when (File.Exists(target)) { }
        }
        var fallback = Path.Combine(folder, $"Snippet {Guid.NewGuid():N}{ext}"); File.Move(source, fallback); return fallback;
    }
}
