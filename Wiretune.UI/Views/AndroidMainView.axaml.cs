using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Platform;
using Avalonia.Threading;
using Wiretune.UI.ViewModels;

namespace Wiretune.UI.Views;

/// <summary>The phone layout (see AndroidMainView.axaml). The navigation state lives in <see cref="MainViewModel"/>.</summary>
public partial class AndroidMainView : UserControl
{
    /// <summary>The space taken by the status bar, the display cutout and the navigation bar; the layout keeps clear of it.</summary>
    public static readonly StyledProperty<Thickness> SafeAreaProperty =
        AvaloniaProperty.Register<AndroidMainView, Thickness>(nameof(SafeArea));

    private MainViewModel? _viewModel;
    private IInsetsManager? _insets;

    public AndroidMainView()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    public Thickness SafeArea
    {
        get => GetValue(SafeAreaProperty);
        set => SetValue(SafeAreaProperty, value);
    }

    /// <summary>
    /// Called by MainActivity when the back button is pressed. Returns true when the view consumed it (closed a dialog,
    /// the full-screen player, the search or a detail page), false when the app may close.
    /// </summary>
    public bool TryGoBack() => _viewModel?.TryNavigateBack() ?? false;

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);

        _insets = TopLevel.GetTopLevel(this)?.InsetsManager;
        if (_insets == null) return;
        SafeArea = _insets.SafeAreaPadding;
        _insets.SafeAreaChanged += OnSafeAreaChanged;
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        if (_insets != null) _insets.SafeAreaChanged -= OnSafeAreaChanged;
        _insets = null;
        base.OnDetachedFromVisualTree(e);
    }

    private void OnSafeAreaChanged(object? sender, SafeAreaChangedArgs e) => SafeArea = e.SafeAreaPadding;

    private void OnDataContextChanged(object? sender, EventArgs e)
    {
        if (_viewModel != null) _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
        _viewModel = DataContext as MainViewModel;
        if (_viewModel != null) _viewModel.PropertyChanged += OnViewModelPropertyChanged;
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_viewModel == null) return;

        // Open the keyboard together with the search field.
        if (e.PropertyName == nameof(MainViewModel.IsSearchOpen) && _viewModel.IsSearchOpen)
        {
            Dispatcher.UIThread.Post(() => SearchBox.Focus(), DispatcherPriority.Input);
        }
        // Show the playing entry when the queue tab opens.
        else if (e.PropertyName == nameof(MainViewModel.NowPlayingTab) && _viewModel.NowPlayingTab == 1)
        {
            Dispatcher.UIThread.Post(ScrollQueueToCurrent, DispatcherPriority.Loaded);
        }
    }

    private void ScrollQueueToCurrent()
    {
        var player = _viewModel?.Player;
        if (player == null || player.CurrentQueueIndex < 0 || player.CurrentQueueIndex >= player.QueueItems.Count) return;
        QueueList.ScrollIntoView(player.CurrentQueueIndex);
    }
}
