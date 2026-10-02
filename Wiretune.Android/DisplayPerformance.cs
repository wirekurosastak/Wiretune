// The Android 11 / 12 members used here (Surface.SetFrameRate, the performance hint) are only reached behind
// OperatingSystem.IsAndroidVersionAtLeast checks; the analyzer cannot follow those across methods. The display
// members are obsolete since API 30 but still answer.
#pragma warning disable CA1416, CA1422

using Android.App;
using Android.Content;
using Android.OS;
using Android.Views;
using Wiretune.UI.Services;

namespace Wiretune.Android;

/// <summary>
/// Makes the phone treat Wiretune like a native app that is being scrolled: it asks for a high refresh rate while the
/// user is interacting, it lowers that wish when the app cannot keep up with it, and it tells the CPU scheduler how much
/// work a frame is.
/// <para>
/// <b>Refresh rate.</b> Avalonia draws into a <see cref="SurfaceView"/>, a layer of its own that - unlike the views of a
/// native app - says nothing about the frame rate it wants. A modern phone (variable refresh rate panel, and Xiaomi's
/// HyperOS in particular) then guesses it from how often buffers arrive, and a list that is a little late once is guessed
/// to need 48, 30 or even 10 Hz - which makes it later still. So the surface votes for a rate while the user touches the
/// screen or a flick is gliding (<see cref="BoostMs"/> after the last touch), and withdraws the vote when nothing has
/// happened for a while, which lets the panel drop to a low rate and save battery again.
/// </para>
/// <para>
/// <b>Automatic rate.</b> The vote starts at the display's highest rate. Avalonia draws a frame in two steps that do not
/// overlap - the UI thread lays it out, then the render thread draws it - so a frame that takes longer than one refresh
/// period waits for the next one, and a screen of 120 Hz whose frames take 10 ms shows a ragged 60-90 frames a second:
/// worse than a steady 60. So every half second the app compares the frames the UI thread really produced (see
/// <see cref="UiFrameProbe"/>) with the rate it voted for; when it keeps falling short it votes for the next lower rate
/// the display offers, and it tries the higher one again after some seconds of keeping up (longer each time that failed, up
/// to eight). When the app produces clearly more frames than it voted for, it moves up at once to the highest rate its
/// frames can still keep up with.
/// The label in the statistics panel can pin the rate to one of the display's rates instead, to compare them by eye.
/// </para>
/// <para>
/// <b>Performance hint.</b> A frame is a short burst of work on two threads (the UI thread and Avalonia's render thread),
/// 60 to 120 times a second. The CPU governor sees bursts, not demand, and keeps the cores slow and the threads on small
/// cores until it is too late. Android's "performance hint" API (ADPF, Android 12+) lets the app name the threads and
/// report how long each frame took against the time it had; the system then raises the clocks and picks the big cores
/// for exactly those threads, and lowers them again when the app reports short frames. That is what games do.
/// </para>
/// </summary>
internal sealed class DisplayPerformance : IDisposable
{
    // How long the high refresh rate stays after the last touch: long enough for the glide of a fast flick (about 3 s).
    private const long BoostMs = 3500;

    // How often the automatic mode looks at the frame rate it got.
    private const long ControlIntervalMs = 500;

    // The automatic mode steps down when the UI thread produces less than this share of the rate it voted for for two
    // checks in a row, and counts a check as good from this share on.
    private const double FallShort = 0.85;
    private const double KeepsUp = 0.95;

    // The UI thread produces this much more than the rate it voted for: the vote is lower than what the app can do (or the
    // system lets the display run faster than it was asked to), so the next higher rate is tried at once - provided the
    // frames that were produced would still keep up with it.
    private const double Overshoot = 1.15;

    private readonly Activity _activity;
    private readonly Handler _handler = new(Looper.MainLooper!);
    private readonly Java.Lang.Runnable _relax;
    private readonly Java.Lang.Runnable _reapply;
    private readonly Java.Lang.Runnable _moveMonitor;
    private readonly Java.Lang.Runnable _control;
    private readonly int _uiThreadId = Process.MyTid();

    // The refresh rates of the display, highest first, and how the vote is chosen: 0 = automatic, i = _rates[i - 1].
    private float[] _rates = { 60f };
    private float _maxRate = 60f;
    private int _mode;

    // State of the automatic mode.
    private float _autoRate = 60f;
    private int _autoBad;
    private int _autoGood;
    private int _autoStable;
    private int _autoOver;
    private int _autoHold = StartHold;
    private int _skipChecks;
    private long _uiFrames;
    private double _uiSumMs;
    private bool _controlPending;
    private long _lastBoostEndMs;
    private bool _started;

    // Good checks (half a second each) to wait before trying the next higher rate, and the longest that wait gets after
    // repeated failures (8 s: a vote that was too ambitious once is not held against the app for half a minute).
    private const int StartHold = 4;
    private const int MaxHold = 16;

    private long _boostUntilMs;
    private long _lastRevoteMs;
    private bool _boosted;
    private bool _disposed;
    private string _voteStatus = "no surface yet";
    private SurfaceView? _surfaceView;
    private Surface? _surface;

    // The performance hint session is created on the render thread, on the first frame.
    private PerformanceHintManager.Session? _hint;
    private bool _hintTried;
    private long _hintReports;
    private string _hintStatus = "hint: not started";

    public DisplayPerformance(Activity activity)
    {
        _activity = activity;
        _relax = new Java.Lang.Runnable(Relax);
        _reapply = new Java.Lang.Runnable(() => { if (_boosted) ApplyVote(VoteRate); });
        _moveMonitor = new Java.Lang.Runnable(FrameMonitor.MoveToEnd);
        _control = new Java.Lang.Runnable(Control);
    }

    // A clock that does not cross into Java: it is read for every touch event.
    private static long Now() => System.Environment.TickCount64;

    /// <summary>The rate the app asks the display for right now (while it is interacting).</summary>
    private float VoteRate => _mode == 0 ? _autoRate : _rates[_mode - 1];

    /// <summary>Short text for the chip of the statistics panel: how the refresh rate is chosen, and what it is now.</summary>
    public string ModeLabel => _mode == 0
        ? $"Refresh: auto ({_autoRate:0} Hz)"
        : $"Refresh: fixed {_rates[_mode - 1]:0} Hz";

    /// <summary>Two lines for the statistics panel: the vote and the display's rate, and the state of the performance hint.</summary>
    public string Status
    {
        get
        {
            var display = ReadDisplayRate();
            var vote = _boosted ? $"{VoteRate:0} Hz ({(_mode == 0 ? "auto" : "fixed")})" : "none (idle)";
            return $"Vote: {vote}, {_voteStatus} - display mode {display:0} Hz\n{_hintStatus}";
        }
    }

    /// <summary>
    /// Moves to the next way of choosing the refresh rate: automatic, then each rate the display offers, highest first.
    /// Returns a message that says what was chosen.
    /// </summary>
    public string CycleMode()
    {
        _mode = (_mode + 1) % (_rates.Length + 1);
        ResetAuto();

        // Say it at once, whether or not a finger is on the screen.
        Boost();
        ApplyVote(VoteRate);

        return _mode == 0
            ? "Refresh rate: automatic - starts at the highest and steps down when frames are late"
            : $"Refresh rate: fixed at {_rates[_mode - 1]:0} Hz while you touch the screen";
    }

    /// <summary>Call from <c>OnCreate</c> (and again from <c>OnResume</c>).</summary>
    public void Start()
    {
        ReadRates();
        if (_mode > _rates.Length) _mode = 0;
        if (!_started || _autoRate < _rates[_rates.Length - 1] || _autoRate > _maxRate) ResetAuto();
        _started = true;

        if (FrameMonitor.Start())
        {
            FrameMonitor.Tick -= OnFrame;
            FrameMonitor.Tick += OnFrame;
        }

        FrameMonitor.UiFrame -= OnUiFrame;
        FrameMonitor.UiFrame += OnUiFrame;
        FrameMonitor.Touched -= OnTouch;
        FrameMonitor.Touched += OnTouch;

        Boost();

        // The surface does not exist yet in OnCreate, and the renderer adds its own frame clock handler only when it does:
        // say the vote again once it is there, and move the hint's timing handler behind the renderer's.
        _handler.PostDelayed(_reapply, 700);
        _handler.PostDelayed(_reapply, 2000);
        _handler.PostDelayed(_moveMonitor, 1500);
    }

    /// <summary>The user is interacting (raised for every pointer event of the phone layout, see FrameMonitor.Touched).</summary>
    private void OnTouch()
    {
        var now = Now();
        _boostUntilMs = now + BoostMs;

        if (!_boosted)
        {
            Boost();
        }
        else if (now - _lastRevoteMs > 2000)
        {
            // It survives a surface that was created again behind our back.
            ApplyVote(VoteRate);
        }
    }

    private void Boost()
    {
        var now = Now();
        _boostUntilMs = Math.Max(_boostUntilMs, now + BoostMs);

        var wasBoosted = _boosted;
        _boosted = true;

        if (!wasBoosted)
        {
            // After a long rest the conditions (clocks, temperature, what else runs) are not the ones that made the last
            // decision: start from the top again.
            if (now - _lastBoostEndMs > 30_000) ResetAuto();

            // The first frames after a rest are slow whatever the app does; they are not a reason to step down.
            _uiFrames = 0;
            _uiSumMs = 0;
            _autoBad = 0;
            _autoGood = 0;
            _autoOver = 0;
            _skipChecks = 1;
        }

        ApplyVote(VoteRate);

        if (!wasBoosted)
        {
            _handler.RemoveCallbacks(_relax);
            _handler.PostDelayed(_relax, BoostMs);
        }

        ScheduleControl();
    }

    private void Relax()
    {
        if (_disposed) return;

        var left = _boostUntilMs - Now();
        if (left > 50)
        {
            // There was a touch since: wait for the rest of the time.
            _handler.PostDelayed(_relax, left);
            return;
        }

        _boosted = false;
        _lastBoostEndMs = Now();
        ApplyVote(0f);
    }

    private void ResetAuto()
    {
        _autoRate = _maxRate;
        _autoBad = 0;
        _autoGood = 0;
        _autoStable = 0;
        _autoOver = 0;
        _autoHold = StartHold;
        FrameMonitor.TargetFrameMs = 1000.0 / Math.Max(VoteRate, 30f);
    }

    private void ScheduleControl()
    {
        if (_controlPending || _disposed) return;

        _controlPending = true;
        _handler.PostDelayed(_control, ControlIntervalMs);
    }

    /// <summary>Runs on the UI thread for every frame the UI thread produced while the user interacts (see UiFrameProbe).</summary>
    private void OnUiFrame(double intervalMs)
    {
        if (intervalMs <= 0 || intervalMs > 250) return;

        _uiFrames++;
        _uiSumMs += intervalMs;
    }

    /// <summary>The automatic mode: compares the frame rate the UI thread achieved with the rate it voted for.</summary>
    private void Control()
    {
        _controlPending = false;
        if (_disposed) return;

        var frames = _uiFrames;
        var seconds = _uiSumMs / 1000.0;
        _uiFrames = 0;
        _uiSumMs = 0;

        if (!_boosted) return;
        ScheduleControl();

        if (_skipChecks > 0)
        {
            _skipChecks--;
            return;
        }

        // Too few frames to tell (the probe is not running yet, or the UI thread was blocked for most of the time).
        if (_mode != 0 || frames < 3 || seconds < 0.2) return;

        var fps = frames / seconds;
        var ratio = fps / _autoRate;

        // Clearly more frames than the vote asks for, and enough to keep up with the next rate up: go there now.
        var next = NextRate(_autoRate, higher: true);
        if (ratio >= Overshoot && next > 0 && fps / next >= FallShort)
        {
            _autoOver++;
        }
        else
        {
            _autoOver = 0;
        }

        if (_autoOver >= 2)
        {
            _autoRate = next;
            ApplyVote(_autoRate);
            _skipChecks = 1;
            _autoOver = 0;
            _autoBad = 0;
            _autoGood = 0;
            return;
        }

        if (ratio < FallShort)
        {
            _autoBad++;
            _autoGood = 0;
        }
        else if (ratio >= KeepsUp)
        {
            _autoGood++;
            _autoBad = 0;
            _autoStable++;
        }
        else
        {
            _autoBad = 0;
            _autoGood = 0;
        }

        if (_autoBad >= 2)
        {
            // Falling short for a second: the next lower rate the display offers (a steady lower rate beats a ragged high one).
            var lower = NextRate(_autoRate, higher: false);
            if (lower > 0)
            {
                _autoRate = lower;
                ApplyVote(_autoRate);
                _skipChecks = 1; // the display needs a moment to switch; the next check would still see the old rate
            }

            _autoBad = 0;
            _autoGood = 0;
            _autoStable = 0;
            _autoHold = Math.Min(_autoHold * 2, MaxHold); // the next attempt at the higher rate waits longer
        }
        else if (_autoGood >= _autoHold && _autoRate < _maxRate)
        {
            var higher = NextRate(_autoRate, higher: true);
            if (higher > 0)
            {
                _autoRate = higher;
                ApplyVote(_autoRate);
                _skipChecks = 1;
            }

            _autoGood = 0;
        }
        else if (_autoStable >= 40 && _autoHold > StartHold)
        {
            // It has been fine for a long time: trust the higher rate sooner again.
            _autoHold = Math.Max(StartHold, _autoHold / 2);
            _autoStable = 0;
        }
    }

    /// <summary>The next higher or lower rate the display offers; 0 when there is none.</summary>
    private float NextRate(float rate, bool higher)
    {
        var result = 0f;
        foreach (var candidate in _rates)
        {
            if (higher && candidate > rate + 0.5f && (result == 0f || candidate < result)) result = candidate;
            if (!higher && candidate < rate - 0.5f && candidate > result) result = candidate;
        }

        return result;
    }

    /// <summary>Tells the surface which frame rate the app would like (0 withdraws the wish).</summary>
    private void ApplyVote(float rate)
    {
        _lastRevoteMs = Now();
        if (rate > 0f) FrameMonitor.TargetFrameMs = 1000.0 / rate;

        if (!OperatingSystem.IsAndroidVersionAtLeast(30))
        {
            _voteStatus = "needs Android 11";
            return;
        }

        try
        {
            // The views are looked up once and kept: walking the view tree wraps every view in a Java peer object, and
            // every peer is work for the garbage collector.
            if (_surfaceView == null || !_surfaceView.IsAttachedToWindow)
            {
                _surfaceView = FindSurfaceView(_activity.Window?.DecorView);
                _surface = null;
            }

            var surface = _surface;
            if (surface == null || !surface.IsValid)
            {
                surface = _surfaceView?.Holder?.Surface;
                _surface = surface;
            }

            if (surface == null || !surface.IsValid)
            {
                _voteStatus = "no surface yet";
                return;
            }

            // FRAME_RATE_COMPATIBILITY_DEFAULT: "this is the rate I would like"; the system picks the nearest it can show.
            surface.SetFrameRate(rate, 0);
            _voteStatus = "sent";
        }
        catch (Exception e)
        {
            _voteStatus = "failed: " + e.GetType().Name;
        }
    }

    private static SurfaceView? FindSurfaceView(View? view)
    {
        if (view is SurfaceView surfaceView) return surfaceView;

        if (view is ViewGroup group)
        {
            for (var i = 0; i < group.ChildCount; i++)
            {
                if (FindSurfaceView(group.GetChildAt(i)) is { } found) return found;
            }
        }

        return null;
    }

    /// <summary>The refresh rates the display offers (45 Hz and up), highest first.</summary>
    private void ReadRates()
    {
        var list = new List<float>();

        try
        {
            var display = _activity.WindowManager?.DefaultDisplay;
            if (display?.GetSupportedRefreshRates() is { } rates)
            {
                foreach (var rate in rates)
                {
                    var rounded = (float)Math.Round((double)rate);
                    if (rounded >= 45f && !list.Contains(rounded)) list.Add(rounded);
                }
            }

            if (list.Count == 0) list.Add(Math.Max((float)Math.Round((double)(display?.RefreshRate ?? 60f)), 60f));
        }
        catch (Exception)
        {
            if (list.Count == 0) list.Add(60f);
        }

        list.Sort((a, b) => b.CompareTo(a));
        _rates = list.ToArray();
        _maxRate = _rates[0];
    }

    private float ReadDisplayRate()
    {
        try
        {
            return _activity.WindowManager?.DefaultDisplay?.RefreshRate ?? 0f;
        }
        catch (Exception)
        {
            return 0f;
        }
    }

    /// <summary>Runs on the render thread after every frame tick.</summary>
    private void OnFrame(long sinceVsyncNanos)
    {
        if (_disposed || !OperatingSystem.IsAndroidVersionAtLeast(31)) return;

        if (!_hintTried)
        {
            _hintTried = true;
            CreateHintSession();
        }

        var hint = _hint;
        if (hint == null) return;

        try
        {
            // The time the frame took, counted from its vsync: the system wants to hear "short" while the list rests
            // and "long" while it scrolls, and raises or lowers the clocks accordingly.
            hint.ReportActualWorkDuration(Math.Max(sinceVsyncNanos, 100_000L));
            _hintReports++;
        }
        catch (Exception e)
        {
            _hint = null;
            _hintStatus = "hint: failed (" + e.GetType().Name + ")";
        }
    }

    private void CreateHintSession()
    {
        try
        {
            if (_activity.GetSystemService(Context.PerformanceHintService) is not PerformanceHintManager manager)
            {
                _hintStatus = "hint: not supported";
                return;
            }

            // The UI thread and this one (Avalonia's render thread, which is where the frame clock runs). The target is
            // set below the time a frame has (70 %), the way games do it: the system then keeps some headroom in the
            // clocks while a list scrolls instead of waiting until a frame is already late.
            var threads = new[] { _uiThreadId, Process.MyTid() };
            var target = (long)(0.7 * 1e9 / Math.Max(_maxRate, 60f));

            _hint = manager.CreateHintSession(threads, target);
            _hintStatus = _hint != null
                ? $"hint: on ({target / 1e6:0.0} ms)"
                : "hint: refused by the system";
        }
        catch (Exception e)
        {
            _hint = null;
            _hintStatus = "hint: failed (" + e.GetType().Name + ")";
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        FrameMonitor.Tick -= OnFrame;
        FrameMonitor.UiFrame -= OnUiFrame;
        FrameMonitor.Touched -= OnTouch;
        _handler.RemoveCallbacks(_relax);
        _handler.RemoveCallbacks(_reapply);
        _handler.RemoveCallbacks(_moveMonitor);
        _handler.RemoveCallbacks(_control);

        try
        {
            _hint?.Close();
        }
        catch (Exception)
        {
            // Closing is a courtesy.
        }

        _hint = null;
    }
}
