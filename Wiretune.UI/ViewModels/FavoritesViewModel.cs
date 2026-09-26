using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class FavoritesViewModel : ObservableObject
{
    private readonly ILibraryService _library;
    private readonly PlayerViewModel _player;

    [ObservableProperty] private IReadOnlyList<Track> _favoriteTracks = Array.Empty<Track>();
    [ObservableProperty] private bool _isEmpty = true;

    public FavoritesViewModel(ILibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Ui.Post(RefreshFavorites);
        _library.FavoriteChanged += (_, _) => Ui.Post(RefreshFavorites);
        RefreshFavorites();
    }

    public void RefreshFavorites()
    {
        FavoriteTracks = _library.Favorites;
        IsEmpty = FavoriteTracks.Count == 0;
    }

    [RelayCommand]
    public void PlayTrack(Track? track)
    {
        if (track != null) _player.PlayQueue(FavoriteTracks, track);
    }

    [RelayCommand]
    public void PlayAll()
    {
        if (FavoriteTracks.Count > 0) _player.PlayQueue(FavoriteTracks);
    }

    [RelayCommand]
    public async Task RemoveFavoriteAsync(Track? track)
    {
        if (track == null) return;
        await _library.ToggleFavoriteAsync(track.Id);
        RefreshFavorites();
    }
}
