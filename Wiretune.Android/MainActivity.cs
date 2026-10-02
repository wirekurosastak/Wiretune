using Android.App;
using Android.Content.PM;
using Android.OS;
using Avalonia;
using Avalonia.Android;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI;
using Wiretune.UI.ViewModels;
using Wiretune.UI.Views;

namespace Wiretune.Android;

[Activity(
    Label = "Wiretune",
    Theme = "@style/Theme.Wiretune",
    Icon = "@drawable/icon",
    MainLauncher = true,
    ConfigurationChanges = ConfigChanges.Orientation | ConfigChanges.ScreenSize | ConfigChanges.UiMode)]
public class MainActivity : AvaloniaMainActivity<App>
{
    // How long the service outlives a stopped player, so the gap between two tracks (or a quick skip) does not tear the
    // foreground service down and then have to start it again - which Android refuses once the app is in the background.
    private const int ServiceStopDelayMs = 10_000;

    private System.ComponentModel.PropertyChangedEventHandler? _playbackStateHandler;
    private Handler? _handler;
    private Java.Lang.Runnable? _pendingStop;
    private DisplayPerformance? _performance;
    private Wiretune.UI.Services.ThemeService? _theme;
    private System.ComponentModel.PropertyChangedEventHandler? _themeHandler;

    protected override AppBuilder CustomizeAppBuilder(AppBuilder builder)
    {
        // ffplay does not exist on Android; play through the platform MediaPlayer instead.
        App.AudioDriverFactory = () => new AndroidAudioDriver();

        // Environment.SpecialFolder.ApplicationData is not a valid writable path on Android.
        // Point AppPaths.GetDataDirectory() at the app's private internal storage directory instead,
        // so the SQLite database can be created and opened correctly.
        var dataDir = global::Android.App.Application.Context.FilesDir?.AbsolutePath;
        if (!string.IsNullOrEmpty(dataDir))
        {
            System.Environment.SetEnvironmentVariable(
                AppPaths.DataDirectoryEnvironmentVariable,
                dataDir);
        }

        var configured = base.CustomizeAppBuilder(builder)
            .WithInterFont()
            // Skia keeps the textures and offscreen buffers of a frame in a GPU cache that defaults to ~28 MB - less than
            // three full-screen buffers of a modern phone. A scrolling list then evicts and recreates them on every frame,
            // which shows up as long, irregular frame times. 128 MB is a small price for steady ones.
            .With(new SkiaOptions { MaxGpuResourceSizeBytes = 128L * 1024 * 1024 });

        // Normally Avalonia draws with OpenGL ES and falls back to the CPU. The label in the top right corner of the app
        // can ask for Vulkan or for the CPU renderer instead, for the next start only (see SwitchRenderer).
        return TakeRequestedRenderingModes() is { } modes
            ? configured.With(new AndroidPlatformOptions { RenderingMode = modes })
            : configured;
    }

    private const string RendererRequestFile = "next-renderer.txt";

    private static string? RendererRequestPath()
    {
        var dir = global::Android.App.Application.Context.FilesDir?.AbsolutePath;
        return string.IsNullOrEmpty(dir) ? null : System.IO.Path.Combine(dir, RendererRequestFile);
    }

    /// <summary>
    /// The renderers the user asked for with the label, or null for the normal ones. The request is deleted as it is read,
    /// so it applies to one start only: if the chosen renderer shows nothing, opening the app again brings back the normal one.
    /// </summary>
    private static AndroidRenderingMode[]? TakeRequestedRenderingModes()
    {
        try
        {
            var path = RendererRequestPath();
            if (path == null || !System.IO.File.Exists(path)) return null;

            var request = System.IO.File.ReadAllText(path).Trim();
            System.IO.File.Delete(path);

            return request switch
            {
                "vulkan" => new[] { AndroidRenderingMode.Vulkan, AndroidRenderingMode.Egl, AndroidRenderingMode.Software },
                "software" => new[] { AndroidRenderingMode.Software },
                _ => null,
            };
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>
    /// Behind the renderer label (see AndroidMainView): OpenGL -> Vulkan -> software -> OpenGL. The renderer is chosen when
    /// the process starts, so this stores the request and closes the app; opening it again uses the new renderer. Comparing
    /// the three tells whether the lag is in the GPU path (the numbers differ) or in the app's own code (they do not).
    /// </summary>
    private string SwitchRenderer()
    {
        var path = RendererRequestPath();
        if (path == null) return "Cannot switch the renderer: no storage";

        try
        {
            var next = Wiretune.UI.Services.RenderingInfo.Backend switch
            {
                "Egl" => "vulkan",
                "Vulkan" => "software",
                _ => "egl",
            };

            if (next == "egl")
            {
                if (System.IO.File.Exists(path)) System.IO.File.Delete(path);
            }
            else
            {
                System.IO.File.WriteAllText(path, next);
            }

            _handler ??= new Handler(Looper.MainLooper!);
            _handler.PostDelayed(() =>
            {
                FinishAndRemoveTask();
                Process.KillProcess(Process.MyPid());
            }, 1800);

            return $"Switching to {next.ToUpperInvariant()}: the app closes now - open it again";
        }
        catch (Exception e)
        {
            return "Could not switch the renderer: " + e.Message;
        }
    }

    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);
        ConfigureSystemBars();
        LetTheContentReachUnderTheBars();
        ReapplySystemBarsLater();
        Wiretune.UI.Services.RenderingInfo.CycleNextRenderer = SwitchRenderer;
        Wiretune.UI.Services.RenderingInfo.WindowStatus = DescribeWindow;
        ReportRenderer();

        // Refresh rate and CPU hints, so that the phone treats a scrolling list like a native app's (see DisplayPerformance).
        _performance = new DisplayPerformance(this);
        _performance.Start();
        Wiretune.UI.Services.RenderingInfo.PerformanceStatus = () => _performance?.Status ?? "";
        Wiretune.UI.Services.RenderingInfo.RefreshModeLabel = () => _performance?.ModeLabel ?? "";
        Wiretune.UI.Services.RenderingInfo.CycleRefreshMode = () => _performance?.CycleMode() ?? "No refresh rate control";
        OnBackPressedDispatcher.AddCallback(this, new BackPressedCallback(this));
        RequestRuntimePermissions();
        HookPlaybackService();
        HookSystemBarIcons();
    }

    /// <summary>
    /// Lets the app draw behind the status bar and the navigation bar: the window is not fitted between them, both bars are
    /// transparent (the theme says so too, see Resources/values/styles.xml) and the display cutout belongs to the window.
    /// The layout of the app keeps clear of the bars (AndroidMainView reads the insets), so nothing clickable or readable
    /// is drawn under them - only the background, which flows on beneath them instead of stopping at their edge.
    /// </summary>
    private void ConfigureSystemBars()
    {
        var window = Window;
        if (window == null) return;

        AndroidX.Core.View.WindowCompat.SetDecorFitsSystemWindows(window, false);

        // Avalonia asks for "edge to edge" (AndroidMainView) and for that it switches on the old translucent-bar flags, which
        // make the system lay a 40 % black scrim over both bars: a dark band on the dark theme and a grey one on the light
        // theme. The bars are meant to be see-through, so the scrim flags go and the window paints the (transparent) bar
        // backgrounds itself.
        window.ClearFlags(
            global::Android.Views.WindowManagerFlags.TranslucentStatus |
            global::Android.Views.WindowManagerFlags.TranslucentNavigation);
        window.AddFlags(global::Android.Views.WindowManagerFlags.DrawsSystemBarBackgrounds);

#pragma warning disable CA1422 // Obsoleted on Android 15 and later, where both bars are transparent anyway; before that this is what makes them so.
        window.SetStatusBarColor(global::Android.Graphics.Color.Transparent);
        window.SetNavigationBarColor(global::Android.Graphics.Color.Transparent);
#pragma warning restore CA1422

        if (OperatingSystem.IsAndroidVersionAtLeast(28) && window.Attributes is { } attributes)
        {
            attributes.LayoutInDisplayCutoutMode = global::Android.Views.LayoutInDisplayCutoutMode.ShortEdges;
            window.Attributes = attributes;
        }
    }

    /// <summary>
    /// Avalonia switches parts of this on again when its view becomes visible (and AppCompat may touch the window while the
    /// activity starts), so the setup is repeated a little later as well.
    /// </summary>
    private void ReapplySystemBarsLater()
    {
        _handler ??= new Handler(Looper.MainLooper!);
        foreach (var delayMs in new long[] { 300, 1200 })
        {
            _handler.PostDelayed(() =>
            {
                if (IsFinishing || IsDestroyed) return;
                ConfigureSystemBars();
                LetTheContentReachUnderTheBars();
            }, delayMs);
        }
    }

    /// <summary>
    /// Makes sure that no layout around the app's view fits it between the system bars. Avalonia's activity is an
    /// AppCompatActivity, and AppCompat wraps the content in layouts with "fitsSystemWindows" set: on Android versions that
    /// do not force edge-to-edge drawing they pad themselves by the height of the status bar and of the navigation bar, so the
    /// app's view would start below the one and end above the other. They are told to stop fitting, all the way up to the
    /// window. The app keeps its content clear of the bars itself (AndroidMainView reads the insets from Avalonia), so only
    /// the background reaches under them.
    /// </summary>
    private void LetTheContentReachUnderTheBars()
    {
        var decor = Window?.DecorView as global::Android.Views.ViewGroup;
        if (decor == null) return;

        global::Android.Views.View? view = FindViewById(global::Android.Resource.Id.Content);
        while (view != null && !ReferenceEquals(view, decor))
        {
            if (view.FitsSystemWindows)
            {
                view.SetFitsSystemWindows(false);
                view.SetPadding(0, 0, 0, 0);
            }

            view = view.Parent as global::Android.Views.View;
        }

        if (decor.FitsSystemWindows) decor.SetFitsSystemWindows(false);
        decor.RequestApplyInsets();
    }

    private static AvaloniaView? FindAvaloniaView(global::Android.Views.View? view, int depth)
    {
        if (view is AvaloniaView found) return found;
        if (depth > 6 || view is not global::Android.Views.ViewGroup group) return null;

        for (var i = 0; i < group.ChildCount; i++)
        {
            if (FindAvaloniaView(group.GetChildAt(i), depth + 1) is { } result) return result;
        }

        return null;
    }

    /// <summary>
    /// Where the window and the app's view really are, in one block of text for the statistics panel (Settings): the size
    /// and position of the window, of the app's view and of every layout between them, and the height of the system bars.
    /// If the bars are ever black again, this shows what holds the view back.
    /// </summary>
    private string DescribeWindow()
    {
        try
        {
            var window = Window;
            if (window?.DecorView is not { } decor) return "Window: not ready";

            var flags = window.Attributes is { } attributes ? unchecked((int)attributes.Flags) : 0;
            var cutout = OperatingSystem.IsAndroidVersionAtLeast(28) && window.Attributes is { } cutoutAttributes
                ? (int)cutoutAttributes.LayoutInDisplayCutoutMode
                : -1;

            var text = new System.Text.StringBuilder();
            text.Append($"Window: API {(int)Build.VERSION.SdkInt}, target {ApplicationInfo?.TargetSdkVersion ?? 0}, cutout {cutout}, flags 0x{flags:X}");
            text.Append($"\nBars: status {SystemDimension("status_bar_height")} px, navigation {SystemDimension("navigation_bar_height")} px");
            text.Append("\nDecor: ").Append(DescribeView(decor));

            if (FindAvaloniaView(decor, 0) is { } host)
            {
                text.Append("\nAvalonia: ").Append(DescribeView(host));
                for (var parent = host.Parent as global::Android.Views.View;
                     parent != null && !ReferenceEquals(parent, decor);
                     parent = parent.Parent as global::Android.Views.View)
                {
                    text.Append("\n < ").Append(DescribeView(parent));
                }
            }
            else
            {
                text.Append("\nAvalonia: view not found");
            }

            return text.ToString();
        }
        catch (Exception e)
        {
            return "Window: " + e.Message;
        }
    }

    private int SystemDimension(string name)
    {
        var resources = Resources;
        if (resources == null) return 0;

        var id = resources.GetIdentifier(name, "dimen", "android");
        return id > 0 ? resources.GetDimensionPixelSize(id) : 0;
    }

    private static string DescribeView(global::Android.Views.View view)
    {
        var onScreen = new int[2];
        view.GetLocationOnScreen(onScreen);

        var name = view.Class.SimpleName;
        return $"{name} {view.Width}x{view.Height} @{onScreen[0]},{onScreen[1]} pad {view.PaddingLeft},{view.PaddingTop},{view.PaddingRight},{view.PaddingBottom}" +
               (view.FitsSystemWindows ? " fits" : "");
    }

    /// <summary>
    /// The icons of the system bars are dark on the light theme and light on the dark one. The theme of the app is its own
    /// choice (it does not follow the system), so the icons follow it: otherwise the clock and the battery would turn
    /// invisible on a light background.
    /// </summary>
    private void HookSystemBarIcons()
    {
        Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            var theme = App.MainVm?.Theme;
            if (theme == null) return;

            _theme = theme;
            _themeHandler = (_, e) =>
            {
                if (e.PropertyName == nameof(theme.IsLight)) ApplySystemBarIcons(theme.IsLight);
            };
            theme.PropertyChanged += _themeHandler;
            ApplySystemBarIcons(theme.IsLight);
        }, Avalonia.Threading.DispatcherPriority.Loaded);
    }

    private void ApplySystemBarIcons(bool lightTheme)
    {
        var window = Window;
        if (window?.DecorView == null) return;

        var controller = AndroidX.Core.View.WindowCompat.GetInsetsController(window, window.DecorView);
        if (controller == null) return;

        controller.AppearanceLightStatusBars = lightTheme;
        controller.AppearanceLightNavigationBars = lightTheme;
    }

    protected override void OnResume()
    {
        base.OnResume();
        ConfigureSystemBars();
        LetTheContentReachUnderTheBars();
        _performance?.Start();
    }

    /// <summary>
    /// Avalonia draws with the GPU (EGL) when it can and quietly falls back to the CPU ("software") renderer when it
    /// cannot - and the CPU renderer cannot keep a full-screen scrolling list above 20-30 fps. So this says which one is
    /// in use: in the log (tag "Wiretune") and, when it is the slow one, as a message on the screen.
    /// </summary>
    private void ReportRenderer()
    {
        var gpu = Wiretune.UI.Services.RenderingInfo.IsGpuRendering();
        if (gpu == true)
        {
            global::Android.Util.Log.Info("Wiretune", "Rendering with the GPU");
            return;
        }

        if (gpu == null)
        {
            global::Android.Util.Log.Warn("Wiretune", "Could not tell whether the GPU or the software renderer is in use");
            return;
        }

        global::Android.Util.Log.Warn("Wiretune", "GPU rendering is not available: Avalonia fell back to the software (CPU) renderer");
        global::Android.Widget.Toast.MakeText(
            this,
            "Wiretune: GPU rendering is unavailable on this device, using the slow software renderer",
            global::Android.Widget.ToastLength.Long)?.Show();
    }

    /// <summary>
    /// Asks for the notification permission (Android 13+), which the playback notification needs. Wiretune plays
    /// server streams only, so it needs no access to the device's media files.
    /// </summary>
    private void RequestRuntimePermissions()
    {
        if (!OperatingSystem.IsAndroidVersionAtLeast(33)) return;

        const string notifications = "android.permission.POST_NOTIFICATIONS";
        if (CheckSelfPermission(notifications) != Permission.Granted)
        {
            RequestPermissions(new[] { notifications }, 0);
        }
    }

    /// <summary>Starts/stops the foreground service in sync with audio engine state.</summary>
    private void HookPlaybackService()
    {
        Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            var vm = App.MainVm;
            if (vm == null) return;

            _handler ??= new Handler(Looper.MainLooper!);
            _playbackStateHandler = (_, e) =>
            {
                if (e.PropertyName != nameof(vm.Player.PlaybackState)) return;

                switch (vm.Player.PlaybackState)
                {
                    case PlaybackState.Playing or PlaybackState.Buffering:
                        CancelPendingStop();
                        PlaybackService.StartPlayback(this);
                        break;
                    case PlaybackState.Paused:
                        CancelPendingStop(); // the notification stays while paused; it goes when playback is stopped
                        break;
                    case PlaybackState.Stopped or PlaybackState.Error:
                        SchedulePendingStop();
                        break;
                }
            };
            vm.Player.PropertyChanged += _playbackStateHandler;
        }, Avalonia.Threading.DispatcherPriority.Loaded);
    }

    private void SchedulePendingStop()
    {
        CancelPendingStop();
        _pendingStop = new Java.Lang.Runnable(() => PlaybackService.StopPlayback(this));
        _handler?.PostDelayed(_pendingStop, ServiceStopDelayMs);
    }

    private void CancelPendingStop()
    {
        if (_pendingStop != null) _handler?.RemoveCallbacks(_pendingStop);
        _pendingStop = null;
    }

    protected override void OnDestroy()
    {
        // The view model outlives the activity; don't leave a handler behind that keeps this activity alive.
        if (_playbackStateHandler != null && App.MainVm is { } vm) vm.Player.PropertyChanged -= _playbackStateHandler;
        _playbackStateHandler = null;

        if (_theme != null && _themeHandler != null) _theme.PropertyChanged -= _themeHandler;
        _theme = null;
        _themeHandler = null;

        // The renderer label must not keep this activity alive.
        if (ReferenceEquals(Wiretune.UI.Services.RenderingInfo.CycleNextRenderer?.Target, this))
        {
            Wiretune.UI.Services.RenderingInfo.CycleNextRenderer = null;
        }

        Wiretune.UI.Services.RenderingInfo.WindowStatus = null;
        Wiretune.UI.Services.RenderingInfo.PerformanceStatus = null;
        Wiretune.UI.Services.RenderingInfo.RefreshModeLabel = null;
        Wiretune.UI.Services.RenderingInfo.CycleRefreshMode = null;
        _performance?.Dispose();
        _performance = null;

        CancelPendingStop();
        PlaybackService.StopPlayback(this);
        base.OnDestroy();
    }

    /// <summary>
    /// The system back gesture or button, on Android 12 and below (and on later versions while predictive back is off).
    /// The view model gets the first chance to close a dialog, the full-screen player, a detail page or to return to the
    /// previous tab; only when it has nothing left to go back to does the system close the app.
    /// </summary>
    public override void OnBackPressed()
    {
        if (TryNavigateBackInApp()) return;

#pragma warning disable CA1422 // OnBackPressed is obsoleted on API 33+; this path is only taken where the system still calls it.
        base.OnBackPressed();
#pragma warning restore CA1422
    }

    /// <summary>
    /// The same thing for Android 13+ with predictive back, which is the default for apps that target Android 16 and later:
    /// there the system never calls <see cref="OnBackPressed"/> and reports the gesture to the AndroidX back dispatcher
    /// instead, so without this callback the back gesture would always leave the app.
    /// </summary>
    private void OnBackGesture(AndroidX.Activity.OnBackPressedCallback callback)
    {
        if (TryNavigateBackInApp()) return;

        // Nothing is left to close inside the app: step aside for a moment so that the dispatcher runs the system's own
        // back behaviour (leaving the app).
        callback.Enabled = false;
        try { OnBackPressedDispatcher.OnBackPressed(); }
        finally { callback.Enabled = true; }
    }

    private static bool TryNavigateBackInApp() => App.MainVm?.TryNavigateBack() ?? false;

    private sealed class BackPressedCallback : AndroidX.Activity.OnBackPressedCallback
    {
        private readonly MainActivity _activity;

        public BackPressedCallback(MainActivity activity) : base(true)
        {
            _activity = activity;
        }

        public override void HandleOnBackPressed() => _activity.OnBackGesture(this);
    }
}

