using Avalonia.Controls;
using Wiretune.UI.ViewModels;

namespace Wiretune.UI.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();

        Closing += (_, _) => (DataContext as MainViewModel)?.Dispose();
        Closed += (_, _) => (DataContext as MainViewModel)?.Dispose();
    }
}
