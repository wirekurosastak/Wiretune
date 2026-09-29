using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.MediaFoundation;
using NAudio.Wave;
using Wiretune.Core.Audio.Dsp;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using PlaybackState = Wiretune.Core.Models.PlaybackState;

namespace Wiretune.Core.Audio.Drivers;

/// <summary>
/// Native Windows audio driver using WASAPI (Shared & Exclusive bit-perfect output)
/// and Windows Media Foundation for decoding audio streams without external dependencies.
/// </summary>
public sealed class WasapiAudioDriver : IAudioDriver
{
    private static bool _mfInitialized;
    private static readonly object MfLock = new();

    private readonly object _stateLock = new();
    private readonly FxSoundSpectrumEngine _spectrumEngine = new();

    private WasapiOut? _wasapiOut;
    private MediaFoundationReader? _reader;
    private SpectrumAndVolumeWaveProvider? _playbackStream;
    private AudioOutputDevice? _currentDevice;
    private bool _isExclusive;
    private bool _isBitperfect;
    private double _volume = 1.0;
    private PlaybackState _state = PlaybackState.Stopped;
    private TimeSpan _currentPosition = TimeSpan.Zero;
    private Timer? _positionTimer;
    private Timer? _spectrumTimer;
    private long _generation;
    private bool _disposed;
    private string? _currentSource;
    private AudioFormat? _currentFormat;

    public string DriverName => _isBitperfect ? "WASAPI Bit-Perfect" : _isExclusive ? "WASAPI Exclusive" : "WASAPI Shared";
    public PlaybackState State => _state;
    public TimeSpan CurrentPosition => _currentPosition;

    public event EventHandler<PlaybackState>? StateChanged;
    public event EventHandler<TimeSpan>? PositionChanged;
    public event EventHandler<float[]>? SpectrumDataAvailable;
    public event EventHandler? TrackEnded;
    public event EventHandler<string>? PlaybackFailed;

    public WasapiAudioDriver()
    {
        EnsureMediaFoundation();
    }

    public async Task InitializeAsync(AudioOutputDevice device, bool exclusive, bool bitperfect)
    {
        bool needsRestart = false;
        string? source = null;
        AudioFormat? format = null;
        TimeSpan pos = TimeSpan.Zero;

        lock (_stateLock)
        {
            if (_currentDevice?.Id != device.Id || _isExclusive != exclusive || _isBitperfect != bitperfect)
            {
                _currentDevice = device;
                _isExclusive = exclusive;
                _isBitperfect = bitperfect;

                if (_playbackStream != null)
                {
                    _playbackStream.IsBitperfect = bitperfect;
                }

                if (_state == PlaybackState.Playing && _currentSource != null)
                {
                    needsRestart = true;
                    source = _currentSource;
                    format = _currentFormat;
                    pos = _currentPosition;
                }
            }
        }

        if (needsRestart && source != null)
        {
            await PlayAsync(source, format ?? new AudioFormat(), pos);
        }
    }

    public Task PlayAsync(string audioSource, AudioFormat format, TimeSpan startPosition, CancellationToken ct = default)
    {
        lock (_stateLock)
        {
            StopInternal();
            var gen = ++_generation;
            _currentSource = audioSource;
            _currentFormat = format;

            try
            {
                EnsureMediaFoundation();

                _reader = new MediaFoundationReader(audioSource);
                if (startPosition > TimeSpan.Zero && startPosition < _reader.TotalTime)
                {
                    _reader.CurrentTime = startPosition;
                }

                _playbackStream = new SpectrumAndVolumeWaveProvider(_reader, _spectrumEngine, bands =>
                {
                    SpectrumDataAvailable?.Invoke(this, bands);
                })
                {
                    Volume = _volume,
                    IsBitperfect = _isBitperfect
                };

                var device = GetTargetMMDevice();
                var shareMode = _isExclusive ? AudioClientShareMode.Exclusive : AudioClientShareMode.Shared;
                int latency = _isExclusive ? 50 : 100;

                try
                {
                    _wasapiOut = new WasapiOut(device, shareMode, true, latency);
                    _wasapiOut.Init(_playbackStream);
                }
                catch (COMException ex) when (_isExclusive)
                {
                    WiretuneLog.Warn("WasapiAudioDriver", $"Exclusive mode failed (0x{ex.HResult:X8}), falling back to Shared mode: {ex.Message}");
                    _wasapiOut?.Dispose();
                    _wasapiOut = new WasapiOut(device, AudioClientShareMode.Shared, true, 100);
                    _wasapiOut.Init(_playbackStream);
                }

                _wasapiOut.PlaybackStopped += (_, e) =>
                {
                    lock (_stateLock)
                    {
                        if (gen != _generation) return;
                        StopTimers();

                        if (e.Exception != null)
                        {
                            Fail($"WASAPI hiba: {e.Exception.Message}");
                        }
                        else
                        {
                            SetState(PlaybackState.Stopped);
                            TrackEnded?.Invoke(this, EventArgs.Empty);
                        }
                    }
                };

                _wasapiOut.Play();
                _currentPosition = startPosition;
                SetState(PlaybackState.Playing);
                StartTimers();
            }
            catch (Exception ex)
            {
                WiretuneLog.Error("WasapiAudioDriver", $"PlayAsync failed for '{audioSource}': {ex.Message}", ex);
                Fail($"A lejátszás nem indítható: {ex.Message}");
            }
        }

        return Task.CompletedTask;
    }

    public Task PauseAsync()
    {
        lock (_stateLock)
        {
            if (_state != PlaybackState.Playing || _wasapiOut == null) return Task.CompletedTask;
            _wasapiOut.Pause();
            StopTimers();
            SetState(PlaybackState.Paused);
            SpectrumDataAvailable?.Invoke(this, new float[FxSoundSpectrumEngine.NumBands]);
        }
        return Task.CompletedTask;
    }

    public Task ResumeAsync()
    {
        lock (_stateLock)
        {
            if (_state != PlaybackState.Paused || _wasapiOut == null) return Task.CompletedTask;
            _wasapiOut.Play();
            SetState(PlaybackState.Playing);
            StartTimers();
        }
        return Task.CompletedTask;
    }

    public Task SeekAsync(TimeSpan position)
    {
        lock (_stateLock)
        {
            _currentPosition = position;
            if (_reader != null)
            {
                try
                {
                    _reader.CurrentTime = position;
                }
                catch (Exception ex)
                {
                    WiretuneLog.Warn("WasapiAudioDriver", $"Seek error: {ex.Message}");
                }
            }
        }
        PositionChanged?.Invoke(this, position);
        return Task.CompletedTask;
    }

    public Task StopAsync()
    {
        lock (_stateLock)
        {
            _generation++;
            StopInternal();
            _currentPosition = TimeSpan.Zero;
            SetState(PlaybackState.Stopped);
            SpectrumDataAvailable?.Invoke(this, new float[FxSoundSpectrumEngine.NumBands]);
        }
        return Task.CompletedTask;
    }

    public void SetVolume(double volume)
    {
        _volume = Math.Clamp(volume, 0.0, 1.0);
        lock (_stateLock)
        {
            if (_playbackStream != null)
            {
                _playbackStream.Volume = _volume;
            }
        }
    }

    private MMDevice GetTargetMMDevice()
    {
        using var enumerator = new MMDeviceEnumerator();
        if (!string.IsNullOrEmpty(_currentDevice?.Id) && _currentDevice.Id != "default" && _currentDevice.Id != "wasapi_default")
        {
            try
            {
                return enumerator.GetDevice(_currentDevice.Id);
            }
            catch (Exception ex)
            {
                WiretuneLog.Warn("WasapiAudioDriver", $"Could not find device {_currentDevice.Id}: {ex.Message}, falling back to default");
            }
        }

        return enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
    }

    private void StartTimers()
    {
        StopTimers();
        _positionTimer = new Timer(_ =>
        {
            TimeSpan pos = TimeSpan.Zero;
            lock (_stateLock)
            {
                if (_wasapiOut == null || _reader == null || _state != PlaybackState.Playing) return;
                try
                {
                    pos = _reader.CurrentTime;
                    _currentPosition = pos;
                }
                catch
                {
                    return;
                }
            }
            PositionChanged?.Invoke(this, pos);
        }, null, 0, 200);

        _spectrumTimer = new Timer(_ =>
        {
            lock (_stateLock)
            {
                if (_wasapiOut == null || _playbackStream == null || _state != PlaybackState.Playing) return;
                try
                {
                    _playbackStream.RenderSpectrum();
                }
                catch
                {
                    // Ignore rendering exceptions
                }
            }
        }, null, 0, 33);
    }

    private void StopTimers()
    {
        _positionTimer?.Dispose();
        _positionTimer = null;
        _spectrumTimer?.Dispose();
        _spectrumTimer = null;
    }

    private void StopInternal()
    {
        StopTimers();
        if (_wasapiOut != null)
        {
            try
            {
                _wasapiOut.Stop();
                _wasapiOut.Dispose();
            }
            catch
            {
                // Ignore dispose errors
            }
            _wasapiOut = null;
        }

        if (_reader != null)
        {
            try { _reader.Dispose(); } catch { }
            _reader = null;
        }

        _playbackStream = null;
    }

    private void Fail(string message)
    {
        WiretuneLog.Warn("WasapiAudioDriver", message);
        StopInternal();
        SetState(PlaybackState.Error);
        PlaybackFailed?.Invoke(this, message);
    }

    private void SetState(PlaybackState state)
    {
        if (_state == state) return;
        _state = state;
        StateChanged?.Invoke(this, state);
    }

    private static void EnsureMediaFoundation()
    {
        if (_mfInitialized) return;
        lock (MfLock)
        {
            if (_mfInitialized) return;
            try
            {
                MediaFoundationApi.Startup();
                _mfInitialized = true;
            }
            catch (Exception ex)
            {
                WiretuneLog.Warn("WasapiAudioDriver", $"MediaFoundation startup failed: {ex.Message}");
            }
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        lock (_stateLock)
        {
            _generation++;
            StopInternal();
        }
    }

    /// <summary>
    /// Stream wrapper that measures live FFT spectrum and applies software volume when not in Bit-Perfect mode.
    /// </summary>
    private sealed class SpectrumAndVolumeWaveProvider : IWaveProvider
    {
        private readonly IWaveProvider _source;
        private readonly FxSoundSpectrumEngine _spectrumEngine;
        private readonly Action<float[]> _onSpectrumAvailable;
        private readonly float[] _fftWindow = new float[FxSoundSpectrumEngine.FftSize];
        private int _fftIndex;
        private readonly object _fftLock = new();

        public WaveFormat WaveFormat => _source.WaveFormat;
        public double Volume { get; set; } = 1.0;
        public bool IsBitperfect { get; set; }

        public SpectrumAndVolumeWaveProvider(
            IWaveProvider source,
            FxSoundSpectrumEngine spectrumEngine,
            Action<float[]> onSpectrumAvailable)
        {
            _source = source;
            _spectrumEngine = spectrumEngine;
            _onSpectrumAvailable = onSpectrumAvailable;
        }

        public int Read(byte[] buffer, int offset, int count)
        {
            int bytesRead = _source.Read(buffer, offset, count);
            if (bytesRead <= 0) return bytesRead;

            if (!IsBitperfect && Volume < 0.999)
            {
                ApplyVolume(buffer, offset, bytesRead, (float)Volume);
            }

            ExtractSpectrumSamples(buffer, offset, bytesRead);

            return bytesRead;
        }

        private void ApplyVolume(byte[] buffer, int offset, int bytesRead, float volume)
        {
            int bitsPerSample = WaveFormat.BitsPerSample;
            if (bitsPerSample == 16)
            {
                for (int i = offset; i < offset + bytesRead; i += 2)
                {
                    short sample = (short)(buffer[i] | (buffer[i + 1] << 8));
                    int scaled = (int)(sample * volume);
                    scaled = Math.Clamp(scaled, short.MinValue, short.MaxValue);
                    buffer[i] = (byte)(scaled & 0xFF);
                    buffer[i + 1] = (byte)((scaled >> 8) & 0xFF);
                }
            }
            else if (bitsPerSample == 32 && WaveFormat.Encoding == WaveFormatEncoding.IeeeFloat)
            {
                for (int i = offset; i < offset + bytesRead; i += 4)
                {
                    float sample = BitConverter.ToSingle(buffer, i);
                    sample *= volume;
                    byte[] bytes = BitConverter.GetBytes(sample);
                    buffer[i] = bytes[0];
                    buffer[i + 1] = bytes[1];
                    buffer[i + 2] = bytes[2];
                    buffer[i + 3] = bytes[3];
                }
            }
        }

        private void ExtractSpectrumSamples(byte[] buffer, int offset, int bytesRead)
        {
            int channels = WaveFormat.Channels;
            int bitsPerSample = WaveFormat.BitsPerSample;
            int bytesPerFrame = (bitsPerSample / 8) * channels;
            if (bytesPerFrame == 0) return;

            int frames = bytesRead / bytesPerFrame;
            lock (_fftLock)
            {
                for (int f = 0; f < frames; f++)
                {
                    int frameOffset = offset + f * bytesPerFrame;
                    float monoSample = 0f;

                    if (bitsPerSample == 16)
                    {
                        for (int ch = 0; ch < channels; ch++)
                        {
                            short s = (short)(buffer[frameOffset + ch * 2] | (buffer[frameOffset + ch * 2 + 1] << 8));
                            monoSample += s / 32768.0f;
                        }
                    }
                    else if (bitsPerSample == 24)
                    {
                        for (int ch = 0; ch < channels; ch++)
                        {
                            int byteIdx = frameOffset + ch * 3;
                            int s = buffer[byteIdx] | (buffer[byteIdx + 1] << 8) | ((sbyte)buffer[byteIdx + 2] << 16);
                            monoSample += s / 8388608.0f;
                        }
                    }
                    else if (bitsPerSample == 32 && WaveFormat.Encoding == WaveFormatEncoding.IeeeFloat)
                    {
                        for (int ch = 0; ch < channels; ch++)
                        {
                            monoSample += BitConverter.ToSingle(buffer, frameOffset + ch * 4);
                        }
                    }
                    monoSample /= channels;

                    _fftWindow[_fftIndex++] = monoSample;
                    if (_fftIndex >= FxSoundSpectrumEngine.FftSize)
                    {
                        _fftIndex = 0;
                    }
                }
            }
        }

        public void RenderSpectrum()
        {
            float[] windowCopy = new float[FxSoundSpectrumEngine.FftSize];
            lock (_fftLock)
            {
                int src = _fftIndex;
                for (int i = 0; i < FxSoundSpectrumEngine.FftSize; i++)
                {
                    windowCopy[i] = _fftWindow[(src + i) % FxSoundSpectrumEngine.FftSize];
                }
            }

            float[] bands = _spectrumEngine.ProcessPcm(windowCopy, isPlaying: true);
            _onSpectrumAvailable(bands);
        }
    }
}



