using Wiretune.Core.Data;
using Wiretune.Core.Localization;
using Wiretune.Core.Models;

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
/// server's track list into the local <see cref="LibraryService"/> cache.
/// </summary>
public sealed class ServerSession : IDisposable
{
    public const string DefaultServerUrl = "http://localhost:5200";

    private readonly LibraryService _library;
    private readonly LibraryRepository _settings;
    private readonly ServerStreamingClient _client;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private string? _statusKey;
    private object?[] _statusArgs = [];

    public string ServerUrl { get; private set; } = DefaultServerUrl;
    public ServerConnectionState State { get; private set; } = ServerConnectionState.NotConfigured;
    public LibrarySource Source { get; private set; } = LibrarySource.None;
    public UserInfo? CurrentUser { get; private set; }
    /// <summary>The current status text in the active language; it follows language changes.</summary>
    public string? StatusMessage => _statusKey == null ? null : Localizer.Format(_statusKey, _statusArgs);
    public string? AuthToken => _client.AuthToken;

    public bool IsLoggedIn => State == ServerConnectionState.Connected && CurrentUser != null;
    public bool IsServerReachable => State is ServerConnectionState.SetupRequired or ServerConnectionState.LoginRequired or ServerConnectionState.Connected;

    /// <summary>Raised (possibly from a background thread) whenever state, user or status message changes.</summary>
    public event EventHandler? StateChanged;

    public ServerSession(LibraryService library, LibraryRepository settings, ServerStreamingClient? client = null)
    {
        _library = library;
        _settings = settings;
        _client = client ?? new ServerStreamingClient();
        Localizer.Instance.LanguageChanged += OnLanguageChanged;
    }

    private void OnLanguageChanged(object? sender, EventArgs e) => StateChanged?.Invoke(this, EventArgs.Empty);

    /// <summary>Lyrics of a server track; null for local tracks, when signed out, on any failure, or when there are none.</summary>
    public async Task<string?> GetLyricsAsync(Track track, CancellationToken ct = default)
    {
        if (track.IsLocal || !IsLoggedIn) return null;
        try
        {
            return await _client.GetLyricsAsync(ServerUrl, track.Id, ct);
        }
        catch (Exception ex) when (ex is ServerRequestException or ServerUnauthorizedException)
        {
            WiretuneLog.Debug("ServerSession", $"No lyrics for '{track.Title}': {ex.Message}");
            return null;
        }
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

        // "user:password@host" would be stored and logged as part of the address.
        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) ||
            string.IsNullOrEmpty(uri.Host) ||
            !string.IsNullOrEmpty(uri.UserInfo))
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
            await GuardedAsync(async () =>
            {
                if (serverUrl != null)
                {
                    if (!TryNormalizeServerUrl(serverUrl, out var normalized))
                    {
                        SetState(ServerConnectionState.Offline, "SessionInvalidUrl", serverUrl);
                        return;
                    }

                    if (!string.Equals(normalized, ServerUrl, StringComparison.OrdinalIgnoreCase))
                    {
                        ServerUrl = normalized;
                        await ForgetTokenAsync(); // a token is never sent to a different server
                    }
                    await _settings.SetSettingAsync("ServerUrl", ServerUrl);
                }

                SetState(ServerConnectionState.Connecting, "SessionConnecting", ServerUrl);
                WiretuneLog.Info("ServerSession", $"Connecting to '{ServerUrl}'");

                if (await _client.CheckSetupRequiredAsync(ServerUrl, ct))
                {
                    SetState(ServerConnectionState.SetupRequired, "SessionSetupRequired");
                    return;
                }

                if (string.IsNullOrEmpty(_client.AuthToken))
                {
                    SetState(ServerConnectionState.LoginRequired, "SessionLoginRequired", ServerUrl);
                    return;
                }

                CurrentUser = await _client.GetCurrentUserAsync(ServerUrl, ct);
                await RefreshLibraryCoreAsync(ct);
            });
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Runs a server operation and turns every failure into a session state the UI can show. The callers are
    /// fire-and-forget UI commands, where an escaping exception would take the whole application down, and the
    /// state must never be left at "Connecting".
    /// </summary>
    private async Task GuardedAsync(Func<Task> operation)
    {
        try
        {
            await operation();
        }
        catch (ServerUnauthorizedException)
        {
            await ForgetTokenAsync();
            SetState(ServerConnectionState.LoginRequired, "SessionExpired");
        }
        catch (ServerRequestException ex)
        {
            WiretuneLog.Warn("ServerSession", $"Server '{ServerUrl}' unavailable: {ex.Message}");
            SetState(ServerConnectionState.Offline, "SessionUnreachable", ServerUrl, ex.Message);
        }
        catch (OperationCanceledException)
        {
            if (State == ServerConnectionState.Connecting) SetState(ServerConnectionState.Offline, "SessionCancelled");
            throw;
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("ServerSession", $"Unexpected failure talking to '{ServerUrl}'", ex);
            SetState(ServerConnectionState.Offline, "SessionUnexpected", ex.Message);
        }
    }

    public Task<string?> LoginAsync(string username, string password, bool rememberMe, CancellationToken ct = default) =>
        AuthenticateAsync(() => _client.LoginAsync(ServerUrl, username.Trim(), password, rememberMe, ct), rememberMe, ct,
            unauthorizedMessageKey: "SessionBadCredentials");

    public Task<string?> SetupAdminAsync(string username, string password, CancellationToken ct = default) =>
        AuthenticateAsync(() => _client.SetupAdminAsync(ServerUrl, username.Trim(), password, ct), rememberMe: true, ct,
            unauthorizedMessageKey: "SessionRejected");

    /// <summary>Returns null on success, otherwise a user-facing error message.</summary>
    private async Task<string?> AuthenticateAsync(Func<Task<AuthResponse>> call, bool rememberMe, CancellationToken ct, string unauthorizedMessageKey)
    {
        await _gate.WaitAsync(ct);
        try
        {
            AuthResponse auth;
            try
            {
                auth = await call();
            }
            catch (ServerUnauthorizedException)
            {
                return Localizer.Get(unauthorizedMessageKey);
            }
            catch (ServerRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Conflict)
            {
                // Another client finished the first-run setup in the meantime.
                SetState(ServerConnectionState.LoginRequired, "SessionAlreadySetUp");
                return StatusMessage;
            }
            catch (ServerRequestException ex)
            {
                if (ex.StatusCode == null)
                {
                    SetState(ServerConnectionState.Offline, "SessionUnreachable", ServerUrl, ex.Message);
                    return ex.Message;
                }
                return Localizer.Format("SessionRejectedWith", ex.Message);
            }

            _client.AuthToken = auth.Token;
            CurrentUser = auth.User;
            await GuardedAsync(async () =>
            {
                await _settings.SetSettingAsync("AuthToken", rememberMe ? auth.Token : string.Empty);
                await RefreshLibraryCoreAsync(ct);
            });

            // The credentials were accepted; if the library download then failed, the state says why.
            return State == ServerConnectionState.Connected ? null : StatusMessage;
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
            SetState(ServerConnectionState.LoginRequired, "SessionSignedOut");
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
            await GuardedAsync(() => RefreshLibraryCoreAsync(ct));
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task<List<UserInfo>> GetUsersAsync(CancellationToken ct = default) =>
        _client.GetUsersAsync(ServerUrl, ct);

    public Task<UserInfo> RegisterUserAsync(string username, string password, CancellationToken ct = default) =>
        _client.RegisterUserAsync(ServerUrl, username, password, ct);

    public Task DeleteUserAsync(string userId, CancellationToken ct = default) =>
        _client.DeleteUserAsync(ServerUrl, userId, ct);

    public Task<ServerConfigInfo> GetServerConfigAsync(CancellationToken ct = default) =>
        _client.GetServerConfigAsync(ServerUrl, ct);

    public Task<ServerConfigInfo> UpdateServerLibraryPathAsync(string newPath, CancellationToken ct = default) =>
        _client.UpdateServerLibraryPathAsync(ServerUrl, newPath, ct);

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
            SetState(ServerConnectionState.Connected, "SessionConnectedHybrid", _library.Tracks.Count, CurrentUser?.Username, ServerUrl);
        }
        else if (!hasServer)
        {
            SetState(ServerConnectionState.NotConfigured, "SessionLocalInUse");
        }
    }

    private async Task RefreshLibraryCoreAsync(CancellationToken ct)
    {
        SetState(ServerConnectionState.Connecting, "SessionDownloading");
        var tracks = await _client.FetchTracksAsync(ServerUrl, ct);
        await _library.MergeServerTracksAsync(tracks, ct);

        bool hasLocal = _library.Tracks.Any(t => string.IsNullOrEmpty(t.StreamUrl));
        Source = hasLocal ? LibrarySource.Hybrid : LibrarySource.Server;
        await _settings.SetSettingAsync("LibrarySource", Source.ToString());

        WiretuneLog.Info("ServerSession", $"Loaded {tracks.Count} tracks from '{ServerUrl}'. Total library: {_library.Tracks.Count} tracks.");
        SetState(ServerConnectionState.Connected, hasLocal ? "SessionConnectedHybrid" : "SessionConnected", _library.Tracks.Count, CurrentUser?.Username, ServerUrl);
    }

    private async Task ForgetTokenAsync()
    {
        _client.AuthToken = null;
        CurrentUser = null;
        await _settings.SetSettingAsync("AuthToken", string.Empty);
    }

    /// <param name="messageKey">Key of the status text in <see cref="Strings"/>; the text is rendered on demand so that it follows language changes.</param>
    private void SetState(ServerConnectionState state, string? messageKey, params object?[] args)
    {
        State = state;
        _statusKey = messageKey;
        _statusArgs = args;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Dispose()
    {
        Localizer.Instance.LanguageChanged -= OnLanguageChanged;
        _client.Dispose();
        _gate.Dispose();
    }
}



