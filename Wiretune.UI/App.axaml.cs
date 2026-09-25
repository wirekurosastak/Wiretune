using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Wiretune.UI.ViewModels;
using Wiretune.UI.Views;

namespace Wiretune.UI;

public partial class App : Application
{
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var mainVm = new MainViewModel();
            var mainWindow = new MainWindow
            {
                DataContext = mainVm
            };
            desktop.MainWindow = mainWindow;

            var automationServer = new Services.UiAutomationServer(mainWindow, mainVm);
            automationServer.Start();

            desktop.ShutdownRequested += (_, _) => { automationServer.Dispose(); mainVm.Dispose(); };
            desktop.Exit += (_, _) => { automationServer.Dispose(); mainVm.Dispose(); };
        }
        else if (ApplicationLifetime is ISingleViewApplicationLifetime singleView)
        {
            var mainVm = new MainViewModel();
            singleView.MainView = new MainView
            {
                DataContext = mainVm
            };
        }

        base.OnFrameworkInitializationCompleted();
    }
}
