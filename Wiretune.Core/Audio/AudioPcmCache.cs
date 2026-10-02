using System.Diagnostics;
using Wiretune.Core.Services;

namespace Wiretune.Core.Audio.Dsp;

/// <summary>
/// High-performance asynchronous PCM sample cache for the currently playing audio track.
/// Decodes the audio source (FLAC, MP3, WAV, AAC, HTTP stream) in the background into 16-bit mono 44.1 kHz PCM
/// so the spectrum analyzer can analyze REAL audio frequency bands in real time.
/// </summary>
public sealed class AudioPcmCache : IDisposable
{
    public const int SampleRate = 44100;

    /// <summary>Decoding stops here (20 minutes, ~106 MB) so a very long mix or audiobook cannot exhaust memory.</summary>
    private const int MaxSamples = SampleRate * 60 * 20;

    private readonly object _lock = new();
    private short[] _samples = Array.Empty<short>();
    private int _sampleCount = 0;
    private Process? _ffmpegProcess;
    private CancellationTokenSource? _cts;
    private string? _currentSource;

    public int SampleCount
    {
        get { lock (_lock) return _sampleCount; }
    }

    /// <summary>
    /// Starts asynchronous decoding of the audio source into the PCM sample cache.
    /// </summary>
    public void LoadTrack(string audioSource)
    {
        lock (_lock)
        {
            if (_currentSource == audioSource && _sampleCount > 0)
                return;

            CancelAndReset();
            _currentSource = audioSource;
            _cts = new CancellationTokenSource();
            var ct = _cts.Token;

            // Initial buffer capacity: 3 minutes @ 44.1kHz mono = ~8M samples (~16MB RAM); it grows on demand.
            _samples = new short[SampleRate * 180];
            _sampleCount = 0;

            Task.Run(() => DecodeWorker(audioSource, ct), ct);
        }
    }

    private void DecodeWorker(string source, CancellationToken ct)
    {
        Process? proc = null;
        try
        {
            // ArgumentList (not a command-line string): file names may contain quotes and must never become options.
            var psi = new ProcessStartInfo
            {
                FileName = "ffmpeg",
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            foreach (var arg in new[] { "-nostdin", "-loglevel", "error", "-i", source, "-f", "s16le", "-ac", "1", "-ar", SampleRate.ToString(), "-vn", "-" })
                psi.ArgumentList.Add(arg);

            proc = Process.Start(psi);
            if (proc == null) return;

            lock (_lock)
            {
                if (ct.IsCancellationRequested)
                {
                    try { proc.Kill(); } catch { }
                    proc.Dispose();
                    return;
                }
                _ffmpegProcess = proc;
            }

            using var stream = proc.StandardOutput.BaseStream;
            byte[] byteBuf = new byte[16384]; // 8192 samples per read (~185ms of audio per read)
            int bytesRead;

            while (!ct.IsCancellationRequested && (bytesRead = stream.Read(byteBuf, 0, byteBuf.Length)) > 0)
            {
                int samplesInChunk = bytesRead / 2;
                lock (_lock)
                {
                    // Cancellation is decided under the same lock that swaps the buffer: a worker that lost the race
                    // must not append the previous track's audio to the next track's samples.
                    if (ct.IsCancellationRequested) return;

                    if (_sampleCount + samplesInChunk > MaxSamples)
                    {
                        WiretuneLog.Info("AudioPcmCache", "Track longer than the spectrum cache limit; visualisation stops after 20 minutes.");
                        return;
                    }

                    if (_sampleCount + samplesInChunk > _samples.Length)
                    {
                        int newCapacity = Math.Min(MaxSamples, Math.Max(_samples.Length * 2, _sampleCount + samplesInChunk + SampleRate * 60));
                        Array.Resize(ref _samples, newCapacity);
                    }

                    for (int i = 0; i < samplesInChunk; i++)
                    {
                        short sample = (short)(byteBuf[i * 2] | (byteBuf[i * 2 + 1] << 8));
                        _samples[_sampleCount + i] = sample;
                    }
                    _sampleCount += samplesInChunk;
                }
            }
        }
        catch (Exception ex) when (!ct.IsCancellationRequested)
        {
            // Failures after cancellation are expected (the process is killed under the reader) and not worth logging.
            WiretuneLog.Warn("AudioPcmCache", $"PCM decode error (is ffmpeg installed?): {ex.Message}");
        }
        finally
        {
            try
            {
                if (proc != null && !proc.HasExited) proc.Kill();
                proc?.Dispose();
            }
            catch { }

            lock (_lock)
            {
                if (_ffmpegProcess == proc) _ffmpegProcess = null;
            }
        }
    }

    /// <summary>
    /// Copies a window of normalized float samples [-1.0 .. +1.0] centered at the specified playback position.
    /// </summary>
    public bool TryGetWindow(TimeSpan position, Span<float> destination)
    {
        long centerIndex = (long)(position.TotalSeconds * SampleRate);
        int windowSize = destination.Length;
        long startIndex = centerIndex - windowSize / 2;

        lock (_lock)
        {
            if (_sampleCount == 0) return false;

            for (int i = 0; i < windowSize; i++)
            {
                long idx = startIndex + i;
                if (idx >= 0 && idx < _sampleCount)
                {
                    destination[i] = _samples[idx] / 32768.0f;
                }
                else
                {
                    destination[i] = 0f;
                }
            }
            return true;
        }
    }

    public void CancelAndReset()
    {
        lock (_lock)
        {
            _cts?.Cancel();
            _cts?.Dispose();
            _cts = null;

            if (_ffmpegProcess != null)
            {
                try
                {
                    if (!_ffmpegProcess.HasExited) _ffmpegProcess.Kill();
                    _ffmpegProcess.Dispose();
                }
                catch { }
                _ffmpegProcess = null;
            }

            _currentSource = null;
            _sampleCount = 0;
            _samples = Array.Empty<short>();
        }
    }

    public void Dispose()
    {
        CancelAndReset();
    }
}
