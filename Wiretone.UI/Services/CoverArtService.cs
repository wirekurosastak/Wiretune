using System.Collections.Concurrent;
using System.IO;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace Wiretone.UI.Services;

public static class CoverArtService
{
    private static readonly ConcurrentDictionary<string, Bitmap> _cache = new();
    private static readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(5) };

    public static async Task<Bitmap?> GetBitmapAsync(string? pathOrUrl)
    {
        if (string.IsNullOrWhiteSpace(pathOrUrl)) return null;

        if (_cache.TryGetValue(pathOrUrl, out var cached))
        {
            return cached;
        }

        return await Task.Run(() =>
        {
            try
            {
                if (pathOrUrl.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
                    pathOrUrl.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                {
                    var task = _httpClient.GetByteArrayAsync(pathOrUrl);
                    task.Wait(5000);
                    if (task.IsCompletedSuccessfully && task.Result != null && task.Result.Length > 0)
                    {
                        using var ms = new MemoryStream(task.Result);
                        var bmp = new Bitmap(ms);
                        _cache[pathOrUrl] = bmp;
                        return bmp;
                    }
                }
                else if (File.Exists(pathOrUrl))
                {
                    var ext = Path.GetExtension(pathOrUrl).ToLowerInvariant();
                    if (ext is ".flac" or ".mp3" or ".m4a" or ".ogg" or ".wav")
                    {
                        using var tagFile = TagLib.File.Create(pathOrUrl);
                        var pics = tagFile.Tag?.Pictures;
                        if (pics != null && pics.Length > 0 && pics[0]?.Data?.Data != null)
                        {
                            using var ms = new MemoryStream(pics[0].Data.Data);
                            var bmp = new Bitmap(ms);
                            _cache[pathOrUrl] = bmp;
                            return bmp;
                        }
                    }
                    else
                    {
                        var bmp = new Bitmap(pathOrUrl);
                        _cache[pathOrUrl] = bmp;
                        return bmp;
                    }
                }
            }
            catch
            {
                // Silently ignore decode / download errors
            }

            return null;
        });
    }

    public static void LoadBitmap(string? pathOrUrl, Action<Bitmap?> onLoaded)
    {
        if (string.IsNullOrWhiteSpace(pathOrUrl))
        {
            onLoaded(null);
            return;
        }

        if (_cache.TryGetValue(pathOrUrl, out var cached))
        {
            onLoaded(cached);
            return;
        }

        _ = Task.Run(async () =>
        {
            var bmp = await GetBitmapAsync(pathOrUrl);
            Dispatcher.UIThread.Post(() => onLoaded(bmp));
        });
    }
}
