using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Platform;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Wiretune.UI.Controls;
using Wiretune.UI.Services;
using Wiretune.UI.ViewModels;

namespace Wiretune.UI.Views;

/// <summary>The phone layout (see AndroidMainView.axaml). The navigation state lives in <see cref="MainViewModel"/>.</summary>
public partial class AndroidMainView : UserControl
{
    /// <summary>The space taken by the status bar, the display cutout and the navigation bar; the layout keeps clear of it.</summary>
    public static readonly StyledProperty<Thickness> SafeAreaProperty =
        AvaloniaProperty.Register<AndroidMainView, Thickness>(nameof(SafeArea));

    /// <summary>The safe area without its bottom edge: what the page area keeps clear of (status bar, cutout, sides).</summary>
    public static readonly StyledProperty<Thickness> SafeAreaTopAndSidesProperty =
        AvaloniaProperty.Register<AndroidMainView, Thickness>(nameof(SafeAreaTopAndSides));

    /// <summary>Only the bottom edge of the safe area: the navigation bar pads itself with it, so that the bar's colour
    /// continues under the system navigation bar instead of leaving a strip of the window background there.</summary>
    public static readonly StyledProperty<Thickness> SafeAreaBottomOnlyProperty =
        AvaloniaProperty.Register<AndroidMainView, Thickness>(nameof(SafeAreaBottomOnly));

    // The room under the statistics panel: the mini player and the navigation bar (on top of the safe area below them).
    private const double DiagnosticsBottomOffset = 176;

    private static readonly IBrush CardBackground = new SolidColorBrush(Color.FromArgb(232, 8, 8, 12));
    private static readonly IBrush ChipBackground = new SolidColorBrush(Color.FromArgb(240, 38, 38, 52));

    private MainViewModel? _viewModel;
    private IInsetsManager? _insets;

    // The frames of the UI thread while the user touches the screen (see UiFrameProbe); runs in every build, because the
    // automatic refresh rate (DisplayPerformance) is based on it.
    private readonly EventHandler<PointerPressedEventArgs> _onPointerPressed;
    private readonly EventHandler<PointerEventArgs> _onPointerMoved;
    private UiFrameProbe? _probe;

    // The statistics panel (see StartDiagnostics); it exists only while the user has it turned on in the settings.
    private bool _isAttached;
    private StackPanel? _diagnosticsPanel;
    private TextBlock? _rendererChip;
    private TextBlock? _refreshChip;
    private TextBlock? _summaryLabel;
    private TextBlock? _layoutTitle;
    private TextBlock? _renderTitle;
    private TextBlock? _intervalTitle;
    private FrameGraph? _layoutGraph;
    private FrameGraph? _renderGraph;
    private FrameGraph? _intervalGraph;
    private string? _notice;
    private double _noticeUntilSeconds;
    private DispatcherTimer? _diagnosticsTimer;
    private DispatcherTimer? _graphTimer;
    private readonly Stopwatch _uptime = new();
    private double _worstGapEverMs;
    private int _hitches;
    private string _lastHitch = "none yet";
    private int _gcAtLastFrame;
    private int _lastGc0, _lastGc1, _lastGc2;
    private long _lastUiAlloc, _lastRenderAlloc, _lastTotalAlloc, _lastBound, _lastCreated;
    private double _lastUpdateSeconds;
    private long _uiFrames;
    private double _uiSumMs;
    private double _uiWorstMs;

    public AndroidMainView()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;

        // Avalonia pads the content of its top level by the safe area on its own (the status bar, the navigation bar and the
        // display cutout) as soon as the app draws edge to edge - and leaves its own background in that padding, which is
        // black: the app then looked cut off, with a black strip as tall as each system bar, and its layout was pushed down
        // twice (once by that padding and once by the safe area padding of the layout below). The layout here keeps clear of
        // the bars itself, so the automatic padding is switched off: the background fills the whole screen, behind the
        // bars, and only the pages, the headers and the controls stay inside the safe area.
        TopLevel.SetAutoSafeAreaPadding(this, false);

        _onPointerPressed = (_, _) => OnTouch();
        _onPointerMoved = (_, _) => OnTouch();

        // Avalonia draws text with LCD sub-pixel anti-aliasing unless told otherwise. On a phone that buys nothing (the
        // screen turns, the background is not always opaque) and costs the GPU a more complicated text shader for every
        // glyph run on the screen - so a scrolling list full of text is drawn with plain grey-scale anti-aliasing.
        RenderOptions.SetTextRenderingMode(this, TextRenderingMode.Antialias);
    }

    public Thickness SafeArea
    {
        get => GetValue(SafeAreaProperty);
        set => SetValue(SafeAreaProperty, value);
    }

    public Thickness SafeAreaTopAndSides
    {
        get => GetValue(SafeAreaTopAndSidesProperty);
        private set => SetValue(SafeAreaTopAndSidesProperty, value);
    }

    public Thickness SafeAreaBottomOnly
    {
        get => GetValue(SafeAreaBottomOnlyProperty);
        private set => SetValue(SafeAreaBottomOnlyProperty, value);
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property != SafeAreaProperty) return;

        var safeArea = SafeArea;
        SafeAreaTopAndSides = new Thickness(safeArea.Left, safeArea.Top, safeArea.Right, 0);
        SafeAreaBottomOnly = new Thickness(0, 0, 0, safeArea.Bottom);
        if (_diagnosticsPanel != null) _diagnosticsPanel.Margin = DiagnosticsMargin(safeArea);
    }

    /// <summary>
    /// Called by MainActivity when the back button is pressed. Returns true when the view consumed it (closed a dialog,
    /// the full-screen player, the search or a detail page), false when the app may close.
    /// </summary>
    public bool TryGoBack() => _viewModel?.TryNavigateBack() ?? false;

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);

        _isAttached = true;
        StartFrameProbe();
        SyncDiagnostics();

        _insets = TopLevel.GetTopLevel(this)?.InsetsManager;
        if (_insets == null) return;

        // From Android 15 on, every app is drawn behind the status bar and the navigation bar. Say so explicitly, so that
        // the safe area reported below includes the system bars and the layout keeps clear of them on every version.
        _insets.DisplayEdgeToEdge = true;
        SafeArea = _insets.SafeAreaPadding;
        _insets.SafeAreaChanged += OnSafeAreaChanged;

        // The insets are not always known yet on the first layout pass: read them again once the view is up.
        Dispatcher.UIThread.Post(() =>
        {
            if (_insets != null) SafeArea = _insets.SafeAreaPadding;
        }, DispatcherPriority.Loaded);
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        _isAttached = false;
        StopDiagnostics();
        StopFrameProbe();
        if (_insets != null) _insets.SafeAreaChanged -= OnSafeAreaChanged;
        _insets = null;
        base.OnDetachedFromVisualTree(e);
    }

    private static Thickness DiagnosticsMargin(Thickness safeArea) =>
        new(0, 0, 6, safeArea.Bottom + DiagnosticsBottomOffset);

    /// <summary>
    /// Starts watching the UI thread's frames: the layout pass of each frame is timed (from the frame's first callback to
    /// the end of its layout pass) and the rate of the frames is reported to <see cref="FrameMonitor"/>, which the automatic
    /// refresh rate of the Android head reads. The probe only runs while the user touches the screen and a few seconds after.
    /// </summary>
    private void StartFrameProbe()
    {
        if (_probe != null || TopLevel.GetTopLevel(this) is not { } topLevel) return;

        _probe = new UiFrameProbe(topLevel, ms => _layoutGraph?.Push(ms));
        LayoutUpdated += OnLayoutUpdated;
        AddHandler(PointerPressedEvent, _onPointerPressed, RoutingStrategies.Tunnel, handledEventsToo: true);
        AddHandler(PointerMovedEvent, _onPointerMoved, RoutingStrategies.Tunnel, handledEventsToo: true);
    }

    private void StopFrameProbe()
    {
        if (_probe == null) return;

        _probe.Stop();
        _probe = null;
        LayoutUpdated -= OnLayoutUpdated;
        RemoveHandler(PointerPressedEvent, _onPointerPressed);
        RemoveHandler(PointerMovedEvent, _onPointerMoved);
    }

    private void OnLayoutUpdated(object? sender, EventArgs e) => _probe?.OnLayoutUpdated();

    /// <summary>Runs for every pointer event: the frame probe starts, and the Android head asks for the high refresh rate.</summary>
    private void OnTouch()
    {
        _probe?.Touch();
        FrameMonitor.ReportTouch();
    }

    /// <summary>Shows or removes the statistics panel to match the setting (Settings > Performance statistics).</summary>
    private void SyncDiagnostics()
    {
        if (!Dispatcher.UIThread.CheckAccess())
        {
            Dispatcher.UIThread.Post(SyncDiagnostics);
            return;
        }

        if (_isAttached && _viewModel?.ShowPerformanceStats == true) StartDiagnostics();
        else StopDiagnostics();
    }

    /// <summary>
    /// Shows the statistics panel, low on the screen above the mini player, where it is not under the status bar (Avalonia's
    /// own frame graphs are not used: they are drawn in the top right corner, under the status bar, and cannot be moved).
    /// It is a tuning tool and off until the user turns it on in the settings. It has three graphs (layout of the UI thread, how late
    /// the renderer is done, the display's tick interval - bars are green well inside the frame time of the refresh rate
    /// the app asks for, amber up to it, red beyond) and a card that tells what they do not: how many frames the UI thread
    /// really produced while a list scrolls, the longest gap between two of them and how many gaps of 40 ms or more (hitches)
    /// there were (with a note when a garbage collection happened during the last one), how often the garbage collector ran
    /// in the last second (generation 0 / 1 / 2), the frame rate of the last fling, and the refresh rate vote with the
    /// state of the performance hint. Two chips: choose how the refresh rate is chosen (tap to
    /// go through automatic and each rate of the display), and which renderer the next start uses ("GPU" or "CPU" -
    /// software rendering cannot keep a scrolling list smooth; Debug builds compile the code while it runs). Together this
    /// tells whether a hitch comes from drawing, from the garbage collector or from the UI thread itself.
    /// </summary>
    private void StartDiagnostics()
    {
        if (_diagnosticsPanel != null || Content is not Panel root) return;

        // Graphs: layout and render are fine up to half the frame time (they run one after the other, so together they
        // must fit in one frame); the tick interval is fine up to a third more than the frame time.
        var layoutBlock = MakeGraphBlock(0.5, 1.0, out var layoutTitle, out var layoutGraph);
        var renderBlock = MakeGraphBlock(0.5, 1.0, out var renderTitle, out var renderGraph);
        var intervalBlock = MakeGraphBlock(1.3, 2.0, out var intervalTitle, out var intervalGraph);
        _layoutTitle = layoutTitle;
        _layoutGraph = layoutGraph;
        _renderTitle = renderTitle;
        _renderGraph = renderGraph;
        _intervalTitle = intervalTitle;
        _intervalGraph = intervalGraph;

        _summaryLabel = new TextBlock
        {
            FontSize = 11,
            Foreground = Brushes.White,
            IsHitTestVisible = false,
            TextWrapping = TextWrapping.Wrap,
        };

        var graphsCard = new Border
        {
            Background = CardBackground,
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(8, 6),
            IsHitTestVisible = false,
            Child = new StackPanel { Spacing = 6, Children = { layoutBlock, renderBlock, intervalBlock } },
        };
        var summaryCard = new Border
        {
            Background = CardBackground,
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(8, 6),
            IsHitTestVisible = false,
            Child = _summaryLabel,
        };
        var statsCards = new StackPanel { Spacing = 4, Children = { graphsCard, summaryCard } };

        // The chips are the only part that takes touches; everything else lets them through to the list underneath.
        var refreshChip = MakeChip(OnRefreshChipPressed, out var refreshText);
        var rendererChip = MakeChip(OnRendererChipPressed, out var rendererText);
        _refreshChip = refreshText;
        _rendererChip = rendererText;

        _diagnosticsPanel = new StackPanel
        {
            Width = 256,
            Spacing = 4,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = DiagnosticsMargin(SafeArea),
            Children = { statsCards, refreshChip, rendererChip },
        };
        root.Children.Add(_diagnosticsPanel);

        FrameMonitor.Frame += OnRenderFrame;
        FrameMonitor.UiFrame += OnUiFrame;
        FrameMonitor.Start();

        _lastGc0 = GC.CollectionCount(0);
        _lastGc1 = GC.CollectionCount(1);
        _lastGc2 = GC.CollectionCount(2);
        _lastUiAlloc = UiThreadAllocatedBytes();
        _lastRenderAlloc = FrameMonitor.RenderThreadAllocatedBytes;
        _lastTotalAlloc = TotalAllocatedBytes();
        _lastBound = TrackRowView.Bound;
        _lastCreated = TrackRowView.Created;

        // A hitch is a gap of 40 ms or more between two frames of a scroll (see OnUiFrame). It is found from the frames
        // themselves: a timer that checks how late it runs would be work for the UI thread and, on Android, a Java object
        // for the garbage collector to look at on every tick - the thing being measured.
        _uptime.Restart();
        _lastUpdateSeconds = 0;
        _gcAtLastFrame = GC.CollectionCount(0);

        _diagnosticsTimer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => UpdateDiagnostics());
        _diagnosticsTimer.Start();

        // The graphs are drawn a few times a second, not on every sample.
        _graphTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(250), DispatcherPriority.Background, (_, _) =>
        {
            _layoutGraph?.InvalidateVisual();
            _renderGraph?.InvalidateVisual();
            _intervalGraph?.InvalidateVisual();
        });
        _graphTimer.Start();

        UpdateDiagnostics();
    }

    private static StackPanel MakeGraphBlock(double goodFactor, double warnFactor, out TextBlock title, out FrameGraph graph)
    {
        title = new TextBlock { FontSize = 11, Foreground = Brushes.White, IsHitTestVisible = false };
        graph = new FrameGraph(goodFactor, warnFactor) { HorizontalAlignment = HorizontalAlignment.Left };
        return new StackPanel { Spacing = 2, Children = { title, graph } };
    }

    /// <summary>A touchable label: returns the border that takes the touch and, through <paramref name="text"/>, the text inside.</summary>
    private static Border MakeChip(EventHandler<PointerPressedEventArgs> pressed, out TextBlock text)
    {
        text = new TextBlock
        {
            FontSize = 11,
            Foreground = Brushes.White,
            IsHitTestVisible = false,
            TextWrapping = TextWrapping.Wrap,
        };

        var chip = new Border
        {
            Background = ChipBackground,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(9, 6),
            HorizontalAlignment = HorizontalAlignment.Right,
            Child = text,
        };
        chip.PointerPressed += pressed;
        return chip;
    }

    /// <summary>Runs on the render thread for every frame tick: how long the display took since the last one, and how late the renderer was done.</summary>
    private void OnRenderFrame(double intervalMs, double handledMs)
    {
        if (intervalMs > 0) _intervalGraph?.Push(intervalMs);
        _renderGraph?.Push(handledMs);
    }

    /// <summary>Runs on the UI thread for every frame of a scroll: the time since the previous one.</summary>
    private void OnUiFrame(double intervalMs)
    {
        if (intervalMs <= 0) return;

        // A collection since the previous frame is noted next to a long gap, because that is the other thing that
        // freezes a frame.
        var gc = GC.CollectionCount(0);
        var collected = gc != _gcAtLastFrame;
        _gcAtLastFrame = gc;

        if (intervalMs >= 40)
        {
            _hitches++;
            _lastHitch = $"{intervalMs:0} ms at {_uptime.Elapsed.TotalSeconds:0} s{(collected ? " (GC)" : "")}";
        }

        if (intervalMs > 1000) return; // coming back from a rest, not a frame

        if (intervalMs > _worstGapEverMs) _worstGapEverMs = intervalMs;
        if (intervalMs > 250) return; // a hitch, but not a rate

        _uiFrames++;
        _uiSumMs += intervalMs;
        if (intervalMs > _uiWorstMs) _uiWorstMs = intervalMs;
    }

    /// <summary>What the calling thread has allocated so far in bytes; 0 when the runtime cannot say.</summary>
    private static long UiThreadAllocatedBytes()
    {
        try
        {
            return GC.GetAllocatedBytesForCurrentThread();
        }
        catch (Exception)
        {
            return 0;
        }
    }

    /// <summary>What all threads have allocated so far in bytes; 0 when the runtime cannot say.</summary>
    private static long TotalAllocatedBytes()
    {
        try
        {
            return GC.GetTotalAllocatedBytes(false);
        }
        catch (Exception)
        {
            return 0;
        }
    }

    private static string PerSecond(long bytesNow, long bytesBefore, double seconds)
    {
        if (bytesNow <= 0 || bytesBefore <= 0 || seconds <= 0.1) return "n/a";
        return $"{(bytesNow - bytesBefore) / (1024.0 * 1024.0) / seconds:0.0}";
    }

    private void UpdateDiagnostics()
    {
        if (_summaryLabel == null) return;

        var gc0 = GC.CollectionCount(0);
        var gc1 = GC.CollectionCount(1);
        var gc2 = GC.CollectionCount(2);

        var renderer = RenderingInfo.IsGpuRendering() switch
        {
            true => "GPU",
            false => "CPU",
            null => "?",
        };
#if DEBUG
        const string build = "Debug";
#else
        const string build = "Release";
#endif
        var fling = SmoothFling.LastFlingFrames > 0
            ? $"{SmoothFling.LastFlingFps:0} fps ({SmoothFling.LastFlingFrames} frames)"
            : "none yet";

        // How fast the display really ticks (one frame clock tick per vsync): if it is well below the rate of the screen
        // while a list scrolls, the phone has lowered the refresh rate and no amount of drawing speed will help.
        var (vsyncHz, longestGapMs, ticks) = FrameMonitor.TakeSnapshot();
        var performance = RenderingInfo.PerformanceStatus?.Invoke();
        var windowStatus = RenderingInfo.WindowStatus?.Invoke();

        // What the frames of the last second cost, in the words of the graphs.
        if (_layoutTitle != null && _layoutGraph != null)
        {
            var (average, worst, _) = _layoutGraph.TakeStats();
            _layoutTitle.Text = $"Layout (UI thread): avg {average:0.0}, max {worst:0} ms";
        }

        if (_renderTitle != null && _renderGraph != null)
        {
            var (average, worst, _) = _renderGraph.TakeStats();
            _renderTitle.Text = $"Render (after vsync): avg {average:0.0}, max {worst:0} ms";
        }

        if (_intervalTitle != null && _intervalGraph != null)
        {
            _intervalGraph.TakeStats();
            _intervalTitle.Text = ticks > 0
                ? $"Display ticks: {vsyncHz:0} Hz, gap max {longestGapMs:0} ms"
                : "Display ticks: none (no frames)";
        }

        var uiLine = _uiFrames > 0 && _uiSumMs > 0
            ? $"UI frames while scrolling: {_uiFrames / (_uiSumMs / 1000.0):0} fps (longest {_uiWorstMs:0} ms)"
            : "UI frames while scrolling: scroll a list";
        _uiFrames = 0;
        _uiSumMs = 0;
        _uiWorstMs = 0;

        var now = _uptime.Elapsed.TotalSeconds;
        if (_notice != null && now > _noticeUntilSeconds) _notice = null;

        if (_rendererChip != null)
        {
            _rendererChip.Text = _notice ??
                $"{renderer} {RenderingInfo.Backend} - {build} - {RuntimeInformation.ProcessArchitecture}  [tap: switch renderer]";
        }

        if (_refreshChip != null)
        {
            _refreshChip.Text = RenderingInfo.RefreshModeLabel?.Invoke() ?? "Refresh: n/a";
        }

        // Who produces the garbage: bytes allocated per second by the UI thread (this one), by the render thread and by
        // everything together (the rest being threads of the pool, the image decoders, the player and so on), and how
        // many rows of the track lists were given a new track in that time, which is what a scroll is made of.
        var uiAlloc = UiThreadAllocatedBytes();
        var renderAlloc = FrameMonitor.RenderThreadAllocatedBytes;
        var totalAlloc = TotalAllocatedBytes();
        var bound = TrackRowView.Bound;
        var created = TrackRowView.Created;
        var seconds = now - _lastUpdateSeconds;
        var allocLine =
            $"Allocated MB/s: UI {PerSecond(uiAlloc, _lastUiAlloc, seconds)}, render {PerSecond(renderAlloc, _lastRenderAlloc, seconds)}, all {PerSecond(totalAlloc, _lastTotalAlloc, seconds)}\n" +
            $"Track rows per s: bound {(seconds > 0.1 ? (bound - _lastBound) / seconds : 0):0}, created {created - _lastCreated} (total {created})\n";

        var gcParams = System.Environment.GetEnvironmentVariable("MONO_GC_PARAMS");
        _summaryLabel.Text =
            uiLine + "\n" +
            $"Hitches (40+ ms gaps): {_hitches}, last {_lastHitch}\n" +
            $"Longest gap ever: {_worstGapEverMs:0} ms\n" +
            $"GC {gc0 - _lastGc0}/{gc1 - _lastGc1}/{gc2 - _lastGc2} per s - {GC.GetTotalMemory(false) / (1024 * 1024)} MB - params: {(string.IsNullOrEmpty(gcParams) ? "default" : gcParams)}\n" +
            allocLine +
            $"Last fling: {fling}" +
            (performance != null ? "\n" + performance : "") +
            (windowStatus != null ? "\n" + windowStatus : "") +
            $"\nSafe area (dip): {SafeArea.Left:0.#}, {SafeArea.Top:0.#}, {SafeArea.Right:0.#}, {SafeArea.Bottom:0.#}";

        _lastGc0 = gc0;
        _lastGc1 = gc1;
        _lastGc2 = gc2;
        _lastUiAlloc = uiAlloc;
        _lastRenderAlloc = renderAlloc;
        _lastTotalAlloc = totalAlloc;
        _lastBound = bound;
        _lastCreated = created;
        _lastUpdateSeconds = now;
    }

    private void StopDiagnostics()
    {
        _diagnosticsTimer?.Stop();
        _diagnosticsTimer = null;
        _graphTimer?.Stop();
        _graphTimer = null;

        if (_diagnosticsPanel == null) return;

        FrameMonitor.Frame -= OnRenderFrame;
        FrameMonitor.UiFrame -= OnUiFrame;

        if (Content is Panel root) root.Children.Remove(_diagnosticsPanel);
        _diagnosticsPanel = null;
        _rendererChip = null;
        _refreshChip = null;
        _summaryLabel = null;
        _layoutTitle = _renderTitle = _intervalTitle = null;
        _layoutGraph = _renderGraph = _intervalGraph = null;
    }

    private void OnRendererChipPressed(object? sender, PointerPressedEventArgs e)
    {
        e.Handled = true;
        ShowNotice(RenderingInfo.CycleNextRenderer?.Invoke() ?? "This build cannot switch the renderer");
    }

    private void OnRefreshChipPressed(object? sender, PointerPressedEventArgs e)
    {
        e.Handled = true;
        ShowNotice(RenderingInfo.CycleRefreshMode?.Invoke() ?? "This build cannot choose the refresh rate");
    }

    /// <summary>Shows a message in the renderer chip for a few seconds.</summary>
    private void ShowNotice(string message)
    {
        _notice = message;
        _noticeUntilSeconds = _uptime.Elapsed.TotalSeconds + 8;
        UpdateDiagnostics();
    }

    private void OnSafeAreaChanged(object? sender, SafeAreaChangedArgs e) => SafeArea = e.SafeAreaPadding;

    private void OnDataContextChanged(object? sender, EventArgs e)
    {
        if (_viewModel != null) _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
        _viewModel = DataContext as MainViewModel;
        if (_viewModel != null) _viewModel.PropertyChanged += OnViewModelPropertyChanged;
        SyncDiagnostics();
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_viewModel == null) return;

        // The statistics panel follows its switch in the settings.
        if (e.PropertyName == nameof(MainViewModel.ShowPerformanceStats))
        {
            SyncDiagnostics();
        }
        // Open the keyboard together with the search field.
        else if (e.PropertyName == nameof(MainViewModel.IsSearchOpen) && _viewModel.IsSearchOpen)
        {
            Dispatcher.UIThread.Post(() => SearchBox.Focus(), DispatcherPriority.Input);
        }
        // Show the playing entry when the queue tab opens.
        else if (e.PropertyName == nameof(MainViewModel.NowPlayingTab) && _viewModel.NowPlayingTab == 1)
        {
            Dispatcher.UIThread.Post(ScrollQueueToCurrent, DispatcherPriority.Loaded);
        }
    }

    private void ScrollQueueToCurrent()
    {
        var player = _viewModel?.Player;
        if (player == null || player.CurrentQueueIndex < 0 || player.CurrentQueueIndex >= player.QueueItems.Count) return;
        QueueList.ScrollIntoView(player.CurrentQueueIndex);
    }
}
