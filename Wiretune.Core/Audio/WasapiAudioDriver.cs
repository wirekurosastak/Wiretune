using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.MediaFoundation;
using NAudio.Wave;
using Wiretune.Core.Audio.Dsp;
using Wiretune.Core.Localization;
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
    private readonly SpectrumAnalyzer _spectrumEngine = new();

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

    /// <summary>
    /// Records the output settings for the next <see cref="PlayAsync"/>. Like the other drivers it does not restart
    /// a running track: the engine does that (<c>ReinitializeOutputAsync</c>), and doing it here too would open the
    /// source twice.
    /// </summary>
    public Task InitializeAsync(AudioOutputDevice device, bool exclusive, bool bitperfect)
    {
        lock (_stateLock)
        {
            _currentDevice = device;
            _isExclusive = exclusive;
            _isBitperfect = bitperfect;

            if (_playbackStream != null)
            {
                _playbackStream.IsBitperfect = bitperfect;
            }
        }

        return Task.CompletedTask;
    }

    /// <summary>
    /// Opening a source can take a long time (an HTTP stream from an unreachable server blocks until the request
    /// times out), so it happens on a worker thread without holding the state lock; the caller and the other
    /// commands (Pause, Stop, ...) stay responsive. If another Play or a Stop arrives meanwhile, the result of the
    /// slow open is discarded.
    /// </summary>
    public async Task PlayAsync(string audioSource, AudioFormat format, TimeSpan startPosition, CancellationToken ct = default)
    {
        long gen;
        AudioOutputDevice? device;
        bool exclusive, bitperfect;
        double volume;
        lock (_stateLock)
        {
            if (_disposed) return;
            StopInternal();
            gen = ++_generation;
            device = _currentDevice;
            exclusive = _isExclusive;
            bitperfect = _isBitperfect;
            volume = _volume;
        }

        OpenedOutput opened;
        try
        {
            opened = await Task.Run(() => Open(audioSource, startPosition, device, exclusive, bitperfect, volume), CancellationToken.None);
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("WasapiAudioDriver", $"PlayAsync failed for '{audioSource}': {ex.Message}", ex);
            lock (_stateLock)
            {
                if (gen == _generation && !_disposed) Fail(Localizer.Format("DriverCannotStart", ex.Message));
            }
            return;
        }

        lock (_stateLock)
        {
            if (gen != _generation || _disposed || ct.IsCancellationRequested)
            {
                opened.Dispose();
                return;
            }

            try
            {
                _reader = opened.Reader;
                _playbackStream = opened.Stream;
                _wasapiOut = opened.Output;
                // Settings may have changed while the source was opening.
                _playbackStream.Volume = _volume;
                _playbackStream.IsBitperfect = _isBitperfect;

                _wasapiOut.PlaybackStopped += (_, e) =>
                {
                    lock (_stateLock)
                    {
                        if (gen != _generation) return;
                        StopTimers();

                        if (e.Exception != null)
                        {
                            Fail(Localizer.Format("DriverWasapiError", e.Exception.Message));
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
                Fail(Localizer.Format("DriverCannotStart", ex.Message));
            }
        }
    }

    /// <summary>Everything a track needs to play; disposed as a unit when it is not going to be used.</summary>
    private sealed class OpenedOutput(MediaFoundationReader reader, SpectrumAndVolumeWaveProvider stream, WasapiOut output) : IDisposable
    {
        public MediaFoundationReader Reader { get; } = reader;
        public SpectrumAndVolumeWaveProvider Stream { get; } = stream;
        public WasapiOut Output { get; } = output;

        public void Dispose()
        {
            try { Output.Dispose(); } catch { }
            try { Reader.Dispose(); } catch { }
        }
    }

    private OpenedOutput Open(string audioSource, TimeSpan startPosition, AudioOutputDevice? deviceInfo, bool exclusive, bool bitperfect, double volume)
    {
        EnsureMediaFoundation();

        MediaFoundationReader? reader = null;
        WasapiOut? output = null;
        try
        {
            reader = new MediaFoundationReader(audioSource);
            if (startPosition > TimeSpan.Zero && startPosition < reader.TotalTime)
            {
                reader.CurrentTime = startPosition;
            }

            var stream = new SpectrumAndVolumeWaveProvider(reader, _spectrumEngine, bands =>
            {
                SpectrumDataAvailable?.Invoke(this, bands);
            })
            {
                Volume = volume,
                IsBitperfect = bitperfect
            };

            var device = GetTargetMMDevice(deviceInfo);
            var shareMode = exclusive ? AudioClientShareMode.Exclusive : AudioClientShareMode.Shared;
            var latency = exclusive ? 50 : 100;

            try
            {
                output = new WasapiOut(device, shareMode, true, latency);
                output.Init(stream);
            }
            // Bit-perfect promises an untouched signal: a shared-mode fallback would resample it behind the user's
            // back, so in that mode the failure is reported instead.
            catch (COMException ex) when (exclusive && !bitperfect)
            {
                WiretuneLog.Warn("WasapiAudioDriver", $"Exclusive mode failed (0x{ex.HResult:X8}), falling back to Shared mode: {ex.Message}");
                output?.Dispose();
                output = new WasapiOut(device, AudioClientShareMode.Shared, true, 100);
                output.Init(stream);
            }

            return new OpenedOutput(reader, stream, output);
        }
        catch
        {
            output?.Dispose();
            reader?.Dispose();
            throw;
        }
    }

    public Task PauseAsync()
    {
        lock (_stateLock)
        {
            if (_state != PlaybackState.Playing || _wasapiOut == null) return Task.CompletedTask;
            _wasapiOut.Pause();
            StopTimers();
            SetState(PlaybackState.Paused);
            SpectrumDataAvailable?.Invoke(this, new float[SpectrumAnalyzer.NumBands]);
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
            SpectrumDataAvailable?.Invoke(this, new float[SpectrumAnalyzer.NumBands]);
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

    private static MMDevice GetTargetMMDevice(AudioOutputDevice? deviceInfo)
    {
        using var enumerator = new MMDeviceEnumerator();
        if (!string.IsNullOrEmpty(deviceInfo?.Id) && deviceInfo.Id != "default" && deviceInfo.Id != "wasapi_default")
        {
            try
            {
                return enumerator.GetDevice(deviceInfo.Id);
            }
            catch (Exception ex)
            {
                WiretuneLog.Warn("WasapiAudioDriver", $"Could not find device {deviceInfo.Id}: {ex.Message}, falling back to default");
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
        _generation++;
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
    internal sealed class SpectrumAndVolumeWaveProvider : IWaveProvider
    {
        private readonly IWaveProvider _source;
        private readonly SpectrumAnalyzer _spectrumEngine;
        private readonly Action<float[]> _onSpectrumAvailable;
        private readonly float[] _fftWindow = new float[SpectrumAnalyzer.FftSize];
        private int _fftIndex;
        private readonly int _decimation;
        private int _decimationCount;
        private float _decimationSum;
        private readonly object _fftLock = new();

        public WaveFormat WaveFormat => _source.WaveFormat;
        public double Volume { get; set; } = 1.0;
        public bool IsBitperfect { get; set; }

        public SpectrumAndVolumeWaveProvider(
            IWaveProvider source,
            SpectrumAnalyzer spectrumEngine,
            Action<float[]> onSpectrumAvailable)
        {
            _source = source;
            _spectrumEngine = spectrumEngine;
            _onSpectrumAvailable = onSpectrumAvailable;
            // The analyser's frequency bands are laid out for 44.1 kHz; average down higher rates so that 96 or
            // 192 kHz files do not shift every band upwards.
            _decimation = Math.Max(1, (int)Math.Round(source.WaveFormat.SampleRate / 44100.0));
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
            int end = offset + bytesRead;
            if (bitsPerSample == 16)
            {
                for (int i = offset; i + 2 <= end; i += 2)
                {
                    short sample = (short)(buffer[i] | (buffer[i + 1] << 8));
                    int scaled = Math.Clamp((int)(sample * volume), short.MinValue, short.MaxValue);
                    buffer[i] = (byte)(scaled & 0xFF);
                    buffer[i + 1] = (byte)((scaled >> 8) & 0xFF);
                }
            }
            else if (bitsPerSample == 24)
            {
                for (int i = offset; i + 3 <= end; i += 3)
                {
                    int sample = buffer[i] | (buffer[i + 1] << 8) | ((sbyte)buffer[i + 2] << 16);
                    int scaled = Math.Clamp((int)(sample * (double)volume), -8388608, 8388607);
                    buffer[i] = (byte)(scaled & 0xFF);
                    buffer[i + 1] = (byte)((scaled >> 8) & 0xFF);
                    buffer[i + 2] = (byte)((scaled >> 16) & 0xFF);
                }
            }
            else if (bitsPerSample == 32 && WaveFormat.Encoding == WaveFormatEncoding.IeeeFloat)
            {
                for (int i = offset; i + 4 <= end; i += 4)
                {
                    float sample = BitConverter.ToSingle(buffer, i) * volume;
                    BitConverter.TryWriteBytes(new Span<byte>(buffer, i, 4), sample);
                }
            }
            else if (bitsPerSample == 32)
            {
                for (int i = offset; i + 4 <= end; i += 4)
                {
                    int sample = BitConverter.ToInt32(buffer, i);
                    int scaled = (int)Math.Clamp(sample * (double)volume, int.MinValue, int.MaxValue);
                    BitConverter.TryWriteBytes(new Span<byte>(buffer, i, 4), scaled);
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
                    else if (bitsPerSample == 32)
                    {
                        for (int ch = 0; ch < channels; ch++)
                        {
                            monoSample += BitConverter.ToInt32(buffer, frameOffset + ch * 4) / 2147483648.0f;
                        }
                    }
                    monoSample /= channels;

                    _decimationSum += monoSample;
                    if (++_decimationCount < _decimation) continue;

                    _fftWindow[_fftIndex++] = _decimationSum / _decimation;
                    _decimationSum = 0f;
                    _decimationCount = 0;
                    if (_fftIndex >= SpectrumAnalyzer.FftSize)
                    {
                        _fftIndex = 0;
                    }
                }
            }
        }

        public void RenderSpectrum()
        {
            float[] windowCopy = new float[SpectrumAnalyzer.FftSize];
            lock (_fftLock)
            {
                int src = _fftIndex;
                for (int i = 0; i < SpectrumAnalyzer.FftSize; i++)
                {
                    windowCopy[i] = _fftWindow[(src + i) % SpectrumAnalyzer.FftSize];
                }
            }

            float[] bands = _spectrumEngine.ProcessPcm(windowCopy, isPlaying: true);
            _onSpectrumAvailable(bands);
        }
    }
}
