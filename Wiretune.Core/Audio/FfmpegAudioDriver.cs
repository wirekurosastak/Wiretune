using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Wiretune.Core.Audio.Dsp;
using Wiretune.Core.Localization;
using Wiretune.Core.Models;
using Wiretune.Core.Services;

namespace Wiretune.Core.Audio.Drivers;

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
    private readonly SpectrumAnalyzer _spectrumEngine = new();
    private readonly AudioPcmCache _pcmCache = new();

    private Process? _playbackProcess;
    private Process? _decoderProcess;
    private CancellationTokenSource? _pipeCts;
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
    private Timer? _mixerVolumeTimer;
    private int _spectrumFrameBusy;
    private string? _currentSource;
    private AudioFormat? _currentFormat;
    private bool _pipewireForceRateActive;
    private Process? _reserveProcess;
    private bool _disposed;

    public string DriverName => "FFmpeg audio engine";
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

        lock (_stateLock)
        {
            if (_disposed) return;

            if (HasHardwareMixer)
            {
                // The slider fires continuously; spawning wpctl/amixer per tick would stall the caller, so only the
                // last value of a burst is applied, off the calling (UI) thread.
                (_mixerVolumeTimer ??= new Timer(_ => ApplyMixerVolume())).Change(60, Timeout.Infinite);
                return;
            }

            // Without a controllable mixer the volume is an ffplay/ffmpeg start argument: restart at the current
            // position, debounced so dragging the slider does not respawn the process on every tick.
            if (_state == PlaybackState.Playing)
            {
                _volumeRestartTimer?.Dispose();
                _volumeRestartTimer = new Timer(_ =>
                {
                    lock (_stateLock)
                    {
                        if (_disposed || _state != PlaybackState.Playing || _currentSource == null) return;
                        UpdatePosition();
                        _seekOffset = _currentPosition;
                        _playStartTime = DateTime.UtcNow;
                        StartPlaybackProcess(_currentPosition, Interlocked.Increment(ref _playbackGeneration));
                    }
                }, null, 400, Timeout.Infinite);
            }
        }
    }

    /// <summary>True when the output device has a system mixer we can drive (PipeWire sink or ALSA card).</summary>
    private bool HasHardwareMixer =>
        OperatingSystem.IsLinux() && _currentDevice is { } dev && (dev.DriverType.Contains("PipeWire") || dev.Id.StartsWith("pw_") || dev.Id.StartsWith("hw:"));

    private void ApplyMixerVolume()
    {
        if (_currentDevice is not { } dev) return;

        bool ok;
        if (dev.DriverType.Contains("PipeWire") || dev.Id.StartsWith("pw_"))
        {
            ok = RunQuiet("wpctl", "set-volume", dev.Id.Replace("pw_", ""), _volume.ToString("0.00", CultureInfo.InvariantCulture));
        }
        else
        {
            var cardNum = dev.Id.Replace("hw:", "").Split(',')[0];
            ok = RunQuiet("amixer", "-q", "-c", cardNum, "sset", "PCM", $"{(int)(_volume * 100)}%");
        }

        if (!ok) WiretuneLog.Debug("FfmpegAudioDriver", $"Mixer volume change failed for '{dev.Name}'.");
    }

    /// <summary>Starts playback for the current source. Must be called under <see cref="_stateLock"/>.</summary>
    private bool StartPlaybackProcess(TimeSpan startPosition, long gen)
    {
        KillPlaybackProcess();
        if (_currentSource == null || _currentFormat == null) return false;

        var isAlsaDirect = OperatingSystem.IsLinux() && (_isExclusive || (_currentDevice != null && (_currentDevice.DriverType.Contains("ALSA") || _currentDevice.Id.StartsWith("hw:"))));
        if (isAlsaDirect)
        {
            var (cardNum, devNum) = ResolveAlsaCardAndDev(_currentDevice);
            return StartDirectAlsaPlayback(startPosition, gen, cardNum, devNum);
        }

        return StartSharedPlaybackProcess(startPosition, gen);
    }

    private bool StartDirectAlsaPlayback(TimeSpan startPosition, long gen, string cardNum, string devNum)
    {
        AcquireDeviceReservation(cardNum);

        var ffmpegPsi = new ProcessStartInfo
        {
            FileName = "ffmpeg",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        ffmpegPsi.ArgumentList.Add("-nostdin");
        ffmpegPsi.ArgumentList.Add("-v");
        ffmpegPsi.ArgumentList.Add("error");

        if (startPosition > TimeSpan.Zero)
        {
            ffmpegPsi.ArgumentList.Add("-ss");
            ffmpegPsi.ArgumentList.Add(startPosition.TotalSeconds.ToString("0.000", CultureInfo.InvariantCulture));
        }

        ffmpegPsi.ArgumentList.Add("-i");
        ffmpegPsi.ArgumentList.Add(_currentSource!);

        if (!_isBitperfect && _volume < 0.999)
        {
            ffmpegPsi.ArgumentList.Add("-af");
            ffmpegPsi.ArgumentList.Add($"volume={_volume.ToString("0.0000", CultureInfo.InvariantCulture)}");
        }

        ffmpegPsi.ArgumentList.Add("-c:a");
        ffmpegPsi.ArgumentList.Add("pcm_s32le");
        ffmpegPsi.ArgumentList.Add("-f");
        ffmpegPsi.ArgumentList.Add("wav");
        ffmpegPsi.ArgumentList.Add("-");

        var aplayPsi = new ProcessStartInfo
        {
            FileName = "aplay",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardError = true
        };

        aplayPsi.ArgumentList.Add("-q");
        aplayPsi.ArgumentList.Add("-D");
        aplayPsi.ArgumentList.Add($"plughw:{cardNum},{devNum}");

        WiretuneLog.Info("FfmpegAudioDriver", $"Starting direct ALSA (ffmpeg | aplay) on plughw:{cardNum},{devNum} at {startPosition:mm\\:ss} for '{RedactToken(_currentSource!)}'");

        Process? ffmpegProc = null;
        Process? aplayProc = null;
        try
        {
            ffmpegProc = Process.Start(ffmpegPsi) ?? throw new InvalidOperationException("ffmpeg did not start.");
            aplayProc = Process.Start(aplayPsi) ?? throw new InvalidOperationException("aplay did not start.");
        }
        catch (Exception ex)
        {
            // If only ffmpeg started it would otherwise keep decoding into a pipe nobody reads.
            TerminateProcess(ffmpegProc);
            TerminateProcess(aplayProc);
            Fail(Localizer.Format(ex is Win32Exception ? "DriverAlsaMissingTools" : "DriverAlsaStartFailed", ex.Message));
            return false;
        }

        _decoderProcess = ffmpegProc;
        _playbackProcess = aplayProc;
        _processSuspended = false;
        _lastProcessError = null;
        _playStartTime = DateTime.UtcNow;

        lock (ProcessLock)
        {
            ActiveProcesses.Add(ffmpegProc);
            ActiveProcesses.Add(aplayProc);
        }

        aplayProc.ErrorDataReceived += (_, e) =>
        {
            if (!string.IsNullOrWhiteSpace(e.Data)) _lastProcessError = e.Data.Trim();
        };
        ffmpegProc.ErrorDataReceived += (_, e) =>
        {
            if (!string.IsNullOrWhiteSpace(e.Data)) _lastProcessError = e.Data.Trim();
        };

        aplayProc.EnableRaisingEvents = true;
        aplayProc.Exited += (_, _) => OnProcessExited(aplayProc, gen);
        aplayProc.BeginErrorReadLine();
        ffmpegProc.BeginErrorReadLine();

        var pipeCts = new CancellationTokenSource();
        _pipeCts = pipeCts;

        _ = Task.Run(async () =>
        {
            try
            {
                await ffmpegProc.StandardOutput.BaseStream.CopyToAsync(aplayProc.StandardInput.BaseStream, 81920, pipeCts.Token);
            }
            catch
            {
                // Broken pipe or cancellation on seek/stop is expected
            }
            finally
            {
                try { aplayProc.StandardInput.Close(); } catch { }
            }
        }, pipeCts.Token);

        return true;
    }

    private bool StartSharedPlaybackProcess(TimeSpan startPosition, long gen)
    {
        ReleaseDeviceReservation();

        var psi = new ProcessStartInfo
        {
            FileName = "ffplay",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = false
        };
        var volumePercent = _isBitperfect ? 100 : (int)Math.Round(_volume * 100);
        foreach (var arg in BuildFfplayArguments(_currentSource!, startPosition, volumePercent)) psi.ArgumentList.Add(arg);

        ConfigureOutputRouting(psi, _currentFormat!);

        WiretuneLog.Info("FfmpegAudioDriver", $"Starting ffplay at {startPosition:mm\\:ss} for '{RedactToken(_currentSource!)}'");

        Process proc;
        try
        {
            proc = Process.Start(psi) ?? throw new InvalidOperationException("ffplay did not start.");
        }
        catch (Win32Exception)
        {
            Fail(Localizer.Get("DriverFfplayMissing"));
            return false;
        }
        catch (Exception ex)
        {
            Fail(Localizer.Format("DriverPlayerStartFailed", ex.Message));
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

    private static (string cardNum, string devNum) ResolveAlsaCardAndDev(AudioOutputDevice? dev)
    {
        if (dev != null && dev.Id.StartsWith("hw:"))
        {
            var parts = dev.Id.Replace("hw:", "").Split(',');
            return (parts[0], parts.Length > 1 ? parts[1] : "0");
        }

        try
        {
            if (File.Exists("/proc/asound/cards"))
            {
                var content = File.ReadAllText("/proc/asound/cards");
                var matches = Regex.Matches(content, @"^\s*(\d+)\s+\[[^\]]+\]:\s+(.+)$", RegexOptions.Multiline);
                foreach (Match m in matches)
                {
                    var card = m.Groups[1].Value;
                    var desc = m.Groups[2].Value;
                    if (dev != null)
                    {
                        if ((!string.IsNullOrEmpty(dev.HardwareCard) && desc.Contains(dev.HardwareCard, StringComparison.OrdinalIgnoreCase)) ||
                            (!string.IsNullOrEmpty(dev.Name) && desc.Contains(dev.Name, StringComparison.OrdinalIgnoreCase)))
                        {
                            return (card, "0");
                        }
                    }
                    else if (desc.Contains("USB", StringComparison.OrdinalIgnoreCase))
                    {
                        return (card, "0");
                    }
                }
            }
        }
        catch { }

        return ("0", "0");
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
        try
        {
            // The parameterless overload returns once the redirected stderr has been read to the end, so the
            // error text used below is complete (Exited alone can fire before the last lines arrive).
            proc.WaitForExit();
            exitCode = proc.ExitCode;
        }
        catch
        {
            exitCode = -1;
        }

        lock (_stateLock)
        {
            if (gen != Interlocked.Read(ref _playbackGeneration) || _state != PlaybackState.Playing) return;

            StopTimers();
            _playbackProcess = null;

            // ffplay exits with 0 even when it could not open the source (unreachable server, expired token, missing
            // file). Without this check such a track would count as "finished" and the queue would race through.
            if (exitCode == 0 && !string.IsNullOrEmpty(_lastProcessError) && DateTime.UtcNow - _playStartTime < TimeSpan.FromSeconds(3))
                exitCode = 1;

            // In the ALSA pipeline aplay sees a clean end of input even when ffmpeg died early (bad URL, expired
            // token, network drop), so the decoder's own exit code decides whether the track really finished.
            if (_decoderProcess is { } decoder)
            {
                _decoderProcess = null;
                try
                {
                    if (decoder.WaitForExit(500) && exitCode == 0) exitCode = decoder.ExitCode;
                }
                catch { }
                TerminateProcess(decoder);
            }

            if (exitCode == 0)
            {
                SetState(PlaybackState.Stopped);
                TrackEnded?.Invoke(this, EventArgs.Empty);
            }
            else
            {
                Fail(string.IsNullOrEmpty(_lastProcessError)
                    ? Localizer.Format("DriverStoppedUnexpectedly", exitCode)
                    : Localizer.Format("DriverPlaybackFailed", RedactToken(_lastProcessError)));
            }
        }
    }

    private void ConfigureOutputRouting(ProcessStartInfo psi, AudioFormat format)
    {
        // Only a detected PipeWire sink can be addressed this way; the generic "default" entry uses ffplay's own default.
        if (!OperatingSystem.IsLinux() || _currentDevice is not { } dev || !dev.Id.StartsWith("pw_")) return;

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

    private void AcquireDeviceReservation(string cardNum)
    {
        if (!OperatingSystem.IsLinux()) return;

        if (_reserveProcess == null || _reserveProcess.HasExited)
        {
            _reserveProcess?.Dispose();
            _reserveProcess = null;

            try
            {
                var psi = new ProcessStartInfo("pw-reserve")
                {
                    Arguments = $"-n Audio{cardNum} -a Wiretune -p 10 -r",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                var proc = Process.Start(psi);
                if (proc != null)
                {
                    _reserveProcess = proc;
                    lock (ProcessLock) ActiveProcesses.Add(proc);
                    WiretuneLog.Info("FfmpegAudioDriver", $"Acquired exclusive reservation for Audio{cardNum} via pw-reserve (PID {proc.Id})");
                    Thread.Sleep(100);
                }
            }
            catch (Exception ex)
            {
                WiretuneLog.Debug("FfmpegAudioDriver", $"pw-reserve start failed: {ex.Message}");
            }
        }
    }

    private void ReleaseDeviceReservation()
    {
        var reserve = _reserveProcess;
        _reserveProcess = null;
        TerminateProcess(reserve, 300);
    }

    private void ResetAudioHardwareSettings()
    {
        ReleaseDeviceReservation();

        if (_pipewireForceRateActive)
        {
            _pipewireForceRateActive = false;
            RunQuiet("pw-metadata", "-n", "settings", "0", "clock.force-rate", "0");
        }
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
            // Timer callbacks overlap when a frame takes longer than the period; the engine is not reentrant.
            if (_state != PlaybackState.Playing || Interlocked.Exchange(ref _spectrumFrameBusy, 1) == 1) return;
            try
            {
                var position = _seekOffset + (DateTime.UtcNow - _playStartTime);
                Span<float> window = stackalloc float[SpectrumAnalyzer.FftSize];
                var bands = _pcmCache.TryGetWindow(position, window)
                    ? _spectrumEngine.ProcessPcm(window, true)
                    : _spectrumEngine.ProcessFrame(position, true);
                SpectrumDataAvailable?.Invoke(this, bands);
            }
            finally
            {
                Volatile.Write(ref _spectrumFrameBusy, 0);
            }
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
        // _mixerVolumeTimer is deliberately kept: a volume change must still reach the mixer while paused or stopped.

        if (!emitSilence) return;
        _spectrumEngine.Reset();
        SpectrumDataAvailable?.Invoke(this, new float[SpectrumAnalyzer.NumBands]);
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
        _processSuspended = false;

        if (_pipeCts != null)
        {
            try { _pipeCts.Cancel(); } catch { }
            _pipeCts.Dispose();
            _pipeCts = null;
        }

        var decoder = _decoderProcess;
        var player = _playbackProcess;
        _decoderProcess = null;
        _playbackProcess = null;
        TerminateProcess(decoder, 150);
        TerminateProcess(player, 150);
    }

    /// <summary>Best-effort kill of a child process tree, with an optional short wait, then release the handle.</summary>
    private static void TerminateProcess(Process? proc, int waitMs = 0)
    {
        if (proc == null) return;

        lock (ProcessLock) ActiveProcesses.Remove(proc);
        try
        {
            if (!proc.HasExited)
            {
                proc.Kill(entireProcessTree: true);
                if (waitMs > 0) proc.WaitForExit(waitMs);
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
        ResetAudioHardwareSettings();
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
            if (proc == null) return false;
            if (proc.WaitForExit(1000)) return proc.ExitCode == 0;

            try { proc.Kill(entireProcessTree: true); } catch { }
            return false;
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
            _mixerVolumeTimer?.Dispose();
            _mixerVolumeTimer = null;
            ResetAudioHardwareSettings();
        }
        _pcmCache.Dispose();
    }
}
