using System.Collections.Concurrent;
using System.Text.Json;
using Wiretune.Core.Models;

namespace Wiretune.Core.Services;

/// <summary>
/// Fetches artist profile pictures from the internet (using Deezer's public artist API)
/// and caches results locally on disk and in memory. Artist names are sent to api.deezer.com;
/// set <c>WIRETUNE_NO_ARTIST_PICTURES=1</c> to keep the library entirely offline.
/// </summary>
public static class ArtistPictureService
{
    public const string DisableEnvironmentVariable = "WIRETUNE_NO_ARTIST_PICTURES";

    /// <summary>After a network/server failure no further requests are made for this long (and nothing is cached).</summary>
    private static readonly TimeSpan FailureBackoff = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan SaveDelay = TimeSpan.FromSeconds(2);

    private static readonly ConcurrentDictionary<string, string> Cache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<string, Task<string?>> InFlight = new(StringComparer.OrdinalIgnoreCase);
    private static readonly SemaphoreSlim BatchThrottle = new(2);
    private static readonly object FileLock = new();
    private static readonly Timer SaveTimer = new(_ => SaveCache(), null, Timeout.Infinite, Timeout.Infinite);
    private static bool _isLoaded;
    private static long _retryAfterTicks;

    // Replaceable by tests (InternalsVisibleTo) so nothing needs the real network or the real profile folder.
    internal static HttpClient Http { get; set; } = CreateHttpClient();
    internal static string? CacheFileOverride { get; set; }

    static ArtistPictureService()
    {
        LoadCache();
    }

    private static HttpClient CreateHttpClient()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Wiretune/1.0 (Audiophile Music Player)");
        return http;
    }

    private static bool IsDisabled => Environment.GetEnvironmentVariable(DisableEnvironmentVariable) is { Length: > 0 } v && v != "0";

    internal static void ResetForTests()
    {
        Cache.Clear();
        InFlight.Clear();
        Interlocked.Exchange(ref _retryAfterTicks, 0);
    }

    internal static bool IsCached(string artistName) => Cache.ContainsKey(artistName.Trim());

    /// <summary>
    /// Gets the cached or fetched artist picture URL. Returns null if not found or on error.
    /// </summary>
    public static async Task<string?> GetArtistPictureUrlAsync(string? artistName, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(artistName) ||
            MetadataScanner.IsUnknownArtist(artistName))
        {
            return null;
        }

        var normalized = artistName.Trim();

        // 1. Memory Cache
        if (Cache.TryGetValue(normalized, out var cached))
        {
            return string.IsNullOrEmpty(cached) ? null : cached;
        }

        if (IsDisabled || DateTime.UtcNow.Ticks < Interlocked.Read(ref _retryAfterTicks)) return null;

        // 2. In-flight coalescing. The shared fetch must not depend on the first caller's token, so callers only
        // cancel their own wait.
        return await InFlight.GetOrAdd(normalized, k => FetchFromInternetAsync(k)).WaitAsync(ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Asynchronously resolves the picture for a single artist and sets PicturePath if found.
    /// </summary>
    public static void ResolveArtistPicture(Artist? artist)
    {
        if (artist == null || string.IsNullOrWhiteSpace(artist.Name)) return;
        if (!string.IsNullOrEmpty(artist.PicturePath) &&
            artist.PicturePath.StartsWith("http", StringComparison.OrdinalIgnoreCase))
        {
            return; // Already has an internet profile picture
        }

        _ = Task.Run(async () =>
        {
            try
            {
                var url = await GetArtistPictureUrlAsync(artist.Name).ConfigureAwait(false);
                if (!string.IsNullOrEmpty(url))
                {
                    artist.PicturePath = url;
                }
            }
            catch (Exception ex)
            {
                WiretuneLog.Debug("ArtistPicture", $"Error resolving picture for '{artist.Name}': {ex.Message}");
            }
        });
    }

    /// <summary>
    /// Background batch resolver that iterates through artists with rate limiting.
    /// </summary>
    public static void ResolveArtistPictures(IEnumerable<Artist> artists)
    {
        var list = artists.ToList();
        if (list.Count == 0) return;

        _ = Task.Run(async () =>
        {
            foreach (var artist in list)
            {
                if (string.IsNullOrWhiteSpace(artist.Name)) continue;
                if (!string.IsNullOrEmpty(artist.PicturePath) &&
                    artist.PicturePath.StartsWith("http", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                // If already in cache, apply immediately
                if (Cache.TryGetValue(artist.Name.Trim(), out var cached))
                {
                    if (!string.IsNullOrEmpty(cached))
                    {
                        artist.PicturePath = cached;
                    }
                    continue;
                }

                await BatchThrottle.WaitAsync().ConfigureAwait(false);
                try
                {
                    var url = await GetArtistPictureUrlAsync(artist.Name).ConfigureAwait(false);
                    if (!string.IsNullOrEmpty(url))
                    {
                        artist.PicturePath = url;
                    }

                    // Gentle delay between requests to be polite to the public API
                    await Task.Delay(80).ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    WiretuneLog.Debug("ArtistPicture", $"Batch error for '{artist.Name}': {ex.Message}");
                }
                finally
                {
                    BatchThrottle.Release();
                }
            }
        });
    }

    private static async Task<string?> FetchFromInternetAsync(string artistName)
    {
        try
        {
            var queryUrl = $"https://api.deezer.com/search/artist?q={Uri.EscapeDataString(artistName)}&limit=1";
            using var response = await Http.GetAsync(queryUrl).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                // Rate limiting or an outage says nothing about the artist: remember nothing, back off instead.
                BackOff($"Deezer answered HTTP {(int)response.StatusCode}");
                return null;
            }

            await using var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
            using var doc = await JsonDocument.ParseAsync(stream).ConfigureAwait(false);

            string? picUrl = null;
            if (doc.RootElement.TryGetProperty("data", out var data) &&
                data.ValueKind == JsonValueKind.Array &&
                data.GetArrayLength() > 0)
            {
                var first = data[0];
                foreach (var field in new[] { "picture_medium", "picture_big", "picture" })
                {
                    if (first.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.String &&
                        Uri.TryCreate(value.GetString(), UriKind.Absolute, out var uri) &&
                        uri.Scheme == Uri.UriSchemeHttps)
                    {
                        picUrl = uri.AbsoluteUri;
                        break;
                    }
                }
            }

            // A definitive answer, including "no such artist" (empty string), is cached so it is never asked again.
            Cache[artistName] = picUrl ?? string.Empty;
            SaveTimer.Change(SaveDelay, Timeout.InfiniteTimeSpan);
            return picUrl;
        }
        catch (Exception ex)
        {
            BackOff(ex.Message);
            return null;
        }
        finally
        {
            InFlight.TryRemove(artistName, out _);
        }
    }

    private static void BackOff(string reason)
    {
        Interlocked.Exchange(ref _retryAfterTicks, (DateTime.UtcNow + FailureBackoff).Ticks);
        WiretuneLog.Debug("ArtistPicture", $"Artist picture lookup failed ({reason}); pausing lookups for {FailureBackoff.TotalMinutes:0} minutes.");
    }

    private static string GetCacheFilePath() =>
        CacheFileOverride ?? Path.Combine(AppPaths.GetDataDirectory(), "artist_pictures.json");

    private static void LoadCache()
    {
        if (_isLoaded) return;
        lock (FileLock)
        {
            if (_isLoaded) return;
            try
            {
                var path = GetCacheFilePath();
                if (File.Exists(path))
                {
                    var json = File.ReadAllText(path);
                    var dict = JsonSerializer.Deserialize<Dictionary<string, string>>(json);
                    if (dict != null)
                    {
                        foreach (var kvp in dict)
                        {
                            Cache[kvp.Key] = kvp.Value;
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                WiretuneLog.Debug("ArtistPicture", $"Failed to load artist cache: {ex.Message}");
            }
            finally
            {
                _isLoaded = true;
            }
        }
    }

    private static void SaveCache()
    {
        lock (FileLock)
        {
            try
            {
                var path = GetCacheFilePath();
                var json = JsonSerializer.Serialize(new Dictionary<string, string>(Cache), new JsonSerializerOptions { WriteIndented = true });
                var temp = path + ".tmp";
                File.WriteAllText(temp, json);
                File.Move(temp, path, overwrite: true); // never leave a half-written cache behind
            }
            catch (Exception ex)
            {
                WiretuneLog.Debug("ArtistPicture", $"Failed to save artist cache: {ex.Message}");
            }
        }
    }
}
