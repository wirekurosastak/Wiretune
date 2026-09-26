using Android.Media;
using Wiretune.Audio.Drivers;
using Wiretune.Core.Models;
using Wiretune.Core.Services;

namespace Wiretune.Android;

/// <summary>Plays local files and server streams through Android's MediaPlayer.</summary>
public sealed class AndroidAudioDriver : IAudioDriver
{
    private readonly object _lock = new();
    private MediaPlayer? _player;
    private Timer? _positionTimer;
    private double _volume = 1.0;
    private long _generation;
    private PlaybackState _state = PlaybackState.Stopped;

    public string DriverName => "Android MediaPlayer";
    public PlaybackState State => _state;
    public TimeSpan CurrentPosition { get; private set; }

    public event EventHandler<PlaybackState>? StateChanged;
    public event EventHandler<TimeSpan>? PositionChanged;
    public event EventHandler<float[]>? SpectrumDataAvailable;
    public event EventHandler? TrackEnded;
    public event EventHandler<string>? PlaybackFailed;

    public Task InitializeAsync(AudioOutputDevice device, bool exclusive, bool bitperfect) => Task.CompletedTask;

    public Task PlayAsync(string audioSource, AudioFormat format, TimeSpan startPosition, CancellationToken ct = default)
    {
        lock (_lock)
        {
            ReleasePlayer();
            var gen = ++_generation;
            var player = new MediaPlayer();
            _player = player;

            try
            {
                player.SetAudioAttributes(new AudioAttributes.Builder()
                    .SetUsage(AudioUsageKind.Media)!
                    .SetContentType(AudioContentType.Music)!
                    .Build()!);
                player.SetDataSource(audioSource);
                player.SetVolume((float)_volume, (float)_volume);

                player.Prepared += (_, _) =>
                {
                    lock (_lock)
                    {
                        if (gen != _generation) return;
                        if (startPosition > TimeSpan.Zero) player.SeekTo((int)startPosition.TotalMilliseconds);
                        player.Start();
                        SetState(PlaybackState.Playing);
                        StartPositionTimer();
                    }
                };
                player.Completion += (_, _) =>
                {
                    lock (_lock)
                    {
                        if (gen != _generation) return;
                        StopPositionTimer();
                        SetState(PlaybackState.Stopped);
                    }
                    TrackEnded?.Invoke(this, EventArgs.Empty);
                };
                player.Error += (_, e) =>
                {
                    e.Handled = true;
                    lock (_lock)
                    {
                        if (gen != _generation) return;
                        Fail($"A lejátszás sikertelen (MediaPlayer hiba: {e.What}, {e.Extra}).");
                    }
                };

                CurrentPosition = startPosition;
                SetState(PlaybackState.Buffering);
                player.PrepareAsync();
            }
            catch (Exception ex)
            {
                Fail($"A lejátszó nem indítható: {ex.Message}");
            }
        }
        return Task.CompletedTask;
    }

    public Task PauseAsync()
    {
        lock (_lock)
        {
            if (_state != PlaybackState.Playing || _player == null) return Task.CompletedTask;
            _player.Pause();
            StopPositionTimer();
            SetState(PlaybackState.Paused);
        }
        return Task.CompletedTask;
    }

    public Task ResumeAsync()
    {
        lock (_lock)
        {
            if (_state != PlaybackState.Paused || _player == null) return Task.CompletedTask;
            _player.Start();
            SetState(PlaybackState.Playing);
            StartPositionTimer();
        }
        return Task.CompletedTask;
    }

    public Task SeekAsync(TimeSpan position)
    {
        lock (_lock)
        {
            CurrentPosition = position;
            if (_player != null && _state is PlaybackState.Playing or PlaybackState.Paused)
            {
                _player.SeekTo((int)position.TotalMilliseconds);
            }
        }
        PositionChanged?.Invoke(this, position);
        return Task.CompletedTask;
    }

    public Task StopAsync()
    {
        lock (_lock)
        {
            _generation++;
            ReleasePlayer();
            CurrentPosition = TimeSpan.Zero;
            SetState(PlaybackState.Stopped);
        }
        return Task.CompletedTask;
    }

    public void SetVolume(double volume)
    {
        _volume = Math.Clamp(volume, 0.0, 1.0);
        lock (_lock)
        {
            _player?.SetVolume((float)_volume, (float)_volume);
        }
    }

    private void StartPositionTimer()
    {
        StopPositionTimer();
        _positionTimer = new Timer(_ =>
        {
            TimeSpan position;
            lock (_lock)
            {
                if (_player == null || _state != PlaybackState.Playing) return;
                position = TimeSpan.FromMilliseconds(_player.CurrentPosition);
            }
            CurrentPosition = position;
            PositionChanged?.Invoke(this, position);
        }, null, 0, 250);
    }

    private void StopPositionTimer()
    {
        _positionTimer?.Dispose();
        _positionTimer = null;
        SpectrumDataAvailable?.Invoke(this, new float[32]);
    }

    private void ReleasePlayer()
    {
        StopPositionTimer();
        var player = _player;
        _player = null;
        if (player == null) return;

        try
        {
            player.Reset();
            player.Release();
        }
        catch
        {
            // Already released.
        }
        player.Dispose();
    }

    private void Fail(string message)
    {
        WiretuneLog.Warn("AndroidAudioDriver", message);
        ReleasePlayer();
        SetState(PlaybackState.Error);
        PlaybackFailed?.Invoke(this, message);
    }

    private void SetState(PlaybackState state)
    {
        if (_state == state) return;
        _state = state;
        StateChanged?.Invoke(this, state);
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _generation++;
            ReleasePlayer();
        }
    }
}
