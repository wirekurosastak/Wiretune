using Wiretone.Core.Models;

namespace Wiretone.Core.Audio;

public interface IAudioEngine : IDisposable
{
    Track? CurrentTrack { get; }
    PlaybackState State { get; }
    TimeSpan CurrentPosition { get; }
    TimeSpan Duration { get; }
    double Volume { get; }
    bool IsMuted { get; }
    bool IsExclusiveMode { get; }
    bool IsBitperfect { get; }
    bool IsVolumeLocked { get; }
    AudioOutputDevice? CurrentDevice { get; }
    IReadOnlyList<AudioOutputDevice> AvailableDevices { get; }
    AudioFormat? CurrentFormat { get; }
    string SignalPathDescription { get; }

    event EventHandler<PlaybackState>? StateChanged;
    event EventHandler<TimeSpan>? PositionChanged;
    event EventHandler<Track?>? TrackChanged;
    event EventHandler<bool>? BitperfectChanged;
    event EventHandler<bool>? ExclusiveModeChanged;
    event EventHandler<float[]>? SpectrumDataAvailable;
    event EventHandler? TrackEnded;

    Task PlayTrackAsync(Track track, CancellationToken ct = default);
    Task PlayStreamAsync(string streamUrl, Track track, CancellationToken ct = default);
    Task PauseAsync();
    Task ResumeAsync();
    Task StopAsync();
    Task SeekAsync(TimeSpan position);
    void SetVolume(double volume);
    void SetMuted(bool muted);
    Task SetExclusiveModeAsync(bool enabled);
    Task SetBitperfectModeAsync(bool enabled);
    Task SetOutputDeviceAsync(AudioOutputDevice device);
    Task RefreshDevicesAsync();
}
