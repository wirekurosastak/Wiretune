using System.Net;
using System.Threading.Channels;
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
/// Client-side connection to a Wiretune server: server address, authentication, synchronising the server's track
/// list into the local <see cref="LibraryService"/> cache, and keeping the signed-in account's favourites, play
/// counts and playlists on the server.
/// </summary>
public sealed class ServerSession : IDisposable
{
    public const string DefaultServerUrl = "http://localhost:5200";

    private readonly LibraryService _library;
    private readonly LibraryRepository _settings;
    private readonly ServerStreamingClient _client;
    private readonly SemaphoreSlim _gate = new(1, 1);
    // Changes to the account's data go to the server one at a time, in the order they were made.
    private readonly Channel<Func<Task>> _pushQueue = Channel.CreateUnbounded<Func<Task>>(new UnboundedChannelOptions { SingleReader = true });
    private int _pushLoopStarted;
    private bool _serverHasUserData;
    private readonly SemaphoreSlim _streamTokenGate = new(1, 1);
    private volatile IssuedStreamToken? _streamToken;
    private string? _statusKey;
    private object?[] _statusArgs = [];

    public string ServerUrl { get; private set; } = DefaultServerUrl;
    public ServerConnectionState State { get; private set; } = ServerConnectionState.NotConfigured;
    public LibrarySource Source { get; private set; } = LibrarySource.None;
    public UserInfo? CurrentUser { get; private set; }
    /// <summary>The current status text in the active language; it follows language changes.</summary>
    public string? StatusMessage => _statusKey == null ? null : Localizer.Format(_statusKey, _statusArgs);
    public string? AuthToken => _client.AuthToken;

    /// <summary>A stream token is replaced once it has less than this left, so one handed out just now outlasts the longest track.</summary>
    private static readonly TimeSpan StreamTokenRefreshMargin = TimeSpan.FromHours(4);

    private sealed record IssuedStreamToken(string Token, DateTime ExpiresUtc);

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

        _library.FavoriteToggled += (_, track) => Enqueue(() => PushFavoriteAsync(track));
        _library.PlayRecorded += (_, track) => Enqueue(() => PushPlayAsync(track));
        _library.PlaylistEdited += (_, playlist) => Enqueue(() => PushPlaylistAsync(playlist.Id));
        _library.PlaylistRemoved += (_, playlistId) => Enqueue(() => PushPlaylistRemovedAsync(playlistId));
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
        _serverHasUserData = await _settings.GetSettingAsync("ServerUserData") == "1";

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
                        await SetServerHasUserDataAsync(false);
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

    public Task<string?> SetupAdminAsync(string username, string password, string? setupCode = null, CancellationToken ct = default) =>
        AuthenticateAsync(() => _client.SetupAdminAsync(ServerUrl, username.Trim(), password, setupCode, ct), rememberMe: true, ct,
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

            _streamToken = null;
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
        // Changes the user just made still have to reach the server while the token is valid, but a server that does
        // not answer must not keep the user from signing out.
        await FlushUserDataAsync(TimeSpan.FromSeconds(10));

        await _gate.WaitAsync();
        try
        {
            await ForgetTokenAsync();
            await SetServerHasUserDataAsync(false);
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
        // What the user changed so far must reach the server before its data is downloaded, or the download undoes it.
        await FlushUserDataAsync(TimeSpan.FromSeconds(10));

        SetState(ServerConnectionState.Connecting, "SessionDownloading");
        var tracks = await _client.FetchTracksAsync(ServerUrl, ct);
        var userData = await LoadUserDataAsync(ct);
        await _library.MergeServerTracksAsync(tracks, userData, ct);

        bool hasLocal = _library.Tracks.Any(t => string.IsNullOrEmpty(t.StreamUrl));
        Source = hasLocal ? LibrarySource.Hybrid : LibrarySource.Server;
        await _settings.SetSettingAsync("LibrarySource", Source.ToString());

        WiretuneLog.Info("ServerSession", $"Loaded {tracks.Count} tracks from '{ServerUrl}'. Total library: {_library.Tracks.Count} tracks.");
        SetState(ServerConnectionState.Connected, hasLocal ? "SessionConnectedHybrid" : "SessionConnected", _library.Tracks.Count, CurrentUser?.Username, ServerUrl);
    }

    /// <summary>
    /// The token for stream URLs: a short-lived one that opens only the audio and cover routes, so that the URL (which
    /// ends up as a decoder argument in the process list) never carries the login token. A server older than stream
    /// tokens only knows the login token, and that is used instead. Null when signed out or when no token could be had.
    /// </summary>
    public async Task<string?> GetStreamTokenAsync(CancellationToken ct = default)
    {
        var login = _client.AuthToken;
        if (string.IsNullOrEmpty(login)) return null;
        if (_streamToken is { } current && current.ExpiresUtc - DateTime.UtcNow > StreamTokenRefreshMargin) return current.Token;

        await _streamTokenGate.WaitAsync(ct);
        try
        {
            if (_streamToken is { } again && again.ExpiresUtc - DateTime.UtcNow > StreamTokenRefreshMargin) return again.Token;

            try
            {
                var issued = await _client.GetStreamTokenAsync(ServerUrl, ct);
                _streamToken = new IssuedStreamToken(issued.Token, issued.ExpiresAt.ToUniversalTime());
            }
            catch (ServerRequestException ex) when (ex.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.MethodNotAllowed)
            {
                WiretuneLog.Info("ServerSession", "The server does not issue stream tokens; stream URLs carry the login token.");
                _streamToken = new IssuedStreamToken(login, DateTime.MaxValue);
            }
            catch (Exception ex) when (ex is ServerRequestException or ServerUnauthorizedException)
            {
                // The token we hold (if any) may still be valid for a while; otherwise playback fails with the server's answer.
                WiretuneLog.Warn("ServerSession", $"Could not get a stream token: {ex.Message}");
            }

            return _streamToken is { } held && held.ExpiresUtc > DateTime.UtcNow ? held.Token : null;
        }
        finally
        {
            _streamTokenGate.Release();
        }
    }

    private async Task ForgetTokenAsync()
    {
        _streamToken = null;
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
        UpdateUserDataMode();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // ── The account's favourites, play counts and playlists ──

    private void UpdateUserDataMode() =>
        _library.UserDataMode = !_serverHasUserData ? UserDataMode.Local : IsLoggedIn ? UserDataMode.Server : UserDataMode.ServerUnavailable;

    private async Task SetServerHasUserDataAsync(bool value)
    {
        _serverHasUserData = value;
        await _settings.SetSettingAsync("ServerUserData", value ? "1" : "0");
        UpdateUserDataMode();
    }

    /// <summary>
    /// Downloads the account's data. A server that predates it answers 404: favourites then stay on this device,
    /// as before, and null is returned. The first time an account signs in on this device, what the device already
    /// holds for server tracks is handed over to the server first, so nothing set before the server kept it is lost.
    /// </summary>
    private async Task<UserDataSnapshot?> LoadUserDataAsync(CancellationToken ct)
    {
        UserDataSnapshot data;
        try
        {
            data = await _client.GetUserDataAsync(ServerUrl, ct);
        }
        catch (ServerRequestException ex) when (ex.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.MethodNotAllowed)
        {
            WiretuneLog.Info("ServerSession", "The server keeps no per-account data; favourites and playlists stay on this device.");
            await SetServerHasUserDataAsync(false);
            return null;
        }

        // What the device kept before the server stored it belongs to whoever used the device then, and goes to the first
        // account that signs in here. From then on the favourites the device shows for server tracks are a copy of an
        // account's data, not the device's own: an account that signs in later (after a session that expired and kept the
        // tracks on show) must not receive the copy of someone else's.
        if (CurrentUser != null && string.IsNullOrEmpty(await _settings.GetSettingAsync("ServerUserDataImported")))
        {
            var handedOver = true;
            if (_library.CollectServerTrackUserData() is { } local)
            {
                WiretuneLog.Info("ServerSession", $"Handing {local.Favorites.Count} favourites, {local.Plays.Count} play counts and {local.Playlists.Count} playlists over to the server.");
                try
                {
                    await _client.ImportUserDataAsync(ServerUrl, local, ct);
                    data = await _client.GetUserDataAsync(ServerUrl, ct);
                }
                catch (ServerRequestException ex) when (IsRefusal(ex))
                {
                    // Not worth keeping the player from connecting: it asks again at the next connect.
                    handedOver = false;
                    WiretuneLog.Warn("ServerSession", $"The server did not accept the data of this device: {ex.Message}");
                }
            }

            if (handedOver) await _settings.SetSettingAsync("ServerUserDataImported", $"{ServerUrl}|{CurrentUser.Id}");
        }

        await SetServerHasUserDataAsync(true);
        return data;
    }

    /// <summary>
    /// Whether changes can be sent to the server now. Deliberately independent of <see cref="State"/>: a change made while
    /// connected is still sent when the session briefly shows "connecting" because of a refresh.
    /// </summary>
    private bool CanPush => _serverHasUserData && CurrentUser != null && !string.IsNullOrEmpty(_client.AuthToken);

    private void Enqueue(Func<Task> job)
    {
        _pushQueue.Writer.TryWrite(job);
        if (Interlocked.Exchange(ref _pushLoopStarted, 1) == 0) _ = Task.Run(PushLoopAsync);
    }

    private async Task PushLoopAsync()
    {
        await foreach (var job in _pushQueue.Reader.ReadAllAsync())
        {
            try
            {
                await job();
            }
            catch (Exception ex)
            {
                WiretuneLog.Error("ServerSession", $"Sending a change to the server failed: {ex.Message}", ex);
            }
        }
    }

    /// <summary>Completes when every change made so far has been sent (or failed), or after <paramref name="timeout"/>.</summary>
    public async Task FlushUserDataAsync(TimeSpan? timeout = null)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Enqueue(() =>
        {
            done.TrySetResult();
            return Task.CompletedTask;
        });

        try
        {
            await done.Task.WaitAsync(timeout ?? TimeSpan.FromSeconds(30));
        }
        catch (TimeoutException)
        {
            WiretuneLog.Warn("ServerSession", "Gave up waiting for pending changes to reach the server.");
        }
    }

    /// <summary>The server answered, and said no: an invalid value, an account limit or a body that is too big.</summary>
    private static bool IsRefusal(ServerRequestException ex) =>
        ex.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.Conflict or HttpStatusCode.RequestEntityTooLarge;

    /// <summary>
    /// Sends one change. A server that refuses it can be reached, so the session keeps its state (the change is not kept);
    /// any other failure is handled like every server call (<see cref="GuardedAsync"/>). False says it was not sent.
    /// </summary>
    private async Task<bool> SendChangeAsync(Func<Task> send)
    {
        var sent = false;
        await GuardedAsync(async () =>
        {
            try
            {
                await send();
                sent = true;
            }
            catch (ServerRequestException ex) when (IsRefusal(ex))
            {
                WiretuneLog.Warn("ServerSession", $"The server did not accept a change: {ex.Message}");
            }
        });
        return sent;
    }

    private async Task PushFavoriteAsync(Track track)
    {
        if (!CanPush) return;

        var favorite = track.IsFavorite;
        var sent = await SendChangeAsync(() => _client.SetFavoriteAsync(ServerUrl, track.Id, favorite));

        // The server did not take it: show the star as it really is instead of pretending.
        if (!sent) await _library.SetFavoriteAsync(track.Id, !favorite);
    }

    private async Task PushPlayAsync(Track track)
    {
        if (!CanPush) return;
        await SendChangeAsync(() => _client.RecordPlayAsync(ServerUrl, track.Id));
    }

    private async Task PushPlaylistAsync(string playlistId)
    {
        if (!CanPush) return;

        // Read when it is this change's turn, so a burst of edits ends with the latest state on the server.
        var playlist = _library.GetPlaylist(playlistId);
        if (playlist is not { IsServer: true }) return;

        await SendChangeAsync(() => _client.SavePlaylistAsync(ServerUrl, playlist));
    }

    private async Task PushPlaylistRemovedAsync(string playlistId)
    {
        if (!CanPush) return;
        await SendChangeAsync(() => _client.DeletePlaylistAsync(ServerUrl, playlistId));
    }

    public void Dispose()
    {
        Localizer.Instance.LanguageChanged -= OnLanguageChanged;
        _pushQueue.Writer.TryComplete();
        _client.Dispose();
        _gate.Dispose();
        _streamTokenGate.Dispose();
    }
}



