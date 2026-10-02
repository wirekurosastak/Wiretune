using System;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Threading;

namespace Wiretune.UI.Controls;

public enum NavWaveDirection
{
    LeftToRight,
    RightToLeft
}

/// <summary>
/// An 8-band audio waveform visualizer control designed as Wiretune's animated streamer logo.
/// Animates a traveling wave across the 8 frequency bands:
/// - Left-to-Right: when navigating downwards (e.g. Artists -> Albums -> Songs) or inwards (e.g. into artist or album details).
/// - Right-to-Left: when navigating upwards (e.g. Songs -> Albums) or outwards (e.g. clicking Back).
/// </summary>
public class NavVisualizerControl : Control
{
    public const int BandsCount = 8;
    private const double WaveDurationMs = 420.0;
    private const double FrameIntervalMs = 16.0;

    // While the control is not on screen (it sits on one page of the phone layout, and a page that is not shown still
    // exists) there is nothing to animate: the timer only checks now and then whether it came into view.
    private static readonly TimeSpan HiddenPollInterval = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan FrameInterval = TimeSpan.FromMilliseconds(FrameIntervalMs);

    public static readonly StyledProperty<int> WaveTriggerProperty =
        AvaloniaProperty.Register<NavVisualizerControl, int>(nameof(WaveTrigger));

    public static readonly StyledProperty<NavWaveDirection> WaveDirectionProperty =
        AvaloniaProperty.Register<NavVisualizerControl, NavWaveDirection>(nameof(WaveDirection), NavWaveDirection.LeftToRight);

    public static readonly StyledProperty<IBrush?> AccentBrushProperty =
        AvaloniaProperty.Register<NavVisualizerControl, IBrush?>(nameof(AccentBrush));

    public static readonly StyledProperty<bool> IsPlayingProperty =
        AvaloniaProperty.Register<NavVisualizerControl, bool>(nameof(IsPlaying), defaultValue: false);

    public int WaveTrigger
    {
        get => GetValue(WaveTriggerProperty);
        set => SetValue(WaveTriggerProperty, value);
    }

    public NavWaveDirection WaveDirection
    {
        get => GetValue(WaveDirectionProperty);
        set => SetValue(WaveDirectionProperty, value);
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

    private readonly DispatcherTimer _timer;
    private readonly float[] _currentHeights = new float[BandsCount];
    private readonly float[] _baseHeights = { 0.24f, 0.40f, 0.62f, 0.46f, 0.54f, 0.70f, 0.44f, 0.26f };
    private readonly Color[] _sourceColors = new Color[BandsCount];
    private readonly Color[] _currentColors = new Color[BandsCount];
    private readonly IBrush[] _barBrushes = new IBrush[BandsCount];
    private Color _targetColor = Color.Parse("#67C8E0");

    private float _waveProgress = 1.0f;
    private bool _isWaveActive;
    private NavWaveDirection _activeDirection = NavWaveDirection.LeftToRight;
    private double _pulsePhase;

    static NavVisualizerControl()
    {
        AffectsRender<NavVisualizerControl>(AccentBrushProperty);
    }

    public NavVisualizerControl()
    {
        ClipToBounds = false;

        var initColor = Color.Parse("#67C8E0");
        // Initialize resting heights and bar colors
        for (int i = 0; i < BandsCount; i++)
        {
            _currentHeights[i] = _baseHeights[i] * 0.32f;
            _sourceColors[i] = initColor;
            _currentColors[i] = initColor;
            _barBrushes[i] = new SolidColorBrush(initColor);
        }

        _timer = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = FrameInterval
        };
        _timer.Tick += OnTick;
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        if (AccentBrush != null)
        {
            _targetColor = ExtractColor(AccentBrush);
            for (int i = 0; i < BandsCount; i++)
            {
                _sourceColors[i] = _targetColor;
                _currentColors[i] = _targetColor;
                _barBrushes[i] = new SolidColorBrush(_targetColor);
            }
        }
        EnsureTimerState();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        _timer.Stop();
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);

        if (change.Property == WaveTriggerProperty)
        {
            TriggerWave(WaveDirection);
        }
        else if (change.Property == AccentBrushProperty)
        {
            var newColor = ExtractColor(change.GetNewValue<IBrush?>());
            if (newColor != _targetColor)
            {
                _targetColor = newColor;
                for (int i = 0; i < BandsCount; i++)
                {
                    _sourceColors[i] = _currentColors[i];
                }
                EnsureTimerState();
            }
        }
        else if (change.Property == IsPlayingProperty)
        {
            EnsureTimerState();
        }
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        // Interactive click: trigger a playful left-to-right sweep
        TriggerWave(NavWaveDirection.LeftToRight);
    }

    public void TriggerWave(NavWaveDirection direction)
    {
        _activeDirection = direction;
        _waveProgress = 0.0f;
        _isWaveActive = true;
        for (int i = 0; i < BandsCount; i++)
        {
            _sourceColors[i] = _currentColors[i];
        }
        EnsureTimerState();
    }

    private void EnsureTimerState()
    {
        bool hasColorMismatch = false;
        for (int i = 0; i < BandsCount; i++)
        {
            if (_currentColors[i] != _targetColor)
            {
                hasColorMismatch = true;
                break;
            }
        }

        if (_isWaveActive || IsPlaying || hasColorMismatch)
        {
            if (!_timer.IsEnabled) _timer.Start();
        }
        else
        {
            if (_timer.IsEnabled && !IsPlaying) _timer.Stop();
        }
    }

    private void OnTick(object? sender, EventArgs e)
    {
        // Not visible: do not animate and do not redraw (this used to run 60 times a second for as long as music played,
        // wherever the user was in the app, and every tick is a frame the phone has to produce). Poll slowly instead.
        if (!IsEffectivelyVisible)
        {
            if (_timer.Interval != HiddenPollInterval) _timer.Interval = HiddenPollInterval;
            return;
        }

        if (_timer.Interval != FrameInterval) _timer.Interval = FrameInterval;

        float crest;

        if (_isWaveActive)
        {
            _waveProgress += (float)(FrameIntervalMs / WaveDurationMs);
            if (_waveProgress >= 1.0f)
            {
                _waveProgress = 1.0f;
                _isWaveActive = false;
            }

            // Smooth sweep across all 8 bands
            // LeftToRight: moves from -1.5 to 8.5
            // RightToLeft: moves from 8.5 to -1.5
            if (_activeDirection == NavWaveDirection.LeftToRight)
            {
                crest = -1.5f + _waveProgress * 10.0f;
            }
            else
            {
                crest = 8.5f - _waveProgress * 10.0f;
            }
        }
        else
        {
            crest = -99f;
        }

        if (IsPlaying)
        {
            _pulsePhase += 0.08;
            if (_pulsePhase > Math.PI * 2.0) _pulsePhase -= Math.PI * 2.0;
        }

        bool hasMovingBars = false;

        for (int i = 0; i < BandsCount; i++)
        {
            float rest;
            if (IsPlaying)
            {
                var pulse = (float)(0.82 + 0.18 * Math.Sin(_pulsePhase + i * 0.7));
                rest = Math.Clamp(_baseHeights[i] * pulse * 0.45f, 0.12f, 0.60f);
            }
            else
            {
                rest = Math.Clamp(_baseHeights[i] * 0.30f, 0.12f, 0.40f);
            }

            float target = rest;

            if (_isWaveActive)
            {
                float dist = Math.Abs(i - crest);
                if (dist < 3.0f)
                {
                    // Sharp, dynamic Gaussian wave crest
                    float wavePeak = (float)Math.Exp(-(dist * dist) / (2.0f * 0.75f * 0.75f));
                    target = Math.Clamp(rest + wavePeak * 0.88f, 0.12f, 0.98f);
                }
            }

            // Color wave sweep or smooth transition
            if (_isWaveActive)
            {
                float factor = _activeDirection == NavWaveDirection.LeftToRight
                    ? Math.Clamp((crest - (i - 1.0f)) / 2.0f, 0.0f, 1.0f)
                    : Math.Clamp(((i + 1.0f) - crest) / 2.0f, 0.0f, 1.0f);

                var colorNow = LerpColor(_sourceColors[i], _targetColor, factor);
                if (colorNow != _currentColors[i])
                {
                    _currentColors[i] = colorNow;
                    _barBrushes[i] = new SolidColorBrush(colorNow);
                }
            }
            else if (_currentColors[i] != _targetColor)
            {
                var colorNow = LerpColor(_currentColors[i], _targetColor, 0.16f);
                _currentColors[i] = colorNow;
                _barBrushes[i] = new SolidColorBrush(colorNow);
            }

            // Physical spring physics: snappy attack, smooth release
            if (target > _currentHeights[i])
            {
                _currentHeights[i] += (target - _currentHeights[i]) * 0.70f;
                hasMovingBars = true;
            }
            else
            {
                float delta = target - _currentHeights[i];
                if (Math.Abs(delta) > 0.005f)
                {
                    _currentHeights[i] += delta * 0.24f;
                    hasMovingBars = true;
                }
                else
                {
                    _currentHeights[i] = target;
                }
            }
        }

        InvalidateVisual();

        bool hasColorMismatch = false;
        for (int i = 0; i < BandsCount; i++)
        {
            if (_currentColors[i] != _targetColor)
            {
                hasColorMismatch = true;
                break;
            }
        }

        if (!_isWaveActive && !IsPlaying && !hasMovingBars && !hasColorMismatch)
        {
            _timer.Stop();
        }
    }

    public override void Render(DrawingContext context)
    {
        base.Render(context);

        var bounds = Bounds;
        if (bounds.Width <= 0 || bounds.Height <= 0) return;

        double totalWidth = bounds.Width;
        double totalHeight = bounds.Height;
        double gap = 2.0;
        double barWidth = Math.Max(2.0, (totalWidth - (BandsCount - 1) * gap) / BandsCount);
        double centerY = totalHeight / 2.0;
        double radius = barWidth / 2.0;

        for (int i = 0; i < BandsCount; i++)
        {
            double x = i * (barWidth + gap);
            double barHeight = Math.Clamp(_currentHeights[i] * totalHeight, 3.2, totalHeight);
            double y = centerY - barHeight / 2.0;

            var rect = new Rect(x, y, barWidth, barHeight);
            var barBrush = _barBrushes[i] ?? AccentBrush ?? Brushes.Lime;
            context.DrawRectangle(barBrush, null, new RoundedRect(rect, radius));
        }
    }

    private static Color LerpColor(Color from, Color to, float t)
    {
        if (t <= 0f) return from;
        if (t >= 1f) return to;
        byte a = (byte)(from.A + (to.A - from.A) * t);
        byte r = (byte)(from.R + (to.R - from.R) * t);
        byte g = (byte)(from.G + (to.G - from.G) * t);
        byte b = (byte)(from.B + (to.B - from.B) * t);
        return Color.FromArgb(a, r, g, b);
    }

    private static Color ExtractColor(IBrush? brush)
    {
        if (brush is ISolidColorBrush scb) return scb.Color;
        return Color.Parse("#67C8E0");
    }
}

