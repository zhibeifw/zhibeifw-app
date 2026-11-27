using System.Buffers.Binary;
using System.Text.Json;
using Zhibei;

if (OperatingSystem.IsMacOS())
    System.Runtime.InteropServices.NativeLibrary.SetDllImportResolver(typeof(Catalog).Assembly, (name, _, _) =>
        name switch {
            "winsqlite3" => System.Runtime.InteropServices.NativeLibrary.Load("/usr/lib/libsqlite3.dylib"),
            "icu" => System.Runtime.InteropServices.NativeLibrary.Load("/usr/lib/libicucore.A.dylib"),
            _ => IntPtr.Zero
        });

int checks = 0;
void Check(bool value, string label)
{
    if (!value) throw new Exception(label);
    checks++;
}
foreach (var (name, validate) in new (string, Func<string, bool>)[] {
    ("ids", Catalog.ValidId), ("paths", Catalog.ValidPath), ("origins", Catalog.ValidOrigin) })
{
    using var json = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "vectors", name + ".json")));
    foreach (var group in new[] { "valid", "invalid" })
        foreach (var item in json.RootElement.GetProperty(group).EnumerateArray())
            Check((item.ValueKind == JsonValueKind.String && validate(item.GetString()!)) == (group == "valid"), name + " " + item);
}
using (var vectors = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "vectors", "app-notice.json"))))
{
    foreach (var row in vectors.RootElement.GetProperty("cases").EnumerateArray())
    {
        var notice = AppNotice.Parse(System.Text.Encoding.UTF8.GetBytes(row[1].GetString()!));
        Check(notice?.Message == row[2].GetString() && notice?.Link?.Label == row[3].GetString() &&
            notice?.Link?.Url.AbsoluteUri == row[4].GetString() &&
            notice?.DismissalKey == row[5].GetString(), "公告：" + row[0].GetString());
    }
}
Check(!Progress.Finished(69, 100) && Progress.Finished(70, 100), "长音频结尾");
Check(!Progress.Finished(18, 20) && Progress.Finished(19, 20) && !Progress.Finished(0, 0), "短音频结尾");
foreach (var (bin, band) in new[] { (2, 0), (12, 1), (50, 2), (200, 3) })
{
    var spectrum = new AudioSpectrum();
    double[]? levels = null;
    for (int i = 0; i < AudioSpectrum.Size; i++)
        levels = spectrum.Add(.25 * Math.Sin(2 * Math.PI * bin * i / AudioSpectrum.Size), 48000);
    Check(levels != null && Math.Abs(levels[band] - .25) < .0001 &&
        levels.Where((_, i) => i != band).All(v => v < .0001), "同一音频窗口频段 " + band);
}
var sample = """{"categories":[{"id":"c","name":"分类","series":[{"id":"s","title":"金刚经","status":"ongoing","coverPath":"图.jpg","episodes":[{"id":"e","title":"第一课","audioPath":"1.mp3"},{"id":"e","title":"重复","audioPath":"2.mp3"},{"id":"f","title":"坏路径","audioPath":"../2.mp3"}]}]}]}""";
var catalog = Catalog.Parse(sample);
var course = catalog.Courses.Single();
var episode = course.Episodes.Single();
Check(episode.Id == "e", "集去重及过滤");
Check(catalog.Search("  金刚经讲记").Single() == course && !catalog.Search("第一课").Any(), "课程名称和最长前缀");
Check(catalog.Search("jgj").Single() == course && catalog.Search("jingangjing").Single() == course, "拼音");
Check(catalog.Search("金刚经延伸", out var prefix).Single() == course && prefix == "金刚经", "显示实际匹配的前缀");
Check(catalog.Search("jgj", out prefix).Single() == course && prefix == "", "拼音匹配不显示前缀提示");
Check(new Progress(0, 3658, false).PillLabel() == "61 分钟" && new Progress(22, 90, false).PillLabel() == "剩 01:08", "单集播放胶囊");
Check(new Progress(0, 90, true).PillLabel() == "2 分钟" && new Progress(0, 0, true).PillLabel() == "已听完", "已听完的时长与占位");
Check(Catalog.MediaUri("https://zbfw.org", "讲义/1%23.mp3").AbsoluteUri.EndsWith("/%E8%AE%B2%E4%B9%89/1%2523.mp3"), "相对路径编码");
var db = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".sqlite");
try
{
    using (var store = new Store(db))
    {
        store.CacheCatalog(sample, "tag");
        store.Favorite(course, true);
        store.Save(course, episode, 45, 180, false, true);
        store.ClearRecent();
        store.Save(course, episode, 50, 180, false, false);
    }
    using var reopened = new Store(db);
    Check(reopened.ReadCatalog().Raw == sample && reopened.ReadCatalog().Tag == "tag", "恢复目录及 ETag");
    Check(reopened.Favorites().Single().Id == course.Id && reopened.Recent().Count == 0, "清空最近不影响收藏");
    Check(reopened.ReadProgress(episode.Id)?.Position == 50, "续听且定时保存不恢复隐藏记录");
    reopened.Mark(course, episode, true);
    Check(reopened.ReadProgress(episode.Id)?.Completed == true && reopened.Recent().Count == 0, "手动标记听完");
    Check(new Progress(0, 0, true).PillLabel(3710) == "62 分钟", "已听完时使用目录中的时长");
    var handler = new CatalogServer(sample);
    using var http = new HttpClient(handler);
    var network = new ContentService(reopened, http);
    Check((await network.RefreshCatalog("", default))?.Courses.Count == 1, "同步目录");
    foreach (var code in new[] { 200, 404, 410, 503 })
    {
        handler.AudioStatus = (System.Net.HttpStatusCode)code;
        Check(await network.AudioRemoved(network.UriFor("test.mp3"), default) == (code is 404 or 410), "音频下架探测 " + code);
    }
    var cache = reopened.ReadCatalog();
    Check(await network.RefreshCatalog(cache.Tag, default) == null && handler.Probes == 1, "ETag 命中，当前线路固定");
    handler.Body = """{"categories":[]}""";
    try { await network.RefreshCatalog("", default); throw new Exception("应拒绝无效目录"); }
    catch (InvalidDataException) { }
    Check(reopened.ReadCatalog() == cache && reopened.Favorites().Count == 1, "损坏的目录保留旧缓存和收藏");
    handler.Body = new string('a', 4097);
    try { await network.Fetch(network.UriFor("cover"), 4096, "", default); throw new Exception("应拒绝超限响应"); }
    catch (InvalidDataException) { checks++; }
    handler.Body = sample;
    Check(await network.RefreshRoutes(default) == RouteStatus.Unchanged && handler.Probes == 2, "重新选中原线路");
    handler.BlockedHosts.Add("zbfw.org");
    Check(await network.RefreshRoutes(default) == RouteStatus.Switched, "备用线路可用");
    Check(reopened.Setting("origin") == "https://zbfw.app", "保存新线路");
    handler.BlockedHosts.Clear();
    var beforeProbe = handler.Probes;
    Check(await network.RefreshRoutes(default) == RouteStatus.Unchanged && handler.Probes == beforeProbe + 1 &&
        reopened.Setting("origin") == "https://zbfw.app", "备用线路仍正常时不切回首选域名");
    handler.BlockedHosts.Add("zbfw.org");
    handler.BlockedHosts.Add("zbfw.app");
    Check(await network.RefreshRoutes(default) == RouteStatus.Unavailable && reopened.Setting("origin") == "", "全部失败清除线路");
    Check(reopened.ReadCatalog() == cache, "线路检测不修改课程目录");
    handler.BlockedHosts.Clear();
    Check((await network.EnsureOrigin(default)) == "https://zbfw.org", "失败后再次联网会重选线路");
    var oldest = episode with { Id = "oldest" };
    reopened.Save(course, oldest, 31, 180, false, true);
    await Task.Delay(20);
    for (int i = 1; i <= 500; i++)
        reopened.Save(course, episode with { Id = $"recent_{i}" }, 32, 180, false, true);
    var visible = reopened.Recent();
    Check(visible.Count == 500 && visible.All(row => row.Id != oldest.Id), "最近播放只显示最新 500 集");
    Check(reopened.ReadProgress(oldest.Id)?.Position == 31, "超出显示上限仍保存进度");
    await Task.Delay(20);
    reopened.Save(course, oldest, 33, 180, false, true);
    Check(reopened.Recent().First().Id == oldest.Id, "再次播放旧集回到列表首位");
    reopened.ClearRecent();
    Check(reopened.Recent().Count == 0 && reopened.CourseProgress(course.Id).Count == 502, "清空涵盖上限之外的记录，保留全部进度");
    Check(reopened.SavedCourseTitle(course.Id) == course.Title && reopened.SavedCourseTitle("missing") == null, "下架课程显示收藏原名，无记录时回退");
    reopened.Favorite(course, false);
    Check(reopened.SavedCourseTitle(course.Id) == course.Title, "取消后收听记录仍可提供课名");
    Check(!reopened.Favorites().Any(), "取消收藏");
}
finally { File.Delete(db); }

var recoveryDir = Directory.CreateTempSubdirectory("zhibeifw-recovery-");
try
{
    var damaged = Path.Combine(recoveryDir.FullName, "library.sqlite");
    using (var store = new Store(damaged))
    {
        store.CacheCatalog(sample, "old-tag");
        store.Favorite(course, true);
        store.Save(course, episode, 45, 180, false, true);
        store.Set("origin", "https://zbfw.org");
    }
    // catalog_index is the first table created in a new database, on SQLite page 2.
    byte[] bytes = File.ReadAllBytes(damaged);
    int pageSize = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(16, 2));
    Check(bytes[pageSize] == 13, "目录回归库的表页");
    bytes[pageSize] = 0;
    File.WriteAllBytes(damaged, bytes);
    using (var recovered = new Store(damaged, out var cache))
    {
        Check(cache == ("", ""), "损坏目录和 ETag 一起丢弃");
        Check(recovered.Favorites().Single().Id == course.Id, "恢复目录保留收藏");
        Check(recovered.Recent().Single().Progress.Position == 45, "恢复目录保留播放进度与最近记录");
        Check(recovered.Setting("origin") == "https://zbfw.org", "恢复目录保留使用中的线路");
        var handler = new CatalogServer(sample);
        using var http = new HttpClient(handler);
        var network = new ContentService(recovered, http);
        Check((await network.RefreshCatalog(cache.Tag, default))?.Courses.Single().Id == course.Id,
            "恢复后重新获取课程");
    }
    using (var reopened = new Store(damaged, out var cache))
        Check(cache.Raw == sample && cache.Tag != "", "下次启动读回新目录及 ETag");
    var backup = recoveryDir.GetFiles("library.sqlite.damaged-*").Single();
    Check(File.ReadAllBytes(backup.FullName).SequenceEqual(bytes), "原始数据库备份逐字节相同");

    // The catalog_meta primary-key index occupies page 4, before user_favorite.
    Check(bytes[4 * pageSize] == 13, "收藏回归库的表页");
    bytes[4 * pageSize] = 0;
    File.WriteAllBytes(damaged, bytes);
    try
    {
        using var failedRecovery = new Store(damaged, out _);
        throw new Exception("收藏页不可读时应停止恢复");
    }
    catch (IOException) { }
    Check(File.ReadAllBytes(damaged).SequenceEqual(bytes) &&
        recoveryDir.GetFiles("library.sqlite*").Length == 2, "恢复失败原库不变且不留临时文件");
}
finally { recoveryDir.Delete(recursive: true); }
Console.WriteLine($"通过 {checks} 项校验");

sealed class CatalogServer(string sample) : HttpMessageHandler
{
    public System.Net.HttpStatusCode AudioStatus { get; set; }
    public string Body { get; set; } = sample;
    public HashSet<string> BlockedHosts { get; } = [];
    public int Probes { get; private set; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var reply = new HttpResponseMessage(System.Net.HttpStatusCode.OK);
        if (request.Method == HttpMethod.Head && request.RequestUri?.AbsolutePath == "/test.mp3") reply.StatusCode = AudioStatus;
        else if (request.RequestUri?.AbsolutePath == "/domains.json")
        {
            Probes++;
            if (BlockedHosts.Contains(request.RequestUri.Host)) throw new HttpRequestException();
            reply.Content = new StringContent("""{"domains":["https://zbfw.org"]}""");
        }
        else if (request.Headers.IfNoneMatch.Any(t => t.Tag == "\"catalog\""))
            reply.StatusCode = System.Net.HttpStatusCode.NotModified;
        else
        {
            reply.Content = new StringContent(Body);
            reply.Headers.ETag = new("\"catalog\"");
        }
        return Task.FromResult(reply);
    }
}
