using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Wiretune.Core.Localization;
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
    private static readonly TimeSpan ProbeTimeout  = TimeSpan.FromSeconds(15); // initial server reachability check
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(30); // normal API calls
    private static readonly TimeSpan LibraryTimeout = TimeSpan.FromMinutes(3);  // large library fetch
    private static readonly TimeSpan ImportTimeout  = TimeSpan.FromMinutes(2);  // one-time hand-over of local favourites
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private static string NotWiretuneMessage => Localizer.Get("ClientNotWiretune");

    private readonly HttpClient _httpClient;
    private readonly bool _ownsClient;

    public string? AuthToken { get; set; }

    public ServerStreamingClient(HttpClient? httpClient = null)
    {
        _ownsClient = httpClient == null;
        // The server gzips its JSON (the library listing is large); per-request timeouts are enforced in SendAsync.
        _httpClient = httpClient ?? new HttpClient(new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All })
        {
            Timeout = Timeout.InfiniteTimeSpan
        };
    }

    public static string BuildStreamUrl(string baseUrl, string trackId) =>
        $"{baseUrl.TrimEnd('/')}/api/stream/{Uri.EscapeDataString(trackId)}";

    public static string BuildCoverUrl(string baseUrl, string trackId) =>
        $"{baseUrl.TrimEnd('/')}/api/cover/{Uri.EscapeDataString(trackId)}";

    /// <summary>The cover of a whole album, so that the tracks of one album share one image (and one download).</summary>
    public static string BuildAlbumCoverUrl(string baseUrl, string albumId) =>
        $"{baseUrl.TrimEnd('/')}/api/cover/album/{Uri.EscapeDataString(albumId)}";

    public async Task<bool> CheckSetupRequiredAsync(string baseUrl, CancellationToken ct = default)
    {
        var element = await SendAsync<JsonElement>(HttpMethod.Get, baseUrl, "/api/auth/setup-required", null, false, ProbeTimeout, ct);
        if (element.ValueKind != JsonValueKind.Object ||
            !element.TryGetProperty("setupRequired", out var prop) ||
            prop.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new ServerRequestException(NotWiretuneMessage, HttpStatusCode.OK);
        }
        return prop.GetBoolean();
    }

    public Task<AuthResponse> SetupAdminAsync(string baseUrl, string username, string password, string? setupCode = null, CancellationToken ct = default) =>
        SendAsync<AuthResponse>(HttpMethod.Post, baseUrl, "/api/auth/setup", new SetupRequest(username, password, setupCode?.Trim()), false, DefaultTimeout, ct);

    public Task<AuthResponse> LoginAsync(string baseUrl, string username, string password, bool rememberMe, CancellationToken ct = default) =>
        SendAsync<AuthResponse>(HttpMethod.Post, baseUrl, "/api/auth/login", new LoginRequest(username, password, rememberMe), false, DefaultTimeout, ct);

    /// <summary>A short-lived token that opens only the audio and cover routes, for use in stream URLs.</summary>
    public Task<StreamTokenResponse> GetStreamTokenAsync(string baseUrl, CancellationToken ct = default) =>
        SendAsync<StreamTokenResponse>(HttpMethod.Post, baseUrl, "/api/auth/stream-token", null, true, DefaultTimeout, ct);

    public Task<UserInfo> GetCurrentUserAsync(string baseUrl, CancellationToken ct = default) =>
        SendAsync<UserInfo>(HttpMethod.Get, baseUrl, "/api/auth/me", null, true, DefaultTimeout, ct);

    public Task<ServerLibraryStatus> GetLibraryStatusAsync(string baseUrl, CancellationToken ct = default) =>
        SendAsync<ServerLibraryStatus>(HttpMethod.Get, baseUrl, "/api/library/status", null, true, DefaultTimeout, ct);

    public Task<List<UserInfo>> GetUsersAsync(string baseUrl, CancellationToken ct = default) =>
        SendAsync<List<UserInfo>>(HttpMethod.Get, baseUrl, "/api/users", null, true, DefaultTimeout, ct);

    public Task<UserInfo> RegisterUserAsync(string baseUrl, string username, string password, CancellationToken ct = default) =>
        SendAsync<UserInfo>(HttpMethod.Post, baseUrl, "/api/auth/register", new RegisterRequest(username, password), true, DefaultTimeout, ct);

    public async Task DeleteUserAsync(string baseUrl, string userId, CancellationToken ct = default) =>
        await SendAsync<JsonElement>(HttpMethod.Delete, baseUrl, $"/api/users/{Uri.EscapeDataString(userId)}", null, true, DefaultTimeout, ct);

    public Task<ServerConfigInfo> GetServerConfigAsync(string baseUrl, CancellationToken ct = default) =>
        SendAsync<ServerConfigInfo>(HttpMethod.Get, baseUrl, "/api/config", null, true, DefaultTimeout, ct);

    public Task<ServerConfigInfo> UpdateServerLibraryPathAsync(string baseUrl, string newPath, CancellationToken ct = default) =>
        SendAsync<ServerConfigInfo>(HttpMethod.Post, baseUrl, "/api/config/library-path", new UpdateLibraryPathRequest(newPath), true, DefaultTimeout, ct);

    public async Task TriggerScanAsync(string baseUrl, CancellationToken ct = default) =>
        await SendAsync<JsonElement>(HttpMethod.Post, baseUrl, "/api/library/scan", null, true, DefaultTimeout, ct);

    // ── The signed-in account's favourites, play statistics and playlists ──

    /// <summary>Everything the server keeps for the account. A server without per-account data answers 404.</summary>
    public Task<UserDataSnapshot> GetUserDataAsync(string baseUrl, CancellationToken ct = default) =>
        SendAsync<UserDataSnapshot>(HttpMethod.Get, baseUrl, "/api/me/data", null, true, DefaultTimeout, ct);

    /// <summary>Adds what this device already holds to the account (union: nothing on the server is removed or lowered).</summary>
    public async Task ImportUserDataAsync(string baseUrl, UserDataSnapshot data, CancellationToken ct = default) =>
        await SendAsync<JsonElement>(HttpMethod.Post, baseUrl, "/api/me/data/import", data, true, ImportTimeout, ct);

    public async Task SetFavoriteAsync(string baseUrl, string trackId, bool favorite, CancellationToken ct = default) =>
        await SendAsync<JsonElement>(favorite ? HttpMethod.Put : HttpMethod.Delete, baseUrl,
            $"/api/me/favorites/{Uri.EscapeDataString(trackId)}", null, true, DefaultTimeout, ct);

    public Task<TrackPlayStats> RecordPlayAsync(string baseUrl, string trackId, CancellationToken ct = default) =>
        SendAsync<TrackPlayStats>(HttpMethod.Post, baseUrl, $"/api/me/plays/{Uri.EscapeDataString(trackId)}", null, true, DefaultTimeout, ct);

    /// <summary>Creates or replaces a playlist of the account with the given one.</summary>
    public async Task SavePlaylistAsync(string baseUrl, Playlist playlist, CancellationToken ct = default) =>
        await SendAsync<JsonElement>(HttpMethod.Put, baseUrl, $"/api/me/playlists/{Uri.EscapeDataString(playlist.Id)}",
            new PlaylistUpdate(playlist.Name, playlist.Description, playlist.TrackIds.ToList()), true, DefaultTimeout, ct);

    /// <summary>Deletes a playlist of the account; one the server no longer has counts as deleted.</summary>
    public async Task DeletePlaylistAsync(string baseUrl, string playlistId, CancellationToken ct = default)
    {
        try
        {
            await SendAsync<JsonElement>(HttpMethod.Delete, baseUrl, $"/api/me/playlists/{Uri.EscapeDataString(playlistId)}", null, true, DefaultTimeout, ct);
        }
        catch (ServerRequestException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // Already gone.
        }
    }

    /// <summary>The lyrics of a server track, or null when it has none (or the server predates the endpoint).</summary>
    public async Task<string?> GetLyricsAsync(string baseUrl, string trackId, CancellationToken ct = default)
    {
        try
        {
            var element = await SendAsync<JsonElement>(HttpMethod.Get, baseUrl, $"/api/lyrics/{Uri.EscapeDataString(trackId)}", null, true, DefaultTimeout, ct);
            return element.ValueKind == JsonValueKind.Object && element.TryGetProperty("lyrics", out var lyrics) ? lyrics.GetString() : null;
        }
        catch (ServerRequestException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    /// <summary>
    /// Fetches the server library. Stream and cover URLs are token-free; authorization is added at playback time. The
    /// tracks of an album point to the album's cover, so each cover is downloaded and cached once, not once per track.
    /// </summary>
    public async Task<List<Track>> FetchTracksAsync(string baseUrl, CancellationToken ct = default)
    {
        var tracks = await SendAsync<List<Track>>(HttpMethod.Get, baseUrl, "/api/tracks", null, true, LibraryTimeout, ct);
        foreach (var t in tracks)
        {
            t.StreamUrl = BuildStreamUrl(baseUrl, t.Id);
            t.CoverArtPath = t.HasCoverArt ? BuildAlbumCoverUrl(baseUrl, t.AlbumId) : null;
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
            throw new ServerRequestException(Localizer.Format("ClientTimeout", timeout.TotalSeconds.ToString("0")));
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
                if (value is null) throw new ServerRequestException(Localizer.Get("ClientEmptyResponse"), response.StatusCode);
                return value;
            }
            catch (JsonException ex)
            {
                throw new ServerRequestException(NotWiretuneMessage, response.StatusCode, ex);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new ServerRequestException(Localizer.Format("ClientBodyTimeout", timeout.TotalSeconds.ToString("0")));
            }
            catch (Exception ex) when (ex is IOException or HttpRequestException or InvalidDataException)
            {
                // The connection dropped (or the body was corrupt) after the headers arrived, e.g. a server restart
                // in the middle of the library download.
                throw new ServerRequestException(Localizer.Format("ClientConnectionCutOff", ex.Message), inner: ex);
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
                return error.GetString() ?? response.ReasonPhrase ?? Localizer.Get("ClientUnknownError");
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
