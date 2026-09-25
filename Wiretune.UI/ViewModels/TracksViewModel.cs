using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;

namespace Wiretune.UI.ViewModels;

public partial class TracksViewModel : ObservableObject
{
    private readonly ILibraryService _library;
    private readonly PlayerViewModel _player;

    [ObservableProperty] private string _searchFilter = string.Empty;
    [ObservableProperty] private Track? _selectedTrack;
    [ObservableProperty] private int _totalTracksCount;
    [ObservableProperty] private string _totalTracksDuration = "0 perc";
    [ObservableProperty] private bool _hasTracks;
    [ObservableProperty] private bool _isEmpty = true;

    public ObservableCollection<Track> DisplayedTracks { get; } = new();

    public TracksViewModel(ILibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(RefreshTracks);
        RefreshTracks();
    }

    public void RefreshTracks()
    {
        var tracks = string.IsNullOrWhiteSpace(SearchFilter)
            ? _library.Tracks
            : _library.Search(SearchFilter);

        DisplayedTracks.Clear();
        foreach (var t in tracks)
        {
            DisplayedTracks.Add(t);
        }

        TotalTracksCount = DisplayedTracks.Count;
        HasTracks = TotalTracksCount > 0;
        IsEmpty = !HasTracks;
        var totalSecs = DisplayedTracks.Sum(t => t.Duration.TotalSeconds);
        var ts = TimeSpan.FromSeconds(totalSecs);
        TotalTracksDuration = ts.Hours > 0
            ? $"{(int)ts.TotalHours} óra {ts.Minutes} perc"
            : $"{ts.Minutes} perc {ts.Seconds} mp";
    }

    partial void OnSearchFilterChanged(string value)
    {
        RefreshTracks();
    }

    [RelayCommand]
    public void PlayTrack(Track? track)
    {
        if (track == null) return;
        _player.PlayQueue(DisplayedTracks, track);
    }

    [RelayCommand]
    public void PlayAll()
    {
        if (DisplayedTracks.Count > 0)
        {
            _player.PlayQueue(DisplayedTracks);
        }
    }

    [RelayCommand]
    public void ShuffleAll()
    {
        if (DisplayedTracks.Count > 0)
        {
            _player.IsShuffle = true;
            _player.PlayQueue(DisplayedTracks);
        }
    }

    [RelayCommand]
    public async Task ToggleFavoriteAsync(Track? track)
    {
        if (track == null) return;
        await _library.ToggleFavoriteAsync(track.Id);
        RefreshTracks();
    }
}
