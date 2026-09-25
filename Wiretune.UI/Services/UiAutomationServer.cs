using System.Net;
using System.Text;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;

namespace Wiretune.UI.Services;

public class UiAutomationServer : IDisposable
{
    private readonly Window _window;
    private readonly MainViewModel _vm;
    private readonly HttpListener _listener;
    private readonly CancellationTokenSource _cts = new();
    private Task? _listenerTask;

    public int Port { get; }

    public UiAutomationServer(Window window, MainViewModel vm, int port = 5201)
    {
        _window = window;
        _vm = vm;
        Port = port;
        _listener = new HttpListener();
    }

    public void Start()
    {
        try
        {
            _listener.Prefixes.Add($"http://127.0.0.1:{Port}/");
            _listener.Start();
            _listenerTask = Task.Run(ListenLoop);
            WiretuneLog.Info("UiAutomation", $"UI Automation Server started on http://127.0.0.1:{Port}/");
        }
        catch (Exception ex)
        {
            WiretuneLog.Warn("UiAutomation", $"Could not start UI Automation Server on port {Port}: {ex.Message}");
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
                if (!_cts.IsCancellationRequested && _listener.IsListening)
                {
                    WiretuneLog.Error("UiAutomation", $"Listener error: {ex.Message}", ex);
                }
            }
        }
    }

    private async Task HandleRequest(HttpListenerContext context)
    {
        var req = context.Request;
        var resp = context.Response;
        resp.Headers.Add("Access-Control-Allow-Origin", "*");
        resp.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
        resp.ContentType = "application/json; charset=utf-8";

        if (req.HttpMethod == "OPTIONS")
        {
            resp.StatusCode = 200;
            resp.Close();
            return;
        }

        try
        {
            var path = req.Url?.AbsolutePath.ToLowerInvariant() ?? "";
            var query = req.QueryString;

            switch (path)
            {
                case "/api/ui/state":
                {
                    var state = await Dispatcher.UIThread.InvokeAsync(() => new
                    {
                        NavigationIndex = _vm.SelectedNavigationIndex,
                        SearchQuery = _vm.SearchQuery,
                        StatusText = _vm.StatusText,
                        PlaybackState = _vm.AudioEngine.State.ToString(),
                        CurrentTrack = _vm.AudioEngine.CurrentTrack != null ? new
                        {
                            Id = _vm.AudioEngine.CurrentTrack.Id,
                            Title = _vm.AudioEngine.CurrentTrack.Title,
                            Artist = _vm.AudioEngine.CurrentTrack.Artist,
                            Album = _vm.AudioEngine.CurrentTrack.Album,
                            Duration = _vm.AudioEngine.CurrentTrack.FormattedDuration
                        } : null,
                        CurrentPositionSeconds = _vm.AudioEngine.CurrentPosition.TotalSeconds,
                        Volume = _vm.AudioEngine.Volume,
                        IsMuted = _vm.AudioEngine.IsMuted,
                        IsBitperfect = _vm.AudioEngine.IsBitperfect,
                        IsExclusive = _vm.AudioEngine.IsExclusiveMode,
                        RepeatMode = _vm.Player.RepeatMode.ToString(),
                        IsShuffle = _vm.Player.IsShuffle,
                        TracksCount = _vm.Library.Tracks.Count,
                        AlbumsCount = _vm.Library.Albums.Count,
                        ArtistsCount = _vm.Library.Artists.Count,
                        PlaylistsCount = _vm.Library.Playlists.Count,
                        FavoritesCount = _vm.Library.Favorites.Count
                    });

                    await WriteJson(resp, 200, state);
                    break;
                }

                case "/api/ui/navigate":
                {
                    var indexStr = query["index"];
                    if (int.TryParse(indexStr, out var idx))
                    {
                        await Dispatcher.UIThread.InvokeAsync(() => _vm.NavigateToCommand.Execute(idx));
                        WiretuneLog.Info("UiAutomation", $"Navigated to tab index {idx}");
                        await WriteJson(resp, 200, new { Success = true, SelectedIndex = idx });
                    }
                    else
                    {
                        await WriteJson(resp, 400, new { Error = "Invalid index" });
                    }
                    break;
                }

                case "/api/ui/screenshot":
                {
                    var savePath = query["path"] ?? Path.Combine(Path.GetTempPath(), "wiretune_ui_screenshot.png");
                    await Dispatcher.UIThread.InvokeAsync(() =>
                    {
                        var w = (int)Math.Max(300, _window.Bounds.Width);
                        var h = (int)Math.Max(300, _window.Bounds.Height);
                        var pixelSize = new PixelSize(w, h);
                        var dpi = new Vector(96, 96);
                        using var rtb = new RenderTargetBitmap(pixelSize, dpi);
                        rtb.Render(_window);
                        var dir = Path.GetDirectoryName(savePath);
                        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                        rtb.Save(savePath);
                    });

                    WiretuneLog.Info("UiAutomation", $"Saved UI screenshot to: {savePath}");
                    await WriteJson(resp, 200, new { Success = true, Path = savePath });
                    break;
                }

                case "/api/ui/search":
                {
                    var q = query["q"] ?? "";
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.SearchQuery = q);
                    WiretuneLog.Info("UiAutomation", $"Search query set to: '{q}'");
                    await WriteJson(resp, 200, new { Success = true, Query = q });
                    break;
                }

                case "/api/ui/play-track":
                {
                    var trackId = query["id"];
                    var artist = query["artist"];
                    var title = query["title"];

                    var track = _vm.Library.Tracks.FirstOrDefault(t =>
                        (!string.IsNullOrEmpty(trackId) && t.Id == trackId) ||
                        (!string.IsNullOrEmpty(title) && t.Title.Contains(title, StringComparison.OrdinalIgnoreCase) &&
                         (string.IsNullOrEmpty(artist) || t.Artist.Contains(artist, StringComparison.OrdinalIgnoreCase))));

                    if (track != null)
                    {
                        await Dispatcher.UIThread.InvokeAsync(async () =>
                        {
                            _vm.Player.PlayQueue(new[] { track }, track);
                            await _vm.AudioEngine.PlayTrackAsync(track);
                        });
                        WiretuneLog.Info("UiAutomation", $"Playing track: {track.Artist} - {track.Title}");
                        await WriteJson(resp, 200, new { Success = true, Track = track });
                    }
                    else
                    {
                        await WriteJson(resp, 404, new { Error = "Track not found" });
                    }
                    break;
                }

                case "/api/ui/play-pause":
                {
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.Player.TogglePlayPauseCommand.Execute(null));
                    WiretuneLog.Info("UiAutomation", "Play/Pause toggled");
                    await WriteJson(resp, 200, new { Success = true, State = _vm.AudioEngine.State.ToString() });
                    break;
                }

                case "/api/ui/next":
                {
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.Player.NextTrackCommand.Execute(null));
                    WiretuneLog.Info("UiAutomation", "Next track requested");
                    await WriteJson(resp, 200, new { Success = true });
                    break;
                }

                case "/api/ui/prev":
                {
                    await Dispatcher.UIThread.InvokeAsync(() => _vm.Player.PreviousTrackCommand.Execute(null));
                    WiretuneLog.Info("UiAutomation", "Previous track requested");
                    await WriteJson(resp, 200, new { Success = true });
                    break;
                }

                case "/api/ui/seek":
                {
                    if (double.TryParse(query["seconds"], out var sec))
                    {
                        await Dispatcher.UIThread.InvokeAsync(async () =>
                            await _vm.AudioEngine.SeekAsync(TimeSpan.FromSeconds(sec)));
                        WiretuneLog.Info("UiAutomation", $"Seeked to {sec:F1}s");
                        await WriteJson(resp, 200, new { Success = true, Seconds = sec });
                    }
                    else
                    {
                        await WriteJson(resp, 400, new { Error = "Invalid seconds parameter" });
                    }
                    break;
                }

                case "/api/ui/volume":
                {
                    if (double.TryParse(query["level"], out var vol))
                    {
                        await Dispatcher.UIThread.InvokeAsync(() => _vm.Player.Volume = vol);
                        WiretuneLog.Info("UiAutomation", $"Volume set to {vol:P0}");
                        await WriteJson(resp, 200, new { Success = true, Volume = vol });
                    }
                    else
                    {
                        await WriteJson(resp, 400, new { Error = "Invalid level parameter" });
                    }
                    break;
                }

                case "/api/ui/bitperfect":
                {
                    if (bool.TryParse(query["enabled"], out var bp))
                    {
                        await Dispatcher.UIThread.InvokeAsync(async () =>
                            await _vm.AudioEngine.SetBitperfectModeAsync(bp));
                        WiretuneLog.Info("UiAutomation", $"Bitperfect set to: {bp}");
                        await WriteJson(resp, 200, new { Success = true, IsBitperfect = bp });
                    }
                    else
                    {
                        await WriteJson(resp, 400, new { Error = "Invalid enabled parameter" });
                    }
                    break;
                }

                case "/api/ui/exclusive":
                {
                    if (bool.TryParse(query["enabled"], out var exc))
                    {
                        await Dispatcher.UIThread.InvokeAsync(async () =>
                            await _vm.AudioEngine.SetExclusiveModeAsync(exc));
                        WiretuneLog.Info("UiAutomation", $"Exclusive set to: {exc}");
                        await WriteJson(resp, 200, new { Success = true, IsExclusive = exc });
                    }
                    else
                    {
                        await WriteJson(resp, 400, new { Error = "Invalid enabled parameter" });
                    }
                    break;
                }

                case "/api/ui/open-album":
                {
                    var title = query["title"];
                    var album = _vm.Library.Albums.FirstOrDefault(a =>
                        !string.IsNullOrEmpty(title) && a.Title.Contains(title, StringComparison.OrdinalIgnoreCase));
                    if (album != null)
                    {
                        await Dispatcher.UIThread.InvokeAsync(() => _vm.OpenAlbum(album));
                        WiretuneLog.Info("UiAutomation", $"Opened album: {album.Title}");
                        await WriteJson(resp, 200, new { Success = true, Album = album });
                    }
                    else
                    {
                        await WriteJson(resp, 404, new { Error = "Album not found" });
                    }
                    break;
                }

                case "/api/ui/open-artist":
                {
                    var name = query["name"];
                    var artist = _vm.Library.Artists.FirstOrDefault(a =>
                        !string.IsNullOrEmpty(name) && a.Name.Contains(name, StringComparison.OrdinalIgnoreCase));
                    if (artist != null)
                    {
                        await Dispatcher.UIThread.InvokeAsync(() => _vm.OpenArtist(artist));
                        WiretuneLog.Info("UiAutomation", $"Opened artist: {artist.Name}");
                        await WriteJson(resp, 200, new { Success = true, Artist = artist });
                    }
                    else
                    {
                        await WriteJson(resp, 404, new { Error = "Artist not found" });
                    }
                    break;
                }

                case "/api/ui/toggle-favorite":
                {
                    var trackId = query["trackid"];
                    if (!string.IsNullOrEmpty(trackId))
                    {
                        await Dispatcher.UIThread.InvokeAsync(async () =>
                            await _vm.Library.ToggleFavoriteAsync(trackId));
                        WiretuneLog.Info("UiAutomation", $"Toggled favorite for track: {trackId}");
                        await WriteJson(resp, 200, new { Success = true, TrackId = trackId });
                    }
                    else
                    {
                        await WriteJson(resp, 400, new { Error = "Missing trackId" });
                    }
                    break;
                }

                default:
                    await WriteJson(resp, 404, new { Error = "Not found", Path = path });
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
        var json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true });
        var bytes = Encoding.UTF8.GetBytes(json);
        resp.ContentLength64 = bytes.Length;
        await resp.OutputStream.WriteAsync(bytes);
        resp.Close();
    }

    private bool _isDisposed = false;

    public void Dispose()
    {
        if (_isDisposed) return;
        _isDisposed = true;

        try { _cts.Cancel(); } catch { }
        try { _listener.Stop(); } catch { }
        try { _listener.Close(); } catch { }
        try { _cts.Dispose(); } catch { }
    }
}
