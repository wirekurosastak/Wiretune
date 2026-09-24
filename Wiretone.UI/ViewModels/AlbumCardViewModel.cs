using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using Wiretone.Core.Models;
using Wiretone.UI.Services;

namespace Wiretone.UI.ViewModels;

public partial class AlbumCardViewModel : ObservableObject
{
    public Album Album { get; }
    public string Title => Album.Title;
    public string Artist => Album.Artist;
    public int? Year => Album.Year;
    public int TrackCount => Album.TrackCount;
    public string FormatBadge => Album.FormatBadge;
    public bool IsHiRes => Album.IsHiRes;

    [ObservableProperty] private Bitmap? _coverBitmap;

    public AlbumCardViewModel(Album album)
    {
        Album = album;
        LoadCover();
    }

    public void LoadCover()
    {
        var path = Album.CoverArtPath ?? Album.Tracks.FirstOrDefault(t => !string.IsNullOrEmpty(t.CoverArtPath))?.CoverArtPath;
        if (!string.IsNullOrEmpty(path))
        {
            CoverArtService.LoadBitmap(path, bmp => CoverBitmap = bmp);
        }
    }
}
