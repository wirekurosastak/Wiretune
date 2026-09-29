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

    /// <summary>Requests storage and notification permissions at runtime.</summary>
    private void RequestRuntimePermissions()
    {
        if (Build.VERSION.SdkInt >= BuildVersionCodes.Tiramisu)
        {
            // READ_MEDIA_AUDIO (replaces READ_EXTERNAL_STORAGE on API 33+)
            // POST_NOTIFICATIONS required to show the playback notification on API 33+
            RequestPermissions(new[]
            {
                "android.permission.READ_MEDIA_AUDIO",
                "android.permission.POST_NOTIFICATIONS"
            }, 0);
        }
    }

    /// <summary>Starts/stops the foreground service in sync with audio engine state.</summary>
    private void HookPlaybackService()
    {
        Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            var vm = App.MainVm;
            if (vm == null) return;

            // Push the real status bar height to the view spacer.
            if ((Avalonia.Application.Current?.ApplicationLifetime as
                Avalonia.Controls.ApplicationLifetimes.ISingleViewApplicationLifetime)?.MainView is AndroidMainView view)
            {
                ApplyStatusBarInset(view);
            }

            vm.Player.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName != nameof(vm.Player.PlaybackState)) return;
                if (vm.Player.PlaybackState == PlaybackState.Playing)
                    PlaybackService.StartPlayback(this);
                else if (vm.Player.PlaybackState is PlaybackState.Stopped or PlaybackState.Error)
                    PlaybackService.StopPlayback(this);
            };
        }, Avalonia.Threading.DispatcherPriority.Loaded);
    }

    private void ApplyStatusBarInset(AndroidMainView view)
    {
        try
        {
            var res = global::Android.App.Application.Context.Resources;
            var resourceId = res?.GetIdentifier("status_bar_height", "dimen", "android") ?? 0;
            var px = resourceId > 0 ? (res?.GetDimensionPixelSize(resourceId) ?? 0) : 0;
            var density = res?.DisplayMetrics?.Density ?? 3.0f;
            var dip = px > 0 ? px / density : 24.0;
            view.SetStatusBarHeight(dip);
        }
        catch
        {
            view.SetStatusBarHeight(28);
        }
    }

    protected override void OnDestroy()
    {
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

