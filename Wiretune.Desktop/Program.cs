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

        // A GUI app has no console to show a crash on: make sure the log file gets the reason.
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            WiretuneLog.Error("Wiretune.Desktop", "Unhandled exception", e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            WiretuneLog.Error("Wiretune.Desktop", "Unobserved task exception", e.Exception);
            e.SetObserved();
        };

        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
