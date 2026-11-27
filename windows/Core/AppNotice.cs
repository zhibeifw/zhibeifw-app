using System.Text.Json;
using System.Text.RegularExpressions;

namespace Zhibei;

public sealed record AppNotice(string DismissalKey, string Message, AppNotice.Destination? Link)
{
    public const string Path = "app-notice.json";
    public const int SizeLimit = 4096;
    static readonly Regex ValidId = new(@"\A[A-Za-z0-9_-]{1,64}\z");
    public sealed record Destination(string Label, Uri Url);

    public static AppNotice? Parse(byte[] data)
    {
        if (data.Length > SizeLimit) return null;
        try
        {
            using var config = JsonDocument.Parse(data);
            var root = config.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("enabled", out var enabled) || enabled.ValueKind != JsonValueKind.True)
                return null;

            var message = ReadText(root, "message", 180);
            if (message == null) return null;
            var id = root.TryGetProperty("id", out var idField) && idField.ValueKind == JsonValueKind.String
                ? idField.GetString() : null;
            var dismissalKey = id != null && ValidId.IsMatch(id) ? "id:" + id : "message:" + message;
            if (!root.TryGetProperty("link", out var link) || link.ValueKind != JsonValueKind.Object)
                return new AppNotice(dismissalKey, message, null);

            var label = ReadText(link, "label", 32);
            var address = ReadText(link, "url", 1000);
            if (label == null || address == null || !address.StartsWith("https://", StringComparison.OrdinalIgnoreCase) ||
                address.Any(c => char.IsWhiteSpace(c) || char.IsControl(c) || c == '\\') ||
                !Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Host.Length == 0 || uri.UserInfo.Length != 0 ||
                uri.Authority.Contains('@'))
                return new AppNotice(dismissalKey, message, null);

            return new AppNotice(dismissalKey, message, new Destination(label, uri));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    static string? ReadText(JsonElement element, string property, int maxLength)
    {
        if (!element.TryGetProperty(property, out var value) || value.ValueKind != JsonValueKind.String) return null;
        var text = value.GetString()?.Trim();
        return text is { Length: > 0 } && text.Length <= maxLength ? text : null;
    }
}
