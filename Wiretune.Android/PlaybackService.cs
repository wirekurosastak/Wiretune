using Android.App;
using Android.Content;
using Android.Media;
using Android.OS;

namespace Wiretune.Android;

/// <summary>
/// Foreground service that keeps the Android process alive while music is playing.
/// Start it with StartPlayback() and stop it with StopPlayback().
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
        return StartCommandResult.Sticky;
    }

    public override void OnDestroy()
    {
        StopForeground(StopForegroundFlags.Remove);
        base.OnDestroy();
    }

    private void CreateNotificationChannel()
    {
        if (Build.VERSION.SdkInt < BuildVersionCodes.O) return;
        var channel = new NotificationChannel(ChannelId, "Playback", NotificationImportance.Low)
        {
            Description = "Wiretune playback notification"
        };
        var manager = (NotificationManager?)GetSystemService(NotificationService);
        manager?.CreateNotificationChannel(channel);
    }

    private Notification BuildNotification()
    {
        var builder = new Notification.Builder(this, ChannelId)
            .SetContentTitle("Wiretune")
            .SetContentText("Playing…")
            .SetSmallIcon(Resource.Drawable.icon)
            .SetOngoing(true);

        return builder.Build()!;
    }

    // ── Static helpers called from MainActivity ──────────────────────────

    public static void StartPlayback(Context context)
    {
        var intent = new Intent(context, typeof(PlaybackService));
        if (Build.VERSION.SdkInt >= BuildVersionCodes.O)
            context.StartForegroundService(intent);
        else
            context.StartService(intent);
    }

    public static void StopPlayback(Context context)
    {
        var intent = new Intent(context, typeof(PlaybackService));
        context.StopService(intent);
    }
}
