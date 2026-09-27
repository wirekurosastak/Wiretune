using System.Windows.Input;
using Avalonia;
using Avalonia.Controls;

namespace Wiretune.UI.Controls;

/// <summary>
/// Shared album tile used by the main Albums grid, the artist-detail album list,
/// and the search results' Albums section. Expects its DataContext to be an
/// AlbumCardViewModel. Always styled with the purple accent; the footer always
/// shows the play button.
/// </summary>
public partial class AlbumTileView : UserControl
{
    public static readonly StyledProperty<ICommand?> OpenCommandProperty =
        AvaloniaProperty.Register<AlbumTileView, ICommand?>(nameof(OpenCommand));

    public static readonly StyledProperty<ICommand?> PlayCommandProperty =
        AvaloniaProperty.Register<AlbumTileView, ICommand?>(nameof(PlayCommand));

    public ICommand? OpenCommand
    {
        get => GetValue(OpenCommandProperty);
        set => SetValue(OpenCommandProperty, value);
    }

    public ICommand? PlayCommand
    {
        get => GetValue(PlayCommandProperty);
        set => SetValue(PlayCommandProperty, value);
    }

    public AlbumTileView()
    {
        InitializeComponent();
    }
}
