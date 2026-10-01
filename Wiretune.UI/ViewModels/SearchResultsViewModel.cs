using Avalonia.Media;
using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Localization;
using Wiretune.Core.Services;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public sealed partial class SearchBestMatchViewModel : ObservableObject
{
    [ObservableProperty] private string _typeLabel = Localizer.Get("TypeMatch");
    [ObservableProperty] private IBrush _typeBrush = new SolidColorBrush(Color.Parse("#67C8E0"));
    [ObservableProperty] private string _title = string.Empty;
    [ObservableProperty] private string _subtitle = string.Empty;
    [ObservableProperty] private string _meta = string.Empty;
    [ObservableProperty] private string _iconKind = "MusicNote";
    [ObservableProperty] private Bitmap? _coverBitmap;
    [ObservableProperty] private bool _hasCover;
    [ObservableProperty] private bool _canOpen;

    public IRelayCommand? PlayCommand { get; init; }
    public IRelayCommand? OpenCommand { get; init; }

    public void LoadCover(string? path)
    {
        CoverArtService.LoadBitmap(path, AlbumCardViewModel.CoverDecodeWidth, bmp =>
        {
            CoverBitmap = bmp;
            HasCover = bmp != null;
        });
    }
}

public sealed partial class SearchResultsViewModel : ObservableObject
{
    private const int MaxTracks = 25;
    private const int MaxCards = 12;

    private readonly LibraryService _library;
    private readonly PlayerViewModel _player;
    private readonly Action<string> _setSearchQueryAction;
    private readonly Action<Album> _openAlbumAction;
    private readonly Action<Artist> _openArtistAction;

    [ObservableProperty] private string _query = string.Empty;
    [ObservableProperty] private bool _isSearchActive;
    [ObservableProperty] private bool _hasResults;
    [ObservableProperty] private bool _hasTracks;
    [ObservableProperty] private bool _hasAlbums;
    [ObservableProperty] private bool _hasArtists;
    [ObservableProperty] private SearchBestMatchViewModel? _bestMatch;
    [ObservableProperty] private IReadOnlyList<Track> _matchingTracks = Array.Empty<Track>();
    [ObservableProperty] private IReadOnlyList<AlbumCardViewModel> _matchingAlbums = Array.Empty<AlbumCardViewModel>();
    [ObservableProperty] private IReadOnlyList<Artist> _matchingArtists = Array.Empty<Artist>();

    public SearchResultsViewModel(
        LibraryService library,
        PlayerViewModel player,
        Action<string> setSearchQueryAction,
        Action<Album> openAlbumAction,
        Action<Artist> openArtistAction)
    {
        _library = library;
        _player = player;
        _setSearchQueryAction = setSearchQueryAction;
        _openAlbumAction = openAlbumAction;
        _openArtistAction = openArtistAction;

        _library.LibraryChanged += (_, _) => Ui.Post(() =>
        {
            if (IsSearchActive) ExecuteSearch(Query);
        });
    }

    /// <summary>Re-renders the texts that were computed in the previous language.</summary>
    public void RefreshLocalizedTexts()
    {
        if (IsSearchActive) ExecuteSearch(Query);
    }

    public void UpdateQuery(string? newQuery)
    {
        Query = newQuery?.Trim() ?? string.Empty;
        IsSearchActive = Query.Length > 0;

        if (IsSearchActive)
        {
            ExecuteSearch(Query);
            return;
        }

        MatchingTracks = Array.Empty<Track>();
        MatchingAlbums = Array.Empty<AlbumCardViewModel>();
        MatchingArtists = Array.Empty<Artist>();
        BestMatch = null;
        HasResults = HasTracks = HasAlbums = HasArtists = false;
    }

    private void ExecuteSearch(string q)
    {
        var tracks = _library.Search(q).Take(MaxTracks).ToList();
        var albums = _library.Albums
            .Where(a => a.Title.Contains(q, StringComparison.OrdinalIgnoreCase) || a.Artist.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Take(MaxCards)
            .ToList();
        var artists = _library.Artists
            .Where(a => a.Name.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Take(MaxCards)
            .ToList();

        MatchingTracks = tracks;
        MatchingAlbums = albums.Select(a => new AlbumCardViewModel(a)).ToList();
        MatchingArtists = artists;

        HasTracks = tracks.Count > 0;
        HasAlbums = albums.Count > 0;
        HasArtists = artists.Count > 0;
        HasResults = HasTracks || HasAlbums || HasArtists;
        BestMatch = ComputeBestMatch(q, tracks, albums, artists);
    }

    private SearchBestMatchViewModel? ComputeBestMatch(string q, List<Track> tracks, List<Album> albums, List<Artist> artists)
    {
        var artist = artists.FirstOrDefault(a => a.Name.Equals(q, StringComparison.OrdinalIgnoreCase))
                     ?? artists.FirstOrDefault(a => a.Name.StartsWith(q, StringComparison.OrdinalIgnoreCase));
        if (artist != null) return ArtistMatch(artist);

        var album = albums.FirstOrDefault(a => a.Title.Equals(q, StringComparison.OrdinalIgnoreCase))
                    ?? albums.FirstOrDefault(a => a.Title.StartsWith(q, StringComparison.OrdinalIgnoreCase));
        if (album != null) return AlbumMatch(album);

        var track = tracks.FirstOrDefault(t => t.Title.Equals(q, StringComparison.OrdinalIgnoreCase))
                    ?? tracks.FirstOrDefault(t => t.Title.StartsWith(q, StringComparison.OrdinalIgnoreCase))
                    ?? tracks.FirstOrDefault();
        if (track != null) return TrackMatch(track);

        if (artists.Count > 0) return ArtistMatch(artists[0]);
        if (albums.Count > 0) return AlbumMatch(albums[0]);
        return null;
    }

    private SearchBestMatchViewModel ArtistMatch(Artist artist)
    {
        var vm = new SearchBestMatchViewModel
        {
            TypeLabel = Localizer.Get("TypeArtist"),
            TypeBrush = new SolidColorBrush(Color.Parse("#FF6B6B")),
            Title = artist.Name,
            Subtitle = Localizer.Get("SubtitleArtist"),
            Meta = $"{Localizer.Format("AlbumCount", artist.AlbumCount)} • {Localizer.Format("TrackCount", artist.TrackCount)}",
            IconKind = "AccountMusic",
            CanOpen = true,
            PlayCommand = new RelayCommand(() => { if (artist.Tracks.Count > 0) _player.PlayQueue(artist.Tracks); }),
            OpenCommand = new RelayCommand(() => _openArtistAction(artist))
        };
        vm.LoadCover(artist.PicturePath);
        return vm;
    }

    private SearchBestMatchViewModel AlbumMatch(Album album)
    {
        var vm = new SearchBestMatchViewModel
        {
            TypeLabel = Localizer.Get("TypeAlbum"),
            TypeBrush = new SolidColorBrush(Color.Parse("#D05CE3")),
            Title = album.Title,
            Subtitle = album.Artist,
            Meta = album.Year.HasValue ? $"{album.Year} • {Localizer.Format("TrackCount", album.TrackCount)}" : Localizer.Format("TrackCount", album.TrackCount),
            IconKind = "Album",
            CanOpen = true,
            PlayCommand = new RelayCommand(() => { if (album.Tracks.Count > 0) _player.PlayQueue(album.Tracks); }),
            OpenCommand = new RelayCommand(() => _openAlbumAction(album))
        };
        vm.LoadCover(album.CoverArtPath);
        return vm;
    }

    private SearchBestMatchViewModel TrackMatch(Track track)
    {
        var album = _library.GetAlbumForTrack(track);
        var vm = new SearchBestMatchViewModel
        {
            TypeLabel = Localizer.Get("TypeTrack"),
            TypeBrush = new SolidColorBrush(Color.Parse("#67C8E0")),
            Title = track.Title,
            Subtitle = $"{track.Artist} • {track.Album}",
            Meta = $"{track.FormattedDuration} • {track.Format.QualityLabel}",
            IconKind = "MusicNote",
            CanOpen = false,
            PlayCommand = new RelayCommand(() => _player.PlayQueue(new[] { track }, track)),
            OpenCommand = new RelayCommand(() =>
            {
                if (album != null) _openAlbumAction(album);
                else _player.PlayQueue(new[] { track }, track);
            })
        };
        vm.LoadCover(track.CoverArtPath);
        return vm;
    }

    [RelayCommand]
    public void PlayTrack(Track? track)
    {
        if (track != null) _player.PlayQueue(MatchingTracks, track);
    }

    [RelayCommand]
    public void OpenAlbum(object? parameter)
    {
        var album = parameter switch
        {
            Album a => a,
            AlbumCardViewModel vm => vm.Album,
            _ => null
        };
        if (album != null) _openAlbumAction(album);
    }

    [RelayCommand]
    public void OpenArtist(Artist? artist)
    {
        if (artist != null) _openArtistAction(artist);
    }

    [RelayCommand]
    public void ClearSearch() => _setSearchQueryAction(string.Empty);
}


