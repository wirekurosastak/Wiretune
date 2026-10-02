using Wiretune.Core.Audio.Dsp;
using Wiretune.Core.Audio.Drivers;
using Wiretune.Core.Models;
using Xunit;

namespace Wiretune.Tests;

/// <summary>
/// Runs the real ffmpeg/ffplay child-process paths against generated WAV files. ffplay is pointed at SDL's
/// "dummy" audio driver, so nothing is played. Each test is reported as skipped on machines without ffmpeg/ffplay.
/// </summary>
public sealed class FfmpegPipelineTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("wiretune_ffmpeg_").FullName;
    private readonly string? _previousSdlDriver = Environment.GetEnvironmentVariable("SDL_AUDIODRIVER");

    public FfmpegPipelineTests()
    {
        Environment.SetEnvironmentVariable("SDL_AUDIODRIVER", "dummy");
    }

    public void Dispose()
    {
        Environment.SetEnvironmentVariable("SDL_AUDIODRIVER", _previousSdlDriver);
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }

    private static async Task<bool> WaitUntilAsync(Func<bool> condition, int timeoutMs = 15000)
    {
        for (var waited = 0; waited < timeoutMs; waited += 50)
        {
            if (condition()) return true;
            await Task.Delay(50);
        }
        return condition();
    }

    [ToolFact("ffmpeg")]
    public async Task PcmCache_DecodesFiles_WhoseNamesContainQuotesAndSpaces()
    {
        // A quote in the name used to break out of the hand-quoted command line.
        var path = Path.Combine(_dir, "a \"quoted\" -i name.wav");
        WavFile.Write(path, AudioPcmCache.SampleRate, seconds: 1.0);

        using var cache = new AudioPcmCache();
        cache.LoadTrack(path);

        Assert.True(await WaitUntilAsync(() => cache.SampleCount >= AudioPcmCache.SampleRate));
        var window = new float[1024];
        Assert.True(cache.TryGetWindow(TimeSpan.FromSeconds(0.5), window));
        Assert.Contains(window, sample => Math.Abs(sample) > 0.05f); // the 440 Hz test tone, not silence
    }

    [ToolFact("ffmpeg")]
    public async Task PcmCache_SwitchingTracks_NeverMixesTheOldTracksSamplesIntoTheNewOne()
    {
        var first = Path.Combine(_dir, "first.wav");
        var second = Path.Combine(_dir, "second.wav");
        WavFile.Write(first, AudioPcmCache.SampleRate, seconds: 5.0);
        WavFile.Write(second, AudioPcmCache.SampleRate, seconds: 1.0);

        using var cache = new AudioPcmCache();
        for (var i = 0; i < 5; i++)
        {
            cache.LoadTrack(first);
            cache.LoadTrack(second); // cancels the first decode before it has finished
            await Task.Delay(10);
        }

        Assert.True(await WaitUntilAsync(() => cache.SampleCount >= AudioPcmCache.SampleRate));
        await Task.Delay(1000); // a straggling decoder of the first track would keep appending
        Assert.Equal(AudioPcmCache.SampleRate, cache.SampleCount);
    }

    [ToolFact("ffplay", "ffmpeg")]
    public async Task Driver_PlaysAFile_AndReportsTheEndOfTheTrack()
    {
        var path = Path.Combine(_dir, "short.wav");
        WavFile.Write(path, 44100, seconds: 0.5);

        using var driver = new FfmpegAudioDriver();
        var ended = new TaskCompletionSource();
        var failures = new List<string>();
        var states = new List<string>();
        driver.TrackEnded += (_, _) => ended.TrySetResult();
        driver.PlaybackFailed += (_, message) => { lock (failures) failures.Add(message); };
        driver.StateChanged += (_, state) => { lock (states) states.Add(state.ToString()); };

        await driver.InitializeAsync(new AudioOutputDevice { Id = "default", DriverType = "Default" }, exclusive: false, bitperfect: false);
        await driver.PlayAsync(path, new AudioFormat(), TimeSpan.Zero);

        var finished = await Task.WhenAny(ended.Task, Task.Delay(15000));

        // What the driver did is part of the message, so a failure on another machine can be read without a debugger.
        string report;
        lock (failures) lock (states) report = $"state {driver.State}; states seen [{string.Join(", ", states)}]; failures [{string.Join(" | ", failures)}]";
        Assert.True(ReferenceEquals(finished, ended.Task), $"The end of the track was not reported within 15 s: {report}");
        Assert.True(failures.Count == 0, $"The track was reported as failed: {report}");
        Assert.Equal(PlaybackState.Stopped, driver.State);
    }

    [ToolFact("ffplay", "ffmpeg")]
    public async Task Driver_ReportsAFailure_InsteadOfSkippingAnUnplayableTrack()
    {
        using var driver = new FfmpegAudioDriver();
        var failed = new TaskCompletionSource<string>();
        var ended = false;
        driver.TrackEnded += (_, _) => ended = true;
        driver.PlaybackFailed += (_, message) => failed.TrySetResult(message);

        await driver.InitializeAsync(new AudioOutputDevice { Id = "default", DriverType = "Default" }, exclusive: false, bitperfect: false);
        // ffplay exits with status 0 after failing to open a source; that must not look like a finished track.
        await driver.PlayAsync(Path.Combine(_dir, "does-not-exist.flac"), new AudioFormat(), TimeSpan.Zero);

        Assert.Equal(failed.Task, await Task.WhenAny(failed.Task, Task.Delay(15000)));
        Assert.False(ended);
        Assert.Equal(PlaybackState.Error, driver.State);
    }
}
