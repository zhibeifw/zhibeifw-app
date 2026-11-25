using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Zhibei.Desktop;

sealed class CourseArtwork : Border
{
    public static readonly DependencyProperty CoverPathProperty = DependencyProperty.Register(
        nameof(CoverPath), typeof(string), typeof(CourseArtwork), new PropertyMetadata("", CoverChanged));
    public static readonly DependencyProperty CourseIdProperty = DependencyProperty.Register(
        nameof(CourseId), typeof(string), typeof(CourseArtwork), new PropertyMetadata("", CoverChanged));
    public string CoverPath { get => (string)GetValue(CoverPathProperty); set => SetValue(CoverPathProperty, value); }
    public string CourseId { get => (string)GetValue(CourseIdProperty); set => SetValue(CourseIdProperty, value); }
    readonly Image picture = new() { Stretch = Stretch.UniformToFill };
    int revision;
    MainWindow? owner;
    public CourseArtwork()
    {
        Child = picture;
        IsHitTestVisible = false;
        SizeChanged += (_, _) => picture.Clip = new RectangleGeometry(new Rect(RenderSize), CornerRadius.TopLeft, CornerRadius.TopLeft);
        Loaded += (_, _) => {
            owner = Window.GetWindow(this) as MainWindow;
            if (owner != null) owner.RetryArtwork += RetryMissing;
            if (picture.Source == null) Reset();
        };
        Unloaded += (_, _) => {
            if (owner == null) return;
            owner.RetryArtwork -= RetryMissing;
            owner.ForgetArtwork(this);
            owner = null;
        };
    }
    static void CoverChanged(DependencyObject target, DependencyPropertyChangedEventArgs e) => ((CourseArtwork)target).Reset();

    void Reset()
    {
        revision++;
        picture.BeginAnimation(OpacityProperty, null);
        picture.Source = null;
        SetResourceReference(BackgroundProperty, "SubtleFillColorSecondaryBrush");
        if (owner == null) return;
        if (Catalog.ValidPath(CoverPath)) owner.QueueArtwork(this);
        else ShowFallback();
    }
    void ShowFallback()
    {
        if (SystemParameters.HighContrast) return;
        var colors = (string[])FindResource("CategoryColors");
        Background = (Brush)new BrushConverter().ConvertFromString(colors[CatalogIcon.Hash(CourseId ?? "") % 8])!;
    }
    internal void RetryMissing()
    {
        if (picture.Source == null) Reset();
    }
    internal async Task Load(Covers covers)
    {
        int requested = revision;
        var load = covers.Get(CoverPath);
        bool animate = !load.IsCompleted;
        var bitmap = await load;
        if (revision != requested || owner == null) return;
        if (bitmap == null) { ShowFallback(); return; }
        picture.Source = bitmap;
        if (animate && SystemParameters.ClientAreaAnimation)
            picture.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, (Duration)FindResource("FadeDuration")) {
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut }, FillBehavior = FillBehavior.Stop
            });
    }
}
