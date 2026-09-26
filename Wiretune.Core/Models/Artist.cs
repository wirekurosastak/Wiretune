using System.Text.Json.Serialization;

namespace Wiretune.Core.Models;

public class Artist
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "Unknown Artist";
    public int AlbumCount { get; set; }
    public int TrackCount { get; set; }
    public string? PicturePath { get; set; }
    public List<Album> Albums { get; set; } = new();

    /// <summary>Tracks performed by the artist plus every track on albums filed under the artist.</summary>
    [JsonIgnore]
    public List<Track> Tracks { get; set; } = new();
}
