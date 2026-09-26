using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Wiretune.Core.Models;

namespace Wiretune.Core.Services;

public sealed class ServerUnauthorizedException : Exception
{
    public ServerUnauthorizedException() : base("The server rejected the credentials.") { }
}

public sealed class ServerRequestException : Exception
{
    public HttpStatusCode? StatusCode { get; }

    public ServerRequestException(string message, HttpStatusCode? statusCode = null, Exception? inner = null)
        : base(message, inner)
    {
        StatusCode = statusCode;
    }
}

/// <summary>Thin typed HTTP client for the Wiretune server REST API.</summary>
public sealed class ServerStreamingClient : IDisposable
{
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan LibraryTimeout = TimeSpan.FromMinutes(3);
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly HttpClient _httpClient;
    private readonly bool _ownsClient;

    public string? AuthToken { get; set; }

    public ServerStreamingClient(HttpClient? httpClient = null)
    {
        _ownsClient = httpClient == null;
        _httpClient = httpClient ?? new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
    }

    public static string BuildStreamUrl(string baseUrl, string trackId) =>
        $"{baseUrl.TrimEnd('/')}/api/stream/{Uri.EscapeDataString(trackId)}";

    public static string BuildCoverUrl(string baseUrl, string trackId) =>
        $"{baseUrl.TrimEnd('/')}/api/cover/{Uri.EscapeDataString(trackId)}";

    public async Task<bool> CheckSetupRequiredAsync(string baseUrl, CancellationToken ct = default)
    {
        var element = await SendAsync<JsonElement>(HttpMethod.Get, baseUrl, "/api/auth/setup-required", null, false, DefaultTimeout, ct);
        return element.TryGetProperty("setupRequired", out var prop) && prop.GetBoolean();
    }

    public Task<AuthResponse> SetupAdminAsync(string baseUrl, string username, string password, string? displayName, CancellationToken ct = default) =>
        SendAsync<AuthResponse>(HttpMethod.Post, baseUrl, "/api/auth/setup", new RegisterRequest(username, password, displayName), false, DefaultTimeout, ct);

    public Task<AuthResponse> LoginAsync(string baseUrl, string username, string password, bool rememberMe, CancellationToken ct = default) =>
        SendAsync<AuthResponse>(HttpMethod.Post, baseUrl, "/api/auth/login", new LoginRequest(username, password, rememberMe), false, DefaultTimeout, ct);

    public Task<UserInfo> GetCurrentUserAsync(string baseUrl, CancellationToken ct = default) =>
        SendAsync<UserInfo>(HttpMethod.Get, baseUrl, "/api/auth/me", null, true, DefaultTimeout, ct);

    public Task<ServerLibraryStatus> GetLibraryStatusAsync(string baseUrl, CancellationToken ct = default) =>
        SendAsync<ServerLibraryStatus>(HttpMethod.Get, baseUrl, "/api/library/status", null, true, DefaultTimeout, ct);

    public async Task TriggerScanAsync(string baseUrl, CancellationToken ct = default) =>
        await SendAsync<JsonElement>(HttpMethod.Post, baseUrl, "/api/library/scan", null, true, DefaultTimeout, ct);

    /// <summary>Fetches the server library. Stream and cover URLs are token-free; authorization is added at playback time.</summary>
    public async Task<List<Track>> FetchTracksAsync(string baseUrl, CancellationToken ct = default)
    {
        var tracks = await SendAsync<List<Track>>(HttpMethod.Get, baseUrl, "/api/tracks", null, true, LibraryTimeout, ct) ?? new List<Track>();
        foreach (var t in tracks)
        {
            t.StreamUrl = BuildStreamUrl(baseUrl, t.Id);
            t.CoverArtPath = t.HasCoverArt ? BuildCoverUrl(baseUrl, t.Id) : null;
        }
        return tracks;
    }

    private async Task<T> SendAsync<T>(HttpMethod method, string baseUrl, string path, object? body, bool authorize, TimeSpan timeout, CancellationToken ct)
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutCts.CancelAfter(timeout);

        using var request = new HttpRequestMessage(method, baseUrl.TrimEnd('/') + path);
        if (body != null) request.Content = JsonContent.Create(body, body.GetType(), options: JsonOptions);
        if (authorize && !string.IsNullOrEmpty(AuthToken))
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", AuthToken);
        }

        HttpResponseMessage response;
        try
        {
            response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeoutCts.Token);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new ServerRequestException($"A szerver nem válaszolt {timeout.TotalSeconds:0} másodpercen belül.");
        }
        catch (HttpRequestException ex)
        {
            throw new ServerRequestException(ex.Message, inner: ex);
        }

        using (response)
        {
            if (response.StatusCode == HttpStatusCode.Unauthorized) throw new ServerUnauthorizedException();
            if (!response.IsSuccessStatusCode)
            {
                throw new ServerRequestException(await ReadErrorAsync(response, timeoutCts.Token), response.StatusCode);
            }

            if (typeof(T) == typeof(JsonElement) && response.Content.Headers.ContentLength == 0) return default!;

            try
            {
                var value = await response.Content.ReadFromJsonAsync<T>(JsonOptions, timeoutCts.Token);
                if (value is null) throw new ServerRequestException("A szerver üres választ küldött.", response.StatusCode);
                return value;
            }
            catch (JsonException ex)
            {
                throw new ServerRequestException("A szerver válasza nem értelmezhető (nem Wiretune szerver?).", response.StatusCode, ex);
            }
        }
    }

    private static async Task<string> ReadErrorAsync(HttpResponseMessage response, CancellationToken ct)
    {
        try
        {
            var element = await response.Content.ReadFromJsonAsync<JsonElement>(JsonOptions, ct);
            if (element.ValueKind == JsonValueKind.Object && element.TryGetProperty("error", out var error))
            {
                return error.GetString() ?? response.ReasonPhrase ?? "Ismeretlen hiba";
            }
        }
        catch
        {
            // Not a JSON error body.
        }

        return $"HTTP {(int)response.StatusCode} {response.ReasonPhrase}";
    }

    public void Dispose()
    {
        if (_ownsClient) _httpClient.Dispose();
    }
}
