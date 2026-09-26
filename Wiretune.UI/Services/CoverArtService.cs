using System.Collections.Concurrent;
using System.Net.Http.Headers;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Wiretune.Core.Services;

namespace Wiretune.UI.Services;

/// <summary>
/// Loads cover art from local files or the Wiretune server, decoded at display size and kept in a bounded
/// LRU cache. Concurrent requests for the same image share one load.
/// </summary>
public static class CoverArtService
{
    public const int MaxCachedBitmaps = 300;
    private static readonly TimeSpan FailureRetryDelay = TimeSpan.FromMinutes(2);

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };
    private static readonly SemaphoreSlim DecodeThrottle = new(4);
    private static readonly object CacheLock = new();
    private static readonly Dictionary<string, LinkedListNode<KeyValuePair<string, Bitmap>>> CacheIndex = new();
    private static readonly LinkedList<KeyValuePair<string, Bitmap>> CacheOrder = new();
    private static readonly ConcurrentDictionary<string, Task<Bitmap?>> InFlight = new();
    private static readonly ConcurrentDictionary<string, DateTime> RecentFailures = new();

    /// <summary>Bearer token sent with server cover requests.</summary>
    public static string? AuthToken { get; set; }

    public static int CachedCount
    {
        get { lock (CacheLock) return CacheIndex.Count; }
    }

    public static Task<Bitmap?> GetBitmapAsync(string? pathOrUrl, int decodeWidth)
    {
        if (string.IsNullOrWhiteSpace(pathOrUrl)) return Task.FromResult<Bitmap?>(null);

        var key = $"{decodeWidth}|{pathOrUrl}";
        if (TryGetCached(key, out var cached)) return Task.FromResult<Bitmap?>(cached);
        if (RecentFailures.TryGetValue(key, out var failedAt) && DateTime.UtcNow - failedAt < FailureRetryDelay)
        {
            return Task.FromResult<Bitmap?>(null);
        }

        return InFlight.GetOrAdd(key, k => LoadAsync(k, pathOrUrl, decodeWidth));
    }

    /// <summary>Loads a cover and invokes <paramref name="onLoaded"/> on the UI thread.</summary>
    public static void LoadBitmap(string? pathOrUrl, int decodeWidth, Action<Bitmap?> onLoaded)
    {
        var task = GetBitmapAsync(pathOrUrl, decodeWidth);
        if (task.IsCompleted)
        {
            onLoaded(task.Result);
            return;
        }

        task.ContinueWith(t => Dispatcher.UIThread.Post(() => onLoaded(t.Result)), TaskScheduler.Default);
    }

    private static async Task<Bitmap?> LoadAsync(string key, string pathOrUrl, int decodeWidth)
    {
        await DecodeThrottle.WaitAsync().ConfigureAwait(false);
        try
        {
            await using var stream = await OpenAsync(pathOrUrl).ConfigureAwait(false);
            if (stream == null)
            {
                RecentFailures[key] = DateTime.UtcNow;
                return null;
            }

            var bitmap = Bitmap.DecodeToWidth(stream, decodeWidth, BitmapInterpolationMode.MediumQuality);
            AddToCache(key, bitmap);
            RecentFailures.TryRemove(key, out _);
            return bitmap;
        }
        catch (Exception ex)
        {
            WiretuneLog.Debug("CoverArt", $"Cover load failed for '{pathOrUrl}': {ex.Message}");
            RecentFailures[key] = DateTime.UtcNow;
            return null;
        }
        finally
        {
            DecodeThrottle.Release();
            InFlight.TryRemove(key, out _);
        }
    }

    private static async Task<Stream?> OpenAsync(string pathOrUrl)
    {
        if (pathOrUrl.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
            pathOrUrl.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, pathOrUrl);
            if (!string.IsNullOrEmpty(AuthToken)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", AuthToken);

            using var response = await Http.SendAsync(request).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return null;
            var bytes = await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
            return bytes.Length > 0 ? new MemoryStream(bytes) : null;
        }

        return File.Exists(pathOrUrl) ? File.OpenRead(pathOrUrl) : null;
    }

    private static bool TryGetCached(string key, out Bitmap bitmap)
    {
        lock (CacheLock)
        {
            if (CacheIndex.TryGetValue(key, out var node))
            {
                CacheOrder.Remove(node);
                CacheOrder.AddFirst(node);
                bitmap = node.Value.Value;
                return true;
            }
        }

        bitmap = null!;
        return false;
    }

    private static void AddToCache(string key, Bitmap bitmap)
    {
        lock (CacheLock)
        {
            if (CacheIndex.TryGetValue(key, out var existing))
            {
                CacheOrder.Remove(existing);
                CacheIndex.Remove(key);
            }

            CacheIndex[key] = CacheOrder.AddFirst(new KeyValuePair<string, Bitmap>(key, bitmap));

            // Evicted bitmaps are not disposed: a view may still display them; the GC reclaims them once unused.
            while (CacheIndex.Count > MaxCachedBitmaps && CacheOrder.Last is { } oldest)
            {
                CacheOrder.RemoveLast();
                CacheIndex.Remove(oldest.Value.Key);
            }
        }
    }
}
