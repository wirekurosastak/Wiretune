using Android.App;
using Android.Content.PM;
using Avalonia;
using Avalonia.Android;
using Wiretune.UI;

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

        return base.CustomizeAppBuilder(builder)
            .WithInterFont();
    }
}
