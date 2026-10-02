using System.Net;
using System.Net.Http.Json;
using Microsoft.Extensions.DependencyInjection;
using Wiretune.Core.Models;
using Wiretune.Server;
using Xunit;
using static Wiretune.Tests.ServerTestHelpers;

namespace Wiretune.Tests;

/// <summary>Favourites, play counts and playlists live on the server, per account.</summary>
public class ServerUserDataTests
{
    private static async Task<UserDataSnapshot> GetDataAsync(HttpClient client) =>
        (await client.GetFromJsonAsync<UserDataSnapshot>("/api/me/data", WiretuneServerFixture.Json))!;

    [Fact]
    public async Task FavoritesPlaysAndPlaylists_BelongToTheAccount_AndSurviveAServerRestart()
    {
        var first = new WiretuneServerFixture { KeepFilesOnDispose = true };
        try
        {
            var (admin, _) = await SetupAdminAsync(first);
            var (guest, _) = await RegisterGuestAsync(first, admin);

            Assert.Equal(HttpStatusCode.OK, (await admin.PutAsync("/api/me/favorites/track-a", null)).StatusCode);
            Assert.Equal(HttpStatusCode.OK, (await admin.PostAsync("/api/me/plays/track-a", null)).StatusCode);
            var second = await admin.PostAsync("/api/me/plays/track-a", null);
            Assert.Equal(2, (await second.Content.ReadFromJsonAsync<TrackPlayStats>(WiretuneServerFixture.Json))!.PlayCount);

            var save = await admin.PutAsJsonAsync("/api/me/playlists/pl-1",
                new PlaylistUpdate("Road trip", "for the car", new List<string> { "track-a", "track-b" }));
            Assert.Equal(HttpStatusCode.OK, save.StatusCode);

            var data = await GetDataAsync(admin);
            Assert.Equal(new[] { "track-a" }, data.Favorites);
            Assert.Equal(2, Assert.Single(data.Plays).PlayCount);
            var playlist = Assert.Single(data.Playlists);
            Assert.Equal("Road trip", playlist.Name);
            Assert.Equal("for the car", playlist.Description);
            Assert.Equal(new[] { "track-a", "track-b" }, playlist.TrackIds);

            // Another account on the same server sees none of it.
            var theirs = await GetDataAsync(guest);
            Assert.Empty(theirs.Favorites);
            Assert.Empty(theirs.Plays);
            Assert.Empty(theirs.Playlists);

            // The same playlist ID in another account is a different playlist.
            await guest.PutAsJsonAsync("/api/me/playlists/pl-1", new PlaylistUpdate("Mine", null, new List<string>()));
            Assert.Equal("Road trip", Assert.Single((await GetDataAsync(admin)).Playlists).Name);

            // "Restart": a new server process over the same data directory.
            first.Dispose();
            using var restarted = new WiretuneServerFixture(first.Root);
            var (admin2, _) = await LoginAsync(restarted, "owner", AdminPassword);

            var afterRestart = await GetDataAsync(admin2);
            Assert.Equal(new[] { "track-a" }, afterRestart.Favorites);
            Assert.Equal(2, Assert.Single(afterRestart.Plays).PlayCount);
            Assert.Equal("Road trip", Assert.Single(afterRestart.Playlists).Name);
        }
        finally
        {
            first.Dispose();
            try { Directory.Delete(first.Root, recursive: true); } catch { }
        }
    }

    [Fact]
    public async Task Favorites_CanBeAddedAndRemovedRepeatedly()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);

        Assert.Equal(HttpStatusCode.OK, (await admin.PutAsync("/api/me/favorites/t1", null)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.PutAsync("/api/me/favorites/t1", null)).StatusCode);
        Assert.Single((await GetDataAsync(admin)).Favorites);

        Assert.Equal(HttpStatusCode.OK, (await admin.DeleteAsync("/api/me/favorites/t1")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.DeleteAsync("/api/me/favorites/t1")).StatusCode);
        Assert.Empty((await GetDataAsync(admin)).Favorites);
    }

    [Fact]
    public async Task UserDataRoutes_RequireSignIn_AndRejectInvalidInput()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);

        var anonymous = server.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await anonymous.GetAsync("/api/me/data")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await anonymous.PutAsync("/api/me/favorites/t1", null)).StatusCode);

        var tooLong = new string('x', UserDataRules.MaxIdLength + 1);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PutAsync($"/api/me/favorites/{tooLong}", null)).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PostAsync($"/api/me/plays/{tooLong}", null)).StatusCode);

        var blankName = await admin.PutAsJsonAsync("/api/me/playlists/p1", new PlaylistUpdate("   ", null, new List<string>()));
        Assert.Equal(HttpStatusCode.BadRequest, blankName.StatusCode);
        var badTrack = await admin.PutAsJsonAsync("/api/me/playlists/p1", new PlaylistUpdate("Ok", null, new List<string> { tooLong }));
        Assert.Equal(HttpStatusCode.BadRequest, badTrack.StatusCode);
        var longName = await admin.PutAsJsonAsync("/api/me/playlists/p1",
            new PlaylistUpdate(new string('n', UserDataRules.MaxPlaylistNameLength + 1), null, new List<string>()));
        Assert.Equal(HttpStatusCode.BadRequest, longName.StatusCode);

        Assert.Equal(HttpStatusCode.NotFound, (await admin.DeleteAsync("/api/me/playlists/unknown")).StatusCode);
        Assert.Empty((await GetDataAsync(admin)).Playlists);
    }

    [Fact]
    public async Task Playlist_PutReplacesTheWholePlaylist_AndDeleteRemovesIt()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);

        await admin.PutAsJsonAsync("/api/me/playlists/p1", new PlaylistUpdate("First", "one", new List<string> { "a", "b" }));
        var created = Assert.Single((await GetDataAsync(admin)).Playlists);

        await admin.PutAsJsonAsync("/api/me/playlists/p1", new PlaylistUpdate("Renamed", null, new List<string> { "c" }));
        var replaced = Assert.Single((await GetDataAsync(admin)).Playlists);
        Assert.Equal("Renamed", replaced.Name);
        Assert.Null(replaced.Description);
        Assert.Equal(new[] { "c" }, replaced.TrackIds);
        Assert.Equal(created.CreatedAt, replaced.CreatedAt);

        Assert.Equal(HttpStatusCode.OK, (await admin.DeleteAsync("/api/me/playlists/p1")).StatusCode);
        Assert.Empty((await GetDataAsync(admin)).Playlists);
    }

    [Fact]
    public async Task Import_IsAUnion_ThatNeverLowersWhatTheServerHolds()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);

        await admin.PutAsync("/api/me/favorites/a", null);
        await admin.PostAsync("/api/me/plays/a", null);
        await admin.PostAsync("/api/me/plays/a", null);
        await admin.PutAsJsonAsync("/api/me/playlists/pl", new PlaylistUpdate("Server copy", null, new List<string> { "a" }));

        var played = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var import = new UserDataSnapshot(
            new List<string> { "a", "b" },
            new List<TrackPlayStats> { new("a", 1, null), new("c", 5, played) },
            new List<PlaylistData>
            {
                new("pl", "Device copy", null, new List<string> { "x" }, played, played),
                new("pl-2", "Only on the device", null, new List<string> { "b" }, played, played)
            });

        for (var round = 0; round < 2; round++) // importing again changes nothing
        {
            Assert.Equal(HttpStatusCode.OK, (await admin.PostAsJsonAsync("/api/me/data/import", import)).StatusCode);

            var data = await GetDataAsync(admin);
            Assert.Equal(new[] { "a", "b" }, data.Favorites.OrderBy(f => f, StringComparer.Ordinal));
            Assert.Equal(2, data.Plays.Single(p => p.TrackId == "a").PlayCount);  // 2 on the server, 1 on the device: the higher wins
            var c = data.Plays.Single(p => p.TrackId == "c");
            Assert.Equal(5, c.PlayCount);
            Assert.Equal(played, c.LastPlayed);
            Assert.Equal("Server copy", data.Playlists.Single(p => p.Id == "pl").Name);   // the server's playlist stays as it is
            Assert.Equal("Only on the device", data.Playlists.Single(p => p.Id == "pl-2").Name);
        }
    }

    [Fact]
    public async Task Import_WithOneInvalidEntry_StoresNothing()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);

        var import = new UserDataSnapshot(
            new List<string> { "fine", new string('x', UserDataRules.MaxIdLength + 1) },
            new List<TrackPlayStats>(),
            new List<PlaylistData>());

        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PostAsJsonAsync("/api/me/data/import", import)).StatusCode);
        Assert.Empty((await GetDataAsync(admin)).Favorites);
    }

    [Fact]
    public async Task DeletingAnAccount_RemovesItsData_AndEndsItsAccess()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);
        var (guest, guestInfo) = await RegisterGuestAsync(server, admin);

        await guest.PutAsync("/api/me/favorites/t1", null);
        await guest.PostAsync("/api/me/plays/t1", null);
        await guest.PutAsJsonAsync("/api/me/playlists/p1", new PlaylistUpdate("Mine", null, new List<string> { "t1" }));

        Assert.Equal(HttpStatusCode.OK, (await admin.DeleteAsync($"/api/users/{guestInfo.Id}")).StatusCode);

        var stored = await server.Services.GetRequiredService<UserDataService>().GetAsync(guestInfo.Id);
        Assert.Empty(stored.Favorites);
        Assert.Empty(stored.Plays);
        Assert.Empty(stored.Playlists);
        Assert.Equal(HttpStatusCode.Unauthorized, (await guest.GetAsync("/api/me/data")).StatusCode);
    }
}
