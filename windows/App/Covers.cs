using System.Net.Http;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Media.Imaging;

namespace Zhibei.Desktop;

sealed class Covers(ContentService network, string directory, CancellationToken lifetime)
{
    readonly Dictionary<string, WeakReference<BitmapImage>> memory = [];
    readonly Dictionary<string, Task<BitmapImage?>> pending = [];
    int generation;
    public async Task<BitmapImage?> Get(string path)
    {
        if (!Catalog.ValidPath(path)) return null;
        if (memory.TryGetValue(path, out var weak) && weak.TryGetTarget(out var cached)) return cached;
        if (pending.TryGetValue(path, out var loading)) return await loading;
        var task = Load(path, generation);
        pending[path] = task;
        try { return await task; }
        finally { if (pending.GetValueOrDefault(path) == task) pending.Remove(path); }
    }
    async Task<BitmapImage?> Load(string path, int version)
    {
        try
        {
            Directory.CreateDirectory(directory);
            var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(path)));
            var file = Path.Combine(directory, key);
            var exists = File.Exists(file);
            var bytes = exists ? await File.ReadAllBytesAsync(file, lifetime) :
                (await network.Fetch(network.UriFor(path), Catalog.SizeLimit, "", lifetime)).Bytes!;
            var image = await Task.Run(() => {
                using var data = new MemoryStream(bytes);
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.DecodePixelWidth = 640;
                bitmap.StreamSource = data;
                bitmap.EndInit();
                bitmap.Freeze();
                return bitmap;
            }, lifetime);
            if (version != generation || lifetime.IsCancellationRequested) return null;
            if (!exists) File.WriteAllBytes(file, bytes);
            memory[path] = new(image);
            return image;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or HttpRequestException or
            OperationCanceledException or FormatException or NotSupportedException or InvalidDataException or System.Runtime.InteropServices.COMException)
        { return null; }
    }
    public void Clear()
    {
        generation++;
        memory.Clear();
        pending.Clear();
        if (Directory.Exists(directory)) Directory.Delete(directory, true);
    }
}
