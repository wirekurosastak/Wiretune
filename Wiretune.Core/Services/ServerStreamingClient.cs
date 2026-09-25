using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Wiretune.Core.Models;

namespace Wiretune.Core.Services;

public class ServerStreamingClient
{
    private readonly HttpClient _httpClient;
    private string? _authToken;

    public string? AuthToken
    {
        get => _authToken;
        set
        {
            _authToken = value;
            _httpClient.DefaultRequestHeaders.Authorization = !string.IsNullOrEmpty(value)
                ? new AuthenticationHeaderValue("Bearer", value)
                : null;
        }
    }

    public UserInfo? CurrentUser { get; set; }

    public ServerStreamingClient(HttpClient? httpClient = null)
    {
        _httpClient = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
    }

    public async Task<bool> PingServerAsync(string baseUrl, CancellationToken ct = default)
    {
        try
        {
            var url = $"{baseUrl.TrimEnd('/')}/api/library/status";
            var response = await _httpClient.GetAsync(url, ct);
            // 200 OK or 401 Unauthorized both mean the server is running and reachable
            return response.IsSuccessStatusCode || response.StatusCode == System.Net.HttpStatusCode.Unauthorized;
        }
        catch
        {
            return false;
        }
    }

    public async Task<bool> CheckSetupRequiredAsync(string baseUrl, CancellationToken ct = default)
    {
        try
        {
            var url = $"{baseUrl.TrimEnd('/')}/api/auth/setup-required";
            var response = await _httpClient.GetFromJsonAsync<JsonElement>(url, cancellationToken: ct);
            if (response.TryGetProperty("setupRequired", out var prop))
            {
                return prop.GetBoolean();
            }
            if (response.TryGetProperty("SetupRequired", out var propPascal))
            {
                return propPascal.GetBoolean();
            }
            return false;
        }
        catch
        {
            return false;
        }
    }

    public async Task<AuthResponse?> SetupAdminAsync(string baseUrl, string username, string password, string? displayName = null, CancellationToken ct = default)
    {
        try
        {
            var url = $"{baseUrl.TrimEnd('/')}/api/auth/setup";
            var req = new RegisterRequest(username, password, displayName);
            var response = await _httpClient.PostAsJsonAsync(url, req, cancellationToken: ct);
            if (!response.IsSuccessStatusCode) return null;

            var auth = await response.Content.ReadFromJsonAsync<AuthResponse>(cancellationToken: ct);
            if (auth != null)
            {
                AuthToken = auth.Token;
                CurrentUser = auth.User;
            }
            return auth;
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("ServerStreamingClient", $"Setup admin error: {ex.Message}", ex);
            return null;
        }
    }

    public async Task<AuthResponse?> LoginAsync(string baseUrl, string username, string password, bool rememberMe = false, CancellationToken ct = default)
    {
        try
        {
            var url = $"{baseUrl.TrimEnd('/')}/api/auth/login";
            var req = new LoginRequest(username, password, rememberMe);
            var response = await _httpClient.PostAsJsonAsync(url, req, cancellationToken: ct);
            if (!response.IsSuccessStatusCode) return null;

            var auth = await response.Content.ReadFromJsonAsync<AuthResponse>(cancellationToken: ct);
            if (auth != null)
            {
                AuthToken = auth.Token;
                CurrentUser = auth.User;
            }
            return auth;
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("ServerStreamingClient", $"Login error: {ex.Message}", ex);
            return null;
        }
    }

    public async Task<UserInfo?> GetCurrentUserAsync(string baseUrl, CancellationToken ct = default)
    {
        try
        {
            var url = $"{baseUrl.TrimEnd('/')}/api/auth/me";
            var user = await _httpClient.GetFromJsonAsync<UserInfo>(url, cancellationToken: ct);
            if (user != null)
            {
                CurrentUser = user;
            }
            return user;
        }
        catch
        {
            return null;
        }
    }

    public async Task<List<Track>> FetchTracksAsync(string baseUrl, CancellationToken ct = default)
    {
        var cleanBase = baseUrl.TrimEnd('/');
        var url = $"{cleanBase}/api/tracks";
        var tracks = await _httpClient.GetFromJsonAsync<List<Track>>(url, cancellationToken: ct) ?? new List<Track>();

        var tokenQuery = !string.IsNullOrEmpty(AuthToken) ? $"?token={Uri.EscapeDataString(AuthToken)}" : "";

        foreach (var t in tracks)
        {
            t.StreamUrl = $"{cleanBase}/api/stream/{t.Id}{tokenQuery}";
            t.CoverArtPath = $"{cleanBase}/api/cover/{t.Id}{tokenQuery}";
            t.HasCoverArt = true;
        }

        return tracks;
    }

    public string GetStreamUrl(string baseUrl, string trackId)
    {
        var tokenQuery = !string.IsNullOrEmpty(AuthToken) ? $"?token={Uri.EscapeDataString(AuthToken)}" : "";
        return $"{baseUrl.TrimEnd('/')}/api/stream/{trackId}{tokenQuery}";
    }

    public string GetCoverArtUrl(string baseUrl, string trackId)
    {
        var tokenQuery = !string.IsNullOrEmpty(AuthToken) ? $"?token={Uri.EscapeDataString(AuthToken)}" : "";
        return $"{baseUrl.TrimEnd('/')}/api/cover/{trackId}{tokenQuery}";
    }

    public async Task<bool> TriggerScanAsync(string baseUrl, string? path = null, CancellationToken ct = default)
    {
        try
        {
            var cleanBase = baseUrl.TrimEnd('/');
            var url = $"{cleanBase}/api/library/scan";
            if (!string.IsNullOrWhiteSpace(path))
            {
                url += $"?path={Uri.EscapeDataString(path)}";
            }
            var response = await _httpClient.PostAsync(url, null, ct);
            return response.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }
}
