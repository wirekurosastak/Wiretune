using System.Windows.Input;
using Avalonia;
using Avalonia.Controls;
using Material.Icons;

namespace Wiretune.UI.Controls;

/// <summary>A track in a phone list (see AndroidMainView). The commands receive the <c>Track</c> as their parameter.</summary>
public partial class TrackRowView : UserControl
{
    public static readonly StyledProperty<ICommand?> PlayCommandProperty =
        AvaloniaProperty.Register<TrackRowView, ICommand?>(nameof(PlayCommand));

    public static readonly StyledProperty<ICommand?> FavoriteCommandProperty =
        AvaloniaProperty.Register<TrackRowView, ICommand?>(nameof(FavoriteCommand));

    public static readonly StyledProperty<ICommand?> AddCommandProperty =
        AvaloniaProperty.Register<TrackRowView, ICommand?>(nameof(AddCommand));

    public static readonly StyledProperty<bool> ShowCoverProperty =
        AvaloniaProperty.Register<TrackRowView, bool>(nameof(ShowCover), true);

    public static readonly StyledProperty<bool> ShowAlbumProperty =
        AvaloniaProperty.Register<TrackRowView, bool>(nameof(ShowAlbum), true);

    public static readonly StyledProperty<bool> ShowDurationProperty =
        AvaloniaProperty.Register<TrackRowView, bool>(nameof(ShowDuration));

    public static readonly StyledProperty<MaterialIconKind> ActionIconProperty =
        AvaloniaProperty.Register<TrackRowView, MaterialIconKind>(nameof(ActionIcon), MaterialIconKind.PlaylistPlus);

    public static readonly StyledProperty<string?> ActionLabelProperty =
        AvaloniaProperty.Register<TrackRowView, string?>(nameof(ActionLabel));

    public TrackRowView()
    {
        InitializeComponent();
    }

    public ICommand? PlayCommand
    {
        get => GetValue(PlayCommandProperty);
        set => SetValue(PlayCommandProperty, value);
    }

    public ICommand? FavoriteCommand
    {
        get => GetValue(FavoriteCommandProperty);
        set => SetValue(FavoriteCommandProperty, value);
    }

    public ICommand? AddCommand
    {
        get => GetValue(AddCommandProperty);
        set => SetValue(AddCommandProperty, value);
    }

    /// <summary>Icon of the row's last button ("add to playlist" unless a list needs another action).</summary>
    public MaterialIconKind ActionIcon
    {
        get => GetValue(ActionIconProperty);
        set => SetValue(ActionIconProperty, value);
    }

    /// <summary>Accessibility name of the last button.</summary>
    public string? ActionLabel
    {
        get => GetValue(ActionLabelProperty);
        set => SetValue(ActionLabelProperty, value);
    }

    /// <summary>Shows the cover art (default) instead of the track number.</summary>
    public bool ShowCover
    {
        get => GetValue(ShowCoverProperty);
        set => SetValue(ShowCoverProperty, value);
    }

    /// <summary>Shows "artist • album" (default) instead of just the artist.</summary>
    public bool ShowAlbum
    {
        get => GetValue(ShowAlbumProperty);
        set => SetValue(ShowAlbumProperty, value);
    }

    public bool ShowDuration
    {
        get => GetValue(ShowDurationProperty);
        set => SetValue(ShowDurationProperty, value);
    }
}
