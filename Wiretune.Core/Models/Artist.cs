using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace Wiretune.Core.Models;

public class Artist : INotifyPropertyChanged
{
    private string? _picturePath;

    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "Unknown Artist";
    public int AlbumCount { get; set; }
    public int TrackCount { get; set; }

    public string? PicturePath
    {
        get => _picturePath;
        set => SetField(ref _picturePath, value);
    }

    public List<Album> Albums { get; set; } = new();

    /// <summary>Tracks performed by the artist plus every track on albums filed under the artist.</summary>
    [JsonIgnore]
    public List<Track> Tracks { get; set; } = new();

    public event PropertyChangedEventHandler? PropertyChanged;

    protected void SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
