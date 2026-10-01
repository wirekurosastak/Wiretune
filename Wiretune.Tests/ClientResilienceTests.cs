using System.Net;
using System.Text;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;
using Xunit;

namespace Wiretune.Tests;

/// <summary>
/// The client talks to a server over a network that can drop at any moment. These tests feed the client
/// scripted, misbehaving responses; every failure has to surface as a session state, never as an exception
/// (the callers are fire-and-forget UI commands, where an exception ends the process).
/// </summary>
public sealed class ClientResilienceTests : IDisposable
{
    private const string BaseUrl = "http://wiretune.test";
    private readonly string _dir = Directory.CreateTempSubdirectory("wiretune_client_").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }

    private sealed class ScriptedHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(respond(request));
    }

    /// <summary>A body that delivers a few bytes and then fails, like a connection reset in mid-download.</summary>
    private sealed class DroppedStream : Stream
    {
        private bool _sentFirstChunk;

        public override int Read(byte[] buffer, int offset, int count)
        {
            if (_sentFirstChunk) throw new IOException("The connection was reset.");
            _sentFirstChunk = true;
            buffer[offset] = (byte)'[';
            return 1;
        }

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private static HttpResponseMessage Json(string body, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    private static HttpResponseMessage DroppedBody() =>
        new(HttpStatusCode.OK) { Content = new StreamContent(new DroppedStream()) { Headers = { ContentType = new("application/json") } } };

    private const string UserJson =
        """{"id":"u1","username":"owner","isAdmin":true,"createdAt":"2026-01-01T00:00:00Z","lastLogin":null}""";

    private const string AuthJson = $$"""{"token":"t0ken","user":{{UserJson}},"expiresAt":"2026-12-31T00:00:00Z"}""";

    private async Task<(ServerSession Session, MockRepository Repo)> CreateSessionAsync(Func<HttpRequestMessage, HttpResponseMessage> respond)
    {
        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner(), Path.Combine(_dir, "covers"));
        await library.InitializeAsync();
        var client = new ServerStreamingClient(new HttpClient(new ScriptedHandler(respond)));
        return (new ServerSession(library, repo, client), repo);
    }

    [Fact]
    public async Task Client_ReportsAConnectionDroppedWhileReadingTheBody_AsAServerRequestException()
    {
        using var client = new ServerStreamingClient(new HttpClient(new ScriptedHandler(_ => DroppedBody())));

        var error = await Assert.ThrowsAsync<ServerRequestException>(() => client.FetchTracksAsync(BaseUrl));

        Assert.IsAssignableFrom<IOException>(error.InnerException);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("[]")]
    [InlineData("\"hello\"")]
    [InlineData("""{"setupRequired":"yes"}""")]
    [InlineData("<html>not json</html>")]
    public async Task SetupProbe_RejectsResponsesThatAreNotFromAWiretuneServer(string body)
    {
        using var client = new ServerStreamingClient(new HttpClient(new ScriptedHandler(_ => Json(body))));

        await Assert.ThrowsAsync<ServerRequestException>(() => client.CheckSetupRequiredAsync(BaseUrl));
    }

    [Fact]
    public async Task SetupProbe_RejectsAnEmptyBody()
    {
        using var client = new ServerStreamingClient(new HttpClient(new ScriptedHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Array.Empty<byte>()) })));

        await Assert.ThrowsAsync<ServerRequestException>(() => client.CheckSetupRequiredAsync(BaseUrl));
    }

    [Fact]
    public async Task Connect_WhenTheLibraryDownloadIsCutOff_EndsOfflineInsteadOfThrowing()
    {
        var (session, repo) = await CreateSessionAsync(request => request.RequestUri!.AbsolutePath switch
        {
            "/api/auth/setup-required" => Json("""{"setupRequired":false}"""),
            "/api/auth/me" => Json(UserJson),
            "/api/tracks" => DroppedBody(),
            _ => new HttpResponseMessage(HttpStatusCode.NotFound)
        });
        using (session)
        {
            repo.Settings["ServerUrl"] = BaseUrl;
            repo.Settings["AuthToken"] = "t0ken";
            await session.InitializeAsync();

            await session.ConnectAsync();

            Assert.Equal(ServerConnectionState.Offline, session.State);
            Assert.Contains("connection was lost", session.StatusMessage);
            Assert.Equal("t0ken", repo.Settings["AuthToken"]); // a network error must not log the user out
        }
    }

    [Fact]
    public async Task Login_ThatSucceeds_ButWhoseLibraryDownloadFails_DoesNotStayInConnecting()
    {
        var (session, repo) = await CreateSessionAsync(request => request.RequestUri!.AbsolutePath switch
        {
            "/api/auth/login" => Json(AuthJson),
            "/api/tracks" => Json("""{"error":"Database is locked."}""", HttpStatusCode.InternalServerError),
            _ => new HttpResponseMessage(HttpStatusCode.NotFound)
        });
        using (session)
        {
            repo.Settings["ServerUrl"] = BaseUrl;
            await session.InitializeAsync();

            var error = await session.LoginAsync("owner", "correct horse", rememberMe: true);

            Assert.NotNull(error);
            Assert.Contains("Database is locked", error);
            Assert.Equal(ServerConnectionState.Offline, session.State);
            Assert.Equal("t0ken", session.AuthToken);            // the credentials were fine...
            Assert.Equal("t0ken", repo.Settings["AuthToken"]);   // ...so the next connect can simply retry
        }
    }

    [Fact]
    public async Task Connect_WhenTheServerAnswersWithSomethingElse_SaysSo()
    {
        var (session, _) = await CreateSessionAsync(_ => Json("""{"hello":"world"}"""));
        using (session)
        {
            await session.InitializeAsync();

            await session.ConnectAsync(BaseUrl);

            Assert.Equal(ServerConnectionState.Offline, session.State);
            Assert.Contains("is this a Wiretune server", session.StatusMessage);
        }
    }

    [Fact]
    public async Task Player_FavoriteToggle_FollowsIntoTheTrackInstanceItIsPlaying_AfterAServerRefreshReplacedTheLibraryObjects()
    {
        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner(), Path.Combine(_dir, "covers"));
        await library.InitializeAsync();
        await library.ReplaceTracksAsync(new[] { TestSupport.MakeTrack("t1", "Song") });
        var playing = library.GetTrack("t1")!;

        using var engine = TestSupport.CreateEngine();
        var player = new PlayerViewModel(engine, library) { CurrentTrack = playing };

        // A refresh builds new Track objects; the player still holds the old one.
        await library.ReplaceTracksAsync(new[] { TestSupport.MakeTrack("t1", "Song") });
        Assert.False(ReferenceEquals(playing, library.GetTrack("t1")));

        await player.ToggleFavoriteCurrentAsync();

        Assert.True(library.GetTrack("t1")!.IsFavorite);
        Assert.True(playing.IsFavorite);
    }

    [Theory]
    [InlineData("http://user:secret@host:5200")]
    [InlineData("user@host")]
    public void ServerUrl_WithEmbeddedCredentials_IsRejected(string input)
    {
        Assert.False(ServerSession.TryNormalizeServerUrl(input, out var normalized));
        Assert.Equal(string.Empty, normalized);
    }

    [Fact]
    public void DataDirectory_CreatedOnUnix_IsPrivateToTheUser()
    {
        if (OperatingSystem.IsWindows()) return;

        var target = Path.Combine(_dir, "fresh", "data");
        var created = AppPaths.GetDataDirectory(target);

        Assert.Equal(target, created);
        Assert.Equal(
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute,
            File.GetUnixFileMode(created) & (UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
                                             UnixFileMode.GroupRead | UnixFileMode.GroupWrite | UnixFileMode.GroupExecute |
                                             UnixFileMode.OtherRead | UnixFileMode.OtherWrite | UnixFileMode.OtherExecute));
    }

    [Fact]
    public void DataDirectory_ThatAlreadyExists_KeepsItsPermissions()
    {
        if (OperatingSystem.IsWindows()) return;

        var existing = Directory.CreateDirectory(Path.Combine(_dir, "shared")).FullName;
        File.SetUnixFileMode(existing, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
                                       UnixFileMode.GroupRead | UnixFileMode.GroupExecute);

        AppPaths.GetDataDirectory(existing);

        Assert.True(File.GetUnixFileMode(existing).HasFlag(UnixFileMode.GroupRead));
    }
}
