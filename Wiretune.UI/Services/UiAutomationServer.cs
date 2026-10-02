#if DEBUG
using System.Net;
using System.Text;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;

namespace Wiretune.UI.Services;

/// <summary>
/// Local HTTP endpoint for scripted UI testing. Compiled into Debug builds only (a release build has no such listener at
/// all). Even then it stays off unless WIRETUNE_UI_AUTOMATION=1 is set, is bound to loopback only, and sends no CORS
/// headers, so web pages cannot drive the player from the browser.
/// </summary>
public sealed class UiAutomationServer : IDisposable
{
    public const string EnableEnvironmentVariable = "WIRETUNE_UI_AUTOMATION";

    private readonly Window _window;
    private readonly MainViewModel _vm;
    private readonly HttpListener _listener = new();
    private readonly CancellationTokenSource _cts = new();
    private bool _isDisposed;

    public int Port { get; }

    public static bool IsEnabled => Environment.GetEnvironmentVariable(EnableEnvironmentVariable) == "1";

    public UiAutomationServer(Window window, MainViewModel vm, int port = 5201)
    {
        _window = window;
        _vm = vm;
        Port = port;
    }

    public void Start()
    {
        try
        {
            _listener.Prefixes.Add($"http://127.0.0.1:{Port}/");
            _listener.Start();
            _ = Task.Run(ListenLoop);
            WiretuneLog.Info("UiAutomation", $"UI automation server started on http://127.0.0.1:{Port}/");
        }
        catch (Exception ex)
        {
            WiretuneLog.Warn("UiAutomation", $"Could not start UI automation server on port {Port}: {ex.Message}");
        }
    }

    private async Task ListenLoop()
    {
        while (!_cts.IsCancellationRequested && _listener.IsListening)
        {
            try
            {
                var context = await _listener.GetContextAsync();
                _ = Task.Run(() => HandleRequest(context));
            }
            catch (Exception ex) when (ex is HttpListenerException or ObjectDisposedException)
            {
                break;
            }
            catch (Exception ex)
            {
                WiretuneLog.Error("UiAutomation", $"Listener error: {ex.Message}", ex);
            }
        }
    }

    private async Task HandleRequest(HttpListenerContext context)
    {
        var req = context.Request;
        var resp = context.Response;
        resp.ContentType = "application/json; charset=utf-8";

        // Reject browser-originated requests outright. Origin covers fetch/XHR; Sec-Fetch-Site also covers plain
        // <img>/<a> requests, which carry no Origin but would otherwise let a web page trigger these GET actions.
        if (!string.IsNullOrEmpty(req.Headers["Origin"]) ||
            req.Headers["Sec-Fetch-Site"] is { Length: > 0 } fetchSite && fetchSite != "none")
        {
            await WriteJson(resp, 403, new { Error = "Cross-origin requests are not allowed." });
            return;
        }

        // DNS rebinding: a web page whose name resolves to 127.0.0.1 reaches this port with a foreign Host header.
        if (req.UserHostName != $"127.0.0.1:{Port}" && req.UserHostName != $"localhost:{Port}")
        {
            await WriteJson(resp, 403, new { Error = "Unexpected Host header." });
            return;
        }

        try
        {
            var path = req.Url?.AbsolutePath.ToLowerInvariant() ?? "";
            var query = req.QueryString;

            switch (path)
            {
                case "/api/ui/state":
                    await WriteJson(resp, 200, await Dispatcher.UIThread.InvokeAsync(() => new
                    {
                        Section = _vm.SelectedSection.ToString(),
                        _vm.SearchQuery,
                        _vm.StatusText,
                        _vm.IsLoginViewActive,
                        ServerState = _vm.Session.State.ToString(),
                        ServerMessage = _vm.Session.StatusMessage,
                        PlaybackState = _vm.AudioEngine.State.ToString(),
                        PlayerError = _vm.Player.ErrorMessage,
                        CurrentTrack = _vm.AudioEngine.CurrentTrack is { } t ? new { t.Id, t.Title, t.Artist, t.Album, t.IsFavorite } : null,
                        CurrentPositionSeconds = _vm.AudioEngine.CurrentPosition.TotalSeconds,
                        _vm.AudioEngine.Volume,
                        _vm.AudioEngine.IsMuted,
                        _vm.AudioEngine.IsBitperfect,
                        IsExclusive = _vm.AudioEngine.IsExclusiveMode,
                        RepeatMode = _vm.Player.RepeatMode.ToString(),
                        _vm.Player.IsShuffle,
                        TracksCount = _vm.Library.Tracks.Count,
                        AlbumsCount = _vm.Library.Albums.Count,
                        ArtistsCount = _vm.Library.Artists.Count,
                        PlaylistsCount = _vm.Library.Playlists.Count,
                        FavoritesCount = _vm.Library.Favorites.Count,
                        CachedCovers = CoverArtService.CachedCount
                    }));
                    break;

                case "/api/ui/navigate" when Enum.TryParse<AppSection>(query["section"], ignoreCase: true, out var section) && Enum.IsDefined(section):
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.NavigateToCommand.Execute(section));
                    await WriteJson(resp, 200, new { Success = true, Section = section.ToString() });
                    break;

                case "/api/ui/screenshot":
                {
                    // Only a file name is accepted; screenshots always go to the temp directory.
                    var fileName = Path.GetFileName(query["name"] ?? "wiretune_ui_screenshot.png");
                    if (!fileName.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) fileName += ".png";
                    var savePath = Path.Combine(Path.GetTempPath(), fileName);
                    await Dispatcher.UIThread.InvokeAsync(() =>
                    {
                        var size = new PixelSize((int)Math.Max(300, _window.Bounds.Width), (int)Math.Max(300, _window.Bounds.Height));
                        using var rtb = new RenderTargetBitmap(size, new Vector(96, 96));
                        rtb.Render(_window);
                        rtb.Save(savePath);
                    });
                    await WriteJson(resp, 200, new { Success = true, Path = savePath });
                    break;
                }

                case "/api/ui/resize" when int.TryParse(query["width"], out var w) && int.TryParse(query["height"], out var h):
                    await Dispatcher.UIThread.InvokeAsync(() =>
                    {
                        _window.WindowState = WindowState.Normal;
                        _window.Width = w;
                        _window.Height = h;
                    });
                    await WriteJson(resp, 200, new { Success = true });
                    break;

                case "/api/ui/search":
                {
                    var q = query["q"] ?? "";
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.SearchQuery = q);
                    await WriteJson(resp, 200, new { Success = true, Query = q });
                    break;
                }

                case "/api/ui/play-track":
                {
                    var id = query["id"];
                    var title = query["title"];
                    var track = _vm.Library.Tracks.FirstOrDefault(t =>
                        (!string.IsNullOrEmpty(id) && t.Id == id) ||
                        (!string.IsNullOrEmpty(title) && t.Title.Contains(title, StringComparison.OrdinalIgnoreCase)));
                    if (track == null)
                    {
                        await WriteJson(resp, 404, new { Error = "Track not found" });
                        break;
                    }

                    await Dispatcher.UIThread.InvokeAsync(() => _vm.Player.PlayQueue(new[] { track }, track));
                    await WriteJson(resp, 200, new { Success = true, track.Id, track.Title });
                    break;
                }

                case "/api/ui/connect" when query["url"] is { Length: > 0 } url:
                    await Dispatcher.UIThread.InvokeAsync(async () =>
                    {
                        _vm.ServerSettings.ServerUrl = url;
                        await _vm.ServerSettings.ConnectServerCommand.ExecuteAsync(null);
                    });
                    await WriteJson(resp, 200, new { Success = true, State = _vm.Session.State.ToString(), _vm.Session.StatusMessage });
                    break;

                case "/api/ui/login" when query["user"] is { Length: > 0 } user:
                {
                    var error = await Dispatcher.UIThread.InvokeAsync(async () =>
                    {
                        _vm.ServerSettings.Username = user;
                        _vm.ServerSettings.Password = query["password"] ?? string.Empty;
                        await _vm.ServerSettings.LoginCommand.ExecuteAsync(null);
                        return _vm.ServerSettings.HasAuthError ? _vm.ServerSettings.AuthErrorMessage : null;
                    });
                    await WriteJson(resp, 200, new { Success = error == null, Error = error, State = _vm.Session.State.ToString() });
                    break;
                }

                case "/api/ui/logout":
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.LogoutCommand.ExecuteAsync(null));
                    await WriteJson(resp, 200, new { Success = true, State = _vm.Session.State.ToString() });
                    break;

                case "/api/ui/continue-offline":
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.ContinueOfflineCommand.Execute(null));
                    await WriteJson(resp, 200, new { Success = true });
                    break;

                case "/api/ui/playlist/new":
                    await Dispatcher.UIThread.InvokeAsync(() =>
                    {
                        _vm.Playlists.OpenCreateDialogCommand.Execute(null);
                        _vm.Playlists.NewPlaylistName = query["name"] ?? string.Empty;
                    });
                    await WriteJson(resp, 200, new { Success = true });
                    break;

                case "/api/ui/playlist/create":
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.Playlists.CreatePlaylistCommand.ExecuteAsync(null));
                    await WriteJson(resp, 200, new { Success = true, Count = _vm.Library.Playlists.Count });
                    break;

                case "/api/ui/playlist/add-current":
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.AddToPlaylistCommand.Execute(_vm.Player.CurrentTrack));
                    await WriteJson(resp, 200, new { Success = true });
                    break;

                case "/api/ui/playlist/add-to" when query["name"] is { Length: > 0 } playlistName:
                    await Dispatcher.UIThread.InvokeAsync(() =>
                        _vm.Playlists.AddPendingTrackToCommand.ExecuteAsync(_vm.Library.Playlists.FirstOrDefault(p => p.Name == playlistName)));
                    await WriteJson(resp, 200, new { Success = true });
                    break;

                case "/api/ui/play-pause":
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.Player.TogglePlayPauseCommand.Execute(null));
                    await WriteJson(resp, 200, new { Success = true });
                    break;

                case "/api/ui/next":
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.Player.NextTrackCommand.Execute(null));
                    await WriteJson(resp, 200, new { Success = true });
                    break;

                case "/api/ui/prev":
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.Player.PreviousTrackCommand.Execute(null));
                    await WriteJson(resp, 200, new { Success = true });
                    break;

                case "/api/ui/seek" when double.TryParse(query["seconds"], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var sec):
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.AudioEngine.SeekAsync(TimeSpan.FromSeconds(sec)));
                    await WriteJson(resp, 200, new { Success = true, Seconds = sec });
                    break;

                case "/api/ui/volume" when double.TryParse(query["level"], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var vol):
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.Player.Volume = vol);
                    await WriteJson(resp, 200, new { Success = true, Volume = vol });
                    break;

                case "/api/ui/toggle-favorite" when query["trackid"] is { Length: > 0 } trackId:
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.Library.ToggleFavoriteAsync(trackId));
                    await WriteJson(resp, 200, new { Success = true, TrackId = trackId });
                    break;

                case "/api/ui/open-album" when query["title"] is { Length: > 0 } albumTitle:
                {
                    var album = _vm.Library.Albums.FirstOrDefault(a => a.Title.Contains(albumTitle, StringComparison.OrdinalIgnoreCase));
                    if (album == null)
                    {
                        await WriteJson(resp, 404, new { Error = "Album not found" });
                        break;
                    }
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.OpenAlbum(album));
                    await WriteJson(resp, 200, new { Success = true, album.Title });
                    break;
                }

                case "/api/ui/open-artist" when query["name"] is { Length: > 0 } artistName:
                {
                    var artist = _vm.Library.Artists.FirstOrDefault(a => a.Name.Contains(artistName, StringComparison.OrdinalIgnoreCase));
                    if (artist == null)
                    {
                        await WriteJson(resp, 404, new { Error = "Artist not found" });
                        break;
                    }
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.OpenArtist(artist));
                    await WriteJson(resp, 200, new { Success = true, artist.Name });
                    break;
                }

                default:
                    await WriteJson(resp, 404, new { Error = "Not found or invalid parameters", Path = path });
                    break;
            }
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("UiAutomation", $"Request handling error: {ex.Message}", ex);
            try { await WriteJson(resp, 500, new { Error = ex.Message }); } catch { }
        }
    }

    private static async Task WriteJson(HttpListenerResponse resp, int statusCode, object data)
    {
        resp.StatusCode = statusCode;
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true }));
        resp.ContentLength64 = bytes.Length;
        await resp.OutputStream.WriteAsync(bytes);
        resp.Close();
    }

    public void Dispose()
    {
        if (_isDisposed) return;
        _isDisposed = true;

        try { _cts.Cancel(); } catch { }
        try { _listener.Stop(); } catch { }
        try { _listener.Close(); } catch { }
        _cts.Dispose();
    }
}
#endif
