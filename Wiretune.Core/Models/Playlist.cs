using System.ComponentModel;
using System.Text.Json.Serialization;

namespace Wiretune.Core.Models;

public class Playlist : INotifyPropertyChanged
{
    private List<string> _trackIds = new();

    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "Új lejátszási lista";
    public string? Description { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime ModifiedAt { get; set; } = DateTime.UtcNow;

    /// <summary>Replaced (never mutated in place) by LibraryService so readers can enumerate it safely.</summary>
    public List<string> TrackIds
    {
        get => _trackIds;
        set
        {
            _trackIds = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(TrackIds)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(TrackCount)));
        }
    }

    private string _formatBadge = string.Empty;

    [JsonIgnore]
    public int TrackCount => TrackIds.Count;

    [JsonIgnore]
    public string FormatBadge
    {
        get => _formatBadge;
        set
        {
            if (_formatBadge != value)
            {
                _formatBadge = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(FormatBadge)));
            }
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
}
