using Wiretune.Core.Audio.Devices;
using Wiretune.Core.Audio.Drivers;
using Wiretune.Core.Localization;
using Wiretune.Core.Models;
using Wiretune.Core.Services;

namespace Wiretune.Core.Audio;

public class WiretuneAudioEngine : IDisposable
{
    private readonly IAudioDriver _driver;
    private readonly Func<Task<List<AudioOutputDevice>>> _detectDevices;
    private readonly Task _initialDeviceScan;
    private readonly object _deviceLock = new();
    private IReadOnlyList<AudioOutputDevice> _availableDevices = Array.Empty<AudioOutputDevice>();
    private Track? _currentTrack;
    private AudioOutputDevice? _currentDevice;
    private bool _isExclusiveMode;
    private bool _isBitperfect;
    private double _volume = 1.0;
    private double _volumeBeforeBitperfect = 1.0;
    private bool _isMuted;
    private string? _streamToken;
    private Func<CancellationToken, Task<string?>>? _streamTokenProvider;
    private bool _disposed;

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
            if (_currentTrack == null) return Localizer.Get("SignalNone");

            var fmt = _currentTrack.Format;
            var dev = _currentDevice?.DisplayTitle ?? Localizer.Get("DefaultOutput");
            var source = fmt.IsLossless
                ? $"{fmt.QualityLabel} ({fmt.Codec} {fmt.BitsPerSample}b/{fmt.SampleRate / 1000.0:0.#}kHz)"
                : fmt.QualityLabel;
            var processing = _isBitperfect
                ? Localizer.Get("SignalProcessingBitPerfect")
                : Localizer.Get("SignalProcessingMixer");
            var access = Localizer.Get(_isExclusiveMode ? "SignalAccessExclusive" : "SignalAccessShared");
            var transport = Localizer.Get(!string.IsNullOrEmpty(_currentTrack.StreamUrl) ? "SignalTransportServer" : "SignalTransportLocal");

            return Localizer.Format("SignalSource", source) + "\n" +
                   Localizer.Format("SignalTransport", transport) + "\n" +
                   Localizer.Format("SignalProcessing", processing) + "\n" +
                   Localizer.Format("SignalAccess", access) + "\n" +
                   Localizer.Format("SignalTarget", dev);
        }
    }

    public event EventHandler<PlaybackState>? StateChanged;
    public event EventHandler<TimeSpan>? PositionChanged;
    public event EventHandler<Track?>? TrackChanged;
    public event EventHandler<bool>? BitperfectChanged;
    public event EventHandler<bool>? ExclusiveModeChanged;
    public event EventHandler<float[]>? SpectrumDataAvailable;
    public event EventHandler? TrackEnded;
    public event EventHandler? DevicesChanged;
    public event EventHandler<string>? PlaybackFailed;

    public WiretuneAudioEngine(IAudioDriver? driver = null, Func<Task<List<AudioOutputDevice>>>? deviceDetector = null)
    {
        _driver = driver ?? CreateDefaultDriver();
        _detectDevices = deviceDetector ?? AudioDeviceManager.DetectOutputDevicesAsync;

        _driver.StateChanged += (_, state) => StateChanged?.Invoke(this, state);
        _driver.PositionChanged += (_, pos) => PositionChanged?.Invoke(this, pos);
        _driver.SpectrumDataAvailable += (_, bands) => SpectrumDataAvailable?.Invoke(this, bands);
        _driver.TrackEnded += (_, e) => TrackEnded?.Invoke(this, e);
        _driver.PlaybackFailed += (_, message) => PlaybackFailed?.Invoke(this, message);

        _initialDeviceScan = RefreshDevicesAsync();
    }

    public void SetStreamAuthorization(string? bearerToken) => _streamToken = string.IsNullOrEmpty(bearerToken) ? null : bearerToken;

    /// <summary>
    /// Supplies the token appended to stream URLs. It is asked for each time a server track starts, so a long-running
    /// player always uses a token that is still valid. Overrides <see cref="SetStreamAuthorization"/> for server tracks.
    /// </summary>
    public void SetStreamTokenProvider(Func<CancellationToken, Task<string?>>? provider) => _streamTokenProvider = provider;

    public async Task RefreshDevicesAsync()
    {
        List<AudioOutputDevice> devices;
        try
        {
            devices = await _detectDevices();
        }
        catch (Exception ex)
        {
            WiretuneLog.Warn("AudioEngine", $"Audio device detection failed: {ex.Message}");
            devices = new List<AudioOutputDevice>();
        }

        AudioOutputDevice? device;
        lock (_deviceLock)
        {
            _availableDevices = devices;
            if (_currentDevice == null || devices.All(d => d.Id != _currentDevice.Id))
            {
                _currentDevice = devices.FirstOrDefault(d => d.IsDefault) ?? devices.FirstOrDefault();
            }
            else
            {
                _currentDevice = devices.First(d => d.Id == _currentDevice.Id);
            }
            device = _currentDevice;
        }

        if (device != null)
        {
            // The first scan runs unobserved from the constructor: report a failure instead of leaving it in a faulted task.
            try
            {
                await _driver.InitializeAsync(device, _isExclusiveMode, _isBitperfect);
            }
            catch (Exception ex)
            {
                WiretuneLog.Error("AudioEngine", $"Initialising output '{device.Name}' failed: {ex.Message}", ex);
                PlaybackFailed?.Invoke(this, Localizer.Format("EngineDeviceInitFailed", device.Name, ex.Message));
            }
        }

        DevicesChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task PlayTrackAsync(Track track, CancellationToken ct = default)
    {
        _currentTrack = track;
        TrackChanged?.Invoke(this, track);

        if (!track.IsLocal && _streamTokenProvider != null) await RefreshStreamTokenAsync(ct);

        var source = ResolveSource(track);
        if (string.IsNullOrEmpty(source))
        {
            PlaybackFailed?.Invoke(this, Localizer.Format("EngineNoSource", track.Title));
            return;
        }

        WiretuneLog.Info("AudioEngine", $"PlayTrack: '{track.Artist} - {track.Title}' ({track.Format.QualityLabel})");
        await _driver.PlayAsync(source, track.Format, TimeSpan.Zero, ct);
    }

    public Task PauseAsync() => _driver.PauseAsync();

    public Task ResumeAsync() => _driver.ResumeAsync();

    public Task StopAsync()
    {
        _currentTrack = null;
        TrackChanged?.Invoke(this, null);
        return _driver.StopAsync();
    }

    public Task SeekAsync(TimeSpan position) => _driver.SeekAsync(position);

    public void SetVolume(double volume)
    {
        if (_isBitperfect)
        {
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
        await _initialDeviceScan;
        if (_isExclusiveMode == enabled) return;

        if (enabled)
        {
            var exclusiveDevice = PreferredExclusiveDevice();
            if (exclusiveDevice == null)
            {
                PlaybackFailed?.Invoke(this, Localizer.Get("EngineNoExclusive"));
                ExclusiveModeChanged?.Invoke(this, false);
                return;
            }
            _currentDevice = exclusiveDevice;
        }
        else
        {
            if (_isBitperfect) DisableBitperfect();
            _currentDevice = _availableDevices.FirstOrDefault(d => d.IsDefault) ?? _availableDevices.FirstOrDefault() ?? _currentDevice;
        }

        _isExclusiveMode = enabled;
        ExclusiveModeChanged?.Invoke(this, enabled);
        await ReinitializeOutputAsync();
    }

    public async Task SetBitperfectModeAsync(bool enabled)
    {
        await _initialDeviceScan;
        if (_isBitperfect == enabled) return;

        if (!enabled)
        {
            DisableBitperfect();
            await ReinitializeOutputAsync();
            return;
        }

        var device = _currentDevice is { IsBitperfectSupported: true, IsExclusiveSupported: true }
            ? _currentDevice
            : PreferredExclusiveDevice(requireBitperfect: true);
        if (device == null)
        {
            PlaybackFailed?.Invoke(this, Localizer.Get("EngineNoBitPerfect"));
            BitperfectChanged?.Invoke(this, false);
            return;
        }

        _currentDevice = device;
        if (!_isExclusiveMode)
        {
            _isExclusiveMode = true;
            ExclusiveModeChanged?.Invoke(this, true);
        }

        _volumeBeforeBitperfect = _volume;
        _isBitperfect = true;
        _volume = 1.0;
        _driver.SetVolume(1.0);
        BitperfectChanged?.Invoke(this, true);
        await ReinitializeOutputAsync();
    }

    public async Task SetOutputDeviceAsync(AudioOutputDevice device)
    {
        _currentDevice = device;
        if (!device.IsExclusiveSupported && _isExclusiveMode)
        {
            if (_isBitperfect) DisableBitperfect();
            _isExclusiveMode = false;
            ExclusiveModeChanged?.Invoke(this, false);
        }
        await ReinitializeOutputAsync();
    }

    private void DisableBitperfect()
    {
        _isBitperfect = false;
        _volume = _volumeBeforeBitperfect;
        _driver.SetVolume(_isMuted ? 0.0 : _volume);
        BitperfectChanged?.Invoke(this, false);
    }

    private AudioOutputDevice? PreferredExclusiveDevice(bool requireBitperfect = false)
    {
        var candidates = _availableDevices.Where(d => d.IsExclusiveSupported && (!requireBitperfect || d.IsBitperfectSupported)).ToList();
        if (candidates.Count == 0) return null;

        // 1. If current device is already an exclusive candidate, keep it
        if (_currentDevice != null && candidates.FirstOrDefault(d => d.Id == _currentDevice.Id) is { } currentMatch)
            return currentMatch;

        // 2. If the current device is a shared sink (e.g. a PipeWire sink), find the hardware device with the same card name
        if (_currentDevice != null)
        {
            var match = candidates.FirstOrDefault(d =>
                (!string.IsNullOrEmpty(d.HardwareCard) && _currentDevice.Name.Contains(d.HardwareCard, StringComparison.OrdinalIgnoreCase)) ||
                (!string.IsNullOrEmpty(_currentDevice.HardwareCard) && d.Name.Contains(_currentDevice.HardwareCard, StringComparison.OrdinalIgnoreCase)));
            if (match != null) return match;
        }

        // 3. Prefer a USB DAC over internal HDMI / motherboard audio
        var usbDac = candidates.FirstOrDefault(d =>
            d.Name.Contains("USB", StringComparison.OrdinalIgnoreCase) ||
            (!string.IsNullOrEmpty(d.HardwareCard) && d.HardwareCard.Contains("USB", StringComparison.OrdinalIgnoreCase)));
        if (usbDac != null) return usbDac;

        // 4. Any direct ALSA device
        var alsaDev = candidates.FirstOrDefault(d => d.DriverType.Contains("ALSA") || d.Id.StartsWith("hw:"));
        if (alsaDev != null) return alsaDev;

        return candidates.FirstOrDefault();
    }

    /// <summary>Applies the current device/mode to the driver and restarts playback in place if a track is playing.</summary>
    private async Task ReinitializeOutputAsync()
    {
        if (_currentDevice == null) return;

        await _driver.InitializeAsync(_currentDevice, _isExclusiveMode, _isBitperfect);

        if (_currentTrack != null && State == PlaybackState.Playing && ResolveSource(_currentTrack) is { } source)
        {
            await _driver.PlayAsync(source, _currentTrack.Format, CurrentPosition);
        }
    }

    private async Task RefreshStreamTokenAsync(CancellationToken ct)
    {
        try
        {
            var token = await _streamTokenProvider!(ct);
            _streamToken = string.IsNullOrEmpty(token) ? null : token;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            // Keep the token we have: it may still be valid, and if not the server's refusal is reported by playback.
            WiretuneLog.Warn("AudioEngine", $"Could not refresh the stream token: {ex.Message}");
        }
    }

    private string? ResolveSource(Track track)
    {
        if (string.IsNullOrEmpty(track.StreamUrl)) return string.IsNullOrEmpty(track.FilePath) ? null : track.FilePath;
        if (_streamToken == null) return track.StreamUrl;

        var separator = track.StreamUrl.Contains('?') ? '&' : '?';
        return $"{track.StreamUrl}{separator}token={Uri.EscapeDataString(_streamToken)}";
    }

    private static IAudioDriver CreateDefaultDriver()
    {
        if (OperatingSystem.IsWindows())
            return new WasapiAudioDriver();
        return new FfmpegAudioDriver();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _driver.Dispose();
        GC.SuppressFinalize(this);
    }
}
