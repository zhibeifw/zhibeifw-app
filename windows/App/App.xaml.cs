using System.IO;
using System.Windows;
using System.Windows.Markup;
using System.Text.Json;

namespace Zhibei.Desktop;

public partial class App : Application
{
    void OnStartup(object sender, StartupEventArgs args)
    {
        try
        {
            using var design = JsonDocument.Parse(typeof(App).Assembly.GetManifestResourceStream("design.json")!);
            var root = design.RootElement;
            var component = root.GetProperty("component");
            foreach (var setting in component.GetProperty("audioWaveform").EnumerateObject())
                Resources["Spectrum." + setting.Name] = setting.Value.GetDouble();
            Resources["TileRadius"] = new CornerRadius(root.GetProperty("radius").GetProperty("tile").GetDouble());
            Resources["LargeCardWidth"] = component.GetProperty("vision").GetProperty("largeCardWidth").GetDouble();
            Resources["FadeDuration"] = new Duration(TimeSpan.FromMilliseconds(root.GetProperty("motion").GetProperty("fadeMs").GetDouble()));
            var miniPlayer = component.GetProperty("windowsMiniPlayer");
            double PlayerSize(string key) => miniPlayer.GetProperty(key).GetDouble();
            foreach (var value in miniPlayer.EnumerateObject().Where(value => value.Value.ValueKind == JsonValueKind.Number))
                Resources["Player." + value.Name] = value.Value.GetDouble();
            Resources["PlayerPadding"] = new Thickness(PlayerSize("padding"), PlayerSize("verticalPadding"), PlayerSize("padding"), PlayerSize("verticalPadding"));
            Resources["PlayerInfoMargin"] = new Thickness(PlayerSize("infoLeadingSpace"), 0, PlayerSize("infoTrailingSpace"), 0);
            Resources["PlayerCoverMargin"] = new Thickness(0, 0, PlayerSize("artworkGap"), 0);
            Resources["PlayerControlMargin"] = new Thickness(PlayerSize("controlSpacing"), 0, 0, 0);
            Resources["PlayerSeekRow"] = new GridLength(PlayerSize("seekAreaHeight"));
            Resources["PlayerGlassCorner"] = new CornerRadius(PlayerSize("glassRadius"));
            Resources["PlayerGlassBleed"] = new Thickness(-2 * PlayerSize("glassBlur"));
            var compact = miniPlayer.GetProperty("compact");
            double CompactPlayerSize(string key) => compact.GetProperty(key).GetDouble();
            Resources["Player.compactWidth"] = CompactPlayerSize("belowWidth");
            Resources["Player.compactControlSize"] = CompactPlayerSize("controlSize");
            Resources["Player.compactRateWidth"] = CompactPlayerSize("rateWidth");
            Resources["PlayerCompactPadding"] = new Thickness(CompactPlayerSize("padding"), PlayerSize("verticalPadding"), CompactPlayerSize("padding"), PlayerSize("verticalPadding"));
            Resources["PlayerCompactInfoMargin"] = new Thickness(CompactPlayerSize("infoLeadingSpace"), 0, CompactPlayerSize("infoTrailingSpace"), 0);
            var palette = root.GetProperty("contentPalette");
            Resources["CategoryColors"] = palette.GetProperty("colors").EnumerateArray()
                .Concat(palette.GetProperty("categoryExtraColors").EnumerateArray()).Select(c => c.GetString()!).ToArray();
            double pageMargin = root.GetProperty("space").GetProperty("pageMargin").GetDouble();
            Resources["PageMargin"] = new Thickness(pageMargin);
            Resources["ScrollContentInset"] = new Thickness(0, 0, pageMargin, 0);
            Resources["ControlGap"] = new Thickness(0, 0, root.GetProperty("space").GetProperty("searchBarInset").GetDouble(), 0);
            Resources["Rates"] = root.GetProperty("ratePicker").GetProperty("rates").EnumerateArray().Select(v => v.GetDouble()).ToArray();
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZhibeiFW");
            Directory.CreateDirectory(dir);
            MainWindow = new MainWindow(dir) { Language = XmlLanguage.GetLanguage("zh-CN") };
            MainWindow.Show();
        }
        catch (Exception ex)
        {
            MessageBox.Show("无法启动智悲佛网。\n" + ex.Message, "智悲佛网", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }
}
