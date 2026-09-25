using System.Collections.ObjectModel;
using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public sealed partial class SearchBestMatchViewModel : ObservableObject
{
    [ObservableProperty] private string _typeLabel = "TALÁLAT";
    [ObservableProperty] private string _title = string.Empty;
    [ObservableProperty] private string _subtitle = string.Empty;
    [ObservableProperty] private string _meta = string.Empty;
    [ObservableProperty] private string _colorClass = "cyan";
    [ObservableProperty] private string _iconKind = "MusicNote";
    [ObservableProperty] private Bitmap? _coverBitmap;
    [ObservableProperty] private bool _hasCover;

    public IRelayCommand? PlayCommand { get; init; }
    public IRelayCommand? OpenCommand { get; init; }
}

public sealed partial class SearchResultsViewModel : ObservableObject
{
    private readonly ILibraryService _library;
    private readonly IAudioEngine _engine;
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

    public ObservableCollection<Track> MatchingTracks { get; } = new();
    public ObservableCollection<AlbumCardViewModel> MatchingAlbums { get; } = new();
    public ObservableCollection<Artist> MatchingArtists { get; } = new();

    public SearchResultsViewModel(
        ILibraryService library,
        IAudioEngine engine,
        PlayerViewModel player,
        Action<string> setSearchQueryAction,
        Action<Album> openAlbumAction,
        Action<Artist> openArtistAction)
    {
        _library = library;
        _engine = engine;
        _player = player;
        _setSearchQueryAction = setSearchQueryAction;
        _openAlbumAction = openAlbumAction;
        _openArtistAction = openArtistAction;
    }

    public void UpdateQuery(string newQuery)
    {
        Query = newQuery?.Trim() ?? string.Empty;
        IsSearchActive = !string.IsNullOrWhiteSpace(Query);

        if (!IsSearchActive)
        {
            MatchingTracks.Clear();
            MatchingAlbums.Clear();
            MatchingArtists.Clear();
            BestMatch = null;
            HasResults = false;
            HasTracks = false;
            HasAlbums = false;
            HasArtists = false;
            return;
        }

        ExecuteSearch(Query);
    }

    private void ExecuteSearch(string q)
    {
        var tracks = _library.Tracks
            .Where(t => t.Title.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                        t.Artist.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                        t.Album.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Take(25)
            .ToList();

        var albums = _library.Albums
            .Where(a => a.Title.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                        a.Artist.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Take(12)
            .ToList();

        var artists = _library.Artists
            .Where(a => a.Name.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Take(12)
            .ToList();

        MatchingTracks.Clear();
        foreach (var t in tracks) MatchingTracks.Add(t);

        MatchingAlbums.Clear();
        foreach (var a in albums) MatchingAlbums.Add(new AlbumCardViewModel(a));

        MatchingArtists.Clear();
        foreach (var art in artists) MatchingArtists.Add(art);

        HasTracks = MatchingTracks.Count > 0;
        HasAlbums = MatchingAlbums.Count > 0;
        HasArtists = MatchingArtists.Count > 0;
        HasResults = HasTracks || HasAlbums || HasArtists;

        ComputeBestMatch(q, tracks, albums, artists);
    }

    private void ComputeBestMatch(string q, List<Track> tracks, List<Album> albums, List<Artist> artists)
    {
        // 1. Exact or starts-with Artist match
        var exactArtist = artists.FirstOrDefault(a => a.Name.Equals(q, StringComparison.OrdinalIgnoreCase)) ??
                          artists.FirstOrDefault(a => a.Name.StartsWith(q, StringComparison.OrdinalIgnoreCase));
        if (exactArtist != null)
        {
            BestMatch = new SearchBestMatchViewModel
            {
                TypeLabel = "ELŐADÓ",
                Title = exactArtist.Name,
                Subtitle = "Előadó",
                Meta = $"{exactArtist.TrackCount} zeneszám az adatbázisban",
                ColorClass = "coral",
                IconKind = "AccountMusic",
                HasCover = false,
                PlayCommand = new RelayCommand(async () =>
                {
                    var artistTracks = _library.Tracks.Where(t => t.Artist.Equals(exactArtist.Name, StringComparison.OrdinalIgnoreCase)).ToList();
                    if (artistTracks.Count > 0)
                    {
                        _player.PlayQueue(artistTracks, artistTracks[0]);
                        await _engine.PlayTrackAsync(artistTracks[0]);
                    }
                }),
                OpenCommand = new RelayCommand(() => _openArtistAction(exactArtist))
            };
            return;
        }

        // 2. Exact or starts-with Album match
        var exactAlbum = albums.FirstOrDefault(a => a.Title.Equals(q, StringComparison.OrdinalIgnoreCase)) ??
                         albums.FirstOrDefault(a => a.Title.StartsWith(q, StringComparison.OrdinalIgnoreCase));
        if (exactAlbum != null)
        {
            var matchVm = new SearchBestMatchViewModel
            {
                TypeLabel = "ALBUM",
                Title = exactAlbum.Title,
                Subtitle = exactAlbum.Artist,
                Meta = $"{exactAlbum.Year} • {exactAlbum.TrackCount} zeneszám",
                ColorClass = "purple",
                IconKind = "Album",
                PlayCommand = new RelayCommand(async () =>
                {
                    var albumTracks = _library.Tracks.Where(t => t.Album.Equals(exactAlbum.Title, StringComparison.OrdinalIgnoreCase)).ToList();
                    if (albumTracks.Count > 0)
                    {
                        _player.PlayQueue(albumTracks, albumTracks[0]);
                        await _engine.PlayTrackAsync(albumTracks[0]);
                    }
                }),
                OpenCommand = new RelayCommand(() => _openAlbumAction(exactAlbum))
            };

            var coverPath = !string.IsNullOrEmpty(exactAlbum.CoverArtPath)
                ? exactAlbum.CoverArtPath
                : (exactAlbum.Tracks.Count > 0 ? exactAlbum.Tracks[0].CoverArtPath : null);
            CoverArtService.LoadBitmap(coverPath, bmp =>
            {
                matchVm.CoverBitmap = bmp;
                matchVm.HasCover = bmp != null;
            });

            BestMatch = matchVm;
            return;
        }

        // 3. Exact or starts-with Track match
        var exactTrack = tracks.FirstOrDefault(t => t.Title.Equals(q, StringComparison.OrdinalIgnoreCase)) ??
                         tracks.FirstOrDefault(t => t.Title.StartsWith(q, StringComparison.OrdinalIgnoreCase)) ??
                         tracks.FirstOrDefault();
        if (exactTrack != null)
        {
            var matchVm = new SearchBestMatchViewModel
            {
                TypeLabel = "ZENESZÁM",
                Title = exactTrack.Title,
                Subtitle = $"{exactTrack.Artist} • {exactTrack.Album}",
                Meta = $"{exactTrack.FormattedDuration} • {exactTrack.Format.QualityLabel}",
                ColorClass = "cyan",
                IconKind = "MusicNote",
                PlayCommand = new RelayCommand(async () =>
                {
                    _player.PlayQueue(new[] { exactTrack }, exactTrack);
                    await _engine.PlayTrackAsync(exactTrack);
                }),
                OpenCommand = new RelayCommand(async () =>
                {
                    _player.PlayQueue(new[] { exactTrack }, exactTrack);
                    await _engine.PlayTrackAsync(exactTrack);
                })
            };

            CoverArtService.LoadBitmap(exactTrack.CoverArtPath, bmp =>
            {
                matchVm.CoverBitmap = bmp;
                matchVm.HasCover = bmp != null;
            });

            BestMatch = matchVm;
            return;
        }

        // 4. Fallback to any artist or album
        if (artists.Count > 0)
        {
            var art = artists[0];
            BestMatch = new SearchBestMatchViewModel
            {
                TypeLabel = "ELŐADÓ",
                Title = art.Name,
                Subtitle = "Előadó",
                Meta = $"{art.TrackCount} zeneszám",
                ColorClass = "coral",
                IconKind = "AccountMusic",
                HasCover = false,
                PlayCommand = new RelayCommand(async () =>
                {
                    var artistTracks = _library.Tracks.Where(t => t.Artist.Equals(art.Name, StringComparison.OrdinalIgnoreCase)).ToList();
                    if (artistTracks.Count > 0)
                    {
                        _player.PlayQueue(artistTracks, artistTracks[0]);
                        await _engine.PlayTrackAsync(artistTracks[0]);
                    }
                }),
                OpenCommand = new RelayCommand(() => _openArtistAction(art))
            };
        }
        else if (albums.Count > 0)
        {
            var alb = albums[0];
            var matchVm = new SearchBestMatchViewModel
            {
                TypeLabel = "ALBUM",
                Title = alb.Title,
                Subtitle = alb.Artist,
                Meta = $"{alb.Year} • {alb.TrackCount} zeneszám",
                ColorClass = "purple",
                IconKind = "Album",
                PlayCommand = new RelayCommand(async () =>
                {
                    var albumTracks = _library.Tracks.Where(t => t.Album.Equals(alb.Title, StringComparison.OrdinalIgnoreCase)).ToList();
                    if (albumTracks.Count > 0)
                    {
                        _player.PlayQueue(albumTracks, albumTracks[0]);
                        await _engine.PlayTrackAsync(albumTracks[0]);
                    }
                }),
                OpenCommand = new RelayCommand(() => _openAlbumAction(alb))
            };
            CoverArtService.LoadBitmap(alb.CoverArtPath, bmp =>
            {
                matchVm.CoverBitmap = bmp;
                matchVm.HasCover = bmp != null;
            });
            BestMatch = matchVm;
        }
        else
        {
            BestMatch = null;
        }
    }

    [RelayCommand]
    public async Task PlayTrack(Track? track)
    {
        if (track == null) return;
        _player.PlayQueue(MatchingTracks, track);
        await _engine.PlayTrackAsync(track);
    }

    [RelayCommand]
    public void OpenAlbum(object? parameter)
    {
        Album? album = parameter switch
        {
            Album a => a,
            AlbumCardViewModel vm => vm.Album,
            _ => null
        };
        if (album == null) return;
        _openAlbumAction(album);
    }

    [RelayCommand]
    public void OpenArtist(Artist? artist)
    {
        if (artist == null) return;
        _openArtistAction(artist);
    }

    [RelayCommand]
    public void ClearSearch()
    {
        _setSearchQueryAction(string.Empty);
    }
}
