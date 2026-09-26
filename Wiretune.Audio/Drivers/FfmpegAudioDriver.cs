using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Wiretune.Audio.Dsp;
using Wiretune.Core.Models;
using Wiretune.Core.Services;

namespace Wiretune.Audio.Drivers;

/// <summary>
/// Desktop playback through an ffplay child process. On Linux it routes to PipeWire nodes or raw ALSA
/// hardware (hw:X,Y) for exclusive / bit-perfect output; elsewhere it uses the system default device.
/// </summary>
public sealed partial class FfmpegAudioDriver : IAudioDriver
{
    private const int LinuxSigStop = 19;
    private const int LinuxSigCont = 18;

    private static readonly List<Process> ActiveProcesses = new();
    private static readonly object ProcessLock = new();

    private readonly object _stateLock = new();
    private readonly FxSoundSpectrumEngine _spectrumEngine = new();
    private readonly AudioPcmCache _pcmCache = new();

    private Process? _playbackProcess;
    private bool _processSuspended;
    private string? _lastProcessError;
    private long _playbackGeneration;
    private AudioOutputDevice? _currentDevice;
    private bool _isExclusive;
    private bool _isBitperfect;
    private double _volume = 1.0;
    private PlaybackState _state = PlaybackState.Stopped;
    private TimeSpan _currentPosition = TimeSpan.Zero;
    private DateTime _playStartTime;
    private TimeSpan _seekOffset = TimeSpan.Zero;
    private Timer? _positionTimer;
    private Timer? _spectrumTimer;
    private Timer? _volumeRestartTimer;
    private string? _currentSource;
    private AudioFormat? _currentFormat;
    private bool _pipewireForceRateActive;
    private string? _claimedPipeWireDeviceId;
    private bool _disposed;

    public string DriverName => "FFmpeg (ffplay) engine";
    public PlaybackState State => _state;
    public TimeSpan CurrentPosition => _currentPosition;

    public event EventHandler<PlaybackState>? StateChanged;
    public event EventHandler<TimeSpan>? PositionChanged;
    public event EventHandler<float[]>? SpectrumDataAvailable;
    public event EventHandler? TrackEnded;
    public event EventHandler<string>? PlaybackFailed;

    static FfmpegAudioDriver()
    {
        AppDomain.CurrentDomain.ProcessExit += (_, _) => KillAllProcesses();
    }

    public Task InitializeAsync(AudioOutputDevice device, bool exclusive, bool bitperfect)
    {
        _currentDevice = device;
        _isExclusive = exclusive;
        _isBitperfect = bitperfect;
        return Task.CompletedTask;
    }

    public Task PlayAsync(string audioSource, AudioFormat format, TimeSpan startPosition, CancellationToken ct = default)
    {
        lock (_stateLock)
        {
            var gen = Interlocked.Increment(ref _playbackGeneration);
            KillPlaybackProcess();
            StopTimers();

            _currentSource = audioSource;
            _currentFormat = format;
            _seekOffset = startPosition;
            _currentPosition = startPosition;

            if (!StartPlaybackProcess(startPosition, gen)) return Task.CompletedTask;

            _pcmCache.LoadTrack(audioSource);
            SetState(PlaybackState.Playing);
            StartTimers();
        }
        return Task.CompletedTask;
    }

    public Task PauseAsync()
    {
        lock (_stateLock)
        {
            if (_state != PlaybackState.Playing) return Task.CompletedTask;

            UpdatePosition();
            StopTimers();

            if (OperatingSystem.IsLinux() && _playbackProcess is { HasExited: false } proc && kill(proc.Id, LinuxSigStop) == 0)
            {
                _processSuspended = true;
            }
            else
            {
                // No SIGSTOP (e.g. Windows): stop the process and restart from the saved position on resume.
                Interlocked.Increment(ref _playbackGeneration);
                KillPlaybackProcess();
            }

            _seekOffset = _currentPosition;
            SetState(PlaybackState.Paused);
        }
        return Task.CompletedTask;
    }

    public Task ResumeAsync()
    {
        lock (_stateLock)
        {
            if (_state != PlaybackState.Paused) return Task.CompletedTask;

            if (_processSuspended && _playbackProcess is { HasExited: false } proc && kill(proc.Id, LinuxSigCont) == 0)
            {
                _processSuspended = false;
            }
            else if (!StartPlaybackProcess(_currentPosition, Interlocked.Increment(ref _playbackGeneration)))
            {
                return Task.CompletedTask;
            }

            _seekOffset = _currentPosition;
            _playStartTime = DateTime.UtcNow;
            SetState(PlaybackState.Playing);
            StartTimers();
        }
        return Task.CompletedTask;
    }

    public Task SeekAsync(TimeSpan position)
    {
        if (position < TimeSpan.Zero) position = TimeSpan.Zero;

        lock (_stateLock)
        {
            _currentPosition = position;
            _seekOffset = position;
            _playStartTime = DateTime.UtcNow;

            if (_state == PlaybackState.Playing && _currentSource != null)
            {
                StartPlaybackProcess(position, Interlocked.Increment(ref _playbackGeneration));
            }
            else if (_state == PlaybackState.Paused)
            {
                // A suspended process would continue from the old position; drop it so resume restarts here.
                Interlocked.Increment(ref _playbackGeneration);
                KillPlaybackProcess();
            }
        }

        PositionChanged?.Invoke(this, position);
        return Task.CompletedTask;
    }

    public Task StopAsync()
    {
        lock (_stateLock)
        {
            Interlocked.Increment(ref _playbackGeneration);
            KillPlaybackProcess();
            StopTimers();
            _pcmCache.CancelAndReset();
            _currentPosition = TimeSpan.Zero;
            _seekOffset = TimeSpan.Zero;
            SetState(PlaybackState.Stopped);
            ResetAudioHardwareSettings();
        }
        return Task.CompletedTask;
    }

    public void SetVolume(double volume)
    {
        if (_isBitperfect)
        {
            _volume = 1.0;
            return;
        }

        _volume = Math.Clamp(volume, 0.0, 1.0);
        if (TryApplyMixerVolume()) return;

        // Without a controllable mixer the volume is an ffplay start argument: restart at the current position,
        // debounced so dragging the slider does not respawn the process on every tick.
        if (_state == PlaybackState.Playing)
        {
            _volumeRestartTimer?.Dispose();
            _volumeRestartTimer = new Timer(_ =>
            {
                lock (_stateLock)
                {
                    if (_state != PlaybackState.Playing || _currentSource == null) return;
                    UpdatePosition();
                    _seekOffset = _currentPosition;
                    _playStartTime = DateTime.UtcNow;
                    StartPlaybackProcess(_currentPosition, Interlocked.Increment(ref _playbackGeneration));
                }
            }, null, 400, Timeout.Infinite);
        }
    }

    private bool TryApplyMixerVolume()
    {
        if (!OperatingSystem.IsLinux() || _currentDevice is not { } dev) return false;

        try
        {
            if (dev.DriverType.Contains("PipeWire") || dev.Id.StartsWith("pw_"))
            {
                var volStr = _volume.ToString("0.00", CultureInfo.InvariantCulture);
                RunQuiet("wpctl", "set-volume", dev.Id.Replace("pw_", ""), volStr);
                return true;
            }

            if (dev.Id.StartsWith("hw:"))
            {
                var cardNum = dev.Id.Replace("hw:", "").Split(',')[0];
                RunQuiet("amixer", "-q", "-c", cardNum, "sset", "PCM", $"{(int)(_volume * 100)}%");
                return true;
            }
        }
        catch (Exception ex)
        {
            WiretuneLog.Debug("FfmpegAudioDriver", $"Mixer volume change failed: {ex.Message}");
        }

        return false;
    }

    /// <summary>Starts ffplay for the current source. Must be called under <see cref="_stateLock"/>.</summary>
    private bool StartPlaybackProcess(TimeSpan startPosition, long gen)
    {
        KillPlaybackProcess();
        if (_currentSource == null || _currentFormat == null) return false;

        var psi = new ProcessStartInfo
        {
            FileName = "ffplay",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = false
        };
        var volumePercent = _isBitperfect ? 100 : (int)Math.Round(_volume * 100);
        foreach (var arg in BuildFfplayArguments(_currentSource, startPosition, volumePercent)) psi.ArgumentList.Add(arg);

        ConfigureOutputRouting(psi, _currentFormat);

        WiretuneLog.Info("FfmpegAudioDriver", $"Starting ffplay at {startPosition:mm\\:ss} for '{RedactToken(_currentSource)}'");

        Process proc;
        try
        {
            proc = Process.Start(psi) ?? throw new InvalidOperationException("ffplay did not start.");
        }
        catch (Win32Exception)
        {
            Fail("Az ffplay nem található. Telepítsd az FFmpeg-et, és gondoskodj róla, hogy a PATH-ban elérhető legyen.");
            return false;
        }
        catch (Exception ex)
        {
            Fail($"A lejátszó nem indítható: {ex.Message}");
            return false;
        }

        _playbackProcess = proc;
        _processSuspended = false;
        _lastProcessError = null;
        _playStartTime = DateTime.UtcNow;
        lock (ProcessLock) ActiveProcesses.Add(proc);

        proc.ErrorDataReceived += (_, e) =>
        {
            if (!string.IsNullOrWhiteSpace(e.Data)) _lastProcessError = e.Data.Trim();
        };
        proc.EnableRaisingEvents = true;
        proc.Exited += (_, _) => OnProcessExited(proc, gen);
        proc.BeginErrorReadLine();
        return true;
    }

    /// <summary>ffplay arguments; the source is always one discrete argument, never spliced into a command line.</summary>
    internal static List<string> BuildFfplayArguments(string source, TimeSpan startPosition, int volumePercent)
    {
        var args = new List<string> { "-nodisp", "-autoexit", "-loglevel", "error" };
        if (startPosition > TimeSpan.Zero)
        {
            args.Add("-ss");
            args.Add(startPosition.TotalSeconds.ToString("0.000", CultureInfo.InvariantCulture));
        }
        args.Add("-volume");
        args.Add(Math.Clamp(volumePercent, 0, 100).ToString(CultureInfo.InvariantCulture));
        args.Add(source);
        return args;
    }

    private void OnProcessExited(Process proc, long gen)
    {
        lock (ProcessLock) ActiveProcesses.Remove(proc);

        int exitCode;
        try { exitCode = proc.ExitCode; } catch { exitCode = -1; }

        lock (_stateLock)
        {
            if (gen != Interlocked.Read(ref _playbackGeneration) || _state != PlaybackState.Playing) return;

            StopTimers();
            _playbackProcess = null;
            if (exitCode == 0)
            {
                SetState(PlaybackState.Stopped);
                TrackEnded?.Invoke(this, EventArgs.Empty);
            }
            else
            {
                Fail(string.IsNullOrEmpty(_lastProcessError)
                    ? $"A lejátszás váratlanul leállt (ffplay kilépési kód: {exitCode})."
                    : $"A lejátszás sikertelen: {RedactToken(_lastProcessError)}");
            }
        }
    }

    private void ConfigureOutputRouting(ProcessStartInfo psi, AudioFormat format)
    {
        if (!OperatingSystem.IsLinux() || _currentDevice is not { } dev) return;

        var isAlsaDirect = dev.DriverType.Contains("ALSA") || dev.Id.StartsWith("hw:");
        if (isAlsaDirect)
        {
            ClaimAlsaDevice(dev);
            psi.EnvironmentVariables["SDL_AUDIODRIVER"] = "alsa";
            psi.EnvironmentVariables["AUDIODEV"] = _isBitperfect || !dev.Id.StartsWith("hw:")
                ? dev.Id
                : dev.Id.Replace("hw:", "plughw:");
            return;
        }

        psi.EnvironmentVariables["SDL_AUDIODRIVER"] = "pipewire";
        psi.EnvironmentVariables["PIPEWIRE_NODE"] = dev.Id.Replace("pw_", "");

        if (_isBitperfect && format.SampleRate > 0)
        {
            var rate = format.SampleRate.ToString(CultureInfo.InvariantCulture);
            if (RunQuiet("pw-metadata", "-n", "settings", "0", "clock.force-rate", rate)) _pipewireForceRateActive = true;
            psi.EnvironmentVariables["PIPEWIRE_RATE"] = rate;
            psi.EnvironmentVariables["PIPEWIRE_LATENCY"] = $"1024/{rate}";
        }
    }

    /// <summary>Releases the PipeWire card profile so ffplay can open the raw ALSA hardware device.</summary>
    private void ClaimAlsaDevice(AudioOutputDevice dev)
    {
        if (_claimedPipeWireDeviceId != null) return;

        var pwDeviceId = FindPipeWireDeviceIdForCard(dev.Name);
        if (!string.IsNullOrEmpty(pwDeviceId) && RunQuiet("wpctl", "set-profile", pwDeviceId, "0"))
        {
            _claimedPipeWireDeviceId = pwDeviceId;
        }
    }

    private void ResetAudioHardwareSettings()
    {
        if (_pipewireForceRateActive)
        {
            _pipewireForceRateActive = false;
            RunQuiet("pw-metadata", "-n", "settings", "0", "clock.force-rate", "0");
        }

        if (_claimedPipeWireDeviceId != null)
        {
            RunQuiet("wpctl", "set-profile", _claimedPipeWireDeviceId, "1");
            _claimedPipeWireDeviceId = null;
        }
    }

    private static string? FindPipeWireDeviceIdForCard(string? cardName)
    {
        if (string.IsNullOrEmpty(cardName)) return null;

        try
        {
            var psi = new ProcessStartInfo("wpctl", "status")
            {
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            psi.EnvironmentVariables["LC_ALL"] = "C";
            using var proc = Process.Start(psi);
            if (proc == null) return null;
            var text = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(1000);

            var inDevices = false;
            foreach (var line in text.Split('\n'))
            {
                if (line.Contains("Devices:")) { inDevices = true; continue; }
                if (inDevices && (line.Contains("Sinks:") || line.Contains("Sources:"))) break;
                if (!inDevices) continue;

                var match = DeviceLineRegex().Match(line);
                if (!match.Success) continue;

                var name = match.Groups["name"].Value.Trim();
                if (cardName.Contains(name, StringComparison.OrdinalIgnoreCase) ||
                    name.Contains(cardName, StringComparison.OrdinalIgnoreCase))
                {
                    return match.Groups["id"].Value.Trim();
                }
            }
        }
        catch (Exception ex)
        {
            WiretuneLog.Debug("FfmpegAudioDriver", $"wpctl status failed: {ex.Message}");
        }

        return null;
    }

    private void StartTimers()
    {
        StopTimers(emitSilence: false);
        _positionTimer = new Timer(_ =>
        {
            if (_state != PlaybackState.Playing) return;
            UpdatePosition();
            PositionChanged?.Invoke(this, _currentPosition);
        }, null, 0, 200);

        _spectrumTimer = new Timer(_ =>
        {
            if (_state != PlaybackState.Playing) return;
            var position = _seekOffset + (DateTime.UtcNow - _playStartTime);
            Span<float> window = stackalloc float[FxSoundSpectrumEngine.FftSize];
            var bands = _pcmCache.TryGetWindow(position, window)
                ? _spectrumEngine.ProcessPcm(window, true)
                : _spectrumEngine.ProcessFrame(position, true);
            SpectrumDataAvailable?.Invoke(this, bands);
        }, null, 0, 33);
    }

    private void StopTimers(bool emitSilence = true)
    {
        _positionTimer?.Dispose();
        _positionTimer = null;
        _spectrumTimer?.Dispose();
        _spectrumTimer = null;
        _volumeRestartTimer?.Dispose();
        _volumeRestartTimer = null;

        if (!emitSilence) return;
        _spectrumEngine.Reset();
        SpectrumDataAvailable?.Invoke(this, new float[FxSoundSpectrumEngine.NumBands]);
    }

    private void UpdatePosition()
    {
        if (_state == PlaybackState.Playing)
        {
            _currentPosition = _seekOffset + (DateTime.UtcNow - _playStartTime);
        }
    }

    private void KillPlaybackProcess()
    {
        var proc = _playbackProcess;
        _playbackProcess = null;
        _processSuspended = false;
        if (proc == null) return;

        lock (ProcessLock) ActiveProcesses.Remove(proc);
        try
        {
            if (!proc.HasExited)
            {
                proc.Kill(true);
                proc.WaitForExit(200);
            }
        }
        catch
        {
            // Already gone.
        }
        finally
        {
            try { proc.Dispose(); } catch { }
        }
    }

    private void Fail(string message)
    {
        WiretuneLog.Warn("FfmpegAudioDriver", message);
        StopTimers();
        SetState(PlaybackState.Error);
        PlaybackFailed?.Invoke(this, message);
    }

    private void SetState(PlaybackState newState)
    {
        if (_state == newState) return;
        _state = newState;
        StateChanged?.Invoke(this, newState);
    }

    private static bool RunQuiet(string fileName, params string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo(fileName) { CreateNoWindow = true, UseShellExecute = false };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var proc = Process.Start(psi);
            return proc != null && proc.WaitForExit(1000) && proc.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    private static string RedactToken(string text) => TokenRegex().Replace(text, "token=***");

    private static void KillAllProcesses()
    {
        lock (ProcessLock)
        {
            foreach (var p in ActiveProcesses)
            {
                try
                {
                    if (!p.HasExited) p.Kill(true);
                }
                catch
                {
                    // Best effort on shutdown.
                }
            }
            ActiveProcesses.Clear();
        }
    }

    [DllImport("libc", SetLastError = true)]
    private static extern int kill(int pid, int sig);

    [GeneratedRegex(@"(?<id>\d+)\.\s+(?<name>[^\[]+)")]
    private static partial Regex DeviceLineRegex();

    [GeneratedRegex(@"token=[^&\s""']+")]
    private static partial Regex TokenRegex();

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        lock (_stateLock)
        {
            Interlocked.Increment(ref _playbackGeneration);
            KillPlaybackProcess();
            StopTimers(emitSilence: false);
            ResetAudioHardwareSettings();
        }
        _pcmCache.Dispose();
    }
}
