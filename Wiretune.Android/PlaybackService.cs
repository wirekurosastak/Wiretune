using Android.App;
using Android.Content;
using Android.Media;
using Android.OS;
using Wiretune.Core.Localization;
using Wiretune.Core.Services;

namespace Wiretune.Android;

/// <summary>
/// Foreground service that keeps the Android process alive while music is playing (the audio itself is played by
/// <see cref="AndroidAudioDriver"/>). Start it with StartPlayback() and stop it with StopPlayback().
/// </summary>
[Service(Exported = false, ForegroundServiceType = global::Android.Content.PM.ForegroundService.TypeMediaPlayback)]
public class PlaybackService : Service
{
    private const string ChannelId = "wiretune_playback";
    private const int NotificationId = 1001;

    public override IBinder? OnBind(Intent? intent) => null;

    public override StartCommandResult OnStartCommand(Intent? intent, StartCommandFlags flags, int startId)
    {
        CreateNotificationChannel();
        StartForeground(NotificationId, BuildNotification());
        // NotSticky: if the process is killed, do not resurrect a "Playing…" notification with nothing playing.
        return StartCommandResult.NotSticky;
    }

    public override void OnDestroy()
    {
        if (OperatingSystem.IsAndroidVersionAtLeast(24))
        {
            StopForeground(StopForegroundFlags.Remove);
        }
        else
        {
#pragma warning disable CA1422 // The overload is deprecated on new devices, but it is the only one before API 24.
            StopForeground(true);
#pragma warning restore CA1422
        }
        base.OnDestroy();
    }

    private void CreateNotificationChannel()
    {
        if (Build.VERSION.SdkInt < BuildVersionCodes.O) return;
        var channel = new NotificationChannel(ChannelId, Localizer.Get("NotificationChannelName"), NotificationImportance.Low)
        {
            Description = Localizer.Get("NotificationChannelDescription")
        };
        var manager = (NotificationManager?)GetSystemService(NotificationService);
        manager?.CreateNotificationChannel(channel);
    }

    private Notification BuildNotification()
    {
        // The channel-aware constructor only exists from API 26; older versions have no channels.
        var builder = OperatingSystem.IsAndroidVersionAtLeast(26)
            ? new Notification.Builder(this, ChannelId)
            : new Notification.Builder(this);

        builder
            .SetContentTitle("Wiretune")
            .SetContentText(Localizer.Get("NotificationPlaying"))
            .SetSmallIcon(Resource.Drawable.icon)
            .SetOngoing(true);

        // Tapping the notification brings the player back to the front.
        var launch = PackageManager?.GetLaunchIntentForPackage(PackageName ?? string.Empty);
        if (launch != null)
        {
            launch.SetFlags(ActivityFlags.NewTask | ActivityFlags.ClearTop | ActivityFlags.SingleTop);
            var flags = OperatingSystem.IsAndroidVersionAtLeast(23)
                ? PendingIntentFlags.Immutable | PendingIntentFlags.UpdateCurrent
                : PendingIntentFlags.UpdateCurrent;
            builder.SetContentIntent(PendingIntent.GetActivity(this, 0, launch, flags));
        }

        return builder.Build()!;
    }

    // ── Static helpers called from MainActivity ──────────────────────────

    public static void StartPlayback(Context context)
    {
        try
        {
            var intent = new Intent(context, typeof(PlaybackService));
            if (OperatingSystem.IsAndroidVersionAtLeast(26))
                context.StartForegroundService(intent);
            else
                context.StartService(intent);
        }
        catch (Exception ex)
        {
            // From API 31 the system refuses to start a foreground service while the app is in the background.
            // Playback itself is unaffected; only the notification (and the protection from being killed) is missing.
            WiretuneLog.Warn("PlaybackService", $"Could not start the playback service: {ex.Message}");
        }
    }

    public static void StopPlayback(Context context)
    {
        var intent = new Intent(context, typeof(PlaybackService));
        context.StopService(intent);
    }
}
