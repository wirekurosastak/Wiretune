using System.Buffers;
using System.Collections.Concurrent;
using System.Net.Http.Headers;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Wiretune.Core.Services;

namespace Wiretune.UI.Services;

/// <summary>
/// Loads cover art from local files or the Wiretune server, decoded at display size and kept in a bounded
/// LRU cache. Concurrent requests for the same image share one load.
/// <para>
/// A list asks for a cover for every row that scrolls into view and asks for another one as soon as the row is reused,
/// so most requests are out of date by the time they would start. A request that nobody is waiting for any more
/// (<see cref="LoadBitmap"/> returns a handle to give it up) is dropped before it downloads or decodes anything, and the
/// work that remains runs off the UI thread with the downloaded bytes in pooled buffers: a fast scroll through a large
/// library used to queue hundreds of full-size downloads and flood the heap with large arrays, which showed up as
/// long pauses in the middle of the scroll.
/// </para>
/// </summary>
public static class CoverArtService
{
    public const int MaxCachedBitmaps = 300;
    private const int MaxCoverBytes = 16 * 1024 * 1024;
    private static readonly TimeSpan FailureRetryDelay = TimeSpan.FromMinutes(2);
    private static readonly TimeSpan DownloadTimeout = TimeSpan.FromSeconds(15);

    // Covers are small images; a hostile or broken URL must not be able to make us buffer gigabytes (see MaxCoverBytes).
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    // Downloads mostly wait for the network, decoding uses the processor: they are limited separately.
    private static readonly SemaphoreSlim DownloadThrottle = new(6);
    private static readonly SemaphoreSlim DecodeThrottle = new(2);

    private static readonly object CacheLock = new();
    private static readonly Dictionary<string, LinkedListNode<KeyValuePair<string, Bitmap>>> CacheIndex = new();
    private static readonly LinkedList<KeyValuePair<string, Bitmap>> CacheOrder = new();
    private static readonly ConcurrentDictionary<string, DateTime> RecentFailures = new();

    // InFlight and Interest change together under PendingLock: the loads that are queued or running, and for each the
    // number of requesters that still want the result.
    private static readonly object PendingLock = new();
    private static readonly ConcurrentDictionary<string, Task<Bitmap?>> InFlight = new();
    private static readonly Dictionary<string, int> Interest = new();

    private static readonly IDisposable NoLoad = new PendingLoad(null);

    /// <summary>Bearer token sent with cover requests to <see cref="ServerUrl"/>. It is never sent anywhere else.</summary>
    public static string? AuthToken { get; set; }

    /// <summary>Base address of the Wiretune server whose covers may be requested with <see cref="AuthToken"/>.</summary>
    public static string? ServerUrl { get; set; }

    public static int CachedCount
    {
        get { lock (CacheLock) return CacheIndex.Count; }
    }

    public static Task<Bitmap?> GetBitmapAsync(string? pathOrUrl, int decodeWidth) =>
        Request(pathOrUrl, decodeWidth, out _);

    /// <summary>
    /// Loads a cover and invokes <paramref name="onLoaded"/> on the UI thread. Dispose the result to say that the cover
    /// is not needed any more (the view moved on to another one): the callback is then not invoked, and a load that has
    /// not started yet is dropped.
    /// </summary>
    public static IDisposable LoadBitmap(string? pathOrUrl, int decodeWidth, Action<Bitmap?> onLoaded)
    {
        var task = Request(pathOrUrl, decodeWidth, out var key);
        if (task.IsCompleted)
        {
            if (key != null) ReleaseInterest(key);
            onLoaded(task.Result);
            return NoLoad;
        }

        var load = new PendingLoad(key);
        task.ContinueWith(t => Dispatcher.UIThread.Post(() =>
        {
            if (!load.IsCancelled) onLoaded(t.Result);
        }), TaskScheduler.Default);
        return load;
    }

    /// <summary>
    /// Returns the cached cover, or the load that produces it (starting one when needed). <paramref name="key"/> is set
    /// when the caller was counted as a requester of a pending load.
    /// </summary>
    private static Task<Bitmap?> Request(string? pathOrUrl, int decodeWidth, out string? key)
    {
        key = null;
        if (string.IsNullOrWhiteSpace(pathOrUrl)) return Task.FromResult<Bitmap?>(null);

        var cacheKey = $"{decodeWidth}|{pathOrUrl}";
        if (TryGetCached(cacheKey, out var cached)) return Task.FromResult<Bitmap?>(cached);
        if (RecentFailures.TryGetValue(cacheKey, out var failedAt) && DateTime.UtcNow - failedAt < FailureRetryDelay)
        {
            return Task.FromResult<Bitmap?>(null);
        }

        lock (PendingLock)
        {
            // The load that was running when we looked may have finished since.
            if (TryGetCached(cacheKey, out cached)) return Task.FromResult<Bitmap?>(cached);

            Interest.TryGetValue(cacheKey, out var requesters);
            Interest[cacheKey] = requesters + 1;
            key = cacheKey;
            return InFlight.GetOrAdd(cacheKey, _ => Task.Run(() => LoadAsync(cacheKey, pathOrUrl, decodeWidth)));
        }
    }

    private static void ReleaseInterest(string key)
    {
        lock (PendingLock)
        {
            if (!Interest.TryGetValue(key, out var requesters)) return;
            if (requesters <= 1) Interest.Remove(key);
            else Interest[key] = requesters - 1;
        }
    }

    /// <summary>
    /// Drops a load that nobody wants any more. Decided under the lock that requests take, so a request that arrives
    /// right afterwards starts a new load instead of receiving the abandoned one.
    /// </summary>
    private static bool TryAbandon(string key)
    {
        lock (PendingLock)
        {
            if (Interest.ContainsKey(key)) return false;
            InFlight.TryRemove(key, out _);
            return true;
        }
    }

    private static async Task<Bitmap?> LoadAsync(string key, string pathOrUrl, int decodeWidth)
    {
        var abandoned = false;
        try
        {
            if (TryAbandon(key))
            {
                abandoned = true;
                return null;
            }

            Stream? stream;
            await DownloadThrottle.WaitAsync().ConfigureAwait(false);
            try
            {
                if (TryAbandon(key))
                {
                    abandoned = true;
                    return null;
                }

                stream = await OpenAsync(pathOrUrl).ConfigureAwait(false);
            }
            finally
            {
                DownloadThrottle.Release();
            }

            await using (stream)
            {
                if (stream == null)
                {
                    RecentFailures[key] = DateTime.UtcNow;
                    return null;
                }

                await DecodeThrottle.WaitAsync().ConfigureAwait(false);
                try
                {
                    var bitmap = Bitmap.DecodeToWidth(stream, decodeWidth, BitmapInterpolationMode.MediumQuality);
                    AddToCache(key, bitmap);
                    RecentFailures.TryRemove(key, out _);
                    return bitmap;
                }
                finally
                {
                    DecodeThrottle.Release();
                }
            }
        }
        catch (Exception ex)
        {
            WiretuneLog.Debug("CoverArt", $"Cover load failed for '{pathOrUrl}': {ex.Message}");
            RecentFailures[key] = DateTime.UtcNow;
            return null;
        }
        finally
        {
            // An abandoned load was already removed, and a newer load of the same cover may own the entries by now.
            if (!abandoned)
            {
                lock (PendingLock)
                {
                    Interest.Remove(key);
                    InFlight.TryRemove(key, out _);
                }
            }
        }
    }

    private static async Task<Stream?> OpenAsync(string pathOrUrl)
    {
        if (pathOrUrl.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
            pathOrUrl.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, pathOrUrl);
            // Artist pictures come from third-party hosts: only our own server ever sees the credentials.
            if (!string.IsNullOrEmpty(AuthToken) && IsServerUrl(pathOrUrl))
            {
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", AuthToken);
            }

            using var timeout = new CancellationTokenSource(DownloadTimeout);
            using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token)
                .ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return null;
            if (response.Content.Headers.ContentLength is > MaxCoverBytes) return null;

            await using var body = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            return await ReadPooledAsync(body, response.Content.Headers.ContentLength, timeout.Token).ConfigureAwait(false);
        }

        return File.Exists(pathOrUrl) ? File.OpenRead(pathOrUrl) : null;
    }

    /// <summary>Reads a download into a pooled buffer (returned to the pool when the stream is disposed).</summary>
    private static async Task<Stream?> ReadPooledAsync(Stream body, long? contentLength, CancellationToken ct)
    {
        var size = (int)Math.Clamp(contentLength ?? 256 * 1024, 16 * 1024, MaxCoverBytes);
        var buffer = ArrayPool<byte>.Shared.Rent(size);
        var count = 0;
        try
        {
            while (true)
            {
                if (count == buffer.Length)
                {
                    if (buffer.Length >= MaxCoverBytes)
                    {
                        ArrayPool<byte>.Shared.Return(buffer);
                        return null;
                    }

                    var bigger = ArrayPool<byte>.Shared.Rent(Math.Min(buffer.Length * 2, MaxCoverBytes));
                    Buffer.BlockCopy(buffer, 0, bigger, 0, count);
                    ArrayPool<byte>.Shared.Return(buffer);
                    buffer = bigger;
                }

                var read = await body.ReadAsync(buffer.AsMemory(count), ct).ConfigureAwait(false);
                if (read == 0) break;
                count += read;
            }
        }
        catch
        {
            ArrayPool<byte>.Shared.Return(buffer);
            throw;
        }

        if (count == 0)
        {
            ArrayPool<byte>.Shared.Return(buffer);
            return null;
        }

        return new PooledStream(buffer, count);
    }

    private static bool IsServerUrl(string url) =>
        ServerUrl is { Length: > 0 } server &&
        url.StartsWith(server.TrimEnd('/') + "/", StringComparison.OrdinalIgnoreCase);

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

    /// <summary>The handle of a requested cover: disposing it withdraws the request.</summary>
    private sealed class PendingLoad : IDisposable
    {
        private string? _key;
        private int _cancelled;

        public PendingLoad(string? key) => _key = key;

        public bool IsCancelled => Volatile.Read(ref _cancelled) != 0;

        public void Dispose()
        {
            Interlocked.Exchange(ref _cancelled, 1);
            var key = Interlocked.Exchange(ref _key, null);
            if (key != null) ReleaseInterest(key);
        }
    }

    /// <summary>A read-only stream over a rented buffer, which goes back to the pool when the stream is disposed.</summary>
    private sealed class PooledStream : MemoryStream
    {
        private byte[]? _buffer;

        public PooledStream(byte[] buffer, int length) : base(buffer, 0, length, writable: false)
        {
            _buffer = buffer;
        }

        protected override void Dispose(bool disposing)
        {
            base.Dispose(disposing);
            var buffer = Interlocked.Exchange(ref _buffer, null);
            if (buffer != null) ArrayPool<byte>.Shared.Return(buffer);
        }
    }
}
