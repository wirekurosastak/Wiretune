using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using Avalonia;

namespace Wiretune.UI.Services;

/// <summary>
/// Listens to the platform's frame clock (on Android: the Choreographer, one tick per vsync of the display) and answers
/// two questions the frame graphs of Avalonia cannot: how fast is the display really ticking right now (a phone that
/// quietly drops to 60, 48 or 30 Hz while a list scrolls shows "20-50 fps" whatever the app does), and - for the Android
/// head, which gives the system a performance hint - how long after the vsync each frame has been handled.
/// <para>
/// The tick handler runs on the render thread, once per vsync, so it does nothing but arithmetic. The frame clock
/// (<c>IRenderTimer</c>) is not part of Avalonia's public API - it is left out of the assemblies an app compiles against -
/// so it is found and listened to by reflection; if that fails, <see cref="Start"/> says so and nothing else happens.
/// </para>
/// </summary>
public static class FrameMonitor
{
    private static readonly object s_lock = new();
    private static readonly Action<TimeSpan> s_handler = OnTick;
    private static object? s_timer;
    private static EventInfo? s_tickEvent;
    private static long s_lastFrameNanos;
    private static long s_ticks;
    private static double s_sumMs;
    private static double s_worstMs;
    private static long s_renderAllocatedBytes;
    private static bool s_allocUnsupported;

    /// <summary>
    /// How many bytes the render thread (the thread the frame ticks arrive on) has allocated in total, as of its latest
    /// tick; 0 when the runtime cannot tell. Together with the same figure of the UI thread it shows which of the two
    /// produces the garbage that makes the collector run.
    /// </summary>
    public static long RenderThreadAllocatedBytes => Interlocked.Read(ref s_renderAllocatedBytes);

    /// <summary>
    /// Raised on the render thread for every frame tick with the time, in nanoseconds, that has passed since the vsync the
    /// frame belongs to. When this handler runs after the renderer's own it is the time the frame took to be handled.
    /// </summary>
    public static event Action<long>? Tick;

    /// <summary>
    /// Raised on the render thread for every frame tick: the time since the previous tick in milliseconds (0 for the first
    /// one) and the time since the vsync in milliseconds, which is how long after its vsync the frame was handled.
    /// </summary>
    public static event Action<double, double>? Frame;

    /// <summary>
    /// Raised on the UI thread for every frame the UI thread itself produced while the user is interacting (see
    /// <see cref="UiFrameProbe"/>), with the time since the previous one in milliseconds: the frame rate the user sees.
    /// </summary>
    public static event Action<double>? UiFrame;

    /// <summary>
    /// The time one frame is supposed to take at the refresh rate the app asks for, in milliseconds. The graphs of the
    /// statistics panel colour their bars against it. The Android head keeps it up to date.
    /// </summary>
    public static double TargetFrameMs { get; set; } = 1000.0 / 60;

    /// <summary>Called by <see cref="UiFrameProbe"/> on the UI thread.</summary>
    public static void ReportUiFrame(double intervalMs) => UiFrame?.Invoke(intervalMs);

    /// <summary>Raised on the UI thread for every pointer event the phone layout receives: the user is interacting.</summary>
    public static event Action? Touched;

    /// <summary>Called by the phone layout on the UI thread for every pointer event.</summary>
    public static void ReportTouch() => Touched?.Invoke();

    /// <summary>Starts listening; true when the frame clock was found (and false on a platform that hides it).</summary>
    [UnconditionalSuppressMessage("Trimming", "IL2075", Justification = "Diagnostic only; a missing member just means no statistics.")]
    public static bool Start()
    {
        lock (s_lock)
        {
            if (s_timer != null) return true;
        }

        try
        {
            var timerType = typeof(AvaloniaObject).Assembly.GetType("Avalonia.Rendering.IRenderTimer");
            if (timerType == null) return false;

            var timer = RenderingInfo.GetPlatformService(timerType);
            var tick = timer?.GetType().GetEvent("Tick", BindingFlags.Public | BindingFlags.Instance);
            if (timer == null || tick == null) return false;

            lock (s_lock)
            {
                if (s_timer != null) return true;
                s_timer = timer;
                s_tickEvent = tick;
            }

            tick.AddEventHandler(timer, s_handler);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// Puts the handler behind the others of the frame clock, so that it runs after the renderer has drawn the frame
    /// (handlers run in the order they were added, and the renderer adds its own whenever a view becomes visible).
    /// </summary>
    public static void MoveToEnd()
    {
        object? timer;
        EventInfo? tick;
        lock (s_lock)
        {
            timer = s_timer;
            tick = s_tickEvent;
        }

        if (timer == null || tick == null) return;

        try
        {
            tick.RemoveEventHandler(timer, s_handler);
            tick.AddEventHandler(timer, s_handler);
        }
        catch (Exception)
        {
            // The statistics just stay where they were.
        }
    }

    /// <summary>
    /// The average rate of the frame ticks since the last call, the longest gap between two of them (ms) and how many
    /// there were. Zero ticks means the frame clock did not run at all (the app is in the background).
    /// </summary>
    public static (double Hz, double WorstGapMs, long Ticks) TakeSnapshot()
    {
        lock (s_lock)
        {
            var ticks = s_ticks;
            var average = ticks > 0 ? s_sumMs / ticks : 0;
            var worst = s_worstMs;
            s_ticks = 0;
            s_sumMs = 0;
            s_worstMs = 0;
            return (average > 0 ? 1000.0 / average : 0, worst, ticks);
        }
    }

    private static void OnTick(TimeSpan time)
    {
        // The frame time is on the monotonic clock, in 100 ns ticks; so is the stopwatch of .NET on Android.
        var frameNanos = time.Ticks * 100;
        var nowNanos = (long)(Stopwatch.GetTimestamp() * (1e9 / Stopwatch.Frequency));
        var intervalMs = 0.0;

        lock (s_lock)
        {
            if (s_lastFrameNanos != 0)
            {
                var gapMs = (frameNanos - s_lastFrameNanos) / 1e6;

                // A gap of a second or more is the app coming back from the background, not a frame.
                if (gapMs > 0 && gapMs < 1000)
                {
                    s_ticks++;
                    s_sumMs += gapMs;
                    if (gapMs > s_worstMs) s_worstMs = gapMs;
                    intervalMs = gapMs;
                }
            }

            s_lastFrameNanos = frameNanos;
        }

        var sinceVsyncNanos = Math.Max(0, nowNanos - frameNanos);

        // Not the same clock after all (or a frame that was never handled): better no number than a wrong one.
        if (sinceVsyncNanos > 1_000_000_000) sinceVsyncNanos = 0;

        Tick?.Invoke(sinceVsyncNanos);
        Frame?.Invoke(intervalMs, sinceVsyncNanos / 1e6);

        RecordAllocations();
    }

    /// <summary>Remembers what this (the render) thread has allocated so far; a runtime that cannot say is asked only once.</summary>
    private static void RecordAllocations()
    {
        if (s_allocUnsupported) return;

        try
        {
            var bytes = GC.GetAllocatedBytesForCurrentThread();
            if (bytes <= 0)
            {
                s_allocUnsupported = true;
                return;
            }

            Interlocked.Exchange(ref s_renderAllocatedBytes, bytes);
        }
        catch (Exception)
        {
            s_allocUnsupported = true;
        }
    }
}
