using System.Collections.ObjectModel;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Services;
using Wiretune.Core.Localization;

namespace Wiretune.UI.ViewModels;

public partial class PlayerViewModel : ObservableObject
{
    private const int CoverDecodeWidth = 640; // large enough for the full-screen phone player

    private readonly WiretuneAudioEngine _engine;
    private readonly LibraryService _library;
    private readonly List<Track> _originalQueue = new();
    private readonly List<Track> _playbackQueue = new();
    private int _queueIndex = -1;
    private bool _isUpdatingPositionFromEngine;
    private bool _isUserSeeking;
    private CancellationTokenSource? _seekDebounceCts;
    private CancellationTokenSource? _lyricsCts;
    private string? _lyricsTrackId;

    [ObservableProperty] private Track? _currentTrack;
    [ObservableProperty] private string? _currentLyrics;
    public bool HasLyrics => !string.IsNullOrWhiteSpace(CurrentLyrics);

    /// <summary>Finds the lyrics of a track (tag of a local file, server request for a server track); set by the application.</summary>
    public Func<Track, CancellationToken, Task<string?>>? LyricsProvider { get; set; }
    partial void OnCurrentLyricsChanged(string? value) => OnPropertyChanged(nameof(HasLyrics));
    [ObservableProperty] private PlaybackState _playbackState = PlaybackState.Stopped;
    [ObservableProperty] private double _positionSeconds;
    [ObservableProperty] private double _durationSeconds;
    [ObservableProperty] private string _formattedPosition = "0:00";
    [ObservableProperty] private string _formattedDuration = "0:00";
    [ObservableProperty] private double _volume = 100;
    [ObservableProperty] private bool _isMuted;
    [ObservableProperty] private bool _isExclusiveMode;
    [ObservableProperty] private bool _isBitperfect;
    [ObservableProperty] private bool _isVolumeLocked;

    public bool IsVolumeDisabledOrMuted => IsMuted || IsVolumeLocked;
    public bool IsVolumeActive => !IsMuted && !IsVolumeLocked;
    public bool IsVolumeLockedAndNotMuted => !IsMuted && IsVolumeLocked;
    public string VolumeToolTip => Localizer.Get(IsMuted ? "VolumeUnmute" : IsVolumeLocked ? "VolumeLocked" : "VolumeMute");

    /// <summary>Title of the current track, or a hint when nothing is loaded.</summary>
    public string NowPlayingTitle => CurrentTrack?.Title ?? Localizer.Get("NothingPlaying");

    /// <summary>Artist of the current track, or a hint when nothing is loaded.</summary>
    public string NowPlayingArtist => CurrentTrack?.Artist ?? Localizer.Get("ChooseMusic");

    /// <summary>Re-renders the texts that were computed in the previous language.</summary>
    public void RefreshLocalizedTexts()
    {
        OnPropertyChanged(nameof(VolumeToolTip));
        OnPropertyChanged(nameof(NowPlayingTitle));
        OnPropertyChanged(nameof(NowPlayingArtist));
    }
    [ObservableProperty] private bool _isShuffle;
    [ObservableProperty] private RepeatMode _repeatMode = RepeatMode.Off;
    [ObservableProperty] private Bitmap? _coverBitmap;
    [ObservableProperty] private string _signalPath = string.Empty;
    [ObservableProperty] private string _qualityBadge = string.Empty;
    [ObservableProperty] private string _qualityShortBadge = string.Empty;
    [ObservableProperty] private string? _errorMessage;
    [ObservableProperty] private float[] _spectrumBands = new float[32];
    [ObservableProperty] private bool _isQueueOpen;
    [ObservableProperty] private IReadOnlyList<Track> _queueTracks = Array.Empty<Track>();
    [ObservableProperty] private ObservableCollection<QueueItemViewModel> _queueItems = new();
    [ObservableProperty] private int _currentQueueIndex = -1;

    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);

    [RelayCommand]
    public void ToggleQueue()
    {
        IsQueueOpen = !IsQueueOpen;
        if (IsQueueOpen)
        {
            UpdateQueueState();
        }
    }

    [RelayCommand]
    public void CloseQueue() => IsQueueOpen = false;

    [RelayCommand]
    public void PlayQueueTrack(object? parameter)
    {
        Track? track = parameter switch
        {
            Track t => t,
            QueueItemViewModel entry => entry.Track, // a row of the queue (phone layout)
            IEnumerable<Track> list => list.FirstOrDefault(),
            _ => null
        };

        if (track == null) return;

        // If a list was passed in, use it as the new queue context.
        if (parameter is IEnumerable<Track> tracks && !(parameter is Track))
        {
            PlayQueue(tracks, track);
            return;
        }

        var idx = _playbackQueue.IndexOf(track);
        if (idx >= 0)
        {
            // Track is already in the queue — just jump to it.
            PlayAt(idx);
        }
        else
        {
            // Track is not in the queue yet (e.g. first play from a list view on Android).
            // Build a queue from the full library using this track as the starting point.
            var allTracks = _library.Tracks.Count > 0 ? _library.Tracks : (IReadOnlyList<Track>)new[] { track };
            PlayQueue(allTracks, track);
        }
    }

    public void MoveQueueTrack(int oldIndex, int newIndex)
    {
        if (oldIndex < 0 || oldIndex >= _playbackQueue.Count) return;
        if (newIndex < 0 || newIndex >= _playbackQueue.Count) return;
        if (oldIndex == newIndex) return;

        var track = _playbackQueue[oldIndex];
        _playbackQueue.RemoveAt(oldIndex);
        _playbackQueue.Insert(newIndex, track);

        if (!IsShuffle)
        {
            _originalQueue.Clear();
            _originalQueue.AddRange(_playbackQueue);
        }

        if (CurrentTrack != null)
        {
            _queueIndex = _playbackQueue.IndexOf(CurrentTrack);
        }
        else if (_queueIndex >= 0)
        {
            if (oldIndex == _queueIndex)
                _queueIndex = newIndex;
            else if (oldIndex < _queueIndex && newIndex >= _queueIndex)
                _queueIndex--;
            else if (oldIndex > _queueIndex && newIndex <= _queueIndex)
                _queueIndex++;
        }

        if (QueueItems.Count == _playbackQueue.Count)
        {
            QueueItems.Move(oldIndex, newIndex);
            for (int i = 0; i < QueueItems.Count; i++)
            {
                QueueItems[i].Index = i;
                QueueItems[i].IsCurrent = (i == _queueIndex);
                QueueItems[i].IsDropTarget = false;
            }
            QueueTracks = _playbackQueue.ToList();
            CurrentQueueIndex = _queueIndex;
        }
        else
        {
            UpdateQueueState();
        }
    }

    [RelayCommand]
    public void MoveQueueTrackUp(QueueItemViewModel? item)
    {
        if (item == null || item.Index <= 0) return;
        MoveQueueTrack(item.Index, item.Index - 1);
    }

    [RelayCommand]
    public void MoveQueueTrackDown(QueueItemViewModel? item)
    {
        if (item == null || item.Index >= _playbackQueue.Count - 1) return;
        MoveQueueTrack(item.Index, item.Index + 1);
    }

    [RelayCommand]
    public void RemoveQueueTrack(Track? track)
    {
        if (track == null) return;
        var idx = _playbackQueue.IndexOf(track);
        if (idx < 0) return;

        var removedCurrent = idx == _queueIndex;
        _playbackQueue.RemoveAt(idx);
        _originalQueue.Remove(track); // also while shuffled, or turning shuffle off would bring the track back

        if (removedCurrent)
        {
            // The playing track was taken out of the queue: carry on with whatever followed it (or stop at the end).
            _queueIndex = idx - 1;
            UpdateQueueState();
            if (_playbackQueue.Count > 0) NextTrack();
            else _ = RunSafeAsync(_engine.StopAsync);
            return;
        }

        if (idx < _queueIndex) _queueIndex--;
        UpdateQueueState();
    }

    [RelayCommand]
    public void ClearQueue()
    {
        var current = CurrentTrack ?? (_queueIndex >= 0 && _queueIndex < _playbackQueue.Count ? _playbackQueue[_queueIndex] : null);
        _playbackQueue.Clear();
        _originalQueue.Clear();
        if (current != null)
        {
            _playbackQueue.Add(current);
            _originalQueue.Add(current);
            _queueIndex = 0;
        }
        else
        {
            _queueIndex = -1;
        }
        UpdateQueueState();
    }

    private void UpdateQueueState()
    {
        QueueTracks = _playbackQueue.ToList();
        CurrentQueueIndex = _queueIndex;

        if (QueueItems.Count == _playbackQueue.Count)
        {
            var match = true;
            for (int i = 0; i < _playbackQueue.Count; i++)
            {
                if (!ReferenceEquals(QueueItems[i].Track, _playbackQueue[i]))
                {
                    match = false;
                    break;
                }
            }
            if (match)
            {
                for (int i = 0; i < _playbackQueue.Count; i++)
                {
                    QueueItems[i].Index = i;
                    QueueItems[i].IsCurrent = (i == _queueIndex);
                    QueueItems[i].IsDropTarget = false;
                }
                return;
            }
        }

        QueueItems = new ObservableCollection<QueueItemViewModel>(
            _playbackQueue.Select((t, i) => new QueueItemViewModel(t, i, i == _queueIndex)));
    }

    public PlayerViewModel(WiretuneAudioEngine engine, LibraryService library)
    {
        _engine = engine;
        _library = library;

        IsExclusiveMode = _engine.IsExclusiveMode;
        IsBitperfect = _engine.IsBitperfect;
        IsVolumeLocked = _engine.IsBitperfect;

        _engine.StateChanged += (_, state) => Dispatcher.UIThread.Post(() =>
        {
            PlaybackState = state;
            if (state == PlaybackState.Playing) ErrorMessage = null;
            if (state != PlaybackState.Playing) SpectrumBands = new float[32];
        });

        // The player keeps the Track instance it started with; a favourite toggled elsewhere changes the library's instance.
        _library.FavoriteChanged += (_, changed) => Ui.Post(() =>
        {
            if (CurrentTrack is { } current && current.Id == changed.Id && !ReferenceEquals(current, changed))
                current.IsFavorite = changed.IsFavorite;
        });

        _engine.PlaybackFailed += (_, message) => Dispatcher.UIThread.Post(() => ErrorMessage = message);
        _engine.TrackEnded += (_, _) => Dispatcher.UIThread.Post(OnTrackEnded);
        _engine.PositionChanged += (_, pos) => Dispatcher.UIThread.Post(() =>
        {
            if (!_isUserSeeking) SetPositionFromEngine(pos);
        });
        _engine.TrackChanged += (_, track) => Dispatcher.UIThread.Post(() => OnEngineTrackChanged(track));
        _engine.BitperfectChanged += (_, bp) => Dispatcher.UIThread.Post(() =>
        {
            IsBitperfect = bp;
            IsVolumeLocked = bp;
            Volume = bp ? 100 : Math.Round(_engine.Volume * 100);
            SignalPath = _engine.SignalPathDescription;
        });
        _engine.ExclusiveModeChanged += (_, exc) => Dispatcher.UIThread.Post(() =>
        {
            IsExclusiveMode = exc;
            SignalPath = _engine.SignalPathDescription;
        });
        _engine.SpectrumDataAvailable += (_, bands) => Dispatcher.UIThread.Post(() =>
        {
            if (PlaybackState == PlaybackState.Playing) SpectrumBands = bands;
        });
    }

    partial void OnErrorMessageChanged(string? value) => OnPropertyChanged(nameof(HasError));

    partial void OnIsQueueOpenChanged(bool value)
    {
        if (value) RefreshLyrics();
    }

    /// <summary>Loads the lyrics of the current track, but only while the queue panel that shows them is open.</summary>
    private void RefreshLyrics()
    {
        var track = CurrentTrack;
        if (track == null)
        {
            _lyricsCts?.Cancel();
            _lyricsTrackId = null;
            CurrentLyrics = null;
            return;
        }

        if (_lyricsTrackId == track.Id) return; // already loaded, or loading, for this track

        _lyricsCts?.Cancel();
        CurrentLyrics = null;
        if (!IsQueueOpen || LyricsProvider == null) return; // loaded when the panel is opened

        _lyricsTrackId = track.Id;
        var cts = _lyricsCts = new CancellationTokenSource();
        _ = LoadLyricsAsync(track, cts);
    }

    private async Task LoadLyricsAsync(Track track, CancellationTokenSource cts)
    {
        string? text = null;
        try
        {
            text = await LyricsProvider!(track, cts.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception ex)
        {
            WiretuneLog.Debug("PlayerViewModel", $"Lyrics unavailable for '{track.Title}': {ex.Message}");
        }

        if (!cts.IsCancellationRequested && ReferenceEquals(CurrentTrack, track)) CurrentLyrics = text;
    }

    partial void OnCurrentTrackChanged(Track? oldValue, Track? newValue)
    {
        OnPropertyChanged(nameof(NowPlayingTitle));
        OnPropertyChanged(nameof(NowPlayingArtist));
        _lyricsTrackId = null;
        RefreshLyrics();
        if (oldValue != null)
        {
            oldValue.IsPlaying = false;
            var oldLib = _library.GetTrack(oldValue.Id);
            if (oldLib != null && !ReferenceEquals(oldLib, oldValue))
                oldLib.IsPlaying = false;
        }
        if (newValue != null)
        {
            newValue.IsPlaying = true;
            var newLib = _library.GetTrack(newValue.Id);
            if (newLib != null && !ReferenceEquals(newLib, newValue))
                newLib.IsPlaying = true;
        }
    }

    private void OnEngineTrackChanged(Track? track)
    {
        _seekDebounceCts?.Cancel();
        _seekDebounceCts = null;
        _isUserSeeking = false;

        CurrentTrack = track;
        SetPositionFromEngine(TimeSpan.Zero);
        CoverBitmap = null;

        if (track == null)
        {
            DurationSeconds = 0;
            FormattedDuration = "0:00";
            return;
        }

        DurationSeconds = track.Duration.TotalSeconds;
        FormattedDuration = track.FormattedDuration;
        QualityBadge = track.Format.DisplayBadge;
        QualityShortBadge = track.Format.DisplayBadge;
        SignalPath = _engine.SignalPathDescription;

        CoverArtService.LoadBitmap(track.CoverArtPath, CoverDecodeWidth, bmp =>
        {
            if (ReferenceEquals(CurrentTrack, track)) CoverBitmap = bmp;
        });
        Ui.Forget(_library.RecordPlayAsync(track.Id), "PlayerViewModel"); // bookkeeping only: no error banner
    }

    private void OnTrackEnded()
    {
        if (RepeatMode == RepeatMode.One && _queueIndex >= 0 && _queueIndex < _playbackQueue.Count)
        {
            PlayAt(_queueIndex);
        }
        else if (_queueIndex < _playbackQueue.Count - 1 || RepeatMode == RepeatMode.All)
        {
            NextTrack();
        }
    }

    private void SetPositionFromEngine(TimeSpan pos)
    {
        _isUpdatingPositionFromEngine = true;
        try
        {
            PositionSeconds = pos.TotalSeconds;
            FormattedPosition = Format(pos);
        }
        finally
        {
            _isUpdatingPositionFromEngine = false;
        }
    }

    public void PlayQueue(IEnumerable<Track> tracks, Track? startTrack = null)
    {
        _originalQueue.Clear();
        _originalQueue.AddRange(tracks);
        if (_originalQueue.Count == 0) return;

        var start = startTrack != null && _originalQueue.Contains(startTrack) ? startTrack : null;

        _playbackQueue.Clear();
        if (IsShuffle)
        {
            var first = start ?? _originalQueue[Random.Shared.Next(_originalQueue.Count)];
            _playbackQueue.Add(first);
            _playbackQueue.AddRange(Shuffled(_originalQueue.Where(t => !ReferenceEquals(t, first))));
            PlayAt(0);
        }
        else
        {
            _playbackQueue.AddRange(_originalQueue);
            PlayAt(start != null ? _playbackQueue.IndexOf(start) : 0);
        }
        UpdateQueueState();
    }

    private void PlayAt(int index)
    {
        if (index < 0 || index >= _playbackQueue.Count) return;
        _queueIndex = index;
        UpdateQueueState();
        ErrorMessage = null;
        _ = RunSafeAsync(() => _engine.PlayTrackAsync(_playbackQueue[index]));
    }

    [RelayCommand]
    public async Task TogglePlayPauseAsync()
    {
        switch (PlaybackState)
        {
            case PlaybackState.Playing:
                await _engine.PauseAsync();
                break;
            case PlaybackState.Paused:
                await _engine.ResumeAsync();
                break;
            default:
                if (_queueIndex >= 0 && _queueIndex < _playbackQueue.Count) PlayAt(_queueIndex);
                else if (CurrentTrack != null) PlayQueue(new[] { CurrentTrack }, CurrentTrack);
                else if (_library.Tracks.Count > 0) PlayQueue(_library.Tracks);
                break;
        }
    }

    [RelayCommand]
    public void NextTrack()
    {
        if (_playbackQueue.Count == 0) return;

        if (_queueIndex + 1 < _playbackQueue.Count)
        {
            PlayAt(_queueIndex + 1);
        }
        else if (RepeatMode == RepeatMode.All)
        {
            PlayAt(0);
        }
        else
        {
            _queueIndex = _playbackQueue.Count; // past the end: nothing is current any more
            UpdateQueueState();
            _ = RunSafeAsync(_engine.StopAsync);
        }
    }

    [RelayCommand]
    public void PreviousTrack()
    {
        if (_playbackQueue.Count == 0) return;

        if (PositionSeconds > 3.0)
        {
            _ = RunSafeAsync(() => _engine.SeekAsync(TimeSpan.Zero));
            return;
        }

        var previous = _queueIndex - 1;
        if (previous < 0) previous = RepeatMode == RepeatMode.All ? _playbackQueue.Count - 1 : 0;
        PlayAt(Math.Min(previous, _playbackQueue.Count - 1));
    }

    [RelayCommand]
    public void ToggleShuffle() => IsShuffle = !IsShuffle;

    partial void OnIsShuffleChanged(bool value)
    {
        if (_playbackQueue.Count < 2 || _queueIndex < 0 || _queueIndex >= _playbackQueue.Count) return;

        // Reorder the rest of the running queue without interrupting the current track.
        var current = _playbackQueue[_queueIndex];
        var rest = value
            ? Shuffled(_originalQueue.Where(t => !ReferenceEquals(t, current)))
            : _originalQueue.SkipWhile(t => !ReferenceEquals(t, current)).Skip(1).ToList();

        _playbackQueue.Clear();
        _playbackQueue.Add(current);
        _playbackQueue.AddRange(rest);
        _queueIndex = 0;
        UpdateQueueState();
    }

    [RelayCommand]
    public void ToggleRepeat()
    {
        RepeatMode = RepeatMode switch
        {
            RepeatMode.Off => RepeatMode.All,
            RepeatMode.All => RepeatMode.One,
            _ => RepeatMode.Off
        };
    }

    [RelayCommand]
    public async Task ToggleFavoriteCurrentAsync()
    {
        if (CurrentTrack is not { } current) return;

        await _library.ToggleFavoriteAsync(current.Id);
        // A server refresh replaces the library's Track objects while the player keeps the one it started playing:
        // mirror the change so the heart in the player bar follows.
        if (_library.GetTrack(current.Id) is { } inLibrary && !ReferenceEquals(inLibrary, current))
            current.IsFavorite = inLibrary.IsFavorite;
    }

    [RelayCommand]
    public Task ToggleBitperfectAsync() => _engine.SetBitperfectModeAsync(!IsBitperfect);

    [RelayCommand]
    public Task ToggleExclusiveModeAsync() => _engine.SetExclusiveModeAsync(!IsExclusiveMode);

    [RelayCommand]
    public void DismissError() => ErrorMessage = null;

    partial void OnPositionSecondsChanged(double value)
    {
        if (_isUpdatingPositionFromEngine || CurrentTrack == null) return;

        // The slider was moved by the user: debounce so dragging produces a single seek.
        var target = TimeSpan.FromSeconds(value);
        FormattedPosition = Format(target);
        _isUserSeeking = true;

        _seekDebounceCts?.Cancel();
        var cts = new CancellationTokenSource();
        _seekDebounceCts = cts;

        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(200, cts.Token);
                await _engine.SeekAsync(target);
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception ex)
            {
                WiretuneLog.Warn("PlayerViewModel", $"Seek failed: {ex.Message}");
            }
            finally
            {
                Dispatcher.UIThread.Post(() =>
                {
                    if (_seekDebounceCts != cts) return;
                    _seekDebounceCts = null;
                    _isUserSeeking = false;
                });
            }
        });
    }

    partial void OnVolumeChanged(double value)
    {
        if (!IsBitperfect) _engine.SetVolume(value / 100.0);
    }

    partial void OnIsMutedChanged(bool value)
    {
        OnPropertyChanged(nameof(IsVolumeDisabledOrMuted));
        OnPropertyChanged(nameof(IsVolumeActive));
        OnPropertyChanged(nameof(IsVolumeLockedAndNotMuted));
        OnPropertyChanged(nameof(VolumeToolTip));
    }

    partial void OnIsVolumeLockedChanged(bool value)
    {
        OnPropertyChanged(nameof(IsVolumeDisabledOrMuted));
        OnPropertyChanged(nameof(IsVolumeActive));
        OnPropertyChanged(nameof(IsVolumeLockedAndNotMuted));
        OnPropertyChanged(nameof(VolumeToolTip));
    }

    [RelayCommand]
    public void ToggleMute()
    {
        if (IsBitperfect) return;
        IsMuted = !IsMuted;
        _engine.SetMuted(IsMuted);
    }

    private static List<Track> Shuffled(IEnumerable<Track> source)
    {
        var list = source.ToList();
        for (var n = list.Count - 1; n > 0; n--)
        {
            var k = Random.Shared.Next(n + 1);
            (list[k], list[n]) = (list[n], list[k]);
        }
        return list;
    }

    private static string Format(TimeSpan t) => t.Hours > 0 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");

    private async Task RunSafeAsync(Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("PlayerViewModel", $"Playback command failed: {ex.Message}", ex);
            ErrorMessage = ex.Message;
        }
    }
}

public sealed partial class QueueItemViewModel : ObservableObject
{
    public Track Track { get; }
    [ObservableProperty] private int _index;
    [ObservableProperty] private bool _isCurrent;
    [ObservableProperty] private bool _isDropTarget;

    public int DisplayIndex => Index + 1;

    public QueueItemViewModel(Track track, int index, bool isCurrent)
    {
        Track = track;
        _index = index;
        _isCurrent = isCurrent;
    }

    partial void OnIndexChanged(int value) => OnPropertyChanged(nameof(DisplayIndex));
}


