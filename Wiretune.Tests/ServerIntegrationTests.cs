using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Xunit;

namespace Wiretune.Tests;

/// <summary>Runs the real Wiretune.Server in memory against a generated music folder.</summary>
public sealed class WiretuneServerFixture : WebApplicationFactory<Program>
{
    public string Root { get; } = Directory.CreateTempSubdirectory("wiretune_server_").FullName;
    public string LibraryPath => Path.Combine(Root, "library");
    public string DataPath => Path.Combine(Root, "data");

    public WiretuneServerFixture()
    {
        WavFile.Write(Path.Combine(LibraryPath, "Artist A", "Album 1", "01 First.wav"), 44100);
        WavFile.Write(Path.Combine(LibraryPath, "Artist A", "Album 1", "02 Second.wav"), 44100);
        WavFile.Write(Path.Combine(LibraryPath, "Artist B", "Album 2", "01 Third.wav"), 96000);
        // A sibling folder whose name shares the library prefix must never be reachable.
        WavFile.Write(Path.Combine(Root, "library2", "Outside.wav"), 44100);
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseSetting("Wiretune:LibraryPath", LibraryPath);
        builder.UseSetting("Wiretune:DataDirectory", DataPath);
        builder.UseSetting("Wiretune:ScanIntervalMinutes", "0");
    }

    public async Task<List<Track>> WaitForTracksAsync(HttpClient client, int expected)
    {
        for (var i = 0; i < 100; i++)
        {
            var tracks = await client.GetFromJsonAsync<List<Track>>("/api/tracks", Json);
            if (tracks?.Count == expected) return tracks;
            await Task.Delay(100);
        }
        throw new TimeoutException("Server did not finish its initial scan.");
    }

    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        try { Directory.Delete(Root, recursive: true); } catch { }
    }
}

internal static class WavFile
{
    public static void Write(string path, int sampleRate, double seconds = 1.0)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var frames = (int)(sampleRate * seconds);
        const short channels = 2, bits = 16;
        var dataSize = frames * channels * bits / 8;

        using var w = new BinaryWriter(File.Create(path));
        w.Write("RIFF"u8); w.Write(36 + dataSize); w.Write("WAVE"u8);
        w.Write("fmt "u8); w.Write(16); w.Write((short)1); w.Write(channels); w.Write(sampleRate);
        w.Write(sampleRate * channels * bits / 8); w.Write((short)(channels * bits / 8)); w.Write(bits);
        w.Write("data"u8); w.Write(dataSize);
        for (var i = 0; i < frames; i++)
        {
            var sample = (short)(8000 * Math.Sin(2 * Math.PI * 440 * i / sampleRate));
            w.Write(sample); w.Write(sample);
        }
    }
}

/// <summary>
/// One server instance per test method (setup can only run once per server), so the tests stay independent.
/// </summary>
public class ServerIntegrationTests
{
    private const string AdminPassword = "correct-horse-battery";

    private static async Task<(HttpClient Client, AuthResponse Auth)> SetupAdminAsync(WiretuneServerFixture server)
    {
        var client = server.CreateClient();
        var response = await client.PostAsJsonAsync("/api/auth/setup", new RegisterRequest("owner", AdminPassword));
        response.EnsureSuccessStatusCode();
        var auth = (await response.Content.ReadFromJsonAsync<AuthResponse>(WiretuneServerFixture.Json))!;
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.Token);
        return (client, auth);
    }

    [Fact]
    public async Task FirstRun_RequiresSetup_AndHasNoDefaultAdmin()
    {
        using var server = new WiretuneServerFixture();
        var client = server.CreateClient();

        var setup = await client.GetFromJsonAsync<JsonElement>("/api/auth/setup-required");
        Assert.True(setup.GetProperty("setupRequired").GetBoolean());

        var login = await client.PostAsJsonAsync("/api/auth/login", new LoginRequest("admin", "admin"));
        Assert.Equal(HttpStatusCode.Unauthorized, login.StatusCode);
    }

    [Fact]
    public async Task Setup_RejectsWeakPassword_AndSucceedsExactlyOnceUnderConcurrency()
    {
        using var server = new WiretuneServerFixture();
        var client = server.CreateClient();

        var weak = await client.PostAsJsonAsync("/api/auth/setup", new RegisterRequest("owner", "short"));
        Assert.Equal(HttpStatusCode.BadRequest, weak.StatusCode);

        var attempts = await Task.WhenAll(Enumerable.Range(0, 5).Select(i =>
            client.PostAsJsonAsync("/api/auth/setup", new RegisterRequest($"owner{i}", AdminPassword))));

        Assert.Equal(1, attempts.Count(r => r.StatusCode == HttpStatusCode.OK));
        Assert.Equal(4, attempts.Count(r => r.StatusCode == HttpStatusCode.Conflict));
    }

    [Fact]
    public async Task Token_AuthorizesLibrary_AndMeReturnsFullUserInfo()
    {
        using var server = new WiretuneServerFixture();
        var anonymous = server.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await anonymous.GetAsync("/api/tracks")).StatusCode);

        var (client, auth) = await SetupAdminAsync(server);
        Assert.True(auth.User.IsAdmin);

        var me = await client.GetFromJsonAsync<UserInfo>("/api/auth/me", WiretuneServerFixture.Json);
        Assert.Equal("owner", me!.Username);
        Assert.True(me.IsAdmin);

        var tracks = await server.WaitForTracksAsync(client, 3);
        Assert.Contains(tracks, t => t.Format.SampleRate == 96000 && t.Format.IsHiRes);
        Assert.DoesNotContain(tracks, t => t.Title == "Outside");
    }

    [Fact]
    public async Task Stream_SupportsRangeRequests_HeaderAndQueryToken()
    {
        using var server = new WiretuneServerFixture();
        var (client, auth) = await SetupAdminAsync(server);
        var track = (await server.WaitForTracksAsync(client, 3))[0];

        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/stream/{track.Id}");
        request.Headers.Range = new RangeHeaderValue(0, 1023);
        var partial = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.PartialContent, partial.StatusCode);
        Assert.Equal(1024, (await partial.Content.ReadAsByteArrayAsync()).Length);
        Assert.Equal("audio/wav", partial.Content.Headers.ContentType?.MediaType);

        var viaQuery = await server.CreateClient().GetAsync($"/api/stream/{track.Id}?token={Uri.EscapeDataString(auth.Token)}");
        Assert.Equal(HttpStatusCode.OK, viaQuery.StatusCode);

        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/api/stream/does-not-exist")).StatusCode);
    }

    [Fact]
    public async Task Stream_RefusesFilesOutsideTheLibraryRoot()
    {
        using var server = new WiretuneServerFixture();
        var (client, _) = await SetupAdminAsync(server);
        await server.WaitForTracksAsync(client, 3);

        // Inject a track that points at a sibling folder sharing the root's name prefix ("library2").
        var library = server.Services.GetRequiredService<ILibraryService>();
        var outsidePath = Path.Combine(server.Root, "library2", "Outside.wav");
        var outside = TestSupport.MakeTrack("outside", "Outside");
        outside.FilePath = outsidePath;
        await library.ReplaceTracksAsync(library.Tracks.Append(outside).ToList());

        Assert.True(File.Exists(outsidePath));
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/api/stream/outside")).StatusCode);
    }

    [Fact]
    public async Task AdminPolicy_ProtectsRegistrationAndScanning()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);

        var register = await admin.PostAsJsonAsync("/api/auth/register", new RegisterRequest("guest", "guest-password"));
        Assert.Equal(HttpStatusCode.OK, register.StatusCode);
        var guestInfo = await register.Content.ReadFromJsonAsync<UserInfo>(WiretuneServerFixture.Json);
        Assert.False(guestInfo!.IsAdmin);

        var duplicate = await admin.PostAsJsonAsync("/api/auth/register", new RegisterRequest("GUEST", "guest-password"));
        Assert.Equal(HttpStatusCode.Conflict, duplicate.StatusCode);

        var guest = server.CreateClient();
        var login = await guest.PostAsJsonAsync("/api/auth/login", new LoginRequest("Guest", "guest-password"));
        Assert.Equal(HttpStatusCode.OK, login.StatusCode);
        var guestAuth = await login.Content.ReadFromJsonAsync<AuthResponse>(WiretuneServerFixture.Json);
        guest.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", guestAuth!.Token);

        Assert.Equal(HttpStatusCode.Forbidden, (await guest.PostAsync("/api/library/scan", null)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await guest.PostAsJsonAsync("/api/auth/register", new RegisterRequest("x", "xxxxxxxxxx"))).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await guest.GetAsync("/api/tracks")).StatusCode);
        Assert.Equal(HttpStatusCode.Accepted, (await admin.PostAsync("/api/library/scan", null)).StatusCode);

        var wrong = await guest.PostAsJsonAsync("/api/auth/login", new LoginRequest("guest", "not-the-password"));
        Assert.Equal(HttpStatusCode.Unauthorized, wrong.StatusCode);
    }

    [Fact]
    public async Task ClientSession_FullLifecycle_AgainstRealServer()
    {
        using var server = new WiretuneServerFixture();
        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner(), Path.Combine(server.Root, "client-covers"));
        await library.InitializeAsync();
        using var session = new ServerSession(library, repo, new ServerStreamingClient(server.CreateClient()));
        await session.InitializeAsync();

        // Fresh server: setup is required.
        await session.ConnectAsync("http://localhost");
        Assert.Equal(ServerConnectionState.SetupRequired, session.State);

        // Creating the admin logs in and downloads the library (after the server's first scan).
        Assert.Null(await session.SetupAdminAsync("owner", AdminPassword));
        await server.WaitForTracksAsync(AuthorizedClient(server, session.AuthToken!), 3);
        await session.RefreshLibraryAsync();

        Assert.Equal(ServerConnectionState.Connected, session.State);
        Assert.Equal(LibrarySource.Server, session.Source);
        Assert.Equal(3, library.Tracks.Count);
        Assert.All(library.Tracks, t =>
        {
            Assert.StartsWith("http://localhost/api/stream/", t.StreamUrl);
            Assert.DoesNotContain("token", t.StreamUrl);
        });

        // Favorites survive a refresh from the server.
        var favorite = library.Tracks[0];
        await library.ToggleFavoriteAsync(favorite.Id);
        await session.RefreshLibraryAsync();
        Assert.True(library.GetTrack(favorite.Id)!.IsFavorite);

        // Logout forgets the token; wrong password is reported; right password reconnects.
        await session.LogoutAsync();
        Assert.Equal(ServerConnectionState.LoginRequired, session.State);
        Assert.Equal(string.Empty, repo.Settings["AuthToken"]);
        Assert.NotNull(await session.LoginAsync("owner", "wrong-password", rememberMe: false));
        Assert.Null(await session.LoginAsync("OWNER", AdminPassword, rememberMe: true));
        Assert.True(session.IsLoggedIn);
        Assert.Equal(session.AuthToken, repo.Settings["AuthToken"]);

        // A stale token is dropped on reconnect instead of looping on 401s.
        repo.Settings["AuthToken"] = "not-a-valid-token";
        using var restarted = new ServerSession(library, repo, new ServerStreamingClient(server.CreateClient()));
        await restarted.InitializeAsync();
        await restarted.ConnectAsync();
        Assert.Equal(ServerConnectionState.LoginRequired, restarted.State);
        Assert.Equal(string.Empty, repo.Settings["AuthToken"]);
    }

    private static HttpClient AuthorizedClient(WiretuneServerFixture server, string token)
    {
        var client = server.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client;
    }
}
