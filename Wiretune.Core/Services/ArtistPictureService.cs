using System.Collections.Concurrent;
using System.Text.Json;
using Wiretune.Core.Models;

namespace Wiretune.Core.Services;

/// <summary>
/// Fetches artist profile pictures from the internet (using Deezer's public artist API)
/// and caches results locally on disk and in memory.
/// </summary>
public static class ArtistPictureService
{
    private static readonly HttpClient Http = new()
    {
        Timeout = TimeSpan.FromSeconds(10)
    };

    private static readonly ConcurrentDictionary<string, string> Cache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<string, Task<string?>> InFlight = new(StringComparer.OrdinalIgnoreCase);
    private static readonly SemaphoreSlim BatchThrottle = new(2);
    private static readonly object FileLock = new();
    private static bool _isLoaded;

    static ArtistPictureService()
    {
        Http.DefaultRequestHeaders.UserAgent.ParseAdd("Wiretune/1.0 (Audiophile Music Player)");
        LoadCache();
    }

    /// <summary>
    /// Gets the cached or fetched artist picture URL. Returns null if not found or on error.
    /// </summary>
    public static async Task<string?> GetArtistPictureUrlAsync(string? artistName, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(artistName) ||
            string.Equals(artistName, "Unknown Artist", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        var normalized = artistName.Trim();

        // 1. Memory Cache
        if (Cache.TryGetValue(normalized, out var cached))
        {
            return string.IsNullOrEmpty(cached) ? null : cached;
        }

        // 2. In-flight coalescing
        return await InFlight.GetOrAdd(normalized, k => FetchFromInternetAsync(k, ct)).ConfigureAwait(false);
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

    private static async Task<string?> FetchFromInternetAsync(string artistName, CancellationToken ct)
    {
        try
        {
            var queryUrl = $"https://api.deezer.com/search/artist?q={Uri.EscapeDataString(artistName)}&limit=1";
            using var response = await Http.GetAsync(queryUrl, ct).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                Cache[artistName] = string.Empty;
                return null;
            }

            await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: ct).ConfigureAwait(false);

            if (doc.RootElement.TryGetProperty("data", out var data) &&
                data.ValueKind == JsonValueKind.Array &&
                data.GetArrayLength() > 0)
            {
                var first = data[0];
                string? picUrl = null;

                if (first.TryGetProperty("picture_medium", out var medium) && medium.ValueKind == JsonValueKind.String)
                {
                    picUrl = medium.GetString();
                }
                else if (first.TryGetProperty("picture_big", out var big) && big.ValueKind == JsonValueKind.String)
                {
                    picUrl = big.GetString();
                }
                else if (first.TryGetProperty("picture", out var pic) && pic.ValueKind == JsonValueKind.String)
                {
                    picUrl = pic.GetString();
                }

                if (!string.IsNullOrEmpty(picUrl))
                {
                    Cache[artistName] = picUrl;
                    SaveCache();
                    return picUrl;
                }
            }

            // Not found on Deezer: cache empty string to prevent repeated queries
            Cache[artistName] = string.Empty;
            SaveCache();
            return null;
        }
        catch (Exception ex)
        {
            WiretuneLog.Debug("ArtistPicture", $"Failed to fetch picture for '{artistName}': {ex.Message}");
            return null;
        }
        finally
        {
            InFlight.TryRemove(artistName, out _);
        }
    }

    private static string GetCacheFilePath() =>
        Path.Combine(AppPaths.GetDataDirectory(), "artist_pictures.json");

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
                var dict = new Dictionary<string, string>(Cache);
                var json = JsonSerializer.Serialize(dict, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(path, json);
            }
            catch (Exception ex)
            {
                WiretuneLog.Debug("ArtistPicture", $"Failed to save artist cache: {ex.Message}");
            }
        }
    }
}
