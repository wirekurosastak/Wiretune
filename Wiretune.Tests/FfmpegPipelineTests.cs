using Wiretune.Core.Audio.Dsp;
using Wiretune.Core.Audio.Drivers;
using Wiretune.Core.Models;
using Xunit;

namespace Wiretune.Tests;

/// <summary>
/// Runs the real ffmpeg/ffplay child-process paths against generated WAV files. ffplay is pointed at SDL's
/// "dummy" audio driver, so nothing is played. Each test returns early on machines without ffmpeg/ffplay.
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

    private static bool OnPath(string tool) =>
        (Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Any(dir => File.Exists(Path.Combine(dir, tool)) || File.Exists(Path.Combine(dir, tool + ".exe")));

    private static async Task<bool> WaitUntilAsync(Func<bool> condition, int timeoutMs = 15000)
    {
        for (var waited = 0; waited < timeoutMs; waited += 50)
        {
            if (condition()) return true;
            await Task.Delay(50);
        }
        return condition();
    }

    [Fact]
    public async Task PcmCache_DecodesFiles_WhoseNamesContainQuotesAndSpaces()
    {
        if (!OnPath("ffmpeg")) return;

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

    [Fact]
    public async Task PcmCache_SwitchingTracks_NeverMixesTheOldTracksSamplesIntoTheNewOne()
    {
        if (!OnPath("ffmpeg")) return;

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

    [Fact]
    public async Task Driver_PlaysAFile_AndReportsTheEndOfTheTrack()
    {
        if (!OnPath("ffplay") || !OnPath("ffmpeg")) return;

        var path = Path.Combine(_dir, "short.wav");
        WavFile.Write(path, 44100, seconds: 0.5);

        using var driver = new FfmpegAudioDriver();
        var ended = new TaskCompletionSource();
        var failures = new List<string>();
        driver.TrackEnded += (_, _) => ended.TrySetResult();
        driver.PlaybackFailed += (_, message) => failures.Add(message);

        await driver.InitializeAsync(new AudioOutputDevice { Id = "default", DriverType = "Default" }, exclusive: false, bitperfect: false);
        await driver.PlayAsync(path, new AudioFormat(), TimeSpan.Zero);

        Assert.Equal(ended.Task, await Task.WhenAny(ended.Task, Task.Delay(15000)));
        Assert.Empty(failures);
        Assert.Equal(PlaybackState.Stopped, driver.State);
    }

    [Fact]
    public async Task Driver_ReportsAFailure_InsteadOfSkippingAnUnplayableTrack()
    {
        if (!OnPath("ffplay") || !OnPath("ffmpeg")) return;

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
