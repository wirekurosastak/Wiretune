using System.Diagnostics;
using Avalonia.Controls;

namespace Wiretune.UI.Services;

/// <summary>
/// Watches the frames of the UI thread while the user is touching the screen (and for a few seconds after, which is
/// as long as a flick glides): how often a frame is produced, and how long its layout pass took.
/// <para>
/// Avalonia runs one frame as: animations and "next frame" callbacks, then the layout pass, then the hand-over of the
/// result to the render thread. The probe asks for a "next frame" callback on every frame, which marks the beginning of
/// the frame; the layout pass of that frame ends with <see cref="OnLayoutUpdated"/>, which the owner calls from the
/// <c>LayoutUpdated</c> event of its view. The time in between is the UI thread's share of the frame before the hand-over:
/// the other animations that run in it and the layout (container creation, styles and bindings of the rows that scroll
/// into view). A frame without a layout pass is counted as 0 ms.
/// </para>
/// <para>
/// The same callbacks give the rate at which the UI thread really produces frames while a list scrolls
/// (<see cref="FrameMonitor.UiFrame"/>; frames without a layout pass are resting frames and are not counted) - what the
/// user sees as "fps", as opposed to the rate at which the display ticks.
/// </para>
/// Everything runs on the UI thread. While the user does not touch the screen nothing is requested, so the app can rest.
/// </summary>
public sealed class UiFrameProbe
{
    // How long the probe keeps running after the last touch: a bit longer than the glide of a fast flick.
    private const double ActiveSeconds = 4;

    private readonly TopLevel _topLevel;
    private readonly Action<double> _layoutSample;
    private readonly Action<TimeSpan> _onFrame;

    private long _activeUntil;
    private bool _running;
    private bool _stopped;
    private long _frameStamp;
    private long _lastFrameStamp;

    /// <param name="topLevel">The window the frames belong to.</param>
    /// <param name="layoutSample">Called once per frame with the time before the end of its layout pass, in milliseconds.</param>
    public UiFrameProbe(TopLevel topLevel, Action<double> layoutSample)
    {
        _topLevel = topLevel;
        _layoutSample = layoutSample;
        _onFrame = OnFrame;
    }

    /// <summary>Call for every pointer event: the user is interacting, so the probe should be running.</summary>
    public void Touch()
    {
        if (_stopped) return;

        _activeUntil = Stopwatch.GetTimestamp() + (long)(ActiveSeconds * Stopwatch.Frequency);
        if (_running) return;

        _running = true;
        _frameStamp = 0;
        _lastFrameStamp = 0;
        _topLevel.RequestAnimationFrame(_onFrame);
    }

    /// <summary>Call from the <c>LayoutUpdated</c> event of the view: the layout pass of this frame has ended.</summary>
    public void OnLayoutUpdated()
    {
        if (_frameStamp == 0) return;

        var ms = (Stopwatch.GetTimestamp() - _frameStamp) * 1000.0 / Stopwatch.Frequency;
        _frameStamp = 0;
        _layoutSample(ms);
    }

    public void Stop()
    {
        _stopped = true;
        _running = false;
    }

    private void OnFrame(TimeSpan time)
    {
        if (_stopped) return;

        var now = Stopwatch.GetTimestamp();

        // The previous frame ended without a layout pass: it cost nothing on that account. It was also not a frame of a
        // scroll: Avalonia paces the frames of a resting UI with a 16 ms timer instead of the display's vsync, so their
        // rate says nothing about how well the list keeps up. Only the rate of the frames that did lay out is reported.
        var previousWasIdle = _frameStamp != 0;
        if (previousWasIdle) _layoutSample(0);

        if (_lastFrameStamp != 0 && !previousWasIdle)
        {
            FrameMonitor.ReportUiFrame((now - _lastFrameStamp) * 1000.0 / Stopwatch.Frequency);
        }

        _lastFrameStamp = now;
        _frameStamp = now;

        if (now < _activeUntil)
        {
            _topLevel.RequestAnimationFrame(_onFrame);
            return;
        }

        _running = false;
        _frameStamp = 0;
        _lastFrameStamp = 0;
    }
}
