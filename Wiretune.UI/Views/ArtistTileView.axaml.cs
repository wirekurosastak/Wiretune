using System.Windows.Input;
using Avalonia;
using Avalonia.Controls;

namespace Wiretune.UI.Controls;

/// <summary>
/// Shared artist tile used by the main Artists grid and the search results'
/// Artists section. Expects its DataContext to be an Artist. Always styled
/// with the coral accent; the footer always shows the play button.
/// </summary>
public partial class ArtistTileView : UserControl
{
    public static readonly StyledProperty<ICommand?> OpenCommandProperty =
        AvaloniaProperty.Register<ArtistTileView, ICommand?>(nameof(OpenCommand));

    public static readonly StyledProperty<ICommand?> PlayCommandProperty =
        AvaloniaProperty.Register<ArtistTileView, ICommand?>(nameof(PlayCommand));

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

    public ArtistTileView()
    {
        InitializeComponent();
    }
}
