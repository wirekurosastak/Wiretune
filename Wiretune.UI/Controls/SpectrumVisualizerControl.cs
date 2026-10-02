using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using System;

namespace Wiretune.UI.Controls;

/// <summary>
/// Spectrum bars for the player: one bar per frequency band (32 by default), centred vertically and growing
/// symmetrically up and down, with an accent gradient that is bright at the tips and softer at the centre line.
/// The look is inspired by the visualizer in FxSound (https://github.com/fxsound2/fxsound-app).
/// </summary>
public class SpectrumVisualizerControl : Control
{
    public const int DefaultNumBands = 32;
    public const int DefaultBarsPerBand = 1;

    public static readonly StyledProperty<float[]?> BandsProperty =
        AvaloniaProperty.Register<SpectrumVisualizerControl, float[]?>(nameof(Bands));

    public static readonly StyledProperty<IBrush?> AccentBrushProperty =
        AvaloniaProperty.Register<SpectrumVisualizerControl, IBrush?>(nameof(AccentBrush));

    public static readonly StyledProperty<bool> IsPlayingProperty =
        AvaloniaProperty.Register<SpectrumVisualizerControl, bool>(nameof(IsPlaying), defaultValue: false);

    public static readonly StyledProperty<int> BarsPerBandProperty =
        AvaloniaProperty.Register<SpectrumVisualizerControl, int>(nameof(BarsPerBand), defaultValue: DefaultBarsPerBand);

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

    public SpectrumVisualizerControl()
    {
        _allocatedBars = DefaultNumBands * DefaultBarsPerBand;
        _bandGraph = new float[_allocatedBars];

        _renderTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(33) // 30 FPS
        };
        _renderTimer.Tick += OnRenderTick;

        AffectsRender<SpectrumVisualizerControl>(AccentBrushProperty);
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
        else if (change.Property == BarsPerBandProperty || change.Property == BandsProperty)
        {
            int numBands = Bands != null && Bands.Length > 0 ? Bands.Length : DefaultNumBands;
            int total = numBands * Math.Max(1, BarsPerBand);
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
    /// Feeds the incoming band levels into the bar graph. With more than one bar per band, each new level is set at the
    /// band's centre bar and shifts outward over the following frames.
    /// </summary>
    private void UpdateGraph()
    {
        var sourceBands = Bands;
        int numBands = sourceBands != null && sourceBands.Length > 0 ? sourceBands.Length : DefaultNumBands;
        int barsPerBand = Math.Max(1, BarsPerBand);
        int totalBars = numBands * barsPerBand;

        if (_bandGraph.Length != totalBars)
        {
            _allocatedBars = totalBars;
            _bandGraph = new float[_allocatedBars];
        }

        int half = barsPerBand / 2;

        for (int i = 0; i < numBands; i++)
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

            if (barsPerBand > 1)
            {
                // Shift outward from the centre
                for (int j = 0; j < half; j++)
                {
                    _bandGraph[i * barsPerBand + j] = _bandGraph[i * barsPerBand + j + 1];
                    _bandGraph[i * barsPerBand + (barsPerBand - 1) - j] = _bandGraph[i * barsPerBand + (barsPerBand - 1) - j - 1];
                }
            }

            // Set new energy at band center
            _bandGraph[i * barsPerBand + half] = incoming;
        }
    }

    public override void Render(DrawingContext context)
    {
        var bounds = Bounds;
        if (bounds.Width <= 0 || bounds.Height <= 0) return;

        // 1. Vertical symmetry gradient (bright tips, deeper centre)
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

        // 2. Vertically centred, symmetrical bars, drawn without a background frame
        int totalBars = _bandGraph.Length > 0 ? _bandGraph.Length : DefaultNumBands;
        double paddingH = 2.0;
        double paddingV = 2.0;
        double availableW = bounds.Width - paddingH * 2;
        double availableH = bounds.Height - paddingV * 2;
        double slotW = availableW / totalBars;
        double barW = Math.Clamp(slotW * 0.70, 2.0, 5.0);
        double cornerRadius = Math.Min(1.5, barW / 2.0);

        double centerY = bounds.Height / 2.0;

        for (int i = 0; i < Math.Min(totalBars, _bandGraph.Length); i++)
        {
            float val = _bandGraph[i];
            // Minimum 2.5px height so a continuous glowing centerline bead is visible even during quiet/resting moments
            float h = (float)Math.Max(2.5, val * availableH);
            float x = (float)(paddingH + i * slotW + (slotW - barW) / 2.0);
            float y = (float)(centerY - h / 2.0); // centre the bar on the midline

            context.DrawRectangle(gradient, null, new RoundedRect(new Rect(x, y, barW, h), cornerRadius));
        }
    }
}
