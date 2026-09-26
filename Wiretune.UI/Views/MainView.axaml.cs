using Avalonia;
using Avalonia.Controls;
using Wiretune.UI.ViewModels;

namespace Wiretune.UI.Views;

public partial class MainView : UserControl
{
    public MainView()
    {
        InitializeComponent();
    }

    /// <summary>Keeps header controls clear of window caption buttons drawn over an extended client area.</summary>
    public void SetCaptionButtonsInset(double right)
    {
        HeaderBar.Padding = new Thickness(24, 0, 24 + right, 0);
    }

    protected override void OnSizeChanged(SizeChangedEventArgs e)
    {
        base.OnSizeChanged(e);
        if (DataContext is MainViewModel vm)
        {
            vm.IsCompactLayout = e.NewSize.Width < MainViewModel.CompactLayoutWidth;
        }
    }
}
