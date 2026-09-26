using Avalonia.Media.Imaging;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class PlayerViewModel : ObservableObject
{
    private const int CoverDecodeWidth = 160;

    private readonly IAudioEngine _engine;
    private readonly ILibraryService _library;
    private readonly List<Track> _originalQueue = new();
    private readonly List<Track> _playbackQueue = new();
    private int _queueIndex = -1;
    private bool _isUpdatingPositionFromEngine;
    private bool _isUserSeeking;
    private CancellationTokenSource? _seekDebounceCts;

    [ObservableProperty] private Track? _currentTrack;
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
    [ObservableProperty] private bool _isShuffle;
    [ObservableProperty] private RepeatMode _repeatMode = RepeatMode.Off;
    [ObservableProperty] private Bitmap? _coverBitmap;
    [ObservableProperty] private string _signalPath = string.Empty;
    [ObservableProperty] private bool _isHiRes;
    [ObservableProperty] private string _qualityBadge = string.Empty;
    [ObservableProperty] private string _qualityShortBadge = string.Empty;
    [ObservableProperty] private string? _errorMessage;
    [ObservableProperty] private float[] _spectrumBands = new float[32];

    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);

    public PlayerViewModel(IAudioEngine engine, ILibraryService library)
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
        IsHiRes = track.Format.IsHiRes;
        QualityBadge = track.Format.DisplayBadge;
        QualityShortBadge = track.Format.IsHiRes ? "HI-RES" : (track.Format.IsLossless ? "LOSSLESS" : track.Format.Codec);
        SignalPath = _engine.SignalPathDescription;

        CoverArtService.LoadBitmap(track.CoverArtPath, CoverDecodeWidth, bmp =>
        {
            if (ReferenceEquals(CurrentTrack, track)) CoverBitmap = bmp;
        });
        _ = RunSafeAsync(() => _library.RecordPlayAsync(track.Id));
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
    }

    private void PlayAt(int index)
    {
        if (index < 0 || index >= _playbackQueue.Count) return;
        _queueIndex = index;
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
            _queueIndex = _playbackQueue.Count;
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
        if (CurrentTrack != null) await _library.ToggleFavoriteAsync(CurrentTrack.Id);
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

    private static async Task RunSafeAsync(Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("PlayerViewModel", $"Playback command failed: {ex.Message}", ex);
        }
    }
}
