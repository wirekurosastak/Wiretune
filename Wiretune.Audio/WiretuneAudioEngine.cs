using Wiretune.Audio.Devices;
using Wiretune.Audio.Drivers;
using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Services;

namespace Wiretune.Audio;

public class WiretuneAudioEngine : IAudioEngine
{
    private IAudioDriver _driver;
    private Track? _currentTrack;
    private AudioOutputDevice? _currentDevice;
    private readonly List<AudioOutputDevice> _availableDevices = new();
    private bool _isExclusiveMode = false;
    private bool _isBitperfect = false;
    private double _volume = 1.0;
    private bool _isMuted = false;

    public Track? CurrentTrack => _currentTrack;
    public PlaybackState State => _driver.State;
    public TimeSpan CurrentPosition => _driver.CurrentPosition;
    public TimeSpan Duration => _currentTrack?.Duration ?? TimeSpan.Zero;
    public double Volume => _isBitperfect ? 1.0 : (_isMuted ? 0.0 : _volume);
    public bool IsMuted => _isMuted;
    public bool IsExclusiveMode => _isExclusiveMode;
    public bool IsBitperfect => _isBitperfect;
    public bool IsVolumeLocked => _isBitperfect;
    public AudioOutputDevice? CurrentDevice => _currentDevice;
    public IReadOnlyList<AudioOutputDevice> AvailableDevices => _availableDevices;
    public AudioFormat? CurrentFormat => _currentTrack?.Format;

    public string SignalPathDescription
    {
        get
        {
            if (_currentTrack == null) return "Nincs aktív lejátszás";

            var fmt = _currentTrack.Format;
            var dev = _currentDevice?.DisplayTitle ?? "Alapértelmezett kimenet";
            var bp = _isBitperfect
                ? "Bit-perfect (1:1 PCM, Unity Gain 0dB, Resampler KIKAPCSOLVA)"
                : "Alapértelmezett keverő (Shared Audio)";
            var exc = _isExclusiveMode
                ? "Kizárólagos mód (Exclusive Hardware Lock)"
                : "Megosztott mód (Shared)";

            return $"Forrás: {fmt.QualityLabel} ({fmt.Codec} {fmt.BitsPerSample}b/{fmt.SampleRate / 1000.0:0.#}kHz)\n" +
                   $"Feldolgozás: {bp}\n" +
                   $"Hozzáférés: {exc}\n" +
                   $"Cél DAC eszköz: {dev}";
        }
    }

    public event EventHandler<PlaybackState>? StateChanged;
    public event EventHandler<TimeSpan>? PositionChanged;
    public event EventHandler<Track?>? TrackChanged;
    public event EventHandler<bool>? BitperfectChanged;
    public event EventHandler<bool>? ExclusiveModeChanged;
    public event EventHandler<float[]>? SpectrumDataAvailable;
    public event EventHandler? TrackEnded;

    public WiretuneAudioEngine(IAudioDriver? driver = null)
    {
        _driver = driver ?? new LinuxAudioDriver();
        HookDriverEvents();
        _ = RefreshDevicesAsync();
    }

    private void HookDriverEvents()
    {
        _driver.StateChanged += (s, state) => StateChanged?.Invoke(this, state);
        _driver.PositionChanged += (s, pos) => PositionChanged?.Invoke(this, pos);
        _driver.SpectrumDataAvailable += (s, bands) => SpectrumDataAvailable?.Invoke(this, bands);
        _driver.TrackEnded += (s, e) => TrackEnded?.Invoke(this, e);
    }

    public async Task RefreshDevicesAsync()
    {
        var devices = await AudioDeviceManager.DetectOutputDevicesAsync();
        _availableDevices.Clear();
        _availableDevices.AddRange(devices);

        if (_currentDevice == null)
        {
            _currentDevice = _availableDevices.FirstOrDefault(d => d.IsDefault) ??
                             _availableDevices.FirstOrDefault();
        }

        if (_currentDevice != null)
        {
            await _driver.InitializeAsync(_currentDevice, _isExclusiveMode, _isBitperfect);
        }
    }

    public async Task PlayTrackAsync(Track track, CancellationToken ct = default)
    {
        _currentTrack = track;
        TrackChanged?.Invoke(this, _currentTrack);

        var source = !string.IsNullOrEmpty(track.StreamUrl) ? track.StreamUrl : track.FilePath;
        WiretuneLog.Info("AudioEngine", $"PlayTrack: '{track.Artist} - {track.Title}' ({track.Format.QualityLabel}) via '{source}'");
        await _driver.PlayAsync(source, track.Format, TimeSpan.Zero, ct);
    }

    public async Task PlayStreamAsync(string streamUrl, Track track, CancellationToken ct = default)
    {
        _currentTrack = track;
        TrackChanged?.Invoke(this, _currentTrack);
        WiretuneLog.Info("AudioEngine", $"PlayStream: '{track.Artist} - {track.Title}' from '{streamUrl}'");
        await _driver.PlayAsync(streamUrl, track.Format, TimeSpan.Zero, ct);
    }

    public Task PauseAsync()
    {
        WiretuneLog.Info("AudioEngine", "Pause requested");
        return _driver.PauseAsync();
    }

    public Task ResumeAsync()
    {
        WiretuneLog.Info("AudioEngine", "Resume requested");
        return _driver.ResumeAsync();
    }

    public Task StopAsync()
    {
        WiretuneLog.Info("AudioEngine", "Stop requested");
        _currentTrack = null;
        TrackChanged?.Invoke(this, null);
        return _driver.StopAsync();
    }

    public Task SeekAsync(TimeSpan position)
    {
        WiretuneLog.Info("AudioEngine", $"Seek requested to {position:mm\\:ss}");
        return _driver.SeekAsync(position);
    }

    public void SetVolume(double volume)
    {
        if (_isBitperfect)
        {
            // Bit-perfect requires 100% (0 dB unity gain) so bits aren't truncated or rescaled
            _volume = 1.0;
            _driver.SetVolume(1.0);
            return;
        }

        _volume = Math.Clamp(volume, 0.0, 1.0);
        _driver.SetVolume(_isMuted ? 0.0 : _volume);
    }

    public void SetMuted(bool muted)
    {
        _isMuted = muted;
        if (!_isBitperfect)
        {
            _driver.SetVolume(_isMuted ? 0.0 : _volume);
        }
    }

    public async Task SetExclusiveModeAsync(bool enabled)
    {
        if (_isExclusiveMode == enabled && (!_isBitperfect || enabled)) return;
        _isExclusiveMode = enabled;
        ExclusiveModeChanged?.Invoke(this, _isExclusiveMode);

        if (!_isExclusiveMode && _isBitperfect)
        {
            // Bit-perfect is impossible in shared mixer mode!
            _isBitperfect = false;
            BitperfectChanged?.Invoke(this, false);
        }

        if (_isExclusiveMode)
        {
            var directAlsa = _availableDevices.FirstOrDefault(d => d.DriverType.Contains("ALSA") || d.Id.StartsWith("hw:"));
            if (directAlsa != null)
            {
                _currentDevice = directAlsa;
            }
        }
        else
        {
            var defaultPw = _availableDevices.FirstOrDefault(d => d.IsDefault) ?? _availableDevices.FirstOrDefault();
            if (defaultPw != null)
            {
                _currentDevice = defaultPw;
            }
        }

        if (_currentDevice != null)
        {
            await _driver.InitializeAsync(_currentDevice, _isExclusiveMode, _isBitperfect);

            if (_currentTrack != null && State == PlaybackState.Playing)
            {
                var pos = CurrentPosition;
                var source = !string.IsNullOrEmpty(_currentTrack.StreamUrl) ? _currentTrack.StreamUrl : _currentTrack.FilePath;
                await _driver.PlayAsync(source, _currentTrack.Format, pos);
            }
        }
    }

    public async Task SetBitperfectModeAsync(bool enabled)
    {
        if (_isBitperfect == enabled) return;
        _isBitperfect = enabled;

        if (_isBitperfect)
        {
            // Bit-perfect requires direct Exclusive access to DAC and unity gain
            if (!_isExclusiveMode)
            {
                _isExclusiveMode = true;
                ExclusiveModeChanged?.Invoke(this, true);
            }

            _volume = 1.0;
            _driver.SetVolume(1.0);
        }

        BitperfectChanged?.Invoke(this, _isBitperfect);

        if (_currentDevice != null)
        {
            await _driver.InitializeAsync(_currentDevice, _isExclusiveMode, _isBitperfect);
        }
    }

    public async Task SetOutputDeviceAsync(AudioOutputDevice device)
    {
        _currentDevice = device;
        await _driver.InitializeAsync(device, _isExclusiveMode, _isBitperfect);

        // If currently playing, restart playback on new device seamlessly
        if (_currentTrack != null && State == PlaybackState.Playing)
        {
            var pos = CurrentPosition;
            var source = !string.IsNullOrEmpty(_currentTrack.StreamUrl) ? _currentTrack.StreamUrl : _currentTrack.FilePath;
            await _driver.PlayAsync(source, _currentTrack.Format, pos);
        }
    }

    public void Dispose()
    {
        _driver.Dispose();
    }
}
