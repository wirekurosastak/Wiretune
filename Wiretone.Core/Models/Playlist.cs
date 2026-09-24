namespace Wiretone.Core.Models;

public class Playlist
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "Új lejátszási lista";
    public string? Description { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime ModifiedAt { get; set; } = DateTime.UtcNow;
    public List<string> TrackIds { get; set; } = new();
    public int TrackCount => TrackIds.Count;
}
