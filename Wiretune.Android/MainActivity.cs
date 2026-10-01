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
    Theme = "@style/Theme.AppCompat.NoActionBar",
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

        return base.CustomizeAppBuilder(builder)
            .WithInterFont();
    }

    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);
        RequestRuntimePermissions();
        HookPlaybackService();
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

        CancelPendingStop();
        PlaybackService.StopPlayback(this);
        base.OnDestroy();
    }

    /// <summary>
    /// On Android 12 and below, intercept the hardware back button.
    /// On Android 13+, this is handled via OnBackInvokedCallback registered in Avalonia.
    /// We override here to give the Avalonia view a first chance to handle navigation
    /// (e.g. closing the Now Playing sheet) before falling back to the default exit behavior.
    /// </summary>
    public override void OnBackPressed()
    {
        // Ask the Avalonia view to handle the back gesture first.
        // AndroidMainView exposes a TryGoBack() helper that closes overlays.
        if (App.MainVm != null)
        {
            var view = (Avalonia.Application.Current?.ApplicationLifetime as
                Avalonia.Controls.ApplicationLifetimes.ISingleViewApplicationLifetime)?.MainView as AndroidMainView;
            if (view != null && view.TryGoBack())
                return;
        }

#pragma warning disable CA1422 // OnBackPressed is obsoleted on API 33+; the Avalonia host handles OnBackInvoked there.
        base.OnBackPressed();
#pragma warning restore CA1422
    }
}

