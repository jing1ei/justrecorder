using System.Net.Http.Json;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace JustRecorder.Core;

public static class AiNamer
{
    public static Uri Endpoint(string input)
    {
        if (!Uri.TryCreate(input.Trim(), UriKind.Absolute, out var url) || url.Scheme is not ("http" or "https") || url.UserInfo.Length > 0) throw new ArgumentException("Enter an HTTP or HTTPS base URL without embedded credentials.");
        if (url.Scheme == "http" && !url.IsLoopback) throw new ArgumentException("Remote AI endpoints must use HTTPS. HTTP is available for a local model.");
        var b = new UriBuilder(url) { Fragment = "" }; var path = b.Path.TrimEnd('/');
        if (!path.EndsWith("/chat/completions", StringComparison.Ordinal)) path += (path.Length == 0 ? "/v1" : "") + "/chat/completions";
        b.Path = path; return b.Uri;
    }
    public static async Task<string> Suggest(Settings settings, string key, Source source, double seconds, CancellationToken cancel)
    {
        if (string.IsNullOrWhiteSpace(settings.Model)) throw new ArgumentException("Enter a model name.");
        using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(settings.AiTimeout) };
        if (key.Length > 0) client.DefaultRequestHeaders.Authorization = new("Bearer", key.Trim());
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var body = new Dictionary<string, object> { ["model"] = settings.Model, ["stream"] = false, ["messages"] = new[] { new { role = "system", content = settings.Prompt }, new { role = "user", content = $"Window title: {source.Raw}\nTrack: {source.Track}\nArtist: {source.Artist}\nApp: {source.App}\nLength: {Naming.Duration(seconds)}" } }, [attempt == 0 ? "max_tokens" : "max_completion_tokens"] = 96 };
            using var response = await client.PostAsJsonAsync(Endpoint(settings.BaseUrl), body, cancel);
            var text = await response.Content.ReadAsStringAsync(cancel);
            if (attempt == 0 && (int)response.StatusCode == 400 && text.Contains("max_tokens", StringComparison.Ordinal)) continue;
            if (!response.IsSuccessStatusCode) throw new HttpRequestException($"AI endpoint returned HTTP {(int)response.StatusCode}.");
            using var json = JsonDocument.Parse(text);
            var reply = json.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content");
            var title = reply.ValueKind == JsonValueKind.String ? reply.GetString() ?? "" : string.Join(" ", reply.EnumerateArray().Select(x => x.TryGetProperty("text", out var t) ? t.GetString() : ""));
            title = title.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim(' ', '`', '"', '\'') ?? "";
            title = Regex.Replace(title, @"\.(m4a|mp3|wav|aac)$", "", RegexOptions.IgnoreCase);
            if (source.Artist.Length > 0) title = Regex.Replace(title, "^" + Regex.Escape(source.Artist) + @"\s*[-–—:|]\s*", "", RegexOptions.IgnoreCase);
            title = Regex.Replace(title, @"\s+" + Regex.Escape(Naming.Duration(seconds)) + "$", "");
            if (title.Length == 0 || title.Length > 110 || Regex.IsMatch(title, @"^(Unknown Snippet|I'm sorry|I cannot|As an AI)", RegexOptions.IgnoreCase)) throw new InvalidDataException("The model did not return a usable title.");
            var safeTitle = Naming.Safe(title, 70);
            if (safeTitle.Length == 0) throw new InvalidDataException("The model did not return a usable title.");
            return safeTitle;
        }
        throw new HttpRequestException("The endpoint rejected the naming request.");
    }
}
