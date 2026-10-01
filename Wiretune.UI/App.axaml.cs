using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using Wiretune.Core.Services;
using Wiretune.Core.Audio.Drivers;
using Wiretune.UI.Services;
using Wiretune.UI.ViewModels;
using Wiretune.UI.Views;
using Wiretune.Core.Localization;

namespace Wiretune.UI;

public partial class App : Application
{
    /// <summary>Platform heads (e.g. Android) set this before startup to supply a native audio driver.</summary>
    public static Func<IAudioDriver>? AudioDriverFactory { get; set; }

    /// <summary>The running MainViewModel; available after OnFrameworkInitializationCompleted.</summary>
    public static MainViewModel? MainVm { get; private set; }

    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        var mainVm = MainViewModel.CreateDefault(AudioDriverFactory?.Invoke());
        MainVm = mainVm;

        // A failed command (locked database, full disk, ...) must not take the whole player down:
        // log it with its stack trace and show it in the status bar instead.
        Dispatcher.UIThread.UnhandledException += (_, e) =>
        {
            WiretuneLog.Error("App", "Unhandled exception on the UI thread", e.Exception);
            mainVm.Player.ErrorMessage = Localizer.Format("UnexpectedError", e.Exception.Message);
            e.Handled = true;
        };

        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var mainWindow = new MainWindow { DataContext = mainVm };
            desktop.MainWindow = mainWindow;

            UiAutomationServer? automation = null;
            if (UiAutomationServer.IsEnabled)
            {
                automation = new UiAutomationServer(mainWindow, mainVm);
                automation.Start();
            }

            desktop.Exit += (_, _) =>
            {
                automation?.Dispose();
                mainVm.Dispose();
            };
        }
        else if (ApplicationLifetime is ISingleViewApplicationLifetime singleView)
        {
            singleView.MainView = new AndroidMainView { DataContext = mainVm };
        }

        Ui.Forget(mainVm.StartAsync(), "App");
        base.OnFrameworkInitializationCompleted();
    }
}

