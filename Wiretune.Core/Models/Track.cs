namespace Wiretune.Core.Models;

public class Track
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Title { get; set; } = "Unknown Title";
    public string Artist { get; set; } = "Unknown Artist";
    public string Album { get; set; } = "Unknown Album";
    public string? AlbumArtist { get; set; }
    public int? TrackNumber { get; set; }
    public int? TrackCount { get; set; }
    public int? DiscNumber { get; set; }
    public int? Year { get; set; }
    public string? Genre { get; set; }
    public TimeSpan Duration { get; set; } = TimeSpan.Zero;
    public long FileSizeBytes { get; set; }
    public string FilePath { get; set; } = string.Empty;
    public string? StreamUrl { get; set; }
    public bool HasCoverArt { get; set; }
    public string? CoverArtPath { get; set; }
    public AudioFormat Format { get; set; } = new();
    public bool IsFavorite { get; set; }
    public int PlayCount { get; set; }
    public DateTime? LastPlayed { get; set; }
    public DateTime DateAdded { get; set; } = DateTime.UtcNow;

    public string FormattedDuration => Duration.Hours > 0
        ? Duration.ToString(@"h\:mm\:ss")
        : Duration.ToString(@"m\:ss");

    public string DisplayTrackNumber => TrackNumber.HasValue ? TrackNumber.Value.ToString("D2") : "--";
}
