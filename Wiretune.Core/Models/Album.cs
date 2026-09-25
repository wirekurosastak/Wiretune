namespace Wiretune.Core.Models;

public class Album
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Title { get; set; } = "Unknown Album";
    public string Artist { get; set; } = "Unknown Artist";
    public int? Year { get; set; }
    public string? Genre { get; set; }
    public string? CoverArtPath { get; set; }
    public int TrackCount { get; set; }
    public TimeSpan TotalDuration { get; set; }
    public bool IsHiRes { get; set; }
    public string FormatBadge { get; set; } = "FLAC";
    public List<Track> Tracks { get; set; } = new();

    public string FormattedTotalDuration => TotalDuration.Hours > 0
        ? $"{(int)TotalDuration.TotalHours} óra {TotalDuration.Minutes} perc"
        : $"{TotalDuration.Minutes} perc {TotalDuration.Seconds} mp";
}
