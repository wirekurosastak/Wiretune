using System.Collections.ObjectModel;
using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretone.Core.Models;
using Wiretone.Core.Services;
using Wiretone.UI.Services;

namespace Wiretone.UI.ViewModels;

public partial class AlbumsViewModel : ObservableObject
{
    private readonly ILibraryService _library;
    private readonly PlayerViewModel _player;

    [ObservableProperty] private string _searchFilter = string.Empty;
    [ObservableProperty] private Album? _selectedAlbum;
    [ObservableProperty] private Bitmap? _selectedAlbumCover;
    [ObservableProperty] private bool _isAlbumDetailOpen;

    public ObservableCollection<AlbumCardViewModel> DisplayedAlbums { get; } = new();

    public AlbumsViewModel(ILibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(RefreshAlbums);
        RefreshAlbums();
    }

    public void RefreshAlbums()
    {
        var albums = string.IsNullOrWhiteSpace(SearchFilter)
            ? _library.Albums
            : _library.Albums.Where(a => a.Title.Contains(SearchFilter, StringComparison.OrdinalIgnoreCase) ||
                                         a.Artist.Contains(SearchFilter, StringComparison.OrdinalIgnoreCase));

        DisplayedAlbums.Clear();
        foreach (var a in albums)
        {
            DisplayedAlbums.Add(new AlbumCardViewModel(a));
        }
    }

    partial void OnSearchFilterChanged(string value)
    {
        RefreshAlbums();
    }

    [RelayCommand]
    public void OpenAlbum(object? param)
    {
        Album? album = param switch
        {
            Album a => a,
            AlbumCardViewModel vm => vm.Album,
            _ => null
        };
        if (album == null) return;
        SelectedAlbum = album;
        IsAlbumDetailOpen = true;

        var path = album.CoverArtPath ?? album.Tracks.FirstOrDefault(t => !string.IsNullOrEmpty(t.CoverArtPath))?.CoverArtPath;
        SelectedAlbumCover = null;
        if (!string.IsNullOrEmpty(path))
        {
            CoverArtService.LoadBitmap(path, bmp => SelectedAlbumCover = bmp);
        }
    }

    [RelayCommand]
    public void CloseAlbumDetail()
    {
        IsAlbumDetailOpen = false;
        SelectedAlbum = null;
        SelectedAlbumCover = null;
    }

    [RelayCommand]
    public void PlayAlbum(object? param)
    {
        Album? album = param switch
        {
            Album a => a,
            AlbumCardViewModel vm => vm.Album,
            _ => null
        };
        if (album == null || album.Tracks.Count == 0) return;
        _player.PlayQueue(album.Tracks);
    }

    [RelayCommand]
    public void PlayAlbumTrack(Track? track)
    {
        if (track == null || SelectedAlbum == null) return;
        _player.PlayQueue(SelectedAlbum.Tracks, track);
    }

    [RelayCommand]
    public void ShuffleAlbum(object? param)
    {
        Album? album = param switch
        {
            Album a => a,
            AlbumCardViewModel vm => vm.Album,
            _ => SelectedAlbum
        };
        if (album == null || album.Tracks.Count == 0) return;
        _player.IsShuffle = true;
        _player.PlayQueue(album.Tracks);
    }
}
