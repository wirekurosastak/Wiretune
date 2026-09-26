using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Controls;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class PlaylistsViewModel : ObservableObject
{
    private readonly ILibraryService _library;
    private readonly PlayerViewModel _player;

    public Action<NavWaveDirection>? OnNavWave { get; set; }

    [ObservableProperty] private IReadOnlyList<Playlist> _playlists = Array.Empty<Playlist>();
    [ObservableProperty] private IReadOnlyList<PlaylistCardViewModel> _displayedPlaylists = Array.Empty<PlaylistCardViewModel>();
    [ObservableProperty] private Playlist? _selectedPlaylist;
    [ObservableProperty] private PlaylistCardViewModel? _selectedPlaylistCard;
    [ObservableProperty] private IReadOnlyList<Track> _selectedPlaylistTracks = Array.Empty<Track>();
    [ObservableProperty] private bool _hasPlaylists;
    [ObservableProperty] private bool _isSelectedPlaylistEmpty;
    [ObservableProperty] private bool _isPlaylistDetailOpen;

    // "New playlist" dialog, optionally adding a pending track once created.
    [ObservableProperty] private bool _isCreateDialogOpen;
    [ObservableProperty] private string _newPlaylistName = string.Empty;

    // "Add to playlist" dialog.
    [ObservableProperty] private bool _isAddToPlaylistDialogOpen;
    [ObservableProperty] private Track? _trackToAdd;

    // Delete confirmation.
    [ObservableProperty] private Playlist? _playlistPendingDelete;

    public bool IsDeleteConfirmOpen => PlaylistPendingDelete != null;
    public bool IsAnyDialogOpen => IsCreateDialogOpen || IsAddToPlaylistDialogOpen || IsDeleteConfirmOpen;

    public PlaylistsViewModel(ILibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.PlaylistsChanged += (_, _) => Ui.Post(RefreshPlaylists);
        _library.LibraryChanged += (_, _) => Ui.Post(RefreshPlaylists);
        RefreshPlaylists();
    }

    partial void OnIsCreateDialogOpenChanged(bool value) => OnPropertyChanged(nameof(IsAnyDialogOpen));
    partial void OnIsAddToPlaylistDialogOpenChanged(bool value) => OnPropertyChanged(nameof(IsAnyDialogOpen));

    partial void OnPlaylistPendingDeleteChanged(Playlist? value)
    {
        OnPropertyChanged(nameof(IsDeleteConfirmOpen));
        OnPropertyChanged(nameof(IsAnyDialogOpen));
    }

    public void RefreshPlaylists()
    {
        var selectedId = SelectedPlaylist?.Id;
        Playlists = _library.Playlists;
        var cardList = new List<PlaylistCardViewModel>();
        foreach (var pl in Playlists)
        {
            var tracks = _library.GetPlaylistTracks(pl);
            if (tracks.Count == 0)
            {
                pl.FormatBadge = string.Empty;
            }
            else
            {
                var distinctSpecs = tracks.Select(t => t.Format)
                    .Select(f => (f.BitsPerSample, f.SampleRate, f.IsLossless, f.Codec))
                    .Distinct()
                    .ToList();
                pl.FormatBadge = distinctSpecs.Count > 1
                    ? "Mixed HQ"
                    : tracks[0].Format.DisplayBadge;
            }
            cardList.Add(new PlaylistCardViewModel(pl, tracks));
        }
        DisplayedPlaylists = cardList;
        HasPlaylists = Playlists.Count > 0;
        SelectedPlaylist = selectedId == null ? null : _library.GetPlaylist(selectedId);
        if (SelectedPlaylist == null) IsPlaylistDetailOpen = false;
        RefreshSelectedTracks();
    }

    partial void OnSelectedPlaylistChanged(Playlist? value) => RefreshSelectedTracks();

    private void RefreshSelectedTracks()
    {
        SelectedPlaylistTracks = SelectedPlaylist == null ? Array.Empty<Track>() : _library.GetPlaylistTracks(SelectedPlaylist);
        SelectedPlaylistCard = SelectedPlaylist == null ? null : new PlaylistCardViewModel(SelectedPlaylist, SelectedPlaylistTracks);
        IsSelectedPlaylistEmpty = SelectedPlaylist != null && SelectedPlaylistTracks.Count == 0;
        if (SelectedPlaylist != null)
        {
            if (SelectedPlaylistTracks.Count == 0)
            {
                SelectedPlaylist.FormatBadge = string.Empty;
            }
            else
            {
                var distinctSpecs = SelectedPlaylistTracks.Select(t => t.Format)
                    .Select(f => (f.BitsPerSample, f.SampleRate, f.IsLossless, f.Codec))
                    .Distinct()
                    .ToList();
                SelectedPlaylist.FormatBadge = distinctSpecs.Count > 1
                    ? "Mixed HQ"
                    : SelectedPlaylistTracks[0].Format.DisplayBadge;
            }
        }
    }

    private static Playlist? Resolve(object? param) => param switch
    {
        Playlist p => p,
        PlaylistCardViewModel vm => vm.Playlist,
        _ => null
    };

    [RelayCommand]
    public void OpenPlaylist(object? param)
    {
        var playlist = Resolve(param);
        if (playlist == null) return;
        SelectedPlaylist = playlist;
        IsPlaylistDetailOpen = true;
        OnNavWave?.Invoke(NavWaveDirection.LeftToRight);
    }

    [RelayCommand]
    public void ClosePlaylistDetail()
    {
        if (IsPlaylistDetailOpen)
        {
            OnNavWave?.Invoke(NavWaveDirection.RightToLeft);
        }
        IsPlaylistDetailOpen = false;
        SelectedPlaylist = null;
    }

    [RelayCommand]
    public void OpenCreateDialog()
    {
        NewPlaylistName = string.Empty;
        IsAddToPlaylistDialogOpen = false;
        IsCreateDialogOpen = true;
    }

    [RelayCommand]
    public void CloseCreateDialog()
    {
        IsCreateDialogOpen = false;
        TrackToAdd = null;
    }

    [RelayCommand]
    public async Task CreatePlaylistAsync()
    {
        if (string.IsNullOrWhiteSpace(NewPlaylistName)) return;

        var playlist = await _library.CreatePlaylistAsync(NewPlaylistName);
        if (TrackToAdd != null) await _library.AddTrackToPlaylistAsync(playlist.Id, TrackToAdd.Id);

        IsCreateDialogOpen = false;
        TrackToAdd = null;
        RefreshPlaylists();
        SelectedPlaylist = _library.GetPlaylist(playlist.Id);
        IsPlaylistDetailOpen = true;
    }

    [RelayCommand]
    public void RequestDeletePlaylist(object? param) => PlaylistPendingDelete = Resolve(param);

    [RelayCommand]
    public void CancelDeletePlaylist() => PlaylistPendingDelete = null;

    [RelayCommand]
    public async Task ConfirmDeletePlaylistAsync()
    {
        var playlist = PlaylistPendingDelete;
        PlaylistPendingDelete = null;
        if (playlist != null) await DeletePlaylistAsync(playlist);
    }

    [RelayCommand]
    public async Task DeletePlaylistAsync(object? param)
    {
        var playlist = Resolve(param);
        if (playlist == null) return;
        await _library.DeletePlaylistAsync(playlist.Id);
        if (SelectedPlaylist?.Id == playlist.Id)
        {
            SelectedPlaylist = null;
            IsPlaylistDetailOpen = false;
        }
        RefreshPlaylists();
    }

    [RelayCommand]
    public void PlayPlaylist(object? param)
    {
        var target = Resolve(param) ?? SelectedPlaylist;
        if (target == null) return;
        var tracks = _library.GetPlaylistTracks(target);
        if (tracks.Count > 0) _player.PlayQueue(tracks);
    }

    [RelayCommand]
    public void ShufflePlaylist(object? param)
    {
        var target = Resolve(param) ?? SelectedPlaylist;
        if (target == null) return;
        var tracks = _library.GetPlaylistTracks(target);
        if (tracks.Count == 0) return;
        _player.IsShuffle = true;
        _player.PlayQueue(tracks);
    }

    [RelayCommand]
    public void PlayTrack(Track? track)
    {
        if (track != null) _player.PlayQueue(SelectedPlaylistTracks, track);
    }

    [RelayCommand]
    public async Task RemoveTrackFromSelectedAsync(Track? track)
    {
        if (track != null && SelectedPlaylist != null)
        {
            await _library.RemoveTrackFromPlaylistAsync(SelectedPlaylist.Id, track.Id);
            RefreshPlaylists();
        }
    }

    public void BeginAddTrack(Track track)
    {
        TrackToAdd = track;
        IsAddToPlaylistDialogOpen = true;
    }

    [RelayCommand]
    public void CancelAddTrack()
    {
        IsAddToPlaylistDialogOpen = false;
        TrackToAdd = null;
    }

    [RelayCommand]
    public async Task AddPendingTrackToAsync(Playlist? playlist)
    {
        if (playlist != null && TrackToAdd != null)
        {
            await _library.AddTrackToPlaylistAsync(playlist.Id, TrackToAdd.Id);
        }
        CancelAddTrack();
    }

    [RelayCommand]
    public void CreatePlaylistForPendingTrack()
    {
        NewPlaylistName = TrackToAdd?.Album ?? string.Empty;
        IsAddToPlaylistDialogOpen = false;
        IsCreateDialogOpen = true;
    }
}
