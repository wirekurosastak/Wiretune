using System.ComponentModel;
using System.Text.Json.Serialization;
using Wiretune.Core.Localization;

namespace Wiretune.Core.Models;

public class Playlist : INotifyPropertyChanged
{
    private List<string> _trackIds = new();

    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = Localizer.Get("PlaylistNew");
    public string? Description { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime ModifiedAt { get; set; } = DateTime.UtcNow;

    /// <summary>
    /// True for a playlist that belongs to the signed-in server account: the server holds the original and this
    /// player's copy is a cache that is dropped on sign-out. False for a playlist that only exists on this device.
    /// </summary>
    public bool IsServer { get; set; }

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

    private QualityTier _formatTier = QualityTier.Silver;
    private string _formatSpec = string.Empty;

    /// <summary>The lowest <see cref="QualityTier"/> among the playlist's tracks; only meaningful while <see cref="FormatBadge"/> is not empty.</summary>
    [JsonIgnore]
    public QualityTier FormatTier
    {
        get => _formatTier;
        set
        {
            if (_formatTier != value)
            {
                _formatTier = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(FormatTier)));
            }
        }
    }

    /// <summary>What the quality tag says after the tier word, e.g. "FLAC 24bit/96kHz", or "MIXED".</summary>
    [JsonIgnore]
    public string FormatSpec
    {
        get => _formatSpec;
        set
        {
            if (_formatSpec != value)
            {
                _formatSpec = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(FormatSpec)));
            }
        }
    }

    /// <summary>Sets <see cref="FormatBadge"/>, <see cref="FormatTier"/> and <see cref="FormatSpec"/> from the playlist's tracks; an empty playlist has no badge.</summary>
    public void ApplyQuality(IReadOnlyCollection<Track> tracks)
    {
        var summary = QualitySummary.Of(tracks.Select(t => t.Format));
        if (summary == null)
        {
            FormatBadge = string.Empty;
            FormatSpec = string.Empty;
            return;
        }

        FormatTier = summary.Tier;
        FormatSpec = summary.Spec;
        FormatBadge = summary.IsMixed ? "MIXED HQ" : tracks.First().Format.DisplayBadge;
    }

    public event PropertyChangedEventHandler? PropertyChanged;
}
