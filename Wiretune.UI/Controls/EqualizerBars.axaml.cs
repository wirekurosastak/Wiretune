using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;

namespace Wiretune.UI.Controls;

/// <summary>
/// The animated "now playing" bars shown instead of a static speaker icon next to the track that is playing.
/// <para>
/// There is one of these in every row of every track list, so it is built to cost next to nothing while it is hidden:
/// it draws the bars itself (no child controls, no styles, no bindings of its own), and the visible ones share one timer
/// that only runs while at least one of them is on screen. Show and hide it with its own IsVisible: it animates only
/// while that is true.
/// </para>
/// </summary>
public sealed class EqualizerBars : Control
{
    private const int BarCount = 4;
    private const double BarWidth = 2.5;
    private const double BarGap = 2;
    private const double BarRadius = 1.25;
    private const double FullWidth = BarCount * BarWidth + (BarCount - 1) * BarGap;
    private const double FullHeight = 14;

    // Per bar: the lowest and the highest height (a fraction of the full height), and the seconds of one up-and-down.
    private static readonly double[] Low = { 0.25, 0.30, 0.40, 0.20 };
    private static readonly double[] High = { 1.00, 0.90, 0.95, 0.70 };
    private static readonly double[] Period = { 1.10, 1.60, 1.32, 1.88 };

    // The bars that are attached and visible, redrawn by one shared timer.
    private static readonly List<EqualizerBars> Running = new();
    private static DispatcherTimer? _timer;

    private bool _isAttached;
    private bool _isRunning;

    public EqualizerBars()
    {
        IsHitTestVisible = false;
    }

    protected override Size MeasureOverride(Size availableSize) => new(FullWidth, FullHeight);

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        _isAttached = true;
        UpdateRunning();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        _isAttached = false;
        UpdateRunning();
        base.OnDetachedFromVisualTree(e);
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == IsVisibleProperty) UpdateRunning();
    }

    private void UpdateRunning()
    {
        var shouldRun = _isAttached && IsVisible;
        if (shouldRun == _isRunning) return;
        _isRunning = shouldRun;

        if (shouldRun)
        {
            Running.Add(this);
            _timer ??= new DispatcherTimer(TimeSpan.FromMilliseconds(50), DispatcherPriority.Background, OnTick);
            if (!_timer.IsEnabled) _timer.Start();
        }
        else
        {
            Running.Remove(this);
            if (Running.Count == 0) _timer?.Stop();
        }
    }

    private static void OnTick(object? sender, EventArgs e)
    {
        for (var i = 0; i < Running.Count; i++)
        {
            if (Running[i].IsEffectivelyVisible) Running[i].InvalidateVisual();
        }
    }

    public override void Render(DrawingContext context)
    {
        // The accent follows the section the user is in (ThemeService swaps the resource), so it is looked up on every
        // frame rather than bound once per row.
        var brush = this.TryFindResource("PrimaryAction", ActualThemeVariant, out var resource) && resource is IBrush accent
            ? accent
            : Brushes.White;

        var height = Bounds.Height > 0 ? Bounds.Height : FullHeight;
        var left = Math.Max(0, (Bounds.Width - FullWidth) / 2);
        var seconds = Environment.TickCount64 / 1000.0;

        for (var i = 0; i < BarCount; i++)
        {
            var wave = 0.5 - 0.5 * Math.Cos(2 * Math.PI * seconds / Period[i]);
            var barHeight = height * (Low[i] + (High[i] - Low[i]) * wave);
            var x = left + i * (BarWidth + BarGap);
            context.DrawRectangle(brush, null, new Rect(x, height - barHeight, BarWidth, barHeight), BarRadius, BarRadius);
        }
    }
}
