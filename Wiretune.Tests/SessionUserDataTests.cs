using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Xunit;
using static Wiretune.Tests.ServerTestHelpers;

namespace Wiretune.Tests;

/// <summary>
/// The player keeps the signed-in account's favourites, play counts and playlists on the server: what it shows is what
/// the server holds, so it follows the account to other devices and survives a sign-out.
/// </summary>
public class SessionUserDataTests
{
    private const string BaseUrl = "http://localhost";

    /// <summary>One player installation: its own database and its own connection to the server.</summary>
    private sealed class Device : IDisposable
    {
        public MockRepository Repo { get; } = new();
        public LibraryService Library { get; }
        public ServerSession Session { get; }

        private Device(WiretuneServerFixture server, string name)
        {
            Library = new LibraryService(Repo, new MetadataScanner(), Path.Combine(server.Root, $"{name}-covers"));
            Session = new ServerSession(Library, Repo, new ServerStreamingClient(server.CreateClient()));
        }

        public static async Task<Device> CreateAsync(WiretuneServerFixture server, string name)
        {
            var device = new Device(server, name);
            await device.Library.InitializeAsync();
            await device.Session.InitializeAsync();
            return device;
        }

        public async Task SignInAsync()
        {
            await Session.ConnectAsync(BaseUrl);
            Assert.Null(await Session.LoginAsync("owner", AdminPassword, rememberMe: true));
        }

        public void Dispose() => Session.Dispose();
    }

    private sealed class ScriptedHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public List<string> Requests { get; } = new();

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            lock (Requests) Requests.Add($"{request.Method} {request.RequestUri!.AbsolutePath}");
            return Task.FromResult(respond(request));
        }
    }

    private static HttpResponseMessage Json(object value, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(JsonSerializer.Serialize(value, WiretuneServerFixture.Json), Encoding.UTF8, "application/json") };

    private static readonly AuthResponse ScriptedAuth =
        new("t0ken", new UserInfo("u1", "owner", true, DateTime.UtcNow, null), DateTime.UtcNow.AddDays(1));

    /// <summary>A session against a scripted server that has one track and a login; <paramref name="more"/> answers the rest.</summary>
    private static async Task<(ServerSession Session, LibraryService Library, ScriptedHandler Handler)> CreateScriptedSessionAsync(
        Func<HttpRequestMessage, HttpResponseMessage?> more)
    {
        var handler = new ScriptedHandler(request => request.RequestUri!.AbsolutePath switch
        {
            "/api/auth/setup-required" => Json(new { setupRequired = false }),
            "/api/auth/login" => Json(ScriptedAuth),
            "/api/tracks" => Json(new List<Track> { TestSupport.MakeTrack("s1", "Server song") }),
            _ => more(request) ?? new HttpResponseMessage(HttpStatusCode.NotFound)
        });

        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner(), Path.Combine(Path.GetTempPath(), "wiretune-test-covers"));
        await library.InitializeAsync();
        var session = new ServerSession(library, repo, new ServerStreamingClient(new HttpClient(handler)));
        await session.InitializeAsync();
        await session.ConnectAsync("http://wiretune.test");
        Assert.Null(await session.LoginAsync("owner", "correct horse", rememberMe: true));
        return (session, library, handler);
    }

    // ── Against the real server ──

    [Fact]
    public async Task Favorites_PlayCountsAndPlaylists_AreOnTheServer_AndFollowTheAccountToAnotherDevice()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);
        await server.WaitForTracksAsync(admin, 3);

        using var phone = await Device.CreateAsync(server, "phone");
        await phone.SignInAsync();
        Assert.Equal(3, phone.Library.Tracks.Count);
        Assert.Equal(UserDataMode.Server, phone.Library.UserDataMode);

        var track = phone.Library.Tracks[0];
        await phone.Library.ToggleFavoriteAsync(track.Id);
        await phone.Library.RecordPlayAsync(track.Id);
        var playlist = await phone.Library.CreatePlaylistAsync("Road trip");
        await phone.Library.AddTrackToPlaylistAsync(playlist.Id, track.Id);
        await phone.Session.FlushUserDataAsync();

        // The server holds it...
        var data = (await admin.GetFromJsonAsync<UserDataSnapshot>("/api/me/data", WiretuneServerFixture.Json))!;
        Assert.Equal(new[] { track.Id }, data.Favorites);
        Assert.Equal(1, Assert.Single(data.Plays).PlayCount);
        var stored = Assert.Single(data.Playlists);
        Assert.Equal("Road trip", stored.Name);
        Assert.Equal(new[] { track.Id }, stored.TrackIds);

        // ...so another device of the account, which has never seen any of it, shows it after signing in.
        using var laptop = await Device.CreateAsync(server, "laptop");
        await laptop.SignInAsync();
        var same = laptop.Library.GetTrack(track.Id)!;
        Assert.True(same.IsFavorite);
        Assert.Equal(1, same.PlayCount);
        var shared = Assert.Single(laptop.Library.Playlists);
        Assert.True(shared.IsServer);
        Assert.Equal("Road trip", shared.Name);
        Assert.Equal(new[] { track.Id }, shared.TrackIds);

        // A change on the laptop reaches the phone with its next refresh.
        await laptop.Library.RenamePlaylistAsync(shared.Id, "Renamed");
        await laptop.Library.ToggleFavoriteAsync(track.Id);
        await laptop.Session.FlushUserDataAsync();

        await phone.Session.RefreshLibraryAsync();
        Assert.Equal("Renamed", Assert.Single(phone.Library.Playlists).Name);
        Assert.False(phone.Library.GetTrack(track.Id)!.IsFavorite);
    }

    [Fact]
    public async Task SigningOut_RemovesTheAccountsDataFromTheDevice_AndSigningInBringsItBack()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);
        await server.WaitForTracksAsync(admin, 3);

        using var device = await Device.CreateAsync(server, "device");
        await device.SignInAsync();
        var track = device.Library.Tracks[0];
        await device.Library.ToggleFavoriteAsync(track.Id);
        await device.Library.RecordPlayAsync(track.Id);
        var playlist = await device.Library.CreatePlaylistAsync("List");
        await device.Library.AddTrackToPlaylistAsync(playlist.Id, track.Id);

        await device.Session.LogoutAsync();

        // Nothing of the account is left behind for the next person who uses this device...
        Assert.Empty(device.Library.Tracks);
        Assert.DoesNotContain(device.Library.Playlists, p => p.IsServer);
        Assert.Equal(UserDataMode.Local, device.Library.UserDataMode);

        // ...but it is all still on the server.
        Assert.Null(await device.Session.LoginAsync("owner", AdminPassword, rememberMe: true));
        var again = device.Library.GetTrack(track.Id)!;
        Assert.True(again.IsFavorite);
        Assert.Equal(1, again.PlayCount);
        var restored = Assert.Single(device.Library.Playlists);
        Assert.True(restored.IsServer);
        Assert.Equal(new[] { track.Id }, restored.TrackIds);
    }

    [Fact]
    public async Task AChangeMadeJustBeforeARefresh_IsNotUndoneByIt()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);
        await server.WaitForTracksAsync(admin, 3);

        using var device = await Device.CreateAsync(server, "device");
        await device.SignInAsync();
        var track = device.Library.Tracks[0];

        // No flush in between: the refresh itself has to send the pending change before it downloads.
        await device.Library.ToggleFavoriteAsync(track.Id);
        await device.Session.RefreshLibraryAsync();

        Assert.True(device.Library.GetTrack(track.Id)!.IsFavorite);
        Assert.Equal(new[] { track.Id }, (await admin.GetFromJsonAsync<UserDataSnapshot>("/api/me/data", WiretuneServerFixture.Json))!.Favorites);
    }

    [Fact]
    public async Task WhatThisDeviceKeptBeforeTheServerStoredIt_IsHandedOverOnce()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);
        var serverTracks = await server.WaitForTracksAsync(admin, 3);

        using var device = await Device.CreateAsync(server, "old");

        // What a player of the previous version left behind: server tracks cached with a favourite and a playlist.
        var cached = serverTracks.Select(t =>
        {
            t.StreamUrl = ServerStreamingClient.BuildStreamUrl(BaseUrl, t.Id);
            return t;
        }).ToList();
        await device.Library.MergeServerTracksAsync(cached);
        await device.Library.ToggleFavoriteAsync(cached[1].Id);
        var oldPlaylist = await device.Library.CreatePlaylistAsync("Old list");
        await device.Library.AddTrackToPlaylistAsync(oldPlaylist.Id, cached[1].Id);
        Assert.False(oldPlaylist.IsServer);

        await device.SignInAsync();

        var data = (await admin.GetFromJsonAsync<UserDataSnapshot>("/api/me/data", WiretuneServerFixture.Json))!;
        Assert.Equal(new[] { cached[1].Id }, data.Favorites);
        Assert.Equal("Old list", Assert.Single(data.Playlists).Name);

        Assert.True(device.Library.GetTrack(cached[1].Id)!.IsFavorite);
        Assert.True(Assert.Single(device.Library.Playlists).IsServer); // the device now shows the server's copy

        // Handed over once: a favourite removed afterwards stays removed instead of being re-imported on the next sign-in.
        await device.Library.ToggleFavoriteAsync(cached[1].Id);
        await device.Session.FlushUserDataAsync();
        await device.Session.LogoutAsync();
        Assert.Null(await device.Session.LoginAsync("owner", AdminPassword, rememberMe: true));
        Assert.False(device.Library.GetTrack(cached[1].Id)!.IsFavorite);
    }

    [Fact]
    public async Task AnotherAccountSigningInLater_DoesNotInheritWhatTheDeviceShowedForTheFirst()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);
        await server.WaitForTracksAsync(admin, 3);
        var (guest, _) = await RegisterGuestAsync(server, admin);

        using var device = await Device.CreateAsync(server, "shared");
        await device.SignInAsync();
        var track = device.Library.Tracks[0];
        await device.Library.ToggleFavoriteAsync(track.Id);
        await device.Session.FlushUserDataAsync();

        // The owner's session ends without a sign-out (an expired token does that): the tracks and their stars stay on show.
        Assert.Null(await device.Session.LoginAsync("guest", GuestPassword, rememberMe: false));

        // What the device cached for the owner is not handed to the guest's account, and the guest sees their own data.
        Assert.False(device.Library.GetTrack(track.Id)!.IsFavorite);
        var theirs = (await guest.GetFromJsonAsync<UserDataSnapshot>("/api/me/data", WiretuneServerFixture.Json))!;
        Assert.Empty(theirs.Favorites);
    }

    [Fact]
    public async Task AServerThatRefusesAChange_CanBeReached_SoTheSessionStaysConnected()
    {
        var (session, library, _) = await CreateScriptedSessionAsync(request => request.RequestUri!.AbsolutePath switch
        {
            "/api/me/data" => Json(new UserDataSnapshot(new List<string>(), new List<TrackPlayStats>(), new List<PlaylistData>())),
            "/api/me/data/import" => Json(new { }),
            var path when path.StartsWith("/api/me/playlists/", StringComparison.Ordinal) =>
                Json(new { error = "An account can have at most 500 playlists." }, HttpStatusCode.Conflict),
            _ => null
        });
        using (session)
        {
            await library.CreatePlaylistAsync("One too many");
            await session.FlushUserDataAsync();

            Assert.Equal(ServerConnectionState.Connected, session.State);
            Assert.Equal(UserDataMode.Server, library.UserDataMode);
        }
    }

    [Fact]
    public async Task StreamToken_IsShortLivedAndMediaOnly_AndIsDroppedOnSignOut()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);
        await server.WaitForTracksAsync(admin, 3);

        using var device = await Device.CreateAsync(server, "device");
        await device.SignInAsync();

        var token = await device.Session.GetStreamTokenAsync();
        Assert.False(string.IsNullOrEmpty(token));
        Assert.NotEqual(device.Session.AuthToken, token);
        Assert.Equal(token, await device.Session.GetStreamTokenAsync()); // reused until it is about to expire

        var track = device.Library.Tracks[0];
        var stream = await server.CreateClient().GetAsync($"/api/stream/{track.Id}?token={Uri.EscapeDataString(token!)}");
        Assert.Equal(HttpStatusCode.OK, stream.StatusCode);

        await device.Session.LogoutAsync();
        Assert.Null(await device.Session.GetStreamTokenAsync());
    }

    // ── Scripted servers ──

    [Fact]
    public async Task AServerWithoutPerAccountData_LeavesFavoritesOnTheDevice_AsBefore()
    {
        var (session, library, handler) = await CreateScriptedSessionAsync(_ => null); // answers 404 for /api/me/*
        using (session)
        {
            Assert.Equal(UserDataMode.Local, library.UserDataMode);

            await library.ToggleFavoriteAsync("s1");
            await session.FlushUserDataAsync();

            Assert.True(library.GetTrack("s1")!.IsFavorite);
            Assert.DoesNotContain(handler.Requests, r => r.Contains("/api/me/favorites"));
        }
    }

    [Fact]
    public async Task AServerWithoutStreamTokens_GetsTheLoginTokenInStreamUrls()
    {
        var (session, _, _) = await CreateScriptedSessionAsync(_ => null);
        using (session)
        {
            Assert.Equal("t0ken", await session.GetStreamTokenAsync());
        }
    }

    [Fact]
    public async Task AFavoriteTheServerRefuses_IsShownAsWhatItReallyIs()
    {
        var (session, library, _) = await CreateScriptedSessionAsync(request => request.RequestUri!.AbsolutePath switch
        {
            "/api/me/data" => Json(new UserDataSnapshot(new List<string>(), new List<TrackPlayStats>(), new List<PlaylistData>())),
            "/api/me/data/import" => Json(new { }),
            "/api/me/favorites/s1" => Json(new { error = "Database is locked." }, HttpStatusCode.InternalServerError),
            _ => null
        });
        using (session)
        {
            Assert.Equal(UserDataMode.Server, library.UserDataMode);

            await library.ToggleFavoriteAsync("s1");
            await session.FlushUserDataAsync();

            Assert.False(library.GetTrack("s1")!.IsFavorite);
        }
    }

    [Fact]
    public async Task WhileTheServerCannotBeReached_ItsTracksCannotBeChanged_ButLocalOnesCan()
    {
        var repo = new MockRepository();
        repo.Settings["ServerUserData"] = "1"; // this device has signed in to a server that keeps per-account data
        var library = new LibraryService(repo, new MetadataScanner(), Path.Combine(Path.GetTempPath(), "wiretune-test-covers"));
        await library.InitializeAsync();

        var remote = TestSupport.MakeTrack("s1", "Server song");
        remote.StreamUrl = "http://wiretune.test/api/stream/s1";
        await library.ReplaceTracksAsync(new[] { remote, TestSupport.MakeTrack("l1", "Local song") });

        using var session = new ServerSession(library, repo,
            new ServerStreamingClient(new HttpClient(new ScriptedHandler(_ => throw new InvalidOperationException("no request expected")))));
        await session.InitializeAsync();

        Assert.Equal(UserDataMode.ServerUnavailable, library.UserDataMode);

        await library.ToggleFavoriteAsync("s1");
        await library.RecordPlayAsync("s1");
        Assert.False(library.GetTrack("s1")!.IsFavorite);
        Assert.Equal(0, library.GetTrack("s1")!.PlayCount);

        await library.ToggleFavoriteAsync("l1");
        Assert.True(library.GetTrack("l1")!.IsFavorite);
    }

    // ── The audio engine ──

    [Fact]
    public async Task Engine_AsksForAFreshStreamTokenEachTimeAServerTrackStarts()
    {
        var driver = new FakeAudioDriver();
        using var engine = TestSupport.CreateEngine(driver);
        var issued = 0;
        engine.SetStreamTokenProvider(_ => Task.FromResult<string?>($"fresh-{++issued}"));

        var remote = TestSupport.MakeTrack("s1", "Remote");
        remote.StreamUrl = "http://server:5200/api/stream/s1";

        await engine.PlayTrackAsync(remote);
        Assert.Equal("http://server:5200/api/stream/s1?token=fresh-1", driver.LastSource);
        await engine.PlayTrackAsync(remote);
        Assert.Equal("http://server:5200/api/stream/s1?token=fresh-2", driver.LastSource);

        // Local files never involve a token.
        var local = TestSupport.MakeTrack("l1", "Local");
        await engine.PlayTrackAsync(local);
        Assert.Equal(local.FilePath, driver.LastSource);
        Assert.Equal(2, issued);
    }

    [Fact]
    public async Task Engine_KeepsPlaying_WhenTheStreamTokenCannotBeRefreshed()
    {
        var driver = new FakeAudioDriver();
        using var engine = TestSupport.CreateEngine(driver);
        engine.SetStreamAuthorization("old-token");
        engine.SetStreamTokenProvider(_ => throw new HttpRequestException("server unreachable"));

        var remote = TestSupport.MakeTrack("s1", "Remote");
        remote.StreamUrl = "http://server:5200/api/stream/s1";
        await engine.PlayTrackAsync(remote);

        Assert.Equal("http://server:5200/api/stream/s1?token=old-token", driver.LastSource);
    }
}
