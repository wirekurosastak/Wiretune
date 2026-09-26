using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class ArtistsViewModel : ObservableObject
{
    private readonly ILibraryService _library;
    private readonly PlayerViewModel _player;

    [ObservableProperty] private IReadOnlyList<Artist> _displayedArtists = Array.Empty<Artist>();
    [ObservableProperty] private Artist? _selectedArtist;
    [ObservableProperty] private bool _isArtistDetailOpen;
    [ObservableProperty] private IReadOnlyList<AlbumCardViewModel> _selectedArtistAlbumCards = Array.Empty<AlbumCardViewModel>();
    [ObservableProperty] private bool _hasSelectedArtistAlbums;
    [ObservableProperty] private IReadOnlyList<Track> _selectedArtistTracks = Array.Empty<Track>();

    public ArtistsViewModel(ILibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Ui.Post(RefreshArtists);
        RefreshArtists();
    }

    public void RefreshArtists()
    {
        DisplayedArtists = _library.Artists;

        if (SelectedArtist != null)
        {
            var updated = _library.GetArtist(SelectedArtist.Id);
            if (updated == null) CloseArtistDetail();
            else OpenArtist(updated);
        }
    }

    [RelayCommand]
    public void OpenArtist(Artist? artist)
    {
        if (artist == null) return;
        SelectedArtist = artist;
        IsArtistDetailOpen = true;
        SelectedArtistAlbumCards = artist.Albums.Select(a => new AlbumCardViewModel(a)).ToList();
        HasSelectedArtistAlbums = SelectedArtistAlbumCards.Count > 0;
        SelectedArtistTracks = artist.Tracks;
    }

    [RelayCommand]
    public void CloseArtistDetail()
    {
        IsArtistDetailOpen = false;
        SelectedArtist = null;
        SelectedArtistAlbumCards = Array.Empty<AlbumCardViewModel>();
        HasSelectedArtistAlbums = false;
        SelectedArtistTracks = Array.Empty<Track>();
    }

    [RelayCommand]
    public void PlayArtist(Artist? artist)
    {
        var target = artist ?? SelectedArtist;
        if (target == null || target.Tracks.Count == 0) return;
        _player.PlayQueue(target.Tracks);
    }

    [RelayCommand]
    public void PlayArtistTrack(Track? track)
    {
        if (track != null && SelectedArtist != null) _player.PlayQueue(SelectedArtist.Tracks, track);
    }
}
