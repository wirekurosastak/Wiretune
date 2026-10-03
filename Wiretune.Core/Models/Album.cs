using System.Text.Json.Serialization;
using Wiretune.Core.Localization;

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

    /// <summary>The lowest <see cref="QualityTier"/> among the album's tracks (see <see cref="QualitySummary"/>).</summary>
    public QualityTier Tier { get; set; } = QualityTier.Silver;

    /// <summary>What the quality tag says after the tier word, e.g. "FLAC 24bit/96kHz", or "MIXED".</summary>
    public string TagSpec { get; set; } = string.Empty;

    public List<Track> Tracks { get; set; } = new();

    [JsonIgnore]
    public string FormattedTotalDuration => Localizer.FormatTotalDuration(TotalDuration);
}
