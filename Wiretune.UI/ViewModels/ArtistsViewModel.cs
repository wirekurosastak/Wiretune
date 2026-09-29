using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Controls;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class ArtistsViewModel : ObservableObject
{
    private readonly LibraryService _library;
    private readonly PlayerViewModel _player;

    public Action<NavWaveDirection>? OnNavWave { get; set; }
    public Action? ReturnAction { get; set; }

    [ObservableProperty] private IReadOnlyList<Artist> _displayedArtists = Array.Empty<Artist>();
    [ObservableProperty] private Artist? _selectedArtist;
    [ObservableProperty] private bool _isArtistDetailOpen;
    [ObservableProperty] private string _backButtonText = "Vissza az összes előadóhoz";
    [ObservableProperty] private IReadOnlyList<AlbumCardViewModel> _selectedArtistAlbumCards = Array.Empty<AlbumCardViewModel>();
    [ObservableProperty] private bool _hasSelectedArtistAlbums;
    [ObservableProperty] private IReadOnlyList<Track> _selectedArtistTracks = Array.Empty<Track>();

    public ArtistsViewModel(LibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Ui.Post(RefreshArtists);
        RefreshArtists();
    }

    public void RefreshArtists()
    {
        DisplayedArtists = _library.Artists;
        ArtistPictureService.ResolveArtistPictures(DisplayedArtists);

        if (SelectedArtist != null)
        {
            var updated = _library.GetArtist(SelectedArtist.Id);
            if (updated == null) CloseArtistDetail();
            else OpenArtist(updated);
        }
    }

    [RelayCommand]
    public void OpenArtist(Artist? artist) => OpenArtistWithOrigin(artist, null, null, NavWaveDirection.LeftToRight);

    public void OpenArtistWithOrigin(Artist? artist, string? backText, Action? onReturn, NavWaveDirection? waveDirection = NavWaveDirection.LeftToRight)
    {
        if (artist == null) return;
        ReturnAction = onReturn;
        BackButtonText = string.IsNullOrWhiteSpace(backText) ? "Vissza az összes előadóhoz" : backText;

        SelectedArtist = artist;
        ArtistPictureService.ResolveArtistPicture(artist);
        IsArtistDetailOpen = true;
        if (waveDirection.HasValue)
        {
            OnNavWave?.Invoke(waveDirection.Value);
        }
        SelectedArtistAlbumCards = artist.Albums
            .OrderByDescending(a => a.Year ?? int.MinValue)
            .ThenBy(a => a.Title, StringComparer.CurrentCultureIgnoreCase)
            .Select(a => new AlbumCardViewModel(a))
            .ToList();
        HasSelectedArtistAlbums = SelectedArtistAlbumCards.Count > 0;
        SelectedArtistTracks = artist.Tracks;
    }

    [RelayCommand]
    public void CloseArtistDetail()
    {
        var returnAction = ReturnAction;
        ReturnAction = null;
        BackButtonText = "Vissza az összes előadóhoz";

        if (IsArtistDetailOpen)
        {
            OnNavWave?.Invoke(NavWaveDirection.RightToLeft);
        }
        IsArtistDetailOpen = false;
        SelectedArtist = null;
        SelectedArtistAlbumCards = Array.Empty<AlbumCardViewModel>();
        HasSelectedArtistAlbums = false;
        SelectedArtistTracks = Array.Empty<Track>();

        returnAction?.Invoke();
    }

    [RelayCommand]
    public void PlayArtist(Artist? artist)
    {
        var target = artist ?? SelectedArtist;
        if (target == null || target.Tracks.Count == 0) return;
        _player.PlayQueue(target.Tracks);
    }

    [RelayCommand]
    public void ShuffleArtist(Artist? artist)
    {
        var target = artist ?? SelectedArtist;
        if (target == null || target.Tracks.Count == 0) return;
        var shuffled = target.Tracks.OrderBy(_ => Random.Shared.Next()).ToList();
        _player.PlayQueue(shuffled);
    }

    [RelayCommand]
    public void PlayArtistTrack(Track? track)
    {
        if (track != null && SelectedArtist != null) _player.PlayQueue(SelectedArtist.Tracks, track);
    }
}


