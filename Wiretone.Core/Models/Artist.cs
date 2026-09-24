namespace Wiretone.Core.Models;

public class Artist
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "Unknown Artist";
    public int AlbumCount { get; set; }
    public int TrackCount { get; set; }
    public string? PicturePath { get; set; }
    public List<Album> Albums { get; set; } = new();
}
