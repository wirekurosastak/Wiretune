using Avalonia.Controls;
using Wiretone.UI.ViewModels;

namespace Wiretone.UI.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();

        Closing += (_, _) => (DataContext as MainViewModel)?.Dispose();
        Closed += (_, _) => (DataContext as MainViewModel)?.Dispose();
    }
}
