namespace Wiretune.UI.ViewModels;

/// <summary>
/// The top-level pages of the app, shown as the sidebar entries on the desktop and the bottom bar on the phone.
/// The numeric values are the order the sections were added in, not the order they are drawn in (see
/// <see cref="MainViewModel.GetNavVisualOrder"/>).
/// </summary>
public enum AppSection
{
    Tracks = 0,
    Albums = 1,
    Artists = 2,
    Playlists = 3,
    Favorites = 4,
    Settings = 5
}
