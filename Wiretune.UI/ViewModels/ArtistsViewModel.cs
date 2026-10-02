using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Controls;
using Wiretune.UI.Services;
using Wiretune.Core.Localization;

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
    private Func<string>? _backTextSource;
    [ObservableProperty] private IReadOnlyList<AlbumCardViewModel> _selectedArtistAlbumCards = Array.Empty<AlbumCardViewModel>();
    [ObservableProperty] private bool _hasSelectedArtistAlbums;
    [ObservableProperty] private IReadOnlyList<Track> _selectedArtistTracks = Array.Empty<Track>();
    [ObservableProperty] private bool _isSortDescending;

    public ArtistsViewModel(LibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Ui.Post(RefreshArtists);
        RefreshArtists();
    }

    /// <summary>Label of the back button: where it leads to, or "all artists" when the detail was opened from the artist list.</summary>
    public string BackButtonText => _backTextSource?.Invoke() is { Length: > 0 } text ? text : Localizer.Get("BackToArtists");

    /// <summary>Label of the sort button: the arrow shows the direction (A to Z, or Z to A).</summary>
    public string SortNameLabel => $"ABC {(IsSortDescending ? "↓" : "↑")}";

    /// <summary>Re-renders the texts that were computed in the previous language.</summary>
    public void RefreshLocalizedTexts() => OnPropertyChanged(nameof(BackButtonText));

    partial void OnIsSortDescendingChanged(bool value)
    {
        OnPropertyChanged(nameof(SortNameLabel));
        ApplySort();
    }

    /// <summary>Artists are sorted by name only: pressing the button flips between A→Z and Z→A.</summary>
    [RelayCommand]
    public void ToggleSort() => IsSortDescending = !IsSortDescending;

    private void ApplySort()
    {
        DisplayedArtists = (IsSortDescending
                ? _library.Artists.OrderByDescending(a => a.Name, StringComparer.CurrentCultureIgnoreCase)
                : _library.Artists.OrderBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase))
            .ToList();
    }

    public void RefreshArtists()
    {
        ApplySort();
        ArtistPictureService.ResolveArtistPictures(DisplayedArtists);

        if (SelectedArtist != null)
        {
            var updated = _library.GetArtist(SelectedArtist.Id);
            if (updated == null) CloseArtistDetail();
            else ShowArtist(updated, waveDirection: null); // keep where "back" leads to
        }
    }

    [RelayCommand]
    public void OpenArtist(Artist? artist) => OpenArtistWithOrigin(artist, null, null, NavWaveDirection.LeftToRight);

    /// <param name="backTextSource">Produces the back button label; called again whenever the language changes.</param>
    public void OpenArtistWithOrigin(Artist? artist, Func<string>? backTextSource, Action? onReturn, NavWaveDirection? waveDirection = NavWaveDirection.LeftToRight)
    {
        if (artist == null) return;
        ReturnAction = onReturn;
        _backTextSource = backTextSource;
        OnPropertyChanged(nameof(BackButtonText));
        ShowArtist(artist, waveDirection);
    }

    private void ShowArtist(Artist artist, NavWaveDirection? waveDirection)
    {
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
        _backTextSource = null;
        OnPropertyChanged(nameof(BackButtonText));

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


