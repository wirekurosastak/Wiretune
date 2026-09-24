using System.Collections.ObjectModel;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretone.Core.Audio;
using Wiretone.Core.Models;
using Wiretone.Core.Services;

namespace Wiretone.UI.ViewModels;

public partial class PlayerViewModel : ObservableObject
{
    private readonly IAudioEngine _engine;
    private readonly ILibraryService _library;
    private readonly List<Track> _playbackQueue = new();
    private int _queueIndex = -1;
    private bool _isScrubbing = false;
    private bool _isUpdatingPositionFromEngine = false;
    private volatile bool _isUserSeeking = false;
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
    [ObservableProperty] private string _qualityBadge = "FLAC";
    [ObservableProperty] private string _qualityShortBadge = "FLAC";
    [ObservableProperty] private bool _isDrawerOpen;

    public ObservableCollection<SpectrumBarViewModel> SpectrumBars { get; } = new();

    public PlayerViewModel(IAudioEngine engine, ILibraryService library)
    {
        _engine = engine;
        _library = library;

        IsExclusiveMode = _engine.IsExclusiveMode;
        IsBitperfect = _engine.IsBitperfect;
        IsVolumeLocked = _engine.IsBitperfect;

        // Initialize 16 spectrum visualizer bars
        for (int i = 0; i < 16; i++) SpectrumBars.Add(new SpectrumBarViewModel());

        _engine.StateChanged += (_, state) => Dispatcher.UIThread.Post(() =>
        {
            PlaybackState = state;
            if (state == PlaybackState.Stopped)
            {
                for (int i = 0; i < SpectrumBars.Count; i++) SpectrumBars[i].Value = 0.05;
            }
        });

        _engine.TrackEnded += (_, _) => Dispatcher.UIThread.Post(() =>
        {
            if (RepeatMode == RepeatMode.One)
            {
                if (_queueIndex >= 0 && _queueIndex < _playbackQueue.Count)
                {
                    _ = _engine.PlayTrackAsync(_playbackQueue[_queueIndex]);
                }
            }
            else if (_queueIndex < _playbackQueue.Count - 1 || RepeatMode == RepeatMode.All)
            {
                NextTrack();
            }
        });

        _engine.PositionChanged += (_, pos) => Dispatcher.UIThread.Post(() =>
        {
            if (_isScrubbing || _isUserSeeking)
            {
                return;
            }

            _isUpdatingPositionFromEngine = true;
            try
            {
                PositionSeconds = pos.TotalSeconds;
                FormattedPosition = pos.Hours > 0 ? pos.ToString(@"h\:mm\:ss") : pos.ToString(@"m\:ss");
            }
            finally
            {
                _isUpdatingPositionFromEngine = false;
            }
        });

        _engine.TrackChanged += (_, track) => Dispatcher.UIThread.Post(() =>
        {
            _seekDebounceCts?.Cancel();
            _seekDebounceCts?.Dispose();
            _seekDebounceCts = null;
            _isUserSeeking = false;

            CurrentTrack = track;
            if (track != null)
            {
                DurationSeconds = track.Duration.TotalSeconds;
                FormattedDuration = track.FormattedDuration;
                _isUpdatingPositionFromEngine = true;
                try
                {
                    PositionSeconds = 0;
                    FormattedPosition = "0:00";
                }
                finally
                {
                    _isUpdatingPositionFromEngine = false;
                }
                IsHiRes = track.Format.IsHiRes;
                QualityBadge = track.Format.DisplayBadge;
                QualityShortBadge = track.Format.IsHiRes ? "HI-RES" : (track.Format.IsLossless ? "LOSSLESS" : track.Format.Codec);
                SignalPath = _engine.SignalPathDescription;
                LoadCoverArt(track);
                _ = _library.RecordPlayAsync(track.Id);
            }
            else
            {
                DurationSeconds = 0;
                _isUpdatingPositionFromEngine = true;
                try
                {
                    PositionSeconds = 0;
                    FormattedPosition = "0:00";
                }
                finally
                {
                    _isUpdatingPositionFromEngine = false;
                }
                CoverBitmap = null;
            }
        });

        _engine.BitperfectChanged += (_, bp) => Dispatcher.UIThread.Post(() =>
        {
            IsBitperfect = bp;
            IsVolumeLocked = bp;
            if (bp) Volume = 100;
            SignalPath = _engine.SignalPathDescription;
        });

        _engine.ExclusiveModeChanged += (_, exc) => Dispatcher.UIThread.Post(() =>
        {
            IsExclusiveMode = exc;
            SignalPath = _engine.SignalPathDescription;
        });

        _engine.SpectrumDataAvailable += (_, bands) => Dispatcher.UIThread.Post(() =>
        {
            if (PlaybackState != PlaybackState.Playing) return;
            for (int i = 0; i < Math.Min(bands.Length, SpectrumBars.Count); i++)
            {
                SpectrumBars[i].Value = bands[i];
            }
        });
    }

    private static readonly HttpClient _artHttpClient = new() { Timeout = TimeSpan.FromSeconds(5) };
    private static readonly Dictionary<string, Bitmap> _artCache = new();
    private CancellationTokenSource? _coverArtCts;

    private void LoadCoverArt(Track? track)
    {
        _coverArtCts?.Cancel();
        _coverArtCts?.Dispose();
        _coverArtCts = new CancellationTokenSource();
        var ct = _coverArtCts.Token;

        CoverBitmap = null;
        if (track == null) return;

        var path = track.CoverArtPath;
        if (string.IsNullOrEmpty(path) && !string.IsNullOrWhiteSpace(_library.ServerUrl))
        {
            path = $"{_library.ServerUrl.TrimEnd('/')}/api/cover/{track.Id}";
        }

        if (string.IsNullOrEmpty(path)) return;

        if (_artCache.TryGetValue(path, out var cached))
        {
            CoverBitmap = cached;
            return;
        }

        _ = Task.Run(async () =>
        {
            try
            {
                if (path.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
                    path.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                {
                    var bytes = await _artHttpClient.GetByteArrayAsync(path, ct);
                    if (bytes != null && bytes.Length > 0 && !ct.IsCancellationRequested)
                    {
                        using var ms = new MemoryStream(bytes);
                        var bmp = new Bitmap(ms);
                        Dispatcher.UIThread.Post(() =>
                        {
                            if (!ct.IsCancellationRequested && CurrentTrack?.Id == track.Id)
                            {
                                _artCache[path] = bmp;
                                CoverBitmap = bmp;
                            }
                        });
                    }
                }
                else if (File.Exists(path))
                {
                    var bmp = new Bitmap(path);
                    Dispatcher.UIThread.Post(() =>
                    {
                        if (!ct.IsCancellationRequested && CurrentTrack?.Id == track.Id)
                        {
                            _artCache[path] = bmp;
                            CoverBitmap = bmp;
                        }
                    });
                }
            }
            catch
            {
                // Cover art failed to load
            }
        }, ct);
    }

    public void PlayQueue(IEnumerable<Track> tracks, Track? startTrack = null)
    {
        _playbackQueue.Clear();
        _playbackQueue.AddRange(tracks);

        if (IsShuffle && _playbackQueue.Count > 1)
        {
            var rng = new Random();
            int n = _playbackQueue.Count;
            while (n > 1)
            {
                n--;
                int k = rng.Next(n + 1);
                (_playbackQueue[k], _playbackQueue[n]) = (_playbackQueue[n], _playbackQueue[k]);
            }
        }

        _queueIndex = startTrack != null ? _playbackQueue.IndexOf(startTrack) : 0;
        if (_queueIndex < 0) _queueIndex = 0;

        if (_queueIndex < _playbackQueue.Count)
        {
            _ = _engine.PlayTrackAsync(_playbackQueue[_queueIndex]);
        }
    }

    [RelayCommand]
    public async Task TogglePlayPauseAsync()
    {
        if (PlaybackState == PlaybackState.Playing)
        {
            await _engine.PauseAsync();
        }
        else if (PlaybackState == PlaybackState.Paused)
        {
            await _engine.ResumeAsync();
        }
        else if (CurrentTrack != null)
        {
            await _engine.PlayTrackAsync(CurrentTrack);
        }
        else if (_library.Tracks.Count > 0)
        {
            PlayQueue(_library.Tracks);
        }
    }

    [RelayCommand]
    public void NextTrack()
    {
        if (_playbackQueue.Count == 0) return;

        _queueIndex++;
        if (_queueIndex >= _playbackQueue.Count)
        {
            if (RepeatMode == RepeatMode.All)
                _queueIndex = 0;
            else
            {
                _ = _engine.StopAsync();
                return;
            }
        }

        _ = _engine.PlayTrackAsync(_playbackQueue[_queueIndex]);
    }

    [RelayCommand]
    public void PreviousTrack()
    {
        if (_playbackQueue.Count == 0) return;

        if (PositionSeconds > 3.0)
        {
            _ = _engine.SeekAsync(TimeSpan.Zero);
            return;
        }

        _queueIndex--;
        if (_queueIndex < 0)
        {
            _queueIndex = RepeatMode == RepeatMode.All ? _playbackQueue.Count - 1 : 0;
        }

        _ = _engine.PlayTrackAsync(_playbackQueue[_queueIndex]);
    }

    [RelayCommand]
    public void ToggleShuffle()
    {
        IsShuffle = !IsShuffle;
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
        if (CurrentTrack != null)
        {
            await _library.ToggleFavoriteAsync(CurrentTrack.Id);
            OnPropertyChanged(nameof(CurrentTrack));
        }
    }

    [RelayCommand]
    public async Task ToggleBitperfectAsync()
    {
        var target = !IsBitperfect;
        await _engine.SetBitperfectModeAsync(target);
    }

    [RelayCommand]
    public async Task ToggleExclusiveModeAsync()
    {
        var target = !IsExclusiveMode;
        await _engine.SetExclusiveModeAsync(target);
    }

    [RelayCommand]
    public void SeekTo(double seconds)
    {
        _isScrubbing = false;
        _ = _engine.SeekAsync(TimeSpan.FromSeconds(seconds));
    }

    [RelayCommand]
    public void StartScrubbing()
    {
        _isScrubbing = true;
    }

    partial void OnPositionSecondsChanged(double value)
    {
        if (_isUpdatingPositionFromEngine) return;

        var posTime = TimeSpan.FromSeconds(value);
        FormattedPosition = posTime.Hours > 0 ? posTime.ToString(@"h\:mm\:ss") : posTime.ToString(@"m\:ss");

        if (CurrentTrack == null) return;

        _isUserSeeking = true;
        _seekDebounceCts?.Cancel();
        _seekDebounceCts?.Dispose();
        var cts = new CancellationTokenSource();
        _seekDebounceCts = cts;

        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(200, cts.Token);
                if (!cts.Token.IsCancellationRequested)
                {
                    await _engine.SeekAsync(posTime);
                }
            }
            catch (OperationCanceledException)
            {
                // Expected when rapid seek changes occur
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[PlayerViewModel] SeekAsync error: {ex.Message}");
            }
            finally
            {
                Dispatcher.UIThread.Post(() =>
                {
                    if (_seekDebounceCts == cts)
                    {
                        _seekDebounceCts.Dispose();
                        _seekDebounceCts = null;
                        _isUserSeeking = false;
                    }
                });
            }
        });
    }

    partial void OnVolumeChanged(double value)
    {
        if (!IsBitperfect)
        {
            _engine.SetVolume(value / 100.0);
        }
    }

    [RelayCommand]
    public void ToggleMute()
    {
        if (!IsBitperfect)
        {
            IsMuted = !IsMuted;
            _engine.SetMuted(IsMuted);
        }
    }

    [RelayCommand]
    public void ToggleDrawer()
    {
        IsDrawerOpen = !IsDrawerOpen;
    }
}

public partial class SpectrumBarViewModel : ObservableObject
{
    [ObservableProperty] private double _value = 0.05;
}
