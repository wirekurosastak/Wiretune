using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Wiretune.Core.Models;

namespace Wiretune.Core.Services;

/// <summary>
/// Looks the lyrics of a track up on the internet, for tracks that have none of their own, using LRCLIB
/// (lrclib.net: a free, open lyrics database that needs no account or API key). This device asks LRCLIB directly,
/// so it works for local files and for server tracks alike, and the server needs no internet access.
/// <para>
/// What leaves the device is the track's title, artist, album and length, nothing else. Answers are kept in a small
/// cache folder next to the library database (a found text for good, "nothing found" for a week), so a track is
/// looked up once, and the lyrics are there when the device is offline. The environment variable
/// <c>WIRETUNE_NO_ONLINE_LYRICS=1</c> switches the lookup off for the whole process, whatever the setting says.
/// </para>
/// </summary>
public sealed class OnlineLyrics : IDisposable
{
    /// <summary>The name shown as the source of lyrics found by this service.</summary>
    public const string SourceName = "LRCLIB";

    public const string DisableEnvironmentVariable = "WIRETUNE_NO_ONLINE_LYRICS";

    private static readonly Uri DefaultBaseAddress = new("https://lrclib.net/");
    private static readonly TimeSpan MissLifetime = TimeSpan.FromDays(7);

    private const int MaxResponseBytes = 1024 * 1024;
    private const int MaxLyricsLength = 100_000;

    /// <summary>A search result whose length differs from the track's by more than this is a different recording.</summary>
    private const double MaxDurationDifferenceSeconds = 5;

    private static readonly Regex LeadingTimestamps = new(@"^(?:\s*\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\])+\s*", RegexOptions.CultureInvariant);
    private static readonly Regex WordTimestamps = new(@"<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>\s?", RegexOptions.CultureInvariant);
    private static readonly Regex VersionNote = new(@"\([^)]*\)|\[[^\]]*\]", RegexOptions.CultureInvariant);
    private static readonly Regex MetadataLine = new(@"^\s*\[[A-Za-z]+:[^\]]*\]\s*$", RegexOptions.CultureInvariant);
    private static readonly string[] ArtistSeparators = { ";", " feat. ", " feat ", " ft. ", " ft ", " & ", " x ", ", " };

    private readonly HttpClient _http;
    private readonly bool _ownsClient;
    private readonly string? _cacheDirectory;
    private readonly Func<DateTime> _now;

    /// <param name="http">The client to send requests with; its base address must be the LRCLIB server. Null creates one.</param>
    /// <param name="cacheDirectory">Where answers are cached; null keeps no cache.</param>
    /// <param name="now">The clock (UTC), replaceable by tests.</param>
    public OnlineLyrics(HttpClient? http = null, string? cacheDirectory = null, Func<DateTime>? now = null)
    {
        _ownsClient = http == null;
        _http = http ?? CreateHttpClient();
        _cacheDirectory = cacheDirectory;
        _now = now ?? (() => DateTime.UtcNow);
    }

    /// <summary>The production service: a cache folder inside the Wiretune data directory.</summary>
    public static OnlineLyrics CreateDefault() => new(cacheDirectory: Path.Combine(AppPaths.GetDataDirectory(), "lyrics"));

    /// <summary>True unless the lookup was switched off for the whole process.</summary>
    public static bool IsAllowedByEnvironment =>
        !(Environment.GetEnvironmentVariable(DisableEnvironmentVariable) is { Length: > 0 } value && value != "0");

    private static HttpClient CreateHttpClient()
    {
        var http = new HttpClient { BaseAddress = DefaultBaseAddress, Timeout = TimeSpan.FromSeconds(12) };
        var version = typeof(OnlineLyrics).Assembly.GetName().Version?.ToString(3) ?? "1.0.0";
        // LRCLIB asks clients to say who they are.
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"Wiretune/{version} (audiophile music player)");
        http.DefaultRequestHeaders.Accept.ParseAdd("application/json");
        return http;
    }

    /// <summary>
    /// The lyrics of <paramref name="track"/> as plain text, or null when LRCLIB has none (or the track has too little
    /// tag data to look for). Throws when the service could not be reached or answered with an error, so the caller can
    /// tell "no lyrics exist" from "could not check"; such a failure is never cached.
    /// </summary>
    public async Task<string?> FindAsync(Track track, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(track);
        if (!IsAllowedByEnvironment) return null;

        var query = LyricsQuery.From(track);
        if (query == null) return null;

        var cached = await ReadCacheAsync(query, ct).ConfigureAwait(false);
        if (cached != null) return cached.Value.Text;

        var text = await FetchAsync(query, ct).ConfigureAwait(false);
        await WriteCacheAsync(query, text, ct).ConfigureAwait(false);
        return text;
    }

    public void Dispose()
    {
        if (_ownsClient) _http.Dispose();
    }

    // ── Network ──────────────────────────────────────────────────────────────────────────────────────

    private async Task<string?> FetchAsync(LyricsQuery query, CancellationToken ct)
    {
        // 1. The exact recording: LRCLIB matches title, artist, album and a length within a couple of seconds.
        if (query.Album != null && query.DurationSeconds > 0)
        {
            using var exact = await GetJsonAsync(
                $"api/get?artist_name={Escape(query.Artist)}&track_name={Escape(query.Title)}&album_name={Escape(query.Album)}&duration={query.DurationSeconds}",
                ct).ConfigureAwait(false);
            var text = exact == null ? null : TextOf(exact.RootElement);
            if (text != null) return text;
        }

        // 2. A search by title and artist, taking the result whose length is closest to the track's. The file's artist
        //    tag may name several artists, while LRCLIB lists the track under the first, so that is tried second.
        foreach (var artist in ArtistCandidates(query.Artist))
        {
            using var found = await GetJsonAsync($"api/search?track_name={Escape(query.Title)}&artist_name={Escape(artist)}", ct).ConfigureAwait(false);
            if (found == null) continue;

            var text = PickBest(found.RootElement, query.Title, artist, query.DurationSeconds);
            if (text != null) return text;
        }

        return null;
    }

    /// <summary>The parsed answer, or null when LRCLIB has nothing for the request (404). Throws for any other failure.</summary>
    private async Task<JsonDocument?> GetJsonAsync(string relativeUrl, CancellationToken ct)
    {
        var address = new Uri(_http.BaseAddress ?? DefaultBaseAddress, relativeUrl);
        using var response = await _http.GetAsync(address, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();

        var bytes = await ReadLimitedAsync(response.Content, ct).ConfigureAwait(false);
        return JsonDocument.Parse(bytes);
    }

    private static async Task<byte[]> ReadLimitedAsync(HttpContent content, CancellationToken ct)
    {
        if (content.Headers.ContentLength > MaxResponseBytes)
            throw new HttpRequestException("The lyrics service sent an unexpectedly large answer.");

        await using var stream = await content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var chunk = new byte[16 * 1024];
        int read;
        while ((read = await stream.ReadAsync(chunk, ct).ConfigureAwait(false)) > 0)
        {
            if (buffer.Length + read > MaxResponseBytes)
                throw new HttpRequestException("The lyrics service sent an unexpectedly large answer.");
            buffer.Write(chunk, 0, read);
        }
        return buffer.ToArray();
    }

    private static string Escape(string value) => Uri.EscapeDataString(value);

    // ── Reading an answer ────────────────────────────────────────────────────────────────────────────

    /// <summary>The lyrics in one LRCLIB record as plain text; null for an instrumental or a record without any text.</summary>
    internal static string? TextOf(JsonElement record)
    {
        if (record.ValueKind != JsonValueKind.Object) return null;
        if (record.TryGetProperty("instrumental", out var instrumental) && instrumental.ValueKind == JsonValueKind.True) return null;

        var plain = StringOf(record, "plainLyrics");
        if (!string.IsNullOrWhiteSpace(plain)) return Tidy(plain);

        // Some records only have the time-synced version; the timestamps are dropped to leave the text.
        var synced = StringOf(record, "syncedLyrics");
        return string.IsNullOrWhiteSpace(synced) ? null : Tidy(StripTimestamps(synced));
    }

    /// <summary>
    /// The lyrics of the search result that is the same song (similar title and artist) and closest in length to
    /// <paramref name="durationSeconds"/> (0 = unknown length: the first match with text). A search can return
    /// loosely related songs; showing the lyrics of a different song would be worse than showing none.
    /// </summary>
    internal static string? PickBest(JsonElement results, string title, string artist, int durationSeconds)
    {
        if (results.ValueKind != JsonValueKind.Array) return null;

        string? best = null;
        var bestDifference = double.MaxValue;
        var inspected = 0;
        foreach (var record in results.EnumerateArray())
        {
            if (++inspected > 50) break;
            if (record.ValueKind != JsonValueKind.Object) continue;
            if (!SimilarTitle(StringOf(record, "trackName"), title) || !SimilarArtist(StringOf(record, "artistName"), artist)) continue;

            var text = TextOf(record);
            if (text == null) continue;

            var difference = 0.0;
            if (durationSeconds > 0 && record.TryGetProperty("duration", out var length) && length.ValueKind == JsonValueKind.Number)
            {
                difference = Math.Abs(length.GetDouble() - durationSeconds);
                if (difference > MaxDurationDifferenceSeconds) continue;
            }

            if (difference < bestDifference)
            {
                best = text;
                bestDifference = difference;
            }
        }
        return best;
    }

    /// <summary>
    /// True when two titles are the same song: equal apart from case, spacing, punctuation and a version note such as
    /// "(Remastered 2011)", "[Live]" or "- Single Edit". A title that merely contains the other ("Another Song" for "Song") is not.
    /// </summary>
    internal static bool SimilarTitle(string? found, string wanted)
    {
        if (found == null) return true; // the record does not say, so it cannot be ruled out
        var a = Fold(found);
        var b = Fold(wanted);
        if (a.Length == 0 || b.Length == 0 || a == b) return true;

        var coreA = Fold(WithoutVersionNote(found));
        var coreB = Fold(WithoutVersionNote(wanted));
        return coreA.Length > 0 && coreA == coreB;
    }

    /// <summary>
    /// True when two artist names are the same act: equal apart from case and punctuation, or one names more artists than
    /// the other ("Artist feat. Guest" and "Artist"). A name of one or two letters is only ever equal to itself.
    /// </summary>
    internal static bool SimilarArtist(string? found, string wanted)
    {
        if (found == null) return true;
        var a = Fold(found);
        var b = Fold(wanted);
        if (a.Length == 0 || b.Length == 0 || a == b) return true;
        return Math.Min(a.Length, b.Length) >= 3 && (a.Contains(b, StringComparison.Ordinal) || b.Contains(a, StringComparison.Ordinal));
    }

    private static string WithoutVersionNote(string title)
    {
        var plain = VersionNote.Replace(title, string.Empty);
        var dash = plain.IndexOf(" - ", StringComparison.Ordinal);
        return dash > 0 ? plain[..dash] : plain;
    }

    private static string Fold(string text) =>
        new(text.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());

    /// <summary>Removes the <c>[01:23.45]</c> time tags of an LRC text, and its <c>[ar:Artist]</c>-style header lines.</summary>
    internal static string StripTimestamps(string lrc)
    {
        var lines = lrc.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        var kept = new List<string>(lines.Length);
        foreach (var line in lines)
        {
            if (MetadataLine.IsMatch(line)) continue;

            var text = LeadingTimestamps.Replace(line, string.Empty);
            kept.Add(WordTimestamps.Replace(text, string.Empty).TrimEnd());
        }
        return string.Join('\n', kept);
    }

    private static string Tidy(string text)
    {
        var tidy = text.Replace("\r\n", "\n").Replace('\r', '\n').Trim();
        return tidy.Length > MaxLyricsLength ? tidy[..MaxLyricsLength] : tidy;
    }

    private static string? StringOf(JsonElement record, string name) =>
        record.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    /// <summary>The artist as tagged, then (when the tag names several artists) the first of them.</summary>
    internal static IEnumerable<string> ArtistCandidates(string artist)
    {
        yield return artist;

        var first = artist;
        foreach (var separator in ArtistSeparators)
        {
            var at = first.IndexOf(separator, StringComparison.OrdinalIgnoreCase);
            if (at > 0) first = first[..at];
        }
        first = first.Trim();
        if (first.Length > 0 && !string.Equals(first, artist, StringComparison.OrdinalIgnoreCase)) yield return first;
    }

    // ── Cache ────────────────────────────────────────────────────────────────────────────────────────

    private string? CachePathFor(LyricsQuery query) =>
        _cacheDirectory == null ? null : Path.Combine(_cacheDirectory, query.CacheKey + ".json");

    /// <summary>The cached answer (whose text is null for a cached "nothing found"), or null when there is no usable entry.</summary>
    private async Task<(string? Text, bool Found)?> ReadCacheAsync(LyricsQuery query, CancellationToken ct)
    {
        var path = CachePathFor(query);
        if (path == null || !File.Exists(path)) return null;

        try
        {
            await using var stream = File.OpenRead(path);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: ct).ConfigureAwait(false);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;

            var text = StringOf(root, "text");
            if (text == null)
            {
                // "Nothing found" is only believed for a while: LRCLIB's collection keeps growing.
                var fetched = root.TryGetProperty("fetchedUtc", out var stamp) && stamp.TryGetDateTime(out var parsed) ? parsed.ToUniversalTime() : DateTime.MinValue;
                if (_now() - fetched > MissLifetime) return null;
            }
            return (text, true);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            WiretuneLog.Debug("OnlineLyrics", $"Ignoring an unreadable cache entry: {ex.Message}");
            return null;
        }
    }

    private async Task WriteCacheAsync(LyricsQuery query, string? text, CancellationToken ct)
    {
        var path = CachePathFor(query);
        if (path == null) return;

        try
        {
            Directory.CreateDirectory(_cacheDirectory!);
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            await using (var stream = File.Create(temporary))
            await using (var writer = new Utf8JsonWriter(stream))
            {
                writer.WriteStartObject();
                writer.WriteString("fetchedUtc", _now());
                if (text == null) writer.WriteNull("text");
                else writer.WriteString("text", text);
                writer.WriteEndObject();
            }
            File.Move(temporary, path, overwrite: true);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // The cache is an optimisation: lyrics that could not be saved are simply looked up again next time.
            WiretuneLog.Debug("OnlineLyrics", $"Could not cache lyrics: {ex.Message}");
        }
    }

    // ── What is asked for ────────────────────────────────────────────────────────────────────────────

    /// <summary>The identifying tags of a track, cleaned up; null for a track that is too anonymous to look up.</summary>
    internal sealed record LyricsQuery(string Title, string Artist, string? Album, int DurationSeconds)
    {
        internal static LyricsQuery? From(Track track)
        {
            var title = Clean(track.Title);
            var artist = Clean(track.Artist);
            if (title == null || artist == null) return null;
            if (MetadataScanner.IsUnknownArtist(artist) || string.Equals(artist, "Unknown Artist", StringComparison.OrdinalIgnoreCase)) return null;
            if (string.Equals(title, "Unknown Title", StringComparison.OrdinalIgnoreCase)) return null;

            var album = Clean(track.Album);
            if (album != null && (string.Equals(album, MetadataScanner.UnknownAlbum, StringComparison.OrdinalIgnoreCase)
                                  || string.Equals(album, "Unknown Album", StringComparison.OrdinalIgnoreCase)))
            {
                album = null;
            }

            return new LyricsQuery(title, artist, album, (int)Math.Round(track.Duration.TotalSeconds));
        }

        /// <summary>A stable file name for this track's cache entry (a hash, so no tag text ends up in a path).</summary>
        internal string CacheKey
        {
            get
            {
                var identity = $"{Artist.ToLowerInvariant()}\n{Title.ToLowerInvariant()}\n{Album?.ToLowerInvariant()}\n{DurationSeconds}";
                return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity)))[..32].ToLowerInvariant();
            }
        }

        private static string? Clean(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }
}
