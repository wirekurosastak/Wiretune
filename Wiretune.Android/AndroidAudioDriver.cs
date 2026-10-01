using Android.Content;
using Android.Media;
using Android.OS;
using Wiretune.Core.Audio.Drivers;
using Wiretune.Core.Localization;
using Wiretune.Core.Models;
using Wiretune.Core.Services;

namespace Wiretune.Android;

/// <summary>Plays local files and server streams through Android's MediaPlayer.</summary>
public sealed class AndroidAudioDriver : IAudioDriver
{
    private readonly object _lock = new();
    private MediaPlayer? _player;
    private AudioFocusRequestClass? _audioFocusRequest;
    private AudioManager? _audioManager;
    private AudioFocusListener? _focusListener;
    private bool _resumeOnFocusGain;
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

    public Task InitializeAsync(AudioOutputDevice device, bool exclusive, bool bitperfect)
    {
        if (_audioManager == null)
        {
            _audioManager = (AudioManager?)global::Android.App.Application.Context.GetSystemService(Context.AudioService);
        }
        return Task.CompletedTask;
    }

    public Task PlayAsync(string audioSource, Wiretune.Core.Models.AudioFormat format, TimeSpan startPosition, CancellationToken ct = default)
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
                // Keep the CPU awake while the screen is off (needs the WAKE_LOCK permission, which the manifest declares).
                player.SetWakeMode(global::Android.App.Application.Context, WakeLockFlags.Partial);
                player.SetDataSource(audioSource);
                player.SetVolume((float)_volume, (float)_volume);

                player.Prepared += (_, _) =>
                {
                    lock (_lock)
                    {
                        if (gen != _generation) return;
                        if (startPosition > TimeSpan.Zero)
                            SeekPlayerTo(player, startPosition);
                        RequestAudioFocus();
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
                        Fail(Localizer.Format("DriverAndroidError", e.What.ToString(), e.Extra));
                    }
                };

                CurrentPosition = startPosition;
                SetState(PlaybackState.Buffering);
                player.PrepareAsync();
            }
            catch (Exception ex)
            {
                Fail(Localizer.Format("DriverCannotStart", ex.Message));
            }
        }
        return Task.CompletedTask;
    }

    public Task PauseAsync()
    {
        lock (_lock)
        {
            _resumeOnFocusGain = false;
            PauseLocked(abandonFocus: true);
        }
        return Task.CompletedTask;
    }

    /// <param name="abandonFocus">
    /// True when the user paused: give focus back so other apps may play. False for a transient loss (a phone call):
    /// focus must be kept, or the system never tells us when it is free again.
    /// </param>
    private void PauseLocked(bool abandonFocus)
    {
        if (_state != PlaybackState.Playing || _player == null) return;

        _player.Pause();
        StopPositionTimer();
        SetState(PlaybackState.Paused);
        if (abandonFocus) AbandonAudioFocus();
    }

    public Task ResumeAsync()
    {
        lock (_lock)
        {
            _resumeOnFocusGain = false;
            if (_state != PlaybackState.Paused || _player == null) return Task.CompletedTask;
            RequestAudioFocus();
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
                SeekPlayerTo(_player, position);
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
            _resumeOnFocusGain = false;
            ReleasePlayer();
            AbandonAudioFocus();
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

    // ── Seek helpers ─────────────────────────────────────────────────────────────────────────────────

    /// <summary>Seeks to <paramref name="position"/> using the precise API on API 26+, legacy int on older devices.</summary>
    private static void SeekPlayerTo(MediaPlayer player, TimeSpan position)
    {
        var ms = (long)position.TotalMilliseconds;
        if (OperatingSystem.IsAndroidVersionAtLeast(26))
        {
#pragma warning disable CA1416 // Both calls are guarded by the version check above.
            player.SeekTo(ms, MediaPlayerSeekMode.PreviousSync);
#pragma warning restore CA1416
        }
        else
        {
#pragma warning disable CA1416 // Legacy overload intentionally used for API < 26.
            player.SeekTo((int)Math.Clamp(ms, int.MinValue, int.MaxValue));
#pragma warning restore CA1416
        }
    }

    /// <summary>Requests audio focus so Wiretune co-exists with phone calls and other players.</summary>
    private void RequestAudioFocus()
    {
        if (_audioManager == null) return;

        _focusListener ??= new AudioFocusListener(this);

        if (OperatingSystem.IsAndroidVersionAtLeast(26))
        {
#pragma warning disable CA1416 // All calls in this branch are guarded by the version check.
            _audioFocusRequest ??= new AudioFocusRequestClass.Builder(AudioFocus.Gain)
                .SetAudioAttributes(new AudioAttributes.Builder()
                    .SetUsage(AudioUsageKind.Media)!
                    .SetContentType(AudioContentType.Music)!
                    .Build()!)!
                .SetAcceptsDelayedFocusGain(false)!
                .SetOnAudioFocusChangeListener(_focusListener)!
                .Build();

            _audioManager.RequestAudioFocus(_audioFocusRequest);
#pragma warning restore CA1416
        }
        else
        {
            // Legacy API (deprecated in API 26 but still functional).
#pragma warning disable CA1416, CA1422
            _audioManager.RequestAudioFocus(_focusListener, global::Android.Media.Stream.Music, AudioFocus.Gain);
#pragma warning restore CA1416, CA1422
        }
    }

    private void AbandonAudioFocus()
    {
        if (_audioManager == null) return;

        if (OperatingSystem.IsAndroidVersionAtLeast(26))
        {
#pragma warning disable CA1416
            if (_audioFocusRequest != null) _audioManager.AbandonAudioFocusRequest(_audioFocusRequest);
            _audioFocusRequest = null;
#pragma warning restore CA1416
        }
        else if (_focusListener != null)
        {
#pragma warning disable CA1416, CA1422
            _audioManager.AbandonAudioFocus(_focusListener);
#pragma warning restore CA1416, CA1422
        }
    }

    private void OnAudioFocusChanged(AudioFocus change)
    {
        lock (_lock)
        {
            switch (change)
            {
                case AudioFocus.Loss:
                    // Another app took over for good (e.g. a different music player): pause and stay paused.
                    _resumeOnFocusGain = false;
                    PauseLocked(abandonFocus: true);
                    break;
                case AudioFocus.LossTransient:
                    // Phone call, alarm: pause, and carry on when the system gives focus back.
                    if (_state == PlaybackState.Playing)
                    {
                        _resumeOnFocusGain = true;
                        PauseLocked(abandonFocus: false);
                    }
                    break;
                case AudioFocus.LossTransientCanDuck:
                    // Navigation prompt, notification sound: play quieter for a moment.
                    _player?.SetVolume(0.2f * (float)_volume, 0.2f * (float)_volume);
                    break;
                case AudioFocus.Gain:
                    _player?.SetVolume((float)_volume, (float)_volume);
                    if (_resumeOnFocusGain && _state == PlaybackState.Paused && _player != null)
                    {
                        _resumeOnFocusGain = false;
                        _player.Start();
                        SetState(PlaybackState.Playing);
                        StartPositionTimer();
                    }
                    break;
            }
        }
    }

    private void Fail(string message)
    {
        WiretuneLog.Warn("AndroidAudioDriver", message);
        ReleasePlayer();
        AbandonAudioFocus();
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
            _resumeOnFocusGain = false;
            ReleasePlayer();
            AbandonAudioFocus();
        }
    }

    // ── Inner class ─────────────────────────────────────────────────────────

    /// <summary>Forwards audio focus changes (phone call, another player, a notification sound) to the driver.</summary>
    private sealed class AudioFocusListener : Java.Lang.Object, AudioManager.IOnAudioFocusChangeListener
    {
        private readonly AndroidAudioDriver _driver;
        internal AudioFocusListener(AndroidAudioDriver driver) => _driver = driver;

        public void OnAudioFocusChange(AudioFocus focusChange) => _driver.OnAudioFocusChanged(focusChange);
    }
}
