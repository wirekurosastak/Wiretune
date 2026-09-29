using Wiretune.Core.Models;

namespace Wiretune.Core.Audio.Drivers;

public interface IAudioDriver : IDisposable
{
    string DriverName { get; }
    PlaybackState State { get; }
    TimeSpan CurrentPosition { get; }

    event EventHandler<PlaybackState>? StateChanged;
    event EventHandler<TimeSpan>? PositionChanged;
    event EventHandler<float[]>? SpectrumDataAvailable;
    event EventHandler? TrackEnded;

    /// <summary>Playback could not start or stopped unexpectedly; the argument is a user-facing message.</summary>
    event EventHandler<string>? PlaybackFailed;

    Task InitializeAsync(AudioOutputDevice device, bool exclusive, bool bitperfect);
    Task PlayAsync(string audioSource, AudioFormat format, TimeSpan startPosition, CancellationToken ct = default);
    Task PauseAsync();
    Task ResumeAsync();
    Task SeekAsync(TimeSpan position);
    Task StopAsync();
    void SetVolume(double volume);
}

