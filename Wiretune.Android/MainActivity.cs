using Android.App;
using Android.Content.PM;
using Avalonia;
using Avalonia.Android;
using Wiretune.UI;

namespace Wiretune.Android;

[Activity(
    Label = "Wiretune",
    Theme = "@style/Theme.AppCompat.NoActionBar",
    Icon = "@mipmap/ic_launcher",
    MainLauncher = true,
    ConfigurationChanges = ConfigChanges.Orientation | ConfigChanges.ScreenSize | ConfigChanges.UiMode)]
public class MainActivity : AvaloniaMainActivity<App>
{
    protected override AppBuilder CustomizeAppBuilder(AppBuilder builder)
    {
        return base.CustomizeAppBuilder(builder)
            .WithInterFont();
    }
}
