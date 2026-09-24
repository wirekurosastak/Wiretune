using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using System;

namespace Wiretone.UI.Controls;

/// <summary>
/// Authentic port of FxSound's FxVisualizer (from fxsound2/fxsound-app).
/// Replicates FxSound's exact visualizer architecture:
/// 1. 10 ISO frequency bands mapped to multi-bar ripple sub-graphs.
/// 2. Outward traveling wave ripple propagation from band centers to adjacent bars.
/// 3. Vertically centered symmetrical expansion (expanding symmetrically up and down from the midline).
/// 4. Vertical symmetry gradient (bright accent color at top and bottom tips, deeper tone at horizontal center line).
/// 5. Sleek dark rounded glass pill container.
/// </summary>
public class FxVisualizerControl : Control
{
    public const int NumSpectrumBands = 10;
    public const int DefaultBarsPerBand = 3;

    public static readonly StyledProperty<float[]?> BandsProperty =
        AvaloniaProperty.Register<FxVisualizerControl, float[]?>(nameof(Bands));

    public static readonly StyledProperty<IBrush?> AccentBrushProperty =
        AvaloniaProperty.Register<FxVisualizerControl, IBrush?>(nameof(AccentBrush));

    public static readonly StyledProperty<bool> IsPlayingProperty =
        AvaloniaProperty.Register<FxVisualizerControl, bool>(nameof(IsPlaying), defaultValue: false);

    public static readonly StyledProperty<int> BarsPerBandProperty =
        AvaloniaProperty.Register<FxVisualizerControl, int>(nameof(BarsPerBand), defaultValue: DefaultBarsPerBand);

    public float[]? Bands
    {
        get => GetValue(BandsProperty);
        set => SetValue(BandsProperty, value);
    }

    public IBrush? AccentBrush
    {
        get => GetValue(AccentBrushProperty);
        set => SetValue(AccentBrushProperty, value);
    }

    public bool IsPlaying
    {
        get => GetValue(IsPlayingProperty);
        set => SetValue(IsPlayingProperty, value);
    }

    public int BarsPerBand
    {
        get => GetValue(BarsPerBandProperty);
        set => SetValue(BarsPerBandProperty, value);
    }

    private readonly DispatcherTimer _renderTimer;
    private float[] _bandGraph;
    private int _allocatedBars;
    private int _decayFramesRemaining = 0;

    public FxVisualizerControl()
    {
        _allocatedBars = NumSpectrumBands * DefaultBarsPerBand;
        _bandGraph = new float[_allocatedBars];

        _renderTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(33) // 30 FPS, matching FxSound
        };
        _renderTimer.Tick += OnRenderTick;

        AffectsRender<FxVisualizerControl>(AccentBrushProperty);
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        EnsureTimerState();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        _renderTimer.Stop();
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);

        if (change.Property == IsPlayingProperty)
        {
            if (IsPlaying)
            {
                _decayFramesRemaining = 30;
                EnsureTimerState();
            }
            else
            {
                // When stopped, allow smooth decay over 25 frames before sleeping timer
                _decayFramesRemaining = 25;
            }
        }
        else if (change.Property == BarsPerBandProperty)
        {
            int total = NumSpectrumBands * Math.Max(1, BarsPerBand);
            if (total != _allocatedBars)
            {
                _allocatedBars = total;
                _bandGraph = new float[_allocatedBars];
            }
        }
    }

    private void EnsureTimerState()
    {
        if (IsEffectivelyVisible && (IsPlaying || _decayFramesRemaining > 0))
        {
            if (!_renderTimer.IsEnabled) _renderTimer.Start();
        }
        else
        {
            if (_renderTimer.IsEnabled && !IsPlaying && _decayFramesRemaining <= 0)
            {
                _renderTimer.Stop();
            }
        }
    }

    private void OnRenderTick(object? sender, EventArgs e)
    {
        UpdateGraph();
        InvalidateVisual();

        if (!IsPlaying)
        {
            _decayFramesRemaining--;
            if (_decayFramesRemaining <= 0)
            {
                _renderTimer.Stop();
            }
        }
    }

    /// <summary>
    /// Exact implementation of FxSound's FxVisualizer::update() ripple algorithm.
    /// Values enter at the center of each frequency band and ripple outward to neighboring bars.
    /// </summary>
    private void UpdateGraph()
    {
        int barsPerBand = Math.Max(1, BarsPerBand);
        int totalBars = NumSpectrumBands * barsPerBand;
        if (_bandGraph.Length != totalBars)
        {
            _allocatedBars = totalBars;
            _bandGraph = new float[_allocatedBars];
        }

        var sourceBands = Bands;
        int half = barsPerBand / 2;

        for (int i = 0; i < NumSpectrumBands; i++)
        {
            float incoming = 0f;
            if (IsPlaying && sourceBands != null && i < sourceBands.Length)
            {
                incoming = Math.Clamp(sourceBands[i], 0f, 1f);
            }
            else if (!IsPlaying)
            {
                // Smooth exponential release decay when paused/stopped
                incoming = Math.Max(0f, _bandGraph[i * barsPerBand + half] * 0.72f);
            }

            // FxSound ripple propagation: Shift outward from center
            for (int j = 0; j < half; j++)
            {
                _bandGraph[i * barsPerBand + j] = _bandGraph[i * barsPerBand + j + 1];
                _bandGraph[i * barsPerBand + (barsPerBand - 1) - j] = _bandGraph[i * barsPerBand + (barsPerBand - 1) - j - 1];
            }

            // Set new energy at band center
            _bandGraph[i * barsPerBand + half] = incoming;
        }
    }

    public override void Render(DrawingContext context)
    {
        var bounds = Bounds;
        if (bounds.Width <= 0 || bounds.Height <= 0) return;

        // 1. FxSound calcGradient(): Vertical symmetry gradient (bright tips, deeper center)
        Color accentColor = Color.Parse("#67C8E0"); // fallback cyan
        if (AccentBrush is SolidColorBrush scb)
        {
            accentColor = scb.Color;
        }

        // Center color has reduced opacity and slight depth
        Color centerColor = Color.FromArgb(
            (byte)(accentColor.A * 0.45),
            accentColor.R,
            accentColor.G,
            accentColor.B);

        var gradient = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0.5, 0.0, RelativeUnit.Relative),
            EndPoint   = new RelativePoint(0.5, 1.0, RelativeUnit.Relative),
            GradientStops = new GradientStops
            {
                new GradientStop(accentColor, 0.0),
                new GradientStop(centerColor, 0.5),
                new GradientStop(accentColor, 1.0)
            }
        };

        // 2. FxSound paint(): Render vertically centered symmetrical audio bars directly without background frame
        int totalBars = NumSpectrumBands * Math.Max(1, BarsPerBand);
        double paddingH = 2.0;
        double paddingV = 2.0;
        double availableW = bounds.Width - paddingH * 2;
        double availableH = bounds.Height - paddingV * 2;
        double slotW = availableW / totalBars;
        double barW = Math.Clamp(slotW * 0.68, 2.0, 5.0);
        double cornerRadius = Math.Min(1.5, barW / 2.0);

        double centerY = bounds.Height / 2.0;

        for (int i = 0; i < Math.Min(totalBars, _bandGraph.Length); i++)
        {
            float val = _bandGraph[i];
            // Minimum 2.5px height so a continuous glowing centerline bead is visible even during quiet/resting moments
            float h = (float)Math.Max(2.5, val * availableH);
            float x = (float)(paddingH + i * slotW + (slotW - barW) / 2.0);
            float y = (float)(centerY - h / 2.0); // Exactly FxSound bounds.getHeight()/2.0f - height/2.0f

            context.DrawRectangle(gradient, null, new RoundedRect(new Rect(x, y, barW, h), cornerRadius));
        }
    }
}
