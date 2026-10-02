using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Markup.Xaml.Styling;
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

    /// <summary>
    /// Adds the styles only one kind of head uses: the desktop layout is built on DataGrid, the phone layout on the phone
    /// styles. Each goes where it sat in the list of App.axaml before (the DataGrid theme right after Fluent, the phone
    /// styles after the icon styles), so that the app's own styles after them still win.
    /// </summary>
    private void AddHeadStyles()
    {
        if (ApplicationLifetime is ISingleViewApplicationLifetime)
        {
            Styles.Insert(Math.Min(2, Styles.Count), Include("avares://Wiretune.UI/Styles/PhoneStyles.axaml"));
        }
        else
        {
            Styles.Insert(Math.Min(1, Styles.Count), Include("avares://Avalonia.Controls.DataGrid/Themes/Fluent.xaml"));
        }

        static StyleInclude Include(string source) => new(new Uri("avares://Wiretune.UI/")) { Source = new Uri(source) };
    }

    public override void OnFrameworkInitializationCompleted()
    {
        AddHeadStyles();

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

#if DEBUG
            // A development aid: compiled into Debug builds only, so a released player has no remote-control endpoint.
            UiAutomationServer? automation = null;
            if (UiAutomationServer.IsEnabled)
            {
                automation = new UiAutomationServer(mainWindow, mainVm);
                automation.Start();
            }
#endif

            desktop.Exit += (_, _) =>
            {
#if DEBUG
                automation?.Dispose();
#endif
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

