using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Wiretune.Core.Audio.Drivers;
using Wiretune.UI.Services;
using Wiretune.UI.ViewModels;
using Wiretune.UI.Views;

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

