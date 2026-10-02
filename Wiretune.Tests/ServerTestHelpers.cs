using System.Net.Http.Headers;
using System.Net.Http.Json;
using Wiretune.Core.Models;

namespace Wiretune.Tests;

/// <summary>Shared steps for tests that talk to a real in-memory server.</summary>
internal static class ServerTestHelpers
{
    public const string AdminPassword = "correct-horse-battery";
    public const string GuestPassword = "guest-password";

    public static async Task<(HttpClient Client, AuthResponse Auth)> SetupAdminAsync(WiretuneServerFixture server)
    {
        var client = server.CreateClient();
        var response = await client.PostAsJsonAsync("/api/auth/setup", new SetupRequest("owner", AdminPassword, WiretuneServerFixture.SetupCode));
        response.EnsureSuccessStatusCode();
        var auth = (await response.Content.ReadFromJsonAsync<AuthResponse>(WiretuneServerFixture.Json))!;
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.Token);
        return (client, auth);
    }

    public static async Task<(HttpClient Client, AuthResponse Auth)> LoginAsync(WiretuneServerFixture server, string username, string password)
    {
        var client = server.CreateClient();
        var response = await client.PostAsJsonAsync("/api/auth/login", new LoginRequest(username, password));
        response.EnsureSuccessStatusCode();
        var auth = (await response.Content.ReadFromJsonAsync<AuthResponse>(WiretuneServerFixture.Json))!;
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.Token);
        return (client, auth);
    }

    /// <summary>Creates a regular account through the admin's client and returns a client signed in as it.</summary>
    public static async Task<(HttpClient Client, UserInfo User)> RegisterGuestAsync(WiretuneServerFixture server, HttpClient admin, string username = "guest")
    {
        var created = await admin.PostAsJsonAsync("/api/auth/register", new RegisterRequest(username, GuestPassword));
        created.EnsureSuccessStatusCode();
        var user = (await created.Content.ReadFromJsonAsync<UserInfo>(WiretuneServerFixture.Json))!;

        var (client, _) = await LoginAsync(server, username, GuestPassword);
        return (client, user);
    }
}
