using Avalonia.Controls;

namespace Wiretune.UI.Views;

public partial class MainWindow : Window
{
    // Width of the minimize/maximize/close buttons Windows draws over the extended client area.
    private const double WindowsCaptionButtonsWidth = 140;

    public MainWindow()
    {
        InitializeComponent();
        Opened += (_, _) =>
        {
            if (IsExtendedIntoWindowDecorations && OperatingSystem.IsWindows())
            {
                RootView.SetCaptionButtonsInset(WindowsCaptionButtonsWidth);
            }
        };
    }
}
