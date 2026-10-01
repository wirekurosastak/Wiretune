using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace Wiretune.Core.Models;

public class Track : INotifyPropertyChanged
{
    private bool _isFavorite;
    private int _playCount;
    private DateTime? _lastPlayed;
    private bool _isPlaying;

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
    public DateTime? FileModifiedUtc { get; set; }
    public string FilePath { get; set; } = string.Empty;
    public string? StreamUrl { get; set; }
    public bool HasCoverArt { get; set; }
    public string? CoverArtPath { get; set; }
    public AudioFormat Format { get; set; } = new();
    public DateTime DateAdded { get; set; } = DateTime.UtcNow;

    public bool IsFavorite
    {
        get => _isFavorite;
        set => SetField(ref _isFavorite, value);
    }

    public int PlayCount
    {
        get => _playCount;
        set => SetField(ref _playCount, value);
    }

    public DateTime? LastPlayed
    {
        get => _lastPlayed;
        set => SetField(ref _lastPlayed, value);
    }

    [JsonIgnore]
    public bool IsPlaying
    {
        get => _isPlaying;
        set => SetField(ref _isPlaying, value);
    }

    /// <summary>The artist an album is filed under: the album artist when tagged, otherwise the track artist.</summary>
    [JsonIgnore]
    public string EffectiveAlbumArtist => string.IsNullOrWhiteSpace(AlbumArtist) ? Artist : AlbumArtist;

    [JsonIgnore]
    public string FormattedDuration => Duration.Hours > 0
        ? Duration.ToString(@"h\:mm\:ss")
        : Duration.ToString(@"m\:ss");

    [JsonIgnore]
    public string DisplayTrackNumber => TrackNumber.HasValue ? TrackNumber.Value.ToString("D2") : "--";

    [JsonIgnore]
    public bool IsLocal => string.IsNullOrEmpty(StreamUrl);

    public event PropertyChangedEventHandler? PropertyChanged;

    private void SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
