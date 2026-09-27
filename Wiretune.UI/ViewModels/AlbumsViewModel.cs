using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Controls;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public enum AlbumSortMode
{
    TitleAsc,
    YearDesc
}

public partial class AlbumsViewModel : ObservableObject
{
    private const int DetailCoverDecodeWidth = 480;

    private readonly ILibraryService _library;
    private readonly PlayerViewModel _player;

    public Action<NavWaveDirection>? OnNavWave { get; set; }
    public Action? ReturnAction { get; set; }

    public IReadOnlyList<AlbumSortMode> SortModes { get; } = new[] { AlbumSortMode.TitleAsc, AlbumSortMode.YearDesc };

    [ObservableProperty] private IReadOnlyList<AlbumCardViewModel> _displayedAlbums = Array.Empty<AlbumCardViewModel>();
    [ObservableProperty] private Album? _selectedAlbum;
    [ObservableProperty] private Bitmap? _selectedAlbumCover;
    [ObservableProperty] private bool _isAlbumDetailOpen;
    [ObservableProperty] private string _backButtonText = "Vissza az összes albumhoz";
    [ObservableProperty] private AlbumSortMode _sortMode = AlbumSortMode.TitleAsc;

    public AlbumsViewModel(ILibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Ui.Post(RefreshAlbums);
        RefreshAlbums();
    }

    public bool IsSortByTitle => SortMode == AlbumSortMode.TitleAsc;
    public bool IsSortByYear => SortMode == AlbumSortMode.YearDesc;

    partial void OnSortModeChanged(AlbumSortMode value)
    {
        OnPropertyChanged(nameof(IsSortByTitle));
        OnPropertyChanged(nameof(IsSortByYear));
        ApplySort();
    }

    [RelayCommand]
    public void SetSortMode(object? param)
    {
        if (param is AlbumSortMode mode) SortMode = mode;
        else if (param is string s && Enum.TryParse<AlbumSortMode>(s, out var parsed)) SortMode = parsed;
    }

    public void RefreshAlbums()
    {
        ApplySort();

        if (SelectedAlbum != null)
        {
            var updated = _library.GetAlbum(SelectedAlbum.Id);
            if (updated == null) CloseAlbumDetail();
            else SelectedAlbum = updated;
        }
    }

    private void ApplySort()
    {
        IEnumerable<Album> ordered = SortMode switch
        {
            AlbumSortMode.YearDesc => _library.Albums
                .OrderByDescending(a => a.Year ?? int.MinValue)
                .ThenBy(a => a.Title, StringComparer.CurrentCultureIgnoreCase),
            _ => _library.Albums
                .OrderBy(a => a.Title, StringComparer.CurrentCultureIgnoreCase)
        };

        DisplayedAlbums = ordered.Select(a => new AlbumCardViewModel(a)).ToList();
    }

    private static Album? Resolve(object? param) => param switch
    {
        Album a => a,
        AlbumCardViewModel vm => vm.Album,
        _ => null
    };

    [RelayCommand]
    public void OpenAlbum(object? param) => OpenAlbumWithOrigin(param, null, null, NavWaveDirection.LeftToRight);

    public void OpenAlbumWithOrigin(object? param, string? backText, Action? onReturn, NavWaveDirection? waveDirection = NavWaveDirection.LeftToRight)
    {
        var album = Resolve(param);
        if (album == null) return;

        ReturnAction = onReturn;
        BackButtonText = string.IsNullOrWhiteSpace(backText) ? "Vissza az összes albumhoz" : backText;

        SelectedAlbum = album;
        IsAlbumDetailOpen = true;
        SelectedAlbumCover = null;
        if (waveDirection.HasValue)
        {
            OnNavWave?.Invoke(waveDirection.Value);
        }
        CoverArtService.LoadBitmap(album.CoverArtPath, DetailCoverDecodeWidth, bmp =>
        {
            if (ReferenceEquals(SelectedAlbum, album)) SelectedAlbumCover = bmp;
        });
    }

    [RelayCommand]
    public void CloseAlbumDetail()
    {
        var returnAction = ReturnAction;
        ReturnAction = null;
        BackButtonText = "Vissza az összes albumhoz";

        if (IsAlbumDetailOpen)
        {
            OnNavWave?.Invoke(NavWaveDirection.RightToLeft);
        }
        IsAlbumDetailOpen = false;
        SelectedAlbum = null;
        SelectedAlbumCover = null;

        returnAction?.Invoke();
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
