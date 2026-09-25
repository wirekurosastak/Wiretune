namespace Wiretune.Core.Models;

public enum PlaybackState
{
    Stopped,
    Playing,
    Paused,
    Buffering,
    Error
}

public enum RepeatMode
{
    Off,
    All,
    One
}

public record ScanProgressReport
{
    public int ScannedFiles { get; init; }
    public int TotalEstimatedFiles { get; init; }
    public string CurrentFile { get; init; } = string.Empty;
    public string CurrentArtist { get; init; } = string.Empty;
    public double ProgressPercentage => TotalEstimatedFiles > 0
        ? Math.Clamp((double)ScannedFiles / TotalEstimatedFiles * 100.0, 0, 100)
        : 0;
}
