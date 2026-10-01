using System.Net;
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

    // The service is static; these tests swap its HTTP client and cache file, so they must never hit the real API.
    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public int Requests;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref Requests);
            return Task.FromResult(respond(request));
        }
    }

    private static HttpResponseMessage Json(string body) =>
        new(HttpStatusCode.OK) { Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json") };

    private static StubHandler UseStub(Func<HttpRequestMessage, HttpResponseMessage> respond)
    {
        var handler = new StubHandler(respond);
        ArtistPictureService.Http = new HttpClient(handler);
        ArtistPictureService.CacheFileOverride = Path.Combine(Path.GetTempPath(), $"wt-artist-{Guid.NewGuid():N}.json");
        ArtistPictureService.ResetForTests();
        return handler;
    }

    [Fact]
    public async Task GetArtistPictureUrlAsync_KnownArtist_ReturnsUrl_AndCachesIt()
    {
        var handler = UseStub(_ => Json("""{"data":[{"picture_medium":"https://cdn.example/queen.jpg"}]}"""));

        Assert.Equal("https://cdn.example/queen.jpg", await ArtistPictureService.GetArtistPictureUrlAsync("Queen"));
        Assert.Equal("https://cdn.example/queen.jpg", await ArtistPictureService.GetArtistPictureUrlAsync("  queen "));
        Assert.Equal(1, handler.Requests);
    }

    [Fact]
    public async Task GetArtistPictureUrlAsync_UnknownArtist_IsRememberedAndNotAskedAgain()
    {
        var handler = UseStub(_ => Json("""{"data":[]}"""));

        Assert.Null(await ArtistPictureService.GetArtistPictureUrlAsync("Nobody"));
        Assert.Null(await ArtistPictureService.GetArtistPictureUrlAsync("Nobody"));
        Assert.Equal(1, handler.Requests);
        Assert.True(ArtistPictureService.IsCached("Nobody"));
    }

    [Fact]
    public async Task GetArtistPictureUrlAsync_ServerErrors_AreNeitherCachedNorRetriedImmediately()
    {
        var handler = UseStub(_ => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable));

        Assert.Null(await ArtistPictureService.GetArtistPictureUrlAsync("Queen"));
        // A rate limit or outage must not turn into "this artist has no picture" - neither now nor after a restart.
        Assert.False(ArtistPictureService.IsCached("Queen"));

        // ...and while backing off the API is left alone.
        Assert.Null(await ArtistPictureService.GetArtistPictureUrlAsync("Abba"));
        Assert.Equal(1, handler.Requests);
    }

    [Fact]
    public async Task GetArtistPictureUrlAsync_RejectsNonHttpsPictureUrls()
    {
        UseStub(_ => Json("""{"data":[{"picture_medium":"file:///etc/passwd","picture_big":"http://insecure.example/x.jpg"}]}"""));

        Assert.Null(await ArtistPictureService.GetArtistPictureUrlAsync("Queen"));
    }

    [Fact]
    public void ResolveArtistPicture_NullOrEmpty_DoesNotThrow()
    {
        ArtistPictureService.ResolveArtistPicture(null);
        ArtistPictureService.ResolveArtistPicture(new Artist { Name = "" });
        ArtistPictureService.ResolveArtistPictures(Array.Empty<Artist>());
    }
}
