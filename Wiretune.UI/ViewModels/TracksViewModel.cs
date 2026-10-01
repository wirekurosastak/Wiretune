using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Services;
using Wiretune.Core.Localization;

namespace Wiretune.UI.ViewModels;

public partial class TracksViewModel : ObservableObject
{
    private readonly LibraryService _library;
    private readonly PlayerViewModel _player;

    [ObservableProperty] private IReadOnlyList<Track> _displayedTracks = Array.Empty<Track>();
    [ObservableProperty] private int _totalTracksCount;
    [ObservableProperty] private string _totalTracksDuration = string.Empty;
    [ObservableProperty] private bool _hasTracks;

    public TracksViewModel(LibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Ui.Post(RefreshTracks);
        RefreshTracks();
    }

    public void RefreshTracks()
    {
        DisplayedTracks = _library.Tracks;
        TotalTracksCount = DisplayedTracks.Count;
        HasTracks = TotalTracksCount > 0;
        TotalTracksDuration = FormatTotal(TimeSpan.FromSeconds(DisplayedTracks.Sum(t => t.Duration.TotalSeconds)));
    }

    internal static string FormatTotal(TimeSpan ts) => Localizer.FormatTotalDuration(ts);

    [RelayCommand]
    public void PlayTrack(Track? track)
    {
        if (track != null) _player.PlayQueue(DisplayedTracks, track);
    }

    [RelayCommand]
    public void PlayAll()
    {
        if (DisplayedTracks.Count > 0) _player.PlayQueue(DisplayedTracks);
    }

    [RelayCommand]
    public void ShuffleAll()
    {
        if (DisplayedTracks.Count == 0) return;
        _player.IsShuffle = true;
        _player.PlayQueue(DisplayedTracks);
    }

    [RelayCommand]
    public async Task ToggleFavoriteAsync(Track? track)
    {
        if (track != null) await _library.ToggleFavoriteAsync(track.Id);
    }
}


