using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class FavoritesViewModel : ObservableObject
{
    private readonly LibraryService _library;
    private readonly PlayerViewModel _player;

    [ObservableProperty] private IReadOnlyList<Track> _favoriteTracks = Array.Empty<Track>();
    [ObservableProperty] private string _totalFavoritesDuration = "0 perc";
    [ObservableProperty] private bool _isEmpty = true;

    public FavoritesViewModel(LibraryService library, PlayerViewModel player)
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
        TotalFavoritesDuration = TracksViewModel.FormatTotal(TimeSpan.FromSeconds(FavoriteTracks.Sum(t => t.Duration.TotalSeconds)));
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
    public void ShuffleAll()
    {
        if (FavoriteTracks.Count == 0) return;
        _player.IsShuffle = true;
        _player.PlayQueue(FavoriteTracks);
    }

    [RelayCommand]
    public async Task RemoveFavoriteAsync(Track? track)
    {
        if (track == null) return;
        await _library.ToggleFavoriteAsync(track.Id);
        RefreshFavorites();
    }
}

