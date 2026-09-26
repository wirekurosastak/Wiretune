using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Xunit;

namespace Wiretune.Tests;

public class ArtistPictureServiceTests
{
    [Fact]
    public async Task GetArtistPictureUrlAsync_NullOrEmpty_ReturnsNull()
    {
        Assert.Null(await ArtistPictureService.GetArtistPictureUrlAsync(null));
        Assert.Null(await ArtistPictureService.GetArtistPictureUrlAsync("   "));
        Assert.Null(await ArtistPictureService.GetArtistPictureUrlAsync("Unknown Artist"));
    }

    [Fact]
    public void Artist_PicturePath_NotifiesPropertyChanged()
    {
        var artist = new Artist { Name = "Daft Punk" };
        string? changedProp = null;
        artist.PropertyChanged += (_, e) => changedProp = e.PropertyName;

        artist.PicturePath = "https://example.com/pfp.jpg";

        Assert.Equal(nameof(Artist.PicturePath), changedProp);
        Assert.Equal("https://example.com/pfp.jpg", artist.PicturePath);
    }

    [Fact]
    public async Task GetArtistPictureUrlAsync_KnownArtist_ReturnsValidUrl()
    {
        var url = await ArtistPictureService.GetArtistPictureUrlAsync("Queen");
        // Queen is available on Deezer CDN
        Assert.NotNull(url);
        Assert.StartsWith("https://", url);
        Assert.Contains("dzcdn.net", url);
    }

    [Fact]
    public void ResolveArtistPicture_NullOrEmpty_DoesNotThrow()
    {
        ArtistPictureService.ResolveArtistPicture(null);
        ArtistPictureService.ResolveArtistPicture(new Artist { Name = "" });
        ArtistPictureService.ResolveArtistPictures(Array.Empty<Artist>());
    }
}
