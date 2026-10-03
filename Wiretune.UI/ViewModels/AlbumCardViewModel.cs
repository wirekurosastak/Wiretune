using Avalonia.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using Wiretune.Core.Models;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class AlbumCardViewModel : ObservableObject, ILazyLoad
{
    public const int CoverDecodeWidth = 320;

    private bool _coverRequested;

    public Album Album { get; }
    public string Title => Album.Title;
    public string Artist => Album.Artist;
    public int? Year => Album.Year;
    public int TrackCount => Album.TrackCount;
    public string FormatBadge => Album.FormatBadge;
    public bool IsHiRes => Album.IsHiRes;
    public QualityTier Tier => Album.Tier;
    public string TagSpec => Album.TagSpec;

    [ObservableProperty] private Bitmap? _coverBitmap;

    public AlbumCardViewModel(Album album)
    {
        Album = album;
    }

    public void EnsureLoaded()
    {
        if (_coverRequested || string.IsNullOrEmpty(Album.CoverArtPath)) return;
        _coverRequested = true;
        CoverArtService.LoadBitmap(Album.CoverArtPath, CoverDecodeWidth, bmp => CoverBitmap = bmp);
    }
}
