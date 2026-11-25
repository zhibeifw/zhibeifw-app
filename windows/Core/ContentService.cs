using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Zhibei;

public enum RouteStatus { Unavailable, Unchanged, Switched }

public sealed class ContentService(Store store, HttpClient http)
{
    public async Task<bool> AudioRemoved(Uri uri, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        using var request = new HttpRequestMessage(HttpMethod.Head, uri);
        try
        {
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            return response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Gone;
        }
        catch (HttpRequestException) { return false; }
        catch (OperationCanceledException) { return false; }
    }

    static readonly string[] Builtin = ["https://zbfw.org", "https://zbfw.app"];
    readonly SemaphoreSlim routeGate = new(1);
    string? selected;
    string? lastKnown;
    public Uri UriFor(string path) => Catalog.MediaUri(lastKnown ?? RememberedOrigin(), path);

    string RememberedOrigin()
    {
        var saved = store.Setting("origin");
        return Catalog.ValidOrigin(saved) ? saved : Builtin[0];
    }

    async Task<string> Resolve(CancellationToken token, string? current = null)
    {
        var origins = new[] { store.Setting("origin") }.Concat(store.Setting("domains").Split('\n')).Concat(Builtin)
            .Where(Catalog.ValidOrigin).Distinct().ToList();
        var checkedRoute = current == null ? null : await Probe(current, token);
        var route = checkedRoute ?? await ChooseRoute(origins.Where(origin => origin != current).ToList(), token);
        token.ThrowIfCancellationRequested();
        store.Set("origin", route.Origin);
        store.Set("domains", string.Join("\n", route.Domains));
        return selected = lastKnown = route.Origin;
    }

    public async Task<string> EnsureOrigin(CancellationToken token)
    {
        await routeGate.WaitAsync(token);
        try { return selected ?? await Resolve(token); }
        finally { routeGate.Release(); }
    }

    public async Task<RouteStatus> RefreshRoutes(CancellationToken token)
    {
        await routeGate.WaitAsync(token);
        try
        {
            var before = selected ?? RememberedOrigin();
            selected = null;
            return await Resolve(token, before) == before ? RouteStatus.Unchanged : RouteStatus.Switched;
        }
        catch (HttpRequestException)
        {
            store.Set("origin", "");
            return RouteStatus.Unavailable;
        }
        finally { routeGate.Release(); }
    }

    public async Task<Catalog?> RefreshCatalog(string etag, CancellationToken token)
    {
        var origin = await EnsureOrigin(token);
        var (data, tag) = await Fetch(Catalog.MediaUri(origin, "index.json"), Catalog.SizeLimit, etag, token);
        if (data == null) return null;
        string raw = new UTF8Encoding(false, true).GetString(data);
        var catalog = await Task.Run(() => Catalog.Parse(raw), token);
        token.ThrowIfCancellationRequested();
        store.CacheCatalog(raw, tag);
        return catalog;
    }

    async Task<(string Origin, string[] Domains)> ChooseRoute(List<string> origins, CancellationToken token)
    {
        using var race = CancellationTokenSource.CreateLinkedTokenSource(token);
        List<Task<(string, string[])?>> probes = [];
        Task<(string, string[] )?>? latest = null;
        int index = 0;
        Task delay = Task.CompletedTask;
        while (index < origins.Count || probes.Count > 0)
        {
            token.ThrowIfCancellationRequested();
            if (index < origins.Count && (delay.IsCompleted || probes.Count == 0))
            {
                latest = Probe(origins[index++], race.Token);
                probes.Add(latest);
                delay = Task.Delay(1500, race.Token);
            }
            var pending = probes.Cast<Task>();
            var first = await Task.WhenAny(index < origins.Count ? pending.Append(delay) : pending);
            if (first == delay) continue;
            var probe = (Task<(string, string[] )?>)first;
            probes.Remove(probe);
            if (await probe is {} result)
            {
                race.Cancel();
                return result;
            }
            if (probe == latest) delay = Task.CompletedTask;
        }
        throw new HttpRequestException("暂时没有可用的网络线路");
    }

    async Task<(string Origin, string[] Domains)?> Probe(string origin, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        try
        {
            var (bytes, _) = await Fetch(Catalog.MediaUri(origin, "domains.json"), 10240, "", timeout.Token);
            using var json = JsonDocument.Parse(bytes!);
            var domains = Catalog.Array(json.RootElement, "domains").Take(10).Select(Catalog.Str)
                .Where(Catalog.ValidOrigin).Distinct().ToArray();
            return domains.Length == 0 ? null : (origin, domains);
        }
        catch (Exception e) when (e is HttpRequestException or IOException or JsonException or OperationCanceledException or InvalidDataException)
        { return null; }
    }

    public async Task<(byte[]? Bytes, string Etag)> Fetch(Uri url, int limit, string etag, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (EntityTagHeaderValue.TryParse(etag, out var validator)) request.Headers.IfNoneMatch.Add(validator);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        if (validator != null && response.StatusCode == HttpStatusCode.NotModified) return (null, etag);
        if (response.StatusCode != HttpStatusCode.OK) throw new HttpRequestException("无法取得内容", null, response.StatusCode);
        if (response.Content.Headers.ContentLength > limit) throw new InvalidDataException("文件超过容量限制");
        using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
        using var output = new MemoryStream();
        byte[] buffer = new byte[16384];
        int n;
        while ((n = await stream.ReadAsync(buffer, timeout.Token).ConfigureAwait(false)) > 0)
        {
            if (output.Length + n > limit) throw new InvalidDataException("文件超过容量限制");
            output.Write(buffer, 0, n);
            timeout.CancelAfter(TimeSpan.FromSeconds(15));
        }
        return (output.ToArray(), response.Headers.ETag?.ToString() ?? "");
    }
}
