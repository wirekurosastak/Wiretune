using Avalonia;
using Wiretone.Core.Services;
using Wiretone.UI;

namespace Wiretone.Desktop;

class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        WiretoneLog.Initialize();
        WiretoneLog.Info("Wiretone.Desktop", "=== Starting Wiretone Desktop App ===");
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
