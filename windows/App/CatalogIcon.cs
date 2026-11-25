using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace Zhibei.Desktop;

// Both desktop clients use the catalog's icon names. Render the project's
// 24-point artwork with WPF so it also inherits high-contrast foregrounds.
sealed class CatalogIcon : FrameworkElement
{
    static readonly Dictionary<string, DrawingGroup> shapes = Load();
    static readonly string[] random = ["school-outline", "shield-checkmark-outline", "planet-outline", "infinite-outline",
        "bulb-outline", "flower-outline", "book-outline", "leaf-outline", "accessibility-outline", "flame-outline",
        "library-outline", "chatbubble-ellipses-outline", "sunny-outline", "moon-outline", "star-outline", "heart-outline",
        "cloudy-outline", "water-outline"];
    public static readonly DependencyProperty NameOfIconProperty = DependencyProperty.Register(
        nameof(NameOfIcon), typeof(string), typeof(CatalogIcon),
        new FrameworkPropertyMetadata("bookmark-outline", FrameworkPropertyMetadataOptions.AffectsRender));
    public string NameOfIcon { get => (string)GetValue(NameOfIconProperty); set => SetValue(NameOfIconProperty, value); }
    static CatalogIcon()
    {
        WidthProperty.OverrideMetadata(typeof(CatalogIcon), new FrameworkPropertyMetadata(16d));
        HeightProperty.OverrideMetadata(typeof(CatalogIcon), new FrameworkPropertyMetadata(16d));
    }
    public CatalogIcon() { IsHitTestVisible = false; }
    public CatalogIcon(string name, double size) : this()
    {
        NameOfIcon = name;
        Width = Height = size;
    }
    public static uint Hash(string id, uint salt = 0)
    {
        uint hash = 2166136261 ^ salt;
        foreach (char ch in id) hash = unchecked((hash ^ ch) * 16777619);
        return hash;
    }
    public static string CategoryName(Category category) => category.Icon == "random"
        ? random[Hash(category.Id, 0x5a) % random.Length] : category.Icon;
    static Dictionary<string, DrawingGroup> Load()
    {
        using var stream = typeof(CatalogIcon).Assembly.GetManifestResourceStream("catalog-icons.json")!;
        using var json = JsonDocument.Parse(stream);
        var result = new Dictionary<string, DrawingGroup>();
        foreach (var icon in json.RootElement.GetProperty("icons").EnumerateObject())
        {
            var group = new DrawingGroup();
            foreach (var part in icon.Value.EnumerateArray())
            {
                var geometry = Geometry.Parse(part.GetProperty("d").GetString()!);
                bool fill = part.TryGetProperty("fill", out var filled) && filled.GetBoolean();
                var pen = new Pen(Brushes.Black, part.TryGetProperty("w", out var weight) ? weight.GetDouble() :
                    json.RootElement.GetProperty("defaultStroke").GetDouble()) {
                    StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round
                };
                group.Children.Add(new GeometryDrawing(fill ? Brushes.Black : null, fill ? null : pen, geometry));
            }
            group.Freeze();
            result.Add(icon.Name, group);
        }
        // Desktop commands without a corresponding catalog symbol share these 24-unit WPF drawings.
        void Add(string name, string outline, string? filled = null)
        {
            var pen = new Pen(Brushes.Black, 1.65) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
            var group = new DrawingGroup();
            group.Children.Add(new GeometryDrawing(null, pen, Geometry.Parse(outline)));
            if (filled != null) group.Children.Add(new GeometryDrawing(Brushes.Black, null, Geometry.Parse(filled)));
            group.Freeze();
            result.Add(name, group);
        }
        const string lesson = "M5,10 V5 Q5,3.5 6.5,3.5 H20 Q21.5,3.5 21.5,5 V16 Q21.5,18 20,18 H11";
        const string badge = "F0 M5.5,12 A4.5,4.5 0 1 1 5.49,12 Z ";
        Add("lesson-mark", lesson, badge + "M2.6,16.4 L3.5,15.5 L5,17 L7.6,14.2 L8.5,15.1 L5,18.8 Z");
        Add("lesson-unmark", lesson, badge + "M2.9,15.8 H8.1 V17.2 H2.9 Z");
        Add("bookmark-remove", "M6,8 V20.6 L12,16.9 L18,20.6 V19 M6,4 V3.5 H18 V14 M3,3 L21,21");
        Add("sidebar", "M4,4.5 H20 Q21.5,4.5 21.5,6 V18 Q21.5,19.5 20,19.5 H4 Q2.5,19.5 2.5,18 V6 Q2.5,4.5 4,4.5 Z M9,5 V19");
        Add("grid-outline", "M3,3.5 H10 V10.5 H3 Z M14,3.5 H21 V10.5 H14 Z M3,14 H10 V21 H3 Z M14,14 H21 V21 H14 Z");
        Add("time-outline", "M12,2.8 A9.2,9.2 0 1 1 11.99,2.8 Z M12,6.2 V12 L16,14.4");
        Add("drive", "M3,14 L5.8,5 H18.2 L21,14 V18 Q21,20 19,20 H5 Q3,20 3,18 Z M3,14 H21 M15,17 H18");
        Add("email", "M3,5 H21 V19 H3 Z M3.5,5.8 L12,12.5 L20.5,5.8");
        Add("privacy", "M7.7,12.7 V6.5 Q7.7,4.4 9.8,5.2 V11 V3.8 Q10.8,1.9 12.2,3.6 V11 V3.2 Q13.6,1.5 14.8,3.4 V11 V5.4 Q16.3,3.8 17.3,5.6 V12 L18.6,9 Q20.7,7.4 20.5,10 L19,16 Q18,21.5 13,21.5 Q9.4,21.5 7.4,18.4 L3.8,13 Q3.2,10.7 5.1,11 Z");
        Add("code", "M7,7 L2.5,12 L7,17 M17,7 L21.5,12 L17,17 M14.5,4 L9.5,20");
        return result;
    }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        var shape = NameOfIcon is { } name && shapes.TryGetValue(name, out var icon) ? icon : shapes["book-outline"];
        var mask = new DrawingBrush(shape) {
            ViewboxUnits = BrushMappingMode.Absolute, Viewbox = new Rect(0, 0, 24, 24), Stretch = Stretch.Fill
        };
        dc.PushOpacityMask(mask);
        dc.DrawRectangle(TextElement.GetForeground(this), null, new Rect(RenderSize));
        dc.Pop();
    }
}
