using System.Text.Json;
namespace JustRecorder.Core;

public enum AudioKind { Aac, Mp3, Alac, Wav24, Wav16 }
public sealed record Settings
{
    public string SaveFolder { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), "JustRecorder Captures");
    public AudioKind Format { get; set; } = AudioKind.Aac;
    public int Bitrate { get; set; } = 256;
    public int Mp3Bitrate { get; set; } = 320;
    public int SampleRate { get; set; } = 48000;
    public int AutoStopMinutes { get; set; } = 10;
    public bool PreRoll { get; set; }
    public int PreRollSeconds { get; set; } = 15;
    public uint HotKey { get; set; } = 0x52;
    public uint Modifiers { get; set; } = 3; // Alt + Control
    public bool Sounds { get; set; } = true;
    public bool Timer { get; set; } = true;
    public bool Reveal { get; set; }
    public bool PlayerMetadata { get; set; } = true;
    public bool AiEnabled { get; set; }
    public string BaseUrl { get; set; } = "https://api.openai.com/v1";
    public string Model { get; set; } = "gpt-4o-mini";
    public string Prompt { get; set; } = "Return only a short track title in its original language. Remove player, site, and marketing text. No artist prefix, duration, extension, explanation, or invented details. If unknown, reply Unknown Snippet.";
    public int AiTimeout { get; set; } = 8;
    public string Template { get; set; } = DefaultTemplate;
    public const string DefaultTemplate = "[{artist} - ]{title} {duration}";
    public void Validate()
    {
        if (!Enum.IsDefined(Format)) Format = AudioKind.Aac;
        if (!new[] { 128, 160, 192, 256, 320 }.Contains(Bitrate)) Bitrate = 256;
        if (!new[] { 128, 160, 192, 256, 320 }.Contains(Mp3Bitrate)) Mp3Bitrate = 320;
        if (SampleRate is not (44100 or 48000)) SampleRate = 48000;
        AutoStopMinutes = Math.Clamp(AutoStopMinutes, 0, 30);
        PreRollSeconds = Math.Clamp(PreRollSeconds, 5, 30);
        AiTimeout = Math.Clamp(AiTimeout, 2, 120);
        if (HotKey is < 1 or > 254) HotKey = 0x52;
        Modifiers &= 15; if (Modifiers == 0) Modifiers = 3;
        if (string.IsNullOrWhiteSpace(SaveFolder)) SaveFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), "JustRecorder Captures");
        Template ??= DefaultTemplate; BaseUrl ??= ""; Model ??= ""; Prompt ??= "";
    }
    public static Settings Load(string path)
    {
        if (!File.Exists(path)) return new();
        var result = JsonSerializer.Deserialize<Settings>(File.ReadAllText(path)) ?? throw new InvalidDataException("Settings are empty.");
        result.Validate(); return result;
    }
    public void Save(string path)
    {
        Validate(); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp"; File.WriteAllText(temp, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temp, path, true);
    }
}
