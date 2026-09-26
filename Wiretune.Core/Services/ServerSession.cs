using Wiretune.Core.Models;
using Wiretune.Core.Repositories;

namespace Wiretune.Core.Services;

public enum ServerConnectionState
{
    NotConfigured,
    Connecting,
    Offline,
    SetupRequired,
    LoginRequired,
    Connected
}

public enum LibrarySource
{
    None,
    Server,
    Local,
    Hybrid
}

/// <summary>
/// Client-side connection to a Wiretune server: server address, authentication, and synchronising the
/// server's track list into the local <see cref="ILibraryService"/> cache.
/// </summary>
public sealed class ServerSession : IDisposable
{
    public const string DefaultServerUrl = "http://localhost:5200";

    private readonly ILibraryService _library;
    private readonly ILibraryRepository _settings;
    private readonly ServerStreamingClient _client;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public string ServerUrl { get; private set; } = DefaultServerUrl;
    public ServerConnectionState State { get; private set; } = ServerConnectionState.NotConfigured;
    public LibrarySource Source { get; private set; } = LibrarySource.None;
    public UserInfo? CurrentUser { get; private set; }
    public string? StatusMessage { get; private set; }
    public string? AuthToken => _client.AuthToken;

    public bool IsLoggedIn => State == ServerConnectionState.Connected && CurrentUser != null;
    public bool IsServerReachable => State is ServerConnectionState.SetupRequired or ServerConnectionState.LoginRequired or ServerConnectionState.Connected;

    /// <summary>Raised (possibly from a background thread) whenever state, user or status message changes.</summary>
    public event EventHandler? StateChanged;

    public ServerSession(ILibraryService library, ILibraryRepository settings, ServerStreamingClient? client = null)
    {
        _library = library;
        _settings = settings;
        _client = client ?? new ServerStreamingClient();
    }

    public async Task InitializeAsync()
    {
        ServerUrl = await _settings.GetSettingAsync("ServerUrl", DefaultServerUrl) is { Length: > 0 } url ? url : DefaultServerUrl;
        Source = Enum.TryParse<LibrarySource>(await _settings.GetSettingAsync("LibrarySource"), out var source)
            ? source
            : LibrarySource.None;

        var token = await _settings.GetSettingAsync("AuthToken");
        _client.AuthToken = string.IsNullOrEmpty(token) ? null : token;

        bool hasLocal = _library.Tracks.Any(t => string.IsNullOrEmpty(t.StreamUrl));
        bool hasServerTracks = _library.Tracks.Any(t => !string.IsNullOrEmpty(t.StreamUrl));
        if (hasLocal && (hasServerTracks || Source == LibrarySource.Server || !string.IsNullOrEmpty(_client.AuthToken)))
        {
            Source = LibrarySource.Hybrid;
            await _settings.SetSettingAsync("LibrarySource", nameof(LibrarySource.Hybrid));
        }

        SetState(Source is LibrarySource.Server or LibrarySource.Hybrid ? ServerConnectionState.Offline : ServerConnectionState.NotConfigured, null);
    }

    public static bool TryNormalizeServerUrl(string? input, out string normalized)
    {
        normalized = string.Empty;
        if (string.IsNullOrWhiteSpace(input)) return false;

        var candidate = input.Trim();
        if (!candidate.Contains("://", StringComparison.Ordinal)) candidate = "http://" + candidate;

        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) ||
            string.IsNullOrEmpty(uri.Host))
        {
            return false;
        }

        normalized = uri.GetLeftPart(UriPartial.Path).TrimEnd('/');
        return true;
    }

    /// <summary>Checks the server and, if already authenticated, refreshes the library from it.</summary>
    public async Task ConnectAsync(string? serverUrl = null, CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct);
        try
        {
            if (serverUrl != null)
            {
                if (!TryNormalizeServerUrl(serverUrl, out var normalized))
                {
                    SetState(ServerConnectionState.Offline, $"Érvénytelen szervercím: „{serverUrl}”. Példa: http://192.168.1.10:5200");
                    return;
                }

                if (!string.Equals(normalized, ServerUrl, StringComparison.OrdinalIgnoreCase))
                {
                    ServerUrl = normalized;
                    await ForgetTokenAsync();
                }
                await _settings.SetSettingAsync("ServerUrl", ServerUrl);
            }

            SetState(ServerConnectionState.Connecting, $"Kapcsolódás: {ServerUrl}...");
            WiretuneLog.Info("ServerSession", $"Connecting to '{ServerUrl}'");

            if (await _client.CheckSetupRequiredAsync(ServerUrl, ct))
            {
                SetState(ServerConnectionState.SetupRequired, "A szerver még nincs beállítva. Hozz létre egy adminisztrátori fiókot!");
                return;
            }

            if (string.IsNullOrEmpty(_client.AuthToken))
            {
                SetState(ServerConnectionState.LoginRequired, $"A szerver ({ServerUrl}) elérhető. Jelentkezz be a folytatáshoz.");
                return;
            }

            try
            {
                CurrentUser = await _client.GetCurrentUserAsync(ServerUrl, ct);
            }
            catch (ServerUnauthorizedException)
            {
                await ForgetTokenAsync();
                SetState(ServerConnectionState.LoginRequired, "A munkamenet lejárt. Jelentkezz be újra.");
                return;
            }

            await RefreshLibraryCoreAsync(ct);
        }
        catch (ServerRequestException ex)
        {
            WiretuneLog.Warn("ServerSession", $"Server '{ServerUrl}' unavailable: {ex.Message}");
            SetState(ServerConnectionState.Offline, $"A szerver ({ServerUrl}) nem érhető el. {ex.Message}");
        }
        catch (ServerUnauthorizedException)
        {
            await ForgetTokenAsync();
            SetState(ServerConnectionState.LoginRequired, "A munkamenet lejárt. Jelentkezz be újra.");
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task<string?> LoginAsync(string username, string password, bool rememberMe, CancellationToken ct = default) =>
        AuthenticateAsync(() => _client.LoginAsync(ServerUrl, username.Trim(), password, rememberMe, ct), rememberMe, ct,
            unauthorizedMessage: "Hibás felhasználónév vagy jelszó.");

    public Task<string?> SetupAdminAsync(string username, string password, string? displayName, CancellationToken ct = default) =>
        AuthenticateAsync(() => _client.SetupAdminAsync(ServerUrl, username.Trim(), password, displayName, ct), rememberMe: true, ct,
            unauthorizedMessage: "A szerver elutasította a kérést.");

    /// <summary>Returns null on success, otherwise a user-facing error message.</summary>
    private async Task<string?> AuthenticateAsync(Func<Task<AuthResponse>> call, bool rememberMe, CancellationToken ct, string unauthorizedMessage)
    {
        await _gate.WaitAsync(ct);
        try
        {
            var auth = await call();
            _client.AuthToken = auth.Token;
            CurrentUser = auth.User;
            await _settings.SetSettingAsync("AuthToken", rememberMe ? auth.Token : string.Empty);
            await RefreshLibraryCoreAsync(ct);
            return null;
        }
        catch (ServerUnauthorizedException)
        {
            return unauthorizedMessage;
        }
        catch (ServerRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Conflict)
        {
            // Another client finished the first-run setup in the meantime.
            const string message = "A szervert időközben már beállították. Jelentkezz be a meglévő fiókkal.";
            SetState(ServerConnectionState.LoginRequired, message);
            return message;
        }
        catch (ServerRequestException ex)
        {
            if (ex.StatusCode == null)
            {
                SetState(ServerConnectionState.Offline, $"A szerver ({ServerUrl}) nem érhető el. {ex.Message}");
                return ex.Message;
            }
            return $"A szerver elutasította a kérést: {ex.Message}";
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task LogoutAsync()
    {
        await _gate.WaitAsync();
        try
        {
            await ForgetTokenAsync();
            await _library.RemoveServerTracksAsync();
            bool hasLocal = _library.Tracks.Any(t => string.IsNullOrEmpty(t.StreamUrl));
            Source = hasLocal ? LibrarySource.Local : LibrarySource.None;
            await _settings.SetSettingAsync("LibrarySource", Source.ToString());
            SetState(ServerConnectionState.LoginRequired, "Kijelentkezve a szerverről.");
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Re-downloads the server's track list.</summary>
    public async Task RefreshLibraryAsync(CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct);
        try
        {
            await RefreshLibraryCoreAsync(ct);
        }
        catch (ServerRequestException ex)
        {
            SetState(ServerConnectionState.Offline, $"A szerver ({ServerUrl}) nem érhető el. {ex.Message}");
        }
        catch (ServerUnauthorizedException)
        {
            await ForgetTokenAsync();
            SetState(ServerConnectionState.LoginRequired, "A munkamenet lejárt. Jelentkezz be újra.");
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task<ServerLibraryStatus> GetLibraryStatusAsync(CancellationToken ct = default) =>
        _client.GetLibraryStatusAsync(ServerUrl, ct);

    public Task TriggerServerScanAsync(CancellationToken ct = default) =>
        _client.TriggerScanAsync(ServerUrl, ct);

    /// <summary>Marks the local folder as active, switching to Hybrid mode if the server is also connected or has tracks.</summary>
    public async Task UseLocalLibraryAsync()
    {
        bool hasServer = IsLoggedIn || _library.Tracks.Any(t => !string.IsNullOrEmpty(t.StreamUrl));
        Source = hasServer ? LibrarySource.Hybrid : LibrarySource.Local;
        await _settings.SetSettingAsync("LibrarySource", Source.ToString());

        if (hasServer && State == ServerConnectionState.Connected)
        {
            var who = CurrentUser?.DisplayName ?? CurrentUser?.Username;
            SetState(ServerConnectionState.Connected, $"Csatlakozva: {who} ({ServerUrl}) • {_library.Tracks.Count} szám (Helyi + Szerver)");
        }
        else if (!hasServer)
        {
            SetState(ServerConnectionState.NotConfigured, "Helyi könyvtár használatban.");
        }
    }

    private async Task RefreshLibraryCoreAsync(CancellationToken ct)
    {
        SetState(ServerConnectionState.Connecting, "Könyvtár letöltése a szerverről...");
        var tracks = await _client.FetchTracksAsync(ServerUrl, ct);
        await _library.MergeServerTracksAsync(tracks, ct);

        bool hasLocal = _library.Tracks.Any(t => string.IsNullOrEmpty(t.StreamUrl));
        Source = hasLocal ? LibrarySource.Hybrid : LibrarySource.Server;
        await _settings.SetSettingAsync("LibrarySource", Source.ToString());

        var who = CurrentUser?.DisplayName ?? CurrentUser?.Username;
        var info = hasLocal ? $" • {_library.Tracks.Count} szám (Helyi + Szerver)" : $" • {_library.Tracks.Count} szám";
        WiretuneLog.Info("ServerSession", $"Loaded {tracks.Count} tracks from '{ServerUrl}'. Total library: {_library.Tracks.Count} tracks.");
        SetState(ServerConnectionState.Connected, $"Csatlakozva: {who} ({ServerUrl}){info}");
    }

    private async Task ForgetTokenAsync()
    {
        _client.AuthToken = null;
        CurrentUser = null;
        await _settings.SetSettingAsync("AuthToken", string.Empty);
    }

    private void SetState(ServerConnectionState state, string? message)
    {
        State = state;
        StatusMessage = message;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Dispose()
    {
        _client.Dispose();
        _gate.Dispose();
    }
}
