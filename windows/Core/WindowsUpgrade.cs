using System.Text.Json;
using System.Text.RegularExpressions;

namespace Zhibei;

public sealed record WindowsUpgrade(string LatestVersion, string MinVersion, string ExePath)
{
    public const string Path = "upgrade.json";
    public const int SizeLimit = 10240;
    static readonly Regex VersionFormat = new(@"\A[0-9]+(?:\.[0-9]+){0,2}\z");

    public static WindowsUpgrade? Parse(byte[] data)
    {
        if (data.Length > SizeLimit) throw new InvalidDataException("更新清单超过容量限制");
        using var manifest = JsonDocument.Parse(data);
        if (manifest.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("更新清单格式无效");
        if (!manifest.RootElement.TryGetProperty("windows", out var section)) return null;

        string latest = Catalog.Str(Catalog.Field(section, "latestVersion"));
        string minimum = Catalog.Str(Catalog.Field(section, "minVersion"));
        string installer = Catalog.Str(Catalog.Field(section, "exePath"));
        if (CompareVersions(minimum, latest) is not (0 or -1) || !Catalog.ValidPath(installer) ||
            installer != $"releases/zhibeifw-{latest}-win-setup.exe")
            throw new InvalidDataException("Windows 更新清单格式无效");
        return new(latest, minimum, installer);
    }

    public static int? CompareVersions(string? first, string? second)
    {
        if (first == null || second == null || !VersionFormat.IsMatch(first) || !VersionFormat.IsMatch(second)) return null;
        var a = first.Split('.');
        var b = second.Split('.');
        for (int i = 0; i < 3; i++)
        {
            string x = i < a.Length ? a[i].TrimStart('0') : "";
            string y = i < b.Length ? b[i].TrimStart('0') : "";
            if (x.Length != y.Length) return x.Length.CompareTo(y.Length);
            if (x != y) return Math.Sign(string.CompareOrdinal(x, y));
        }
        return 0;
    }
}

public enum WindowsUpdateStatus { Current, Available, Outdated, Failed }
public sealed record WindowsUpdateResult(WindowsUpdateStatus Status, WindowsUpgrade? Release = null, bool ShowDialog = false);

public sealed class WindowsUpdateChecker(Store store, ContentService network, string currentVersion)
{
    const string CacheKey = "update.windows.cache";
    const string ReminderKey = "update.windows.reminder";
    readonly SemaphoreSlim gate = new(1);
    sealed record Cache(string Etag, DateTimeOffset CheckedAt, WindowsUpgrade? Upgrade);
    sealed record Reminder(string Version, DateTimeOffset At);

    public async Task<WindowsUpdateResult> Check(bool manual, DateTimeOffset now, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            var cached = Read<Cache>(CacheKey);
            if (!manual && cached != null && now - cached.CheckedAt < TimeSpan.FromHours(24))
                return Decide(cached.Upgrade, false, now);

            var origin = await network.EnsureOrigin(token);
            var (bytes, etag) = await network.Fetch(Catalog.MediaUri(origin, WindowsUpgrade.Path),
                WindowsUpgrade.SizeLimit, cached?.Etag ?? "", token);
            var upgrade = bytes == null ? cached?.Upgrade : WindowsUpgrade.Parse(bytes);
            token.ThrowIfCancellationRequested();
            store.Set(CacheKey, JsonSerializer.Serialize(new Cache(etag, now, upgrade)));
            return Decide(upgrade, manual, now);
        }
        catch (Exception e) when (!token.IsCancellationRequested &&
            e is HttpRequestException or IOException or InvalidDataException or JsonException or OperationCanceledException)
        { return new(WindowsUpdateStatus.Failed); }
        finally { gate.Release(); }
    }

    public void RemindLater(string version, DateTimeOffset now) =>
        store.Set(ReminderKey, JsonSerializer.Serialize(new Reminder(version, now)));

    WindowsUpdateResult Decide(WindowsUpgrade? upgrade, bool manual, DateTimeOffset now)
    {
        if (upgrade == null || WindowsUpgrade.CompareVersions(currentVersion, upgrade.LatestVersion) != -1)
            return new(WindowsUpdateStatus.Current);
        if (WindowsUpgrade.CompareVersions(currentVersion, upgrade.MinVersion) == -1)
            return new(WindowsUpdateStatus.Outdated, upgrade, manual);

        var reminder = Read<Reminder>(ReminderKey);
        bool suppressed = reminder?.Version == upgrade.LatestVersion && now - reminder.At < TimeSpan.FromDays(7);
        return new(WindowsUpdateStatus.Available, upgrade, manual || !suppressed);
    }

    T? Read<T>(string key) where T : class
    {
        var value = store.Setting(key);
        if (value.Length == 0) return null;
        try { return JsonSerializer.Deserialize<T>(value); }
        catch (JsonException) { return null; }
    }
}
