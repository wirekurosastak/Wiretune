using Avalonia;
using Wiretune.Core.Services;
using Wiretune.UI;

namespace Wiretune.Desktop;

class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        WiretuneLog.Initialize();
        WiretuneLog.Info("Wiretune.Desktop", "=== Starting Wiretune Desktop App ===");
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
