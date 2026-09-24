using System.Diagnostics;
using Wiretone.Audio.Dsp;
using Wiretone.Core.Models;
using Wiretone.Core.Services;

namespace Wiretone.Audio.Drivers;

public class LinuxAudioDriver : IAudioDriver
{
    private Process? _playbackProcess;
    private AudioOutputDevice? _currentDevice;
    private bool _isExclusive;
    private bool _isBitperfect;
    private double _volume = 1.0;
    private PlaybackState _state = PlaybackState.Stopped;
    private TimeSpan _currentPosition = TimeSpan.Zero;
    private TimeSpan _duration = TimeSpan.Zero;
    private DateTime _playStartTime;
    private TimeSpan _seekOffset = TimeSpan.Zero;
    private System.Threading.Timer? _positionTimer;
    private System.Threading.Timer? _spectrumTimer;
    private readonly Random _rng = new();
    private readonly Dsp.FxSoundSpectrumEngine _spectrumEngine = new();
    private readonly Dsp.AudioPcmCache _pcmCache = new();
    private string? _currentSource;
    private AudioFormat? _currentFormat;
    private volatile bool _isIntentionalStop = false;
    private long _playbackGeneration = 0;
    private bool _pipewireForceRateActive = false;
    private bool _alsaDirectClaimActive = false;

    public string DriverName => "Linux ALSA / PipeWire Engine";
    public PlaybackState State => _state;
    public TimeSpan CurrentPosition => _currentPosition;

    public event EventHandler<PlaybackState>? StateChanged;
    public event EventHandler<TimeSpan>? PositionChanged;
    public event EventHandler<float[]>? SpectrumDataAvailable;
    public event EventHandler? TrackEnded;

    public Task InitializeAsync(AudioOutputDevice device, bool exclusive, bool bitperfect)
    {
        _currentDevice = device;
        _isExclusive = exclusive;
        _isBitperfect = bitperfect;
        return Task.CompletedTask;
    }

    public async Task PlayAsync(string audioSource, AudioFormat format, TimeSpan startPosition, CancellationToken ct = default)
    {
        await StopPlaybackInternalAsync();

        long gen = Interlocked.Increment(ref _playbackGeneration);
        _currentSource = audioSource;
        _currentFormat = format;
        _seekOffset = startPosition;
        _currentPosition = startPosition;

        StartPlaybackProcess(audioSource, format, startPosition, gen);

        _playStartTime = DateTime.UtcNow;
        _pcmCache.LoadTrack(audioSource);
        SetState(PlaybackState.Playing);
        StartTimers();
    }

    private static readonly List<Process> _activeProcesses = new();
    private static readonly object _processLock = new();

    static LinuxAudioDriver()
    {
        AppDomain.CurrentDomain.ProcessExit += (_, _) => KillAllGlobalProcesses();
        Console.CancelKeyPress += (_, _) => KillAllGlobalProcesses();
    }

    public LinuxAudioDriver()
    {
        AppDomain.CurrentDomain.ProcessExit += (_, _) => KillProcess();
    }

    private static void KillAllGlobalProcesses()
    {
        lock (_processLock)
        {
            foreach (var p in _activeProcesses)
            {
                try
                {
                    if (!p.HasExited)
                    {
                        p.Kill(true);
                        p.WaitForExit(100);
                    }
                }
                catch { }
            }
            _activeProcesses.Clear();
        }

        try
        {
            Process.Start(new ProcessStartInfo("pkill", $"-9 -P {Environment.ProcessId} ffplay")
            {
                CreateNoWindow = true,
                UseShellExecute = false
            })?.WaitForExit(200);
        }
        catch { }
    }

    private void StartPlaybackProcess(string audioSource, AudioFormat format, TimeSpan startPosition, long gen)
    {
        try
        {
            var ssArg = startPosition > TimeSpan.Zero
                ? $"-ss {startPosition.TotalSeconds:F2}"
                : "";

            // In Bitperfect mode, volume must be unity gain (1.0 = 100% / 0 dB)
            var volumeToUse = _isBitperfect ? 100 : Math.Clamp((int)(_volume * 100), 0, 100);

            // SONE / Audiophile flags: in bitperfect mode, preserve native sample rate without resampling
            var rateArg = _isBitperfect && format.SampleRate > 0 ? $"-ar {format.SampleRate}" : "";

            // We use ffplay as the high-fidelity decoder/player
            var arguments = $"-nodisp -autoexit -loglevel quiet {rateArg} {ssArg} -volume {volumeToUse} \"{audioSource}\"";
            WiretoneLog.Info("LinuxAudioDriver", $"Launching ffplay: {arguments}");

            var psi = new ProcessStartInfo
            {
                FileName = "ffplay",
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardError = false,
                RedirectStandardOutput = false
            };

            // Configure Audiophile hardware routing (ALSA Direct vs PipeWire Exclusive)
            if (_currentDevice != null)
            {
                var isAlsaDirect = _currentDevice.DriverType.Contains("ALSA") || _currentDevice.Id.StartsWith("hw:");
                if (isAlsaDirect)
                {
                    // Exclusive ALSA mode: release PipeWire device claim so ALSA direct can open the hardware DAC
                    try
                    {
                        Process.Start(new ProcessStartInfo("wpctl", "set-profile 67 0") { CreateNoWindow = true, UseShellExecute = false })?.WaitForExit(200);
                        _alsaDirectClaimActive = true;
                    }
                    catch { }

                    psi.EnvironmentVariables["SDL_AUDIODRIVER"] = "alsa";
                    var alsaDev = _currentDevice.Id.StartsWith("hw:")
                        ? _currentDevice.Id.Replace("hw:", "plughw:")
                        : _currentDevice.Id;
                    psi.EnvironmentVariables["AUDIODEV"] = alsaDev;
                }
                else
                {
                    // PipeWire direct sink node routing
                    psi.EnvironmentVariables["SDL_AUDIODRIVER"] = "pipewire";
                    var targetId = _currentDevice.Id.Replace("pw_", "");
                    psi.EnvironmentVariables["PIPEWIRE_NODE"] = targetId;

                    if (_isBitperfect && format.SampleRate > 0)
                    {
                        // Instruct PipeWire to switch DAC hardware clock to native sample rate directly
                        try
                        {
                            Process.Start(new ProcessStartInfo("pw-metadata", $"-n settings 0 clock.force-rate {format.SampleRate}") { CreateNoWindow = true, UseShellExecute = false })?.WaitForExit(200);
                            _pipewireForceRateActive = true;
                        }
                        catch { }

                        psi.EnvironmentVariables["PIPEWIRE_RATE"] = format.SampleRate.ToString();
                        psi.EnvironmentVariables["PIPEWIRE_LATENCY"] = $"1024/{format.SampleRate}";
                    }
                }
            }

            var proc = Process.Start(psi);
            if (proc != null)
            {
                _playbackProcess = proc;
                lock (_processLock)
                {
                    _activeProcesses.Add(proc);
                }

                proc.EnableRaisingEvents = true;
                proc.Exited += (sender, args) =>
                {
                    // Discard stale or killed processes from previous seeks or tracks
                    if (gen != Volatile.Read(ref _playbackGeneration))
                        return;

                    if (_isIntentionalStop)
                        return;

                    lock (_processLock)
                    {
                        _activeProcesses.Remove(proc);
                    }

                    if (_state == PlaybackState.Playing)
                    {
                        SetState(PlaybackState.Stopped);
                        StopTimers();
                        TrackEnded?.Invoke(this, EventArgs.Empty);
                    }
                };
            }
        }
        catch (Exception)
        {
            SetState(PlaybackState.Error);
        }
    }

    public Task PauseAsync()
    {
        if (_state == PlaybackState.Playing && _playbackProcess != null && !_playbackProcess.HasExited)
        {
            try
            {
                // Send SIGSTOP to pause playback without killing the process
                Process.Start("kill", $"-STOP {_playbackProcess.Id}")?.WaitForExit(500);
                SetState(PlaybackState.Paused);
                StopTimers();
            }
            catch
            {
                // Fallback: kill and store position
                _seekOffset = _currentPosition;
                KillProcess();
                SetState(PlaybackState.Paused);
                StopTimers();
            }
        }
        return Task.CompletedTask;
    }

    public Task ResumeAsync()
    {
        if (_state == PlaybackState.Paused)
        {
            if (_playbackProcess != null && !_playbackProcess.HasExited)
            {
                try
                {
                    // Send SIGCONT to continue playback
                    Process.Start("kill", $"-CONT {_playbackProcess.Id}")?.WaitForExit(500);
                    _playStartTime = DateTime.UtcNow;
                    _seekOffset = _currentPosition;
                    SetState(PlaybackState.Playing);
                    StartTimers();
                    return Task.CompletedTask;
                }
                catch
                {
                    // Ignore and restart below
                }
            }

            // Restart process from last position
            if (_currentSource != null && _currentFormat != null)
            {
                long gen = Interlocked.Increment(ref _playbackGeneration);
                StartPlaybackProcess(_currentSource, _currentFormat, _currentPosition, gen);
                _playStartTime = DateTime.UtcNow;
                _seekOffset = _currentPosition;
                SetState(PlaybackState.Playing);
                StartTimers();
            }
        }
        return Task.CompletedTask;
    }

    public Task SeekAsync(TimeSpan position)
    {
        _currentPosition = position;
        _seekOffset = position;
        _playStartTime = DateTime.UtcNow;

        if (_state == PlaybackState.Playing && _currentSource != null && _currentFormat != null)
        {
            long gen = Interlocked.Increment(ref _playbackGeneration);
            _isIntentionalStop = true;
            KillProcess();
            _isIntentionalStop = false;

            StartPlaybackProcess(_currentSource, _currentFormat, position, gen);
            StartTimers();
        }

        PositionChanged?.Invoke(this, _currentPosition);
        return Task.CompletedTask;
    }

    public Task StopAsync()
    {
        Interlocked.Increment(ref _playbackGeneration);
        _isIntentionalStop = true;
        KillProcess();
        StopTimers();
        _pcmCache.CancelAndReset();
        _currentPosition = TimeSpan.Zero;
        _seekOffset = TimeSpan.Zero;
        SetState(PlaybackState.Stopped);
        _isIntentionalStop = false;

        ResetAudioHardwareSettings();
        return Task.CompletedTask;
    }

    private Task StopPlaybackInternalAsync()
    {
        Interlocked.Increment(ref _playbackGeneration);
        _isIntentionalStop = true;
        KillProcess();
        StopTimers();
        _pcmCache.CancelAndReset();
        _currentPosition = TimeSpan.Zero;
        _seekOffset = TimeSpan.Zero;
        _isIntentionalStop = false;
        return Task.CompletedTask;
    }

    private void ResetAudioHardwareSettings()
    {
        if (_pipewireForceRateActive)
        {
            _pipewireForceRateActive = false;
            try
            {
                Process.Start(new ProcessStartInfo("pw-metadata", "-n settings 0 clock.force-rate 0") { CreateNoWindow = true, UseShellExecute = false })?.WaitForExit(200);
            }
            catch { }
        }

        if (_alsaDirectClaimActive)
        {
            _alsaDirectClaimActive = false;
            try
            {
                Process.Start(new ProcessStartInfo("wpctl", "set-profile 67 1") { CreateNoWindow = true, UseShellExecute = false })?.WaitForExit(200);
            }
            catch { }
        }
    }

    public void SetVolume(double volume)
    {
        if (_isBitperfect)
        {
            // Bitperfect mode bypasses volume attenuation: always 1.0 (unity gain)
            _volume = 1.0;
            return;
        }

        _volume = Math.Clamp(volume, 0.0, 1.0);
    }

    private void StartTimers()
    {
        StopTimers();

        // Timer for tracking playback position
        _positionTimer = new System.Threading.Timer(_ =>
        {
            if (_state != PlaybackState.Playing) return;

            var elapsed = DateTime.UtcNow - _playStartTime;
            _currentPosition = _seekOffset + elapsed;
            PositionChanged?.Invoke(this, _currentPosition);
        }, null, 0, 200);

        // Timer for generating live frequency spectrum analyzer visualizer data via FxSound DSP engine
        _spectrumTimer = new System.Threading.Timer(_ =>
        {
            if (_state != PlaybackState.Playing) return;

            var liveElapsed = _seekOffset + (DateTime.UtcNow - _playStartTime);
            float[] bands;

            Span<float> pcmWindow = stackalloc float[FxSoundSpectrumEngine.FftSize];
            if (_pcmCache.TryGetWindow(liveElapsed, pcmWindow))
            {
                bands = _spectrumEngine.ProcessPcm(pcmWindow, true);
            }
            else
            {
                bands = _spectrumEngine.ProcessFrame(liveElapsed, true);
            }

            SpectrumDataAvailable?.Invoke(this, bands);
        }, null, 0, 33);
    }

    private void StopTimers()
    {
        _positionTimer?.Dispose();
        _positionTimer = null;
        _spectrumTimer?.Dispose();
        _spectrumTimer = null;

        _spectrumEngine.Reset();
        var zeros = new float[FxSoundSpectrumEngine.NumBands];
        for (int i = 0; i < zeros.Length; i++) zeros[i] = 0.04f;
        SpectrumDataAvailable?.Invoke(this, zeros);
    }

    private void KillProcess()
    {
        Process? proc = null;
        lock (_processLock)
        {
            proc = _playbackProcess;
            _playbackProcess = null;
            if (proc != null)
            {
                _activeProcesses.Remove(proc);
            }
        }

        if (proc != null)
        {
            try
            {
                if (!proc.HasExited)
                {
                    proc.Kill(true);
                    proc.WaitForExit(100);
                }
            }
            catch
            {
                // Process already terminated
            }
            finally
            {
                try { proc.Dispose(); } catch { }
            }
        }
    }

    private void SetState(PlaybackState newState)
    {
        if (_state != newState)
        {
            _state = newState;
            StateChanged?.Invoke(this, _state);
        }
    }

    public void Dispose()
    {
        KillProcess();
        StopTimers();
        _pcmCache.Dispose();
        ResetAudioHardwareSettings();
    }
}
