using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Zhibei;

public record Category(string Id, string Name, string Color, string Icon);
public record Episode(string Id, string Title, string Path, double Duration);
public record Course(string Id, string Title, string Category, string Cover, string Status,
    string Description, long Updated, List<Episode> Episodes);
public record Featured(string CourseId, string Title);

public sealed class Catalog
{
    public const int SizeLimit = 10 * 1024 * 1024;
    public List<Category> Categories { get; } = [];
    public List<Course> Courses { get; } = [];
    public List<Featured> Featured { get; } = [];
    public List<string> CategoryOrder { get; } = [];
    private Dictionary<Course, (string Initials, string Full)>? phonetics;

    public static bool ValidId(string s) => s.Length is > 0 and <= 100 && s.IsNormalized()
        && s.EnumerateRunes().All(r => Rune.IsLetterOrDigit(r) || r.Value is '_' or '-');
    public static bool ValidOrigin(string s) => s.Length <= 253 && Regex.IsMatch(s,
        @"\Ahttps://(?:\[[0-9A-Fa-f:.]{2,45}\]|[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*)(?::[0-9]{1,5})?\z")
        && Uri.TryCreate(s, UriKind.Absolute, out _);
    public static bool ValidPath(string s) => s.Length is > 0 and <= 300 && s[0] != '/'
        && !s.Contains("..") && !s.Contains("//") && !Regex.IsMatch(s, @"^[A-Za-z][A-Za-z0-9+.\-]*:")
        && !s.Any(c => c <= ' ' || c is '\u007f' or '\\' or '?' or '#');
    public static Uri MediaUri(string origin, string path)
    {
        if (!ValidOrigin(origin) || !ValidPath(path)) throw new InvalidDataException("资源地址无效");
        return new Uri(origin + "/" + string.Join("/", path.Split('/').Select(Uri.EscapeDataString)));
    }

    internal static JsonElement Field(JsonElement e, string key) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var v) ? v : default;
    internal static IEnumerable<JsonElement> Array(JsonElement e, string key) =>
        Field(e, key) is { ValueKind: JsonValueKind.Array } a ? a.EnumerateArray() : [];
    internal static string Str(JsonElement e) => e.ValueKind == JsonValueKind.String ? e.GetString()! : "";
    static string Text(JsonElement e, string key) => Str(Field(e, key));
    static bool IsTitle(string s) => !string.IsNullOrWhiteSpace(s) && s.Length <= 200;

    public static Catalog Parse(string raw)
    {
        if (Encoding.UTF8.GetByteCount(raw) > SizeLimit) throw new InvalidDataException("目录过大");
        using var json = JsonDocument.Parse(raw);
        var root = json.RootElement;
        var catalog = new Catalog();
        HashSet<string> categories = [], courses = [], episodes = [];
        bool hasSeries = false;
        foreach (var c in Array(root, "categories"))
        {
            var cid = Text(c, "id");
            var name = Text(c, "name");
            if (!ValidId(cid) || !IsTitle(name) || !categories.Add(cid)) continue;
            catalog.Categories.Add(new(cid, name, Text(c, "color"), Text(c, "icon")));
            foreach (var s in Array(c, "series"))
            {
                hasSeries = true;
                var id = Text(s, "id");
                var title = Text(s, "title");
                var cover = Text(s, "coverPath");
                var status = Text(s, "status");
                if (!ValidId(id) || !IsTitle(title) || !ValidPath(cover) ||
                    status is not ("ongoing" or "completed") || !courses.Add(id)) continue;
                List<Episode> tracks = [];
                foreach (var e in Array(s, "episodes"))
                {
                    var eid = Text(e, "id");
                    var et = Text(e, "title");
                    var path = Text(e, "audioPath");
                    if (!ValidId(eid) || !IsTitle(et) || !ValidPath(path) || !episodes.Add(eid)) continue;
                    var d = Field(e, "duration");
                    var duration = d.ValueKind == JsonValueKind.Number && d.TryGetDouble(out var sec) &&
                        sec is > 0 and <= 86400 ? Math.Round(sec, MidpointRounding.AwayFromZero) : 0;
                    tracks.Add(new(eid, et, path, duration));
                }
                var desc = Text(s, "description");
                if (desc.Length > 5000) desc = desc[..(char.IsHighSurrogate(desc[4999]) ? 4999 : 5000)];
                var u = Field(s, "updatedAt");
                var updated = u.ValueKind == JsonValueKind.Number && u.TryGetInt64(out var t) && t is > 0 and < 100000000000 ? t : 0;
                catalog.Courses.Add(new(id, title, cid, cover, status, desc, updated, tracks));
            }
        }
        if (categories.Count == 0 || hasSeries && courses.Count == 0) throw new InvalidDataException("目录格式无效");
        HashSet<string> featured = [];
        foreach (var f in Array(root, "featured"))
        {
            var id = Text(f, "seriesId");
            var title = Text(f, "title");
            if (courses.Contains(id) && IsTitle(title) && featured.Add(id)) catalog.Featured.Add(new(id, title));
            if (catalog.Featured.Count == 50) break;
        }
        catalog.CategoryOrder.AddRange(Array(root, "categoryOrder").Select(Str).Where(categories.Contains).Distinct());
        return catalog;
    }

    internal static string Normalize(string s) => Regex.Replace(
        Regex.Replace(s, @"[\x00-\x1f\x7f-\x9f\u200b-\u200f\u2028-\u202e\u2060-\u2064\ufeff]", "")
        .Normalize(NormalizationForm.FormKC).ToLowerInvariant().Trim(), @"\s+", " ");

    public List<Course> Search(string input) => Search(input, out _);

    public List<Course> Search(string input, out string fallback)
    {
        fallback = "";
        var runes = Normalize(input).EnumerateRunes().Take(30).ToArray();
        string Prefix(int length) => string.Concat(runes.Take(length));
        var q = Prefix(runes.Length);
        if (q == "") return [];
        List<Course> Titles(string term) => Courses.Where(c => Normalize(c.Title).Contains(term, StringComparison.Ordinal))
            .OrderByDescending(c => Normalize(c.Title).StartsWith(term, StringComparison.Ordinal)).Take(500).ToList();
        var hits = Titles(q);
        var letters = q.Replace(" ", "");
        if (letters.Length >= 2 && letters.All(char.IsAsciiLetter))
        {
            phonetics ??= Pinyin.Index(Courses);
            int Rank((string Initials, string Full) p) => p.Initials.StartsWith(letters, StringComparison.Ordinal) ? 0 :
                p.Initials.Contains(letters) ? 1 : p.Full.StartsWith(letters, StringComparison.Ordinal) ? 2 : p.Full.Contains(letters) ? 3 : 4;
            hits = hits.Concat(Courses.Where(c => Rank(phonetics[c]) < 4).OrderBy(c => Rank(phonetics[c]))).Distinct().Take(500).ToList();
        }
        for (int n = runes.Length - 1; hits.Count == 0 && n >= 2; n--)
        {
            string prefix = Prefix(n);
            hits = Titles(prefix);
            if (hits.Count > 0) fallback = prefix;
        }
        return hits;
    }
}

public record Progress(double Position, double Duration, bool Completed)
{
    public string PillLabel(double knownDuration = 0)
    {
        double duration = Duration > 0 ? Duration : knownDuration;
        if (!Completed && Position > 0 && duration > 0) return "剩 " + Clock(duration - Position);
        if (duration > 0) return $"{Math.Max(1, Math.Round(duration / 60, MidpointRounding.AwayFromZero))} 分钟";
        return Completed ? "已听完" : "播放";
    }

    public static bool Finished(double pos, double duration) =>
        duration > 0 && (duration <= 30 ? pos >= duration * .95 : duration - pos <= 30);
    public static string Clock(double seconds)
    {
        int s = (int)Math.Clamp(double.IsFinite(seconds) ? seconds : 0, 0, 1e9);
        return $"{s / 60:00}:{s % 60:00}";
    }
}
