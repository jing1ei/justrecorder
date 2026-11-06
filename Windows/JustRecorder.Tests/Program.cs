using JustRecorder.Core;
var failures = 0;
void Test(string name, Action action) { try { action(); Console.WriteLine("PASS " + name); } catch (Exception ex) { failures++; Console.WriteLine("FAIL " + name + ": " + ex.Message); } }
void Equal<T>(T a, T b) { if (!Equals(a, b)) throw new Exception($"Expected {b}, got {a}"); }
Test("optional artist", () => Equal(Naming.Render(Settings.DefaultTemplate, new Source(Track: "Song"), 63, AudioKind.Aac, DateTime.Now), "Song 1m3s"));
Test("unfinished optional group", () => Equal(Naming.Render("[{artist} - ]{title}[ {artist}", new Source(Track: "Song"), 63, AudioKind.Aac, DateTime.Now), "Song"));
Test("literal token in title", () => Equal(Naming.Render("[{title}]", new Source(Track: "{artist}"), 1, AudioKind.Aac, DateTime.Now), "{artist}"));
Test("Windows device names", () => { Equal(Naming.Safe("CON"), "_CON"); Equal(Naming.Safe("LPT1.txt"), "_LPT1.txt"); Equal(Naming.Safe("song. "), "song"); });
Test("Unicode boundaries", () => { var s = Naming.Safe(new string('a', 149) + "🎶"); Equal(s.Length, 149); });
Test("window chrome", () => Equal(Naming.Clean("(3) Example Track - YouTube — Google Chrome"), "Example Track"));
Test("query endpoint", () => Equal(AiNamer.Endpoint("https://example.com/v1?api-version=1").AbsoluteUri, "https://example.com/v1/chat/completions?api-version=1"));
Test("local HTTP", () => Equal(AiNamer.Endpoint("http://127.0.0.1:11434").AbsolutePath, "/v1/chat/completions"));
Test("remote credentials transport", () => { try { AiNamer.Endpoint("http://example.com"); throw new Exception("accepted insecure remote"); } catch (ArgumentException) { } });
Test("ring keeps newest stereo frames", () => { var r = new FloatRing(6); r.Append([1, 2, 3, 4]); r.Append([5, 6, 7, 8]); Equal(string.Join(',', r.Drain()), "3,4,5,6,7,8"); Equal(r.Drain().Length, 0); });
Test("oversize ring input replaces old frames", () =>
{
    var ring = new FloatRing(4);
    ring.Append([1, 2]);
    ring.Append([3, 4, 5, 6, 7, 8]);
    ring.Append([9, 10]);
    Equal(string.Join(',', ring.Drain()), "7,8,9,10");
});
Test("preference validation", () => { var s = new Settings { AutoStopMinutes = int.MaxValue, PreRollSeconds = -1, Modifiers = 0, SampleRate = 1 }; s.Validate(); Equal(s.AutoStopMinutes, 30); Equal(s.PreRollSeconds, 5); Equal(s.Modifiers, 3u); Equal(s.SampleRate, 48000); });
Test("atomic settings and collision safe naming", () => { var dir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString()); Directory.CreateDirectory(dir); try { var p = Path.Combine(dir, "settings.json"); new Settings { Template = "{app}" }.Save(p); Equal(Settings.Load(p).Template, "{app}"); File.WriteAllText(Path.Combine(dir, "Song.wav"), "old"); var temp = Path.Combine(dir, "temp.wav"); File.WriteAllText(temp, "new"); var moved = Naming.MoveUnique(temp, "Song"); Equal(Path.GetFileName(moved), "Song 2.wav"); Equal(File.ReadAllText(Path.Combine(dir, "Song.wav")), "old"); } finally { Directory.Delete(dir, true); } });
Console.WriteLine($"{failures} failure(s)"); return failures == 0 ? 0 : 1;
