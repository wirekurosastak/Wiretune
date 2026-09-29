using Avalonia;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace Wiretune.UI.Views;

public partial class AndroidMainView : UserControl
{
    public AndroidMainView()
    {
        InitializeComponent();
        OpenFullPlayerBtn.Click += OpenNowPlaying;
        CloseFullPlayerBtn.Click += CloseNowPlaying;
    }

    /// <summary>Called by the Android host to set the real status bar height in DIPs.</summary>
    public void SetStatusBarHeight(double heightDip)
    {
        StatusBarSpacer.Height = Math.Max(20, heightDip);
    }

    private void OpenNowPlaying(object? sender, RoutedEventArgs e)
    {
        NowPlayingSheet.IsVisible = true;
    }

    private void CloseNowPlaying(object? sender, RoutedEventArgs e)
    {
        NowPlayingSheet.IsVisible = false;
    }

    /// <summary>
    /// Called by MainActivity when the hardware back button is pressed.
    /// Returns true if the view consumed the event (i.e. closed an overlay).
    /// </summary>
    public bool TryGoBack()
    {
        if (NowPlayingSheet.IsVisible)
        {
            NowPlayingSheet.IsVisible = false;
            return true;
        }
        return false;
    }
}

