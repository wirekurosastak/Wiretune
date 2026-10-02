using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Wiretune.UI.Services;

namespace Wiretune.UI.Controls;

/// <summary>
/// A small bar graph of the last frames (one bar per sample, newest on the right) for the statistics panel of the phone
/// layout: how long each frame's layout took, how late the renderer was done, how far apart the display ticks. Bars are
/// coloured against the frame time the app aims for (<see cref="FrameMonitor.TargetFrameMs"/>): green well inside it,
/// amber up to it, red beyond. Samples can be added from any thread; the graph is only drawn when <c>InvalidateVisual</c>
/// is called (the panel does that a few times a second), so a busy frame clock does not cause any drawing of its own.
/// </summary>
public sealed class FrameGraph : Control
{
    private const int Capacity = 120;
    private const double BarWidth = 2;
    private const double BarGap = 0;
    private const double GraphHeight = 34;

    private static readonly IBrush Good = new SolidColorBrush(Color.FromRgb(70, 210, 120));
    private static readonly IBrush Warn = new SolidColorBrush(Color.FromRgb(255, 190, 60));
    private static readonly IBrush Bad = new SolidColorBrush(Color.FromRgb(255, 80, 80));
    private static readonly IBrush Backdrop = new SolidColorBrush(Color.FromArgb(70, 255, 255, 255));
    private static readonly IBrush Guide = new SolidColorBrush(Color.FromArgb(110, 255, 255, 255));

    private readonly object _lock = new();
    private readonly double[] _samples = new double[Capacity];
    private readonly double _goodFactor;
    private readonly double _warnFactor;
    private int _next;
    private int _count;
    private double _sum;
    private double _worst;
    private long _statCount;

    /// <param name="goodFactor">A sample up to this multiple of the target frame time is green.</param>
    /// <param name="warnFactor">A sample up to this multiple of the target frame time is amber (above it, red).</param>
    public FrameGraph(double goodFactor, double warnFactor)
    {
        _goodFactor = goodFactor;
        _warnFactor = warnFactor;
        IsHitTestVisible = false;
    }

    /// <summary>Adds a sample (milliseconds). Safe to call from any thread.</summary>
    public void Push(double ms)
    {
        lock (_lock)
        {
            _samples[_next] = ms;
            _next = (_next + 1) % Capacity;
            if (_count < Capacity) _count++;

            _sum += ms;
            _statCount++;
            if (ms > _worst) _worst = ms;
        }
    }

    /// <summary>The average and the worst sample (and how many there were) since the last call.</summary>
    public (double Average, double Worst, long Count) TakeStats()
    {
        lock (_lock)
        {
            var result = (_statCount > 0 ? _sum / _statCount : 0, _worst, _statCount);
            _sum = 0;
            _worst = 0;
            _statCount = 0;
            return result;
        }
    }

    protected override Size MeasureOverride(Size availableSize) => new(Capacity * (BarWidth + BarGap), GraphHeight);

    public override void Render(DrawingContext context)
    {
        var width = Capacity * (BarWidth + BarGap);
        var target = Math.Max(1, FrameMonitor.TargetFrameMs);
        var scale = Math.Max(target * 4, 20);

        context.DrawRectangle(Backdrop, null, new Rect(0, 0, width, GraphHeight));

        lock (_lock)
        {
            // The oldest sample is the one that will be overwritten next (once the ring is full).
            var start = _count < Capacity ? 0 : _next;
            for (var i = 0; i < _count; i++)
            {
                var ms = _samples[(start + i) % Capacity];
                if (ms <= 0) continue;

                var height = Math.Min(1, ms / scale) * GraphHeight;
                if (height < 1) height = 1;

                var brush = ms <= target * _goodFactor ? Good : ms <= target * _warnFactor ? Warn : Bad;
                var x = (Capacity - _count + i) * (BarWidth + BarGap);
                context.DrawRectangle(brush, null, new Rect(x, GraphHeight - height, BarWidth, height));
            }
        }

        // Thin guide lines where green turns to amber and amber to red.
        DrawGuide(context, width, target * _goodFactor, scale);
        DrawGuide(context, width, target * _warnFactor, scale);
    }

    private static void DrawGuide(DrawingContext context, double width, double ms, double scale)
    {
        if (ms >= scale) return;

        var y = GraphHeight - ms / scale * GraphHeight;
        context.DrawRectangle(Guide, null, new Rect(0, Math.Max(0, y - 0.5), width, 1));
    }
}
