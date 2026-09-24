using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretone.Core.Models;
using Wiretone.Core.Services;

namespace Wiretone.UI.ViewModels;

public partial class ArtistsViewModel : ObservableObject
{
    private readonly ILibraryService _library;
    private readonly PlayerViewModel _player;

    [ObservableProperty] private string _searchFilter = string.Empty;
    [ObservableProperty] private Artist? _selectedArtist;
    [ObservableProperty] private bool _isArtistDetailOpen;

    public ObservableCollection<Artist> DisplayedArtists { get; } = new();
    public ObservableCollection<AlbumCardViewModel> SelectedArtistAlbumCards { get; } = new();
    public ObservableCollection<Track> SelectedArtistTracks { get; } = new();

    public ArtistsViewModel(ILibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(RefreshArtists);
        RefreshArtists();
    }

    public void RefreshArtists()
    {
        var artists = string.IsNullOrWhiteSpace(SearchFilter)
            ? _library.Artists
            : _library.Artists.Where(a => a.Name.Contains(SearchFilter, StringComparison.OrdinalIgnoreCase));

        DisplayedArtists.Clear();
        foreach (var a in artists)
        {
            DisplayedArtists.Add(a);
        }
    }

    partial void OnSearchFilterChanged(string value)
    {
        RefreshArtists();
    }

    [RelayCommand]
    public void OpenArtist(Artist? artist)
    {
        if (artist == null) return;
        SelectedArtist = artist;
        IsArtistDetailOpen = true;

        SelectedArtistAlbumCards.Clear();
        foreach (var a in artist.Albums)
        {
            SelectedArtistAlbumCards.Add(new AlbumCardViewModel(a));
        }

        SelectedArtistTracks.Clear();
        foreach (var t in artist.Albums.SelectMany(a => a.Tracks))
        {
            SelectedArtistTracks.Add(t);
        }
    }

    [RelayCommand]
    public void CloseArtistDetail()
    {
        IsArtistDetailOpen = false;
        SelectedArtist = null;
        SelectedArtistAlbumCards.Clear();
        SelectedArtistTracks.Clear();
    }

    [RelayCommand]
    public void PlayArtist(Artist? artist)
    {
        var target = artist ?? SelectedArtist;
        if (target == null) return;
        var allArtistTracks = target.Albums.SelectMany(a => a.Tracks).ToList();
        if (allArtistTracks.Count > 0)
        {
            _player.PlayQueue(allArtistTracks);
        }
    }

    [RelayCommand]
    public void PlayArtistTrack(Track? track)
    {
        if (track == null || SelectedArtist == null) return;
        var allArtistTracks = SelectedArtist.Albums.SelectMany(a => a.Tracks).ToList();
        _player.PlayQueue(allArtistTracks, track);
    }
}
