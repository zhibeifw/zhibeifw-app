using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace Zhibei.Desktop;

public sealed class SpectrumBars : FrameworkElement
{
    public static readonly DependencyProperty LevelsProperty = DependencyProperty.Register(nameof(Levels), typeof(IReadOnlyList<double>),
        typeof(SpectrumBars), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    public IReadOnlyList<double>? Levels { get => (IReadOnlyList<double>?)GetValue(LevelsProperty); set => SetValue(LevelsProperty, value); }
    readonly double bar = (double)Application.Current.FindResource("Spectrum.barWidth");
    readonly double gap = (double)Application.Current.FindResource("Spectrum.spacing");
    readonly double gain = (double)Application.Current.FindResource("Spectrum.spectrumGain");
    readonly double power = (double)Application.Current.FindResource("Spectrum.spectrumExponent");

    protected override void OnRender(DrawingContext dc)
    {
        var brush = TextElement.GetForeground(this);
        for (int i = 0; i < 4; i++)
        {
            double level = Levels is { Count: 4 } bands ? bands[i] : 0;
            double h = Math.Max(bar, ActualHeight * Math.Pow(Math.Clamp(level * gain, 0, 1), power));
            dc.DrawRoundedRectangle(brush, null, new Rect(i * (bar + gap), (ActualHeight - h) / 2, bar, h), bar / 2, bar / 2);
        }
    }
}
