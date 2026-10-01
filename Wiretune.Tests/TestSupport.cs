using Wiretune.Core.Audio;
using Wiretune.Core.Audio.Drivers;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;

namespace Wiretune.Tests;

/// <summary>In-memory audio driver so engine/view-model tests never touch real audio hardware or spawn ffplay.</summary>
public sealed class FakeAudioDriver : IAudioDriver
{
    public string DriverName => "Fake";
    public PlaybackState State { get; private set; } = PlaybackState.Stopped;
    public TimeSpan CurrentPosition { get; private set; }
    public double Volume { get; private set; } = 1.0;
    public string? LastSource { get; private set; }
    public int PlayCalls { get; private set; }
    public AudioOutputDevice? Device { get; private set; }
    public bool IsExclusive { get; private set; }
    public bool IsBitperfect { get; private set; }

    public event EventHandler<PlaybackState>? StateChanged;
    public event EventHandler<TimeSpan>? PositionChanged;
    public event EventHandler<float[]>? SpectrumDataAvailable;
    public event EventHandler? TrackEnded;
    public event EventHandler<string>? PlaybackFailed;

    public Task InitializeAsync(AudioOutputDevice device, bool exclusive, bool bitperfect)
    {
        Device = device;
        IsExclusive = exclusive;
        IsBitperfect = bitperfect;
        return Task.CompletedTask;
    }

    public Task PlayAsync(string audioSource, AudioFormat format, TimeSpan startPosition, CancellationToken ct = default)
    {
        PlayCalls++;
        LastSource = audioSource;
        CurrentPosition = startPosition;
        SetState(PlaybackState.Playing);
        return Task.CompletedTask;
    }

    public Task PauseAsync()
    {
        if (State == PlaybackState.Playing) SetState(PlaybackState.Paused);
        return Task.CompletedTask;
    }

    public Task ResumeAsync()
    {
        if (State == PlaybackState.Paused) SetState(PlaybackState.Playing);
        return Task.CompletedTask;
    }

    public Task SeekAsync(TimeSpan position)
    {
        CurrentPosition = position;
        PositionChanged?.Invoke(this, position);
        return Task.CompletedTask;
    }

    public Task StopAsync()
    {
        CurrentPosition = TimeSpan.Zero;
        SetState(PlaybackState.Stopped);
        return Task.CompletedTask;
    }

    public void SetVolume(double volume) => Volume = volume;

    public void SimulateTrackEnded()
    {
        SetState(PlaybackState.Stopped);
        TrackEnded?.Invoke(this, EventArgs.Empty);
    }

    public void SimulateFailure(string message)
    {
        SetState(PlaybackState.Error);
        PlaybackFailed?.Invoke(this, message);
    }

    public void SimulateSpectrum(float[] bands) => SpectrumDataAvailable?.Invoke(this, bands);

    private void SetState(PlaybackState state)
    {
        if (State == state) return;
        State = state;
        StateChanged?.Invoke(this, state);
    }

    public void Dispose()
    {
    }
}

public static class TestSupport
{
    public static readonly AudioOutputDevice CapableDevice = new()
    {
        Id = "hw:1,0",
        Name = "Test USB DAC",
        DriverType = "ALSA Direct",
        IsDefault = true,
        IsExclusiveSupported = true,
        IsBitperfectSupported = true
    };

    public static readonly AudioOutputDevice SharedOnlyDevice = new()
    {
        Id = "wasapi_default",
        Name = "Shared output",
        DriverType = "WASAPI Shared",
        IsDefault = true,
        IsExclusiveSupported = false,
        IsBitperfectSupported = false
    };

    public static WiretuneAudioEngine CreateEngine(FakeAudioDriver? driver = null, params AudioOutputDevice[] devices)
    {
        var list = devices.Length > 0 ? devices.ToList() : new List<AudioOutputDevice> { CapableDevice };
        return new WiretuneAudioEngine(driver ?? new FakeAudioDriver(), () => Task.FromResult(list));
    }

    public static MainViewModel CreateMainViewModel(LibraryService library, WiretuneAudioEngine? engine = null) =>
        new(engine ?? CreateEngine(), library, new ServerSession(library, new MockRepository()));

    public static Track MakeTrack(string id, string title, string artist = "Artist", string album = "Album",
        int sampleRate = 44100, int bits = 16, int trackNumber = 1, double minutes = 4.0, string? albumArtist = null) =>
        new()
        {
            Id = id,
            Title = title,
            Artist = artist,
            Album = album,
            AlbumArtist = albumArtist,
            TrackNumber = trackNumber,
            Duration = TimeSpan.FromMinutes(minutes),
            FilePath = $"/music/{id}.flac",
            Format = new AudioFormat { Codec = "FLAC", SampleRate = sampleRate, BitsPerSample = bits, IsLossless = true }
        };
}



