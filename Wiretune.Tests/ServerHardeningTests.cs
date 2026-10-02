using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.RegularExpressions;
using Wiretune.Core.Models;
using Wiretune.Server;
using Xunit;
using static Wiretune.Tests.ServerTestHelpers;

namespace Wiretune.Tests;

/// <summary>First-run protection, what the library routes reveal, stream tokens and restarts.</summary>
public class ServerHardeningTests
{
    // ── Setup code ──

    [Fact]
    public async Task Setup_NeedsTheSetupCode_ThatTheOperatorSees()
    {
        using var server = new WiretuneServerFixture();
        var client = server.CreateClient();

        // A caller that does not know the code (or an older player that sends none) cannot become administrator.
        var none = await client.PostAsJsonAsync("/api/auth/setup", new SetupRequest("owner", AdminPassword));
        Assert.Equal(HttpStatusCode.Forbidden, none.StatusCode);
        var wrong = await client.PostAsJsonAsync("/api/auth/setup", new SetupRequest("owner", AdminPassword, "WRONG-CODE"));
        Assert.Equal(HttpStatusCode.Forbidden, wrong.StatusCode);

        var setup = await client.GetFromJsonAsync<JsonElement>("/api/auth/setup-required");
        Assert.True(setup.GetProperty("setupRequired").GetBoolean());

        // Case, spaces and dashes do not matter when the code is typed by hand.
        var right = await client.PostAsJsonAsync("/api/auth/setup", new SetupRequest("owner", AdminPassword, " TEST setup-code "));
        Assert.Equal(HttpStatusCode.OK, right.StatusCode);
    }

    [Fact]
    public async Task Setup_WhenAlreadyDone_AnswersConflict_EvenWithAWrongCode()
    {
        using var server = new WiretuneServerFixture();
        await SetupAdminAsync(server);

        var again = await server.CreateClient().PostAsJsonAsync("/api/auth/setup", new SetupRequest("intruder", AdminPassword, "WRONG-CODE"));

        Assert.Equal(HttpStatusCode.Conflict, again.StatusCode);
    }

    [Fact]
    public void SetupCode_IsGeneratedWhenNotConfigured_AndComparedLeniently()
    {
        var generated = new SetupCode(null);
        Assert.Matches(new Regex("^[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$"), generated.Value);
        Assert.True(generated.Matches(generated.Value));
        Assert.True(generated.Matches(generated.Value.ToLowerInvariant().Replace("-", " ")));
        Assert.False(generated.Matches(null));
        Assert.False(generated.Matches(string.Empty));
        Assert.False(generated.Matches("AAAA-AAAA"));

        // Two servers do not share a code, and an unusable configured value (nothing to compare) is not accepted as "no code".
        Assert.NotEqual(generated.Value, new SetupCode(null).Value);
        foreach (var unusable in new[] { "", "  ", "----" })
        {
            var made = new SetupCode(unusable);
            Assert.Matches(new Regex("^[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$"), made.Value);
            Assert.False(made.Matches(string.Empty));
        }

        var chosen = new SetupCode("Open-Sesame");
        Assert.Equal("Open-Sesame", chosen.Value);
        Assert.True(chosen.Matches("OPEN SESAME"));
    }

    // ── What the library routes reveal ──

    [Fact]
    public async Task LibraryRoutes_NeverExposeServerPaths()
    {
        using var server = new WiretuneServerFixture();
        var (client, _) = await SetupAdminAsync(server);
        await server.WaitForTracksAsync(client, 3);

        // The generated folder's name appears in every absolute path (library files and the cover cache).
        var folderName = Path.GetFileName(server.Root);
        foreach (var route in new[] { "/api/tracks", "/api/albums", "/api/artists", "/api/tracks?q=first" })
        {
            var body = await client.GetStringAsync(route);
            Assert.DoesNotContain(folderName, body);
            Assert.DoesNotContain("coverArtPath", body, StringComparison.OrdinalIgnoreCase);
        }

        // Older players key their database on a unique, non-empty filePath: it stays, as a placeholder.
        var tracks = (await client.GetFromJsonAsync<List<Track>>("/api/tracks", WiretuneServerFixture.Json))!;
        Assert.All(tracks, t => Assert.Equal($"server:{t.Id}", t.FilePath));
        Assert.Equal(tracks.Count, tracks.Select(t => t.FilePath).Distinct().Count());
    }

    [Fact]
    public async Task Tracks_StillCarryEverythingAPlayerNeeds()
    {
        using var server = new WiretuneServerFixture();
        var (client, _) = await SetupAdminAsync(server);
        var tracks = await server.WaitForTracksAsync(client, 3);

        Assert.All(tracks, t =>
        {
            Assert.False(string.IsNullOrEmpty(t.Title));
            Assert.True(t.Duration > TimeSpan.Zero);
            Assert.True(t.FileSizeBytes > 0);
            Assert.NotNull(t.FileModifiedUtc);
            Assert.True(t.Format.SampleRate > 0);
        });
        Assert.Contains(tracks, t => t.Format.SampleRate == 96000);
    }

    // ── Stream tokens ──

    [Fact]
    public async Task StreamToken_OpensTheMediaRoutes_AndNothingElse()
    {
        using var server = new WiretuneServerFixture();
        var (admin, auth) = await SetupAdminAsync(server);
        var track = (await server.WaitForTracksAsync(admin, 3))[0];

        var response = await admin.PostAsync("/api/auth/stream-token", null);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var issued = (await response.Content.ReadFromJsonAsync<StreamTokenResponse>(WiretuneServerFixture.Json))!;
        Assert.NotEqual(auth.Token, issued.Token);
        Assert.InRange(issued.ExpiresAt, DateTime.UtcNow.AddHours(1), DateTime.UtcNow.AddHours(9));

        var media = server.CreateClient();
        Assert.Equal(HttpStatusCode.OK, (await media.GetAsync($"/api/stream/{track.Id}?token={Uri.EscapeDataString(issued.Token)}")).StatusCode);
        Assert.NotEqual(HttpStatusCode.Unauthorized, (await media.GetAsync($"/api/cover/{track.Id}?token={Uri.EscapeDataString(issued.Token)}")).StatusCode);

        // Not on the management API (even as a header), and not to mint more tokens.
        media.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", issued.Token);
        foreach (var route in new[] { "/api/tracks", "/api/me/data", "/api/auth/me", "/api/users", "/api/config" })
        {
            Assert.Equal(HttpStatusCode.Unauthorized, (await media.GetAsync(route)).StatusCode);
        }
        Assert.Equal(HttpStatusCode.Unauthorized, (await media.PostAsync("/api/auth/stream-token", null)).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await media.PostAsJsonAsync("/api/auth/register", new RegisterRequest("x", "xxxxxxxxxx"))).StatusCode);

        // Players that predate stream tokens still stream with the login token.
        var legacy = await server.CreateClient().GetAsync($"/api/stream/{track.Id}?token={Uri.EscapeDataString(auth.Token)}");
        Assert.Equal(HttpStatusCode.OK, legacy.StatusCode);
    }

    [Fact]
    public async Task StreamToken_ForAnAdmin_NeverCarriesTheAdminRole()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);

        var issued = (await (await admin.PostAsync("/api/auth/stream-token", null)).Content
            .ReadFromJsonAsync<StreamTokenResponse>(WiretuneServerFixture.Json))!;

        // The payload is the middle part of the JWT.
        var payload = issued.Token.Split('.')[1].Replace('-', '+').Replace('_', '/');
        payload = payload.PadRight(payload.Length + (4 - payload.Length % 4) % 4, '=');
        var json = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(payload));

        Assert.DoesNotContain("admin", json);
    }

    [Fact]
    public async Task StreamToken_StopsWorking_WhenTheAccountIsDeleted()
    {
        using var server = new WiretuneServerFixture();
        var (admin, _) = await SetupAdminAsync(server);
        var track = (await server.WaitForTracksAsync(admin, 3))[0];
        var (guest, guestInfo) = await RegisterGuestAsync(server, admin);

        var issued = (await (await guest.PostAsync("/api/auth/stream-token", null)).Content
            .ReadFromJsonAsync<StreamTokenResponse>(WiretuneServerFixture.Json))!;
        var url = $"/api/stream/{track.Id}?token={Uri.EscapeDataString(issued.Token)}";
        Assert.Equal(HttpStatusCode.OK, (await server.CreateClient().GetAsync(url)).StatusCode);

        await admin.DeleteAsync($"/api/users/{guestInfo.Id}");

        Assert.Equal(HttpStatusCode.Unauthorized, (await server.CreateClient().GetAsync(url)).StatusCode);
    }

    // ── Restart ──

    [Fact]
    public async Task ServerRestart_KeepsAccountsAndTokens_AndSetupStaysClosed()
    {
        var first = new WiretuneServerFixture { KeepFilesOnDispose = true };
        try
        {
            var (_, auth) = await SetupAdminAsync(first);
            first.Dispose();

            using var restarted = new WiretuneServerFixture(first.Root);
            var client = restarted.CreateClient();
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.Token);

            // The token signed before the restart is still valid: the signing key lives in the database.
            Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/api/auth/me")).StatusCode);

            var setup = await restarted.CreateClient().GetFromJsonAsync<JsonElement>("/api/auth/setup-required");
            Assert.False(setup.GetProperty("setupRequired").GetBoolean());
        }
        finally
        {
            first.Dispose();
            try { Directory.Delete(first.Root, recursive: true); } catch { }
        }
    }
}
