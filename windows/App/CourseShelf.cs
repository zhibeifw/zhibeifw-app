using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Zhibei.Desktop;

sealed class CourseShelf : ScrollViewer
{
    const int MouseHorizontalWheel = 0x020E;
    Point? press;
    double offsetAtPress;
    bool dragging;

    // WPF exposes the vertical mouse wheel as a routed event. Hit-test the
    // horizontal Windows message so only the shelf under the pointer moves.
    public static nint HandleWindowMessage(Window window, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message != MouseHorizontalWheel) return 0;
        int packed = (int)lParam;
        var screen = new Point((short)packed, (short)(packed >> 16));
        var hit = window.InputHitTest(window.PointFromScreen(screen)) as DependencyObject;
        for (DependencyObject? item = hit; item != null; item = VisualTreeHelper.GetParent(item))
        {
            if (item is not CourseShelf shelf) continue;
            shelf.ScrollWheel((short)((long)wParam >> 16));
            handled = true;
            break;
        }
        return 0;
    }

    void ScrollWheel(int delta)
    {
        int lines = SystemParameters.WheelScrollLines;
        double step = lines < 0 ? ViewportWidth : lines * FontSize;
        ScrollToHorizontalOffset(HorizontalOffset + delta * step / Mouse.MouseWheelDeltaForOneLine);
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        // An ordinary wheel event bubbles up to the vertical page.
        if ((Keyboard.Modifiers & ModifierKeys.Shift) == 0) return;
        ScrollWheel(-e.Delta);
        e.Handled = true;
    }

    protected override void OnPreviewMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnPreviewMouseLeftButtonDown(e);
        if (e.StylusDevice != null || ScrollableWidth <= 0) return;
        press = e.GetPosition(this);
        offsetAtPress = HorizontalOffset;
    }

    protected override void OnPreviewMouseMove(MouseEventArgs e)
    {
        base.OnPreviewMouseMove(e);
        if (press is not Point start || e.StylusDevice != null) return;
        if (e.LeftButton != MouseButtonState.Pressed) { EndDrag(); return; }
        var distance = e.GetPosition(this) - start;
        if (!dragging)
        {
            if (Math.Abs(distance.X) < SystemParameters.MinimumHorizontalDragDistance ||
                Math.Abs(distance.X) <= Math.Abs(distance.Y)) return;
            // Taking capture away from the pressed card cancels its click.
            if (!CaptureMouse()) return;
            dragging = true;
        }
        ScrollToHorizontalOffset(offsetAtPress - distance.X);
        e.Handled = true;
    }

    protected override void OnPreviewMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnPreviewMouseLeftButtonUp(e);
        if (dragging) e.Handled = true;
        EndDrag();
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        if (ReferenceEquals(e.OriginalSource, this)) EndDrag();
    }

    void EndDrag()
    {
        press = null;
        dragging = false;
        if (IsMouseCaptured) ReleaseMouseCapture();
    }
}
