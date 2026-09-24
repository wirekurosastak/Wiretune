using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretone.Core.Models;
using Wiretone.Core.Services;

namespace Wiretone.UI.ViewModels;

public partial class FavoritesViewModel : ObservableObject
{
    private readonly ILibraryService _library;
    private readonly PlayerViewModel _player;

    public ObservableCollection<Track> FavoriteTracks { get; } = new();

    public FavoritesViewModel(ILibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(RefreshFavorites);
        RefreshFavorites();
    }

    public void RefreshFavorites()
    {
        FavoriteTracks.Clear();
        foreach (var t in _library.Favorites)
        {
            FavoriteTracks.Add(t);
        }
    }

    [RelayCommand]
    public void PlayTrack(Track? track)
    {
        if (track == null) return;
        _player.PlayQueue(FavoriteTracks, track);
    }

    [RelayCommand]
    public void PlayAll()
    {
        if (FavoriteTracks.Count > 0)
        {
            _player.PlayQueue(FavoriteTracks);
        }
    }

    [RelayCommand]
    public async Task RemoveFavoriteAsync(Track? track)
    {
        if (track == null) return;
        await _library.ToggleFavoriteAsync(track.Id);
        RefreshFavorites();
    }
}
