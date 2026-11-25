using System.Net;
using System.Net.Http;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Media.Imaging;

namespace Zhibei.Desktop;

sealed class Covers(ContentService network, string directory, CancellationToken lifetime)
{
    readonly Dictionary<(string Path, int Width), WeakReference<BitmapImage>> memory = [];
    readonly Dictionary<(string Path, int Width), Task<BitmapImage?>> pending = [];
    readonly Dictionary<string, Task<byte[]>> downloads = [];
    readonly HashSet<string> missingThumbnails = [];
    bool foundThumbnail;
    int generation;
    internal static int RequestWidth(int pixels)
    {
        if (pixels <= 0) return 0;
        if (pixels <= 320) return 320;
        if (pixels <= 640) return 640;
        return (pixels + 255) / 256 * 256;
    }

    public async Task<BitmapImage?> Get(string path, int width)
    {
        if (width <= 0 || !Catalog.ValidPath(path)) return null;
        int version = generation;
        int dot = path.LastIndexOf('.');
        if (width <= 640 && dot > path.LastIndexOf('/') && !missingThumbnails.Contains(path) &&
            (foundThumbnail || missingThumbnails.Count < 3))
        {
            string thumbnail = path.Insert(dot, $"-{width}");
            if (Catalog.ValidPath(thumbnail))
            {
                try
                {
                    var image = await GetSource(thumbnail, width);
                    if (generation != version) return null;
                    if (image != null)
                    {
                        foundThumbnail = true;
                        return image;
                    }
                    // 升级前可能只缓存过原图，离线时仍可以使用。
                    if (!File.Exists(DiskFile(path))) return null;
                }
                catch (HttpRequestException ex) when (Missing(ex))
                {
                    if (generation != version) return null;
                    missingThumbnails.Add(path);
                }
            }
        }
        try { return await GetSource(path, width); }
        catch (HttpRequestException ex) when (Missing(ex)) { return null; }
    }

    static bool Missing(HttpRequestException ex) => ex.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Forbidden;
    string DiskFile(string path) => Path.Combine(directory, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(path))));

    async Task<BitmapImage?> GetSource(string path, int width)
    {
        var key = (path, width);
        if (memory.TryGetValue(key, out var weak) && weak.TryGetTarget(out var cached)) return cached;
        if (pending.TryGetValue(key, out var loading)) return await loading;
        var task = Load(path, width, generation);
        pending[key] = task;
        try { return await task; }
        finally { if (pending.GetValueOrDefault(key) == task) pending.Remove(key); }
    }

    async Task<byte[]> Download(string path)
    {
        if (downloads.TryGetValue(path, out var running)) return await running;
        async Task<byte[]> Fetch() => (await network.Fetch(network.UriFor(path), Catalog.SizeLimit, "", lifetime)).Bytes!;
        var task = Fetch();
        downloads[path] = task;
        try { return await task; }
        finally { if (downloads.GetValueOrDefault(path) == task) downloads.Remove(path); }
    }

    async Task<BitmapImage?> Load(string path, int width, int version)
    {
        try
        {
            Directory.CreateDirectory(directory);
            var file = DiskFile(path);
            var exists = File.Exists(file);
            var bytes = exists ? await File.ReadAllBytesAsync(file, lifetime) : await Download(path);
            var image = await Task.Run(() => {
                using var data = new MemoryStream(bytes);
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.DecodePixelWidth = width;
                bitmap.StreamSource = data;
                bitmap.EndInit();
                bitmap.Freeze();
                return bitmap;
            }, lifetime);
            if (version != generation || lifetime.IsCancellationRequested) return null;
            if (!exists && !File.Exists(file)) File.WriteAllBytes(file, bytes);
            memory[(path, width)] = new(image);
            return image;
        }
        catch (HttpRequestException ex) when (Missing(ex)) { throw; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or HttpRequestException or
            OperationCanceledException or FormatException or NotSupportedException or InvalidDataException or System.Runtime.InteropServices.COMException)
        { return null; }
    }
    public void Clear()
    {
        generation++;
        memory.Clear();
        pending.Clear();
        downloads.Clear();
        missingThumbnails.Clear();
        foundThumbnail = false;
        if (Directory.Exists(directory)) Directory.Delete(directory, true);
    }
}
