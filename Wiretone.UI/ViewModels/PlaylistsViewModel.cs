using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretone.Core.Models;
using Wiretone.Core.Services;

namespace Wiretone.UI.ViewModels;

public partial class PlaylistsViewModel : ObservableObject
{
    private readonly ILibraryService _library;
    private readonly PlayerViewModel _player;

    [ObservableProperty] private Playlist? _selectedPlaylist;
    [ObservableProperty] private string _newPlaylistName = string.Empty;
    [ObservableProperty] private bool _isCreateDialogOpen;

    public ObservableCollection<Playlist> Playlists { get; } = new();
    public ObservableCollection<Track> SelectedPlaylistTracks { get; } = new();

    public PlaylistsViewModel(ILibraryService library, PlayerViewModel player)
    {
        _library = library;
        _player = player;

        _library.LibraryChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(RefreshPlaylists);
        RefreshPlaylists();
    }

    public void RefreshPlaylists()
    {
        Playlists.Clear();
        foreach (var p in _library.Playlists)
        {
            Playlists.Add(p);
        }

        if (SelectedPlaylist != null)
        {
            RefreshPlaylistTracks(SelectedPlaylist);
        }
    }

    private void RefreshPlaylistTracks(Playlist playlist)
    {
        SelectedPlaylistTracks.Clear();
        var trackMap = _library.Tracks.ToDictionary(t => t.Id, t => t);

        foreach (var id in playlist.TrackIds)
        {
            if (trackMap.TryGetValue(id, out var tr))
            {
                SelectedPlaylistTracks.Add(tr);
            }
        }
    }

    partial void OnSelectedPlaylistChanged(Playlist? value)
    {
        if (value != null)
        {
            RefreshPlaylistTracks(value);
        }
        else
        {
            SelectedPlaylistTracks.Clear();
        }
    }

    [RelayCommand]
    public void OpenCreateDialog()
    {
        NewPlaylistName = string.Empty;
        IsCreateDialogOpen = true;
    }

    [RelayCommand]
    public void CloseCreateDialog()
    {
        IsCreateDialogOpen = false;
    }

    [RelayCommand]
    public async Task CreatePlaylistAsync()
    {
        if (string.IsNullOrWhiteSpace(NewPlaylistName)) return;

        var pl = await _library.CreatePlaylistAsync(NewPlaylistName);
        IsCreateDialogOpen = false;
        SelectedPlaylist = pl;
        RefreshPlaylists();
    }

    [RelayCommand]
    public async Task DeletePlaylistAsync(Playlist? playlist)
    {
        if (playlist == null) return;
        await _library.DeletePlaylistAsync(playlist.Id);
        if (SelectedPlaylist?.Id == playlist.Id)
        {
            SelectedPlaylist = null;
        }
        RefreshPlaylists();
    }

    [RelayCommand]
    public void PlayPlaylist(Playlist? playlist)
    {
        if (playlist == null) return;
        RefreshPlaylistTracks(playlist);
        if (SelectedPlaylistTracks.Count > 0)
        {
            _player.PlayQueue(SelectedPlaylistTracks);
        }
    }

    [RelayCommand]
    public void PlayTrack(Track? track)
    {
        if (track == null) return;
        _player.PlayQueue(SelectedPlaylistTracks, track);
    }
}
