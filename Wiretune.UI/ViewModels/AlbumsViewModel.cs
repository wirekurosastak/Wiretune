using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Controls;
using Wiretune.UI.Services;
using Wiretune.Core.Localization;

namespace Wiretune.UI.ViewModels;

public enum AlbumSortField
{
    Title,
    Year
}

public partial class AlbumsViewModel : ObservableObject
{
    private const int DetailCoverDecodeWidth = 480;

    private readonly LibraryService _library;
    private readonly PlayerViewModel _player;

    public Action<NavWaveDirection>? OnNavWave { get; set; }
    public Action? ReturnAction { get; set; }

    [ObservableProperty] private IReadOnlyList<AlbumCardViewModel> _displayedAlbums = Array.Empty<AlbumCardViewModel>();
    [ObservableProperty] private Album? _selectedAlbum;
    [ObservableProperty] private Bitmap? _selectedAlbumCover;
    [ObservableProperty] private bool _isAlbumDetailOpen;
    private Func<string>? _backTextSource;
    [ObservableProperty] private AlbumSortField _sortField = AlbumSortField.Title;
    [ObservableProperty] private bool _isSortDescending;

    public AlbumsViewModel(LibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Ui.Post(RefreshAlbums);
        RefreshAlbums();
    }

    public bool IsSortByTitle => SortField == AlbumSortField.Title;
    public bool IsSortByYear => SortField == AlbumSortField.Year;

    /// <summary>Label of the back button: where it leads to, or "all albums" when the detail was opened from the album list.</summary>
    public string BackButtonText => _backTextSource?.Invoke() is { Length: > 0 } text ? text : Localizer.Get("BackToAlbums");

    public string SortTitleLabel => IsSortByTitle ? $"ABC {(IsSortDescending ? "↓" : "↑")}" : "ABC";
    public string SortYearLabel => IsSortByYear ? $"{Localizer.Get("SortYear")} {(IsSortDescending ? "↓" : "↑")}" : Localizer.Get("SortYear");

    /// <summary>Re-renders the texts that were computed in the previous language.</summary>
    public void RefreshLocalizedTexts()
    {
        OnPropertyChanged(nameof(BackButtonText));
        OnPropertyChanged(nameof(SortYearLabel));
    }

    partial void OnSortFieldChanged(AlbumSortField value) => OnSortChanged();
    partial void OnIsSortDescendingChanged(bool value) => OnSortChanged();

    private void OnSortChanged()
    {
        OnPropertyChanged(nameof(IsSortByTitle));
        OnPropertyChanged(nameof(IsSortByYear));
        OnPropertyChanged(nameof(SortTitleLabel));
        OnPropertyChanged(nameof(SortYearLabel));
        ApplySort();
    }

    /// <summary>
    /// Clicking the active sort field flips its direction; clicking the other one switches to it
    /// with its natural default (A→Z for titles, newest first for years).
    /// </summary>
    [RelayCommand]
    public void SetSortField(object? param)
    {
        var field = param switch
        {
            AlbumSortField f => f,
            string s when Enum.TryParse<AlbumSortField>(s, out var parsed) => parsed,
            _ => (AlbumSortField?)null
        };
        if (field == null) return;

        if (field == SortField)
        {
            IsSortDescending = !IsSortDescending;
            return;
        }

        // Set direction first so the single re-sort below already sees the final state.
        _suppressSort = true;
        IsSortDescending = field == AlbumSortField.Year;
        _suppressSort = false;
        SortField = field.Value;
    }

    private bool _suppressSort;

    public void RefreshAlbums()
    {
        ApplySort();

        if (SelectedAlbum != null)
        {
            var previous = SelectedAlbum;
            var updated = _library.GetAlbum(previous.Id);
            if (updated == null)
            {
                CloseAlbumDetail();
            }
            else
            {
                SelectedAlbum = updated;
                if (updated.CoverArtPath != previous.CoverArtPath) LoadSelectedCover(updated);
            }
        }
    }

    private void ApplySort()
    {
        if (_suppressSort) return;

        IEnumerable<Album> ordered;
        if (SortField == AlbumSortField.Year)
        {
            // Albums without a year always go last, in either direction.
            var byYear = _library.Albums.OrderBy(a => a.Year == null);
            ordered = IsSortDescending
                ? byYear.ThenByDescending(a => a.Year ?? 0).ThenBy(a => a.Title, StringComparer.CurrentCultureIgnoreCase)
                : byYear.ThenBy(a => a.Year ?? 0).ThenBy(a => a.Title, StringComparer.CurrentCultureIgnoreCase);
        }
        else
        {
            ordered = IsSortDescending
                ? _library.Albums.OrderByDescending(a => a.Title, StringComparer.CurrentCultureIgnoreCase)
                : _library.Albums.OrderBy(a => a.Title, StringComparer.CurrentCultureIgnoreCase);
        }

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

    /// <param name="backTextSource">Produces the back button label; called again whenever the language changes.</param>
    public void OpenAlbumWithOrigin(object? param, Func<string>? backTextSource, Action? onReturn, NavWaveDirection? waveDirection = NavWaveDirection.LeftToRight)
    {
        var album = Resolve(param);
        if (album == null) return;

        ReturnAction = onReturn;
        _backTextSource = backTextSource;
        OnPropertyChanged(nameof(BackButtonText));

        SelectedAlbum = album;
        IsAlbumDetailOpen = true;
        SelectedAlbumCover = null;
        if (waveDirection.HasValue)
        {
            OnNavWave?.Invoke(waveDirection.Value);
        }
        LoadSelectedCover(album);
    }

    private void LoadSelectedCover(Album album) =>
        CoverArtService.LoadBitmap(album.CoverArtPath, DetailCoverDecodeWidth, bmp =>
        {
            // Compare by id: a library refresh replaces the Album object while the cover is still loading.
            if (SelectedAlbum?.Id == album.Id) SelectedAlbumCover = bmp;
        });

    [RelayCommand]
    public void CloseAlbumDetail()
    {
        var returnAction = ReturnAction;
        ReturnAction = null;
        _backTextSource = null;
        OnPropertyChanged(nameof(BackButtonText));

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


