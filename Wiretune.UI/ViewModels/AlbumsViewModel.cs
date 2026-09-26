using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class AlbumsViewModel : ObservableObject
{
    private const int DetailCoverDecodeWidth = 480;

    private readonly ILibraryService _library;
    private readonly PlayerViewModel _player;

    [ObservableProperty] private IReadOnlyList<AlbumCardViewModel> _displayedAlbums = Array.Empty<AlbumCardViewModel>();
    [ObservableProperty] private Album? _selectedAlbum;
    [ObservableProperty] private Bitmap? _selectedAlbumCover;
    [ObservableProperty] private bool _isAlbumDetailOpen;

    public AlbumsViewModel(ILibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Ui.Post(RefreshAlbums);
        RefreshAlbums();
    }

    public void RefreshAlbums()
    {
        DisplayedAlbums = _library.Albums.Select(a => new AlbumCardViewModel(a)).ToList();

        if (SelectedAlbum != null)
        {
            var updated = _library.GetAlbum(SelectedAlbum.Id);
            if (updated == null) CloseAlbumDetail();
            else SelectedAlbum = updated;
        }
    }

    private static Album? Resolve(object? param) => param switch
    {
        Album a => a,
        AlbumCardViewModel vm => vm.Album,
        _ => null
    };

    [RelayCommand]
    public void OpenAlbum(object? param)
    {
        var album = Resolve(param);
        if (album == null) return;

        SelectedAlbum = album;
        IsAlbumDetailOpen = true;
        SelectedAlbumCover = null;
        CoverArtService.LoadBitmap(album.CoverArtPath, DetailCoverDecodeWidth, bmp =>
        {
            if (ReferenceEquals(SelectedAlbum, album)) SelectedAlbumCover = bmp;
        });
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
        var album = Resolve(param) ?? SelectedAlbum;
        if (album == null || album.Tracks.Count == 0) return;
        _player.PlayQueue(album.Tracks);
    }

    [RelayCommand]
    public void PlayAlbumTrack(Track? track)
    {
        if (track != null && SelectedAlbum != null) _player.PlayQueue(SelectedAlbum.Tracks, track);
    }

    [RelayCommand]
    public void ShuffleAlbum(object? param)
    {
        var album = Resolve(param) ?? SelectedAlbum;
        if (album == null || album.Tracks.Count == 0) return;
        _player.IsShuffle = true;
        _player.PlayQueue(album.Tracks);
    }
}
