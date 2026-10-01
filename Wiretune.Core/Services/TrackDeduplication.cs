using System.Text;
using System.Text.RegularExpressions;
using Wiretune.Core.Models;

namespace Wiretune.Core.Services;

/// <summary>
/// Handles track deduplication and merging between local files and remote server tracks.
/// When duplicate tracks exist across local and server libraries, local tracks are always
/// preferred to avoid network dependencies and preserve offline playback.
/// </summary>
public static class TrackDeduplication
{
    /// <summary>
    /// Merges local tracks and server tracks into a single unified list.
    /// When duplicates are detected between a local track and a server track,
    /// the local track is preferred. User metadata (favorite status, play counts,
    /// last played, cover art) from the server duplicate is merged into the local track.
    /// </summary>
    /// <param name="localTracks">The list of local tracks.</param>
    /// <param name="serverTracks">The list of server tracks.</param>
    /// <param name="aliasedTrackIds">Maps replaced server track IDs to the preferred local track IDs.</param>
    /// <returns>A merged list containing all local tracks and non-duplicate server tracks.</returns>
    public static List<Track> MergeTracks(
        IEnumerable<Track> localTracks,
        IEnumerable<Track> serverTracks,
        out Dictionary<string, string> aliasedTrackIds)
    {
        aliasedTrackIds = new Dictionary<string, string>(StringComparer.Ordinal);
        var locals = localTracks.ToList();
        var servers = serverTracks.ToList();

        if (locals.Count == 0) return servers;
        if (servers.Count == 0) return locals;

        var result = new List<Track>(locals);

        // Group local tracks by normalized title and artist for fast O(1) candidate lookup
        var localByTitleArtist = locals
            .GroupBy(t => $"{CleanTitle(t.Title)}|{CleanArtist(t.Artist)}", StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        foreach (var serverTrack in servers)
        {
            var key = $"{CleanTitle(serverTrack.Title)}|{CleanArtist(serverTrack.Artist)}";
            Track? duplicateLocal = null;

            if (localByTitleArtist.TryGetValue(key, out var candidates))
            {
                duplicateLocal = candidates.FirstOrDefault(l => IsDuplicate(l, serverTrack));
            }

            if (duplicateLocal != null)
            {
                // Local track is preferred! Merge metadata from server into local track
                MergeMetadataIntoLocal(duplicateLocal, serverTrack);
                aliasedTrackIds[serverTrack.Id] = duplicateLocal.Id;
            }
            else
            {
                result.Add(serverTrack);
            }
        }

        return result;
    }

    /// <summary>
    /// Determines whether a local track and a server track represent the same song.
    /// </summary>
    public static bool IsDuplicate(Track local, Track server)
    {
        if (local == null || server == null) return false;

        var localTitle = CleanTitle(local.Title);
        var serverTitle = CleanTitle(server.Title);
        if (string.IsNullOrEmpty(localTitle) || string.IsNullOrEmpty(serverTitle)) return false;
        if (!string.Equals(localTitle, serverTitle, StringComparison.OrdinalIgnoreCase)) return false;

        var localArtist = CleanArtist(local.Artist);
        var serverArtist = CleanArtist(server.Artist);
        if (string.IsNullOrEmpty(localArtist) || string.IsNullOrEmpty(serverArtist)) return false;
        if (!string.Equals(localArtist, serverArtist, StringComparison.OrdinalIgnoreCase)) return false;

        // Both title and artist match.
        bool hasLocalDuration = local.Duration > TimeSpan.Zero;
        bool hasServerDuration = server.Duration > TimeSpan.Zero;

        if (hasLocalDuration && hasServerDuration)
        {
            var diff = Math.Abs((local.Duration - server.Duration).TotalSeconds);
            // If albums match, allow up to 5 seconds difference
            if (AlbumsMatch(local.Album, server.Album))
            {
                return diff <= 5.0;
            }
            // If albums differ (e.g. Greatest Hits compilation vs Studio Album), only consider duplicate if duration is very close (within 3.5 seconds)
            return diff <= 3.5;
        }

        // If at least one duration is missing/zero, rely on album matching
        return AlbumsMatch(local.Album, server.Album);
    }

    /// <summary>
    /// Merges metadata from the server track onto the preferred local track.
    /// </summary>
    public static void MergeMetadataIntoLocal(Track localTrack, Track serverTrack)
    {
        if (serverTrack.IsFavorite) localTrack.IsFavorite = true;
        localTrack.PlayCount = Math.Max(localTrack.PlayCount, serverTrack.PlayCount);
        if (serverTrack.LastPlayed.HasValue && (localTrack.LastPlayed == null || serverTrack.LastPlayed > localTrack.LastPlayed))
        {
            localTrack.LastPlayed = serverTrack.LastPlayed;
        }
        if (!localTrack.HasCoverArt && serverTrack.HasCoverArt && !string.IsNullOrEmpty(serverTrack.CoverArtPath))
        {
            localTrack.HasCoverArt = true;
            localTrack.CoverArtPath = serverTrack.CoverArtPath;
        }
    }

    public static bool AlbumsMatch(string? a, string? b)
    {
        if (string.IsNullOrWhiteSpace(a) || string.IsNullOrWhiteSpace(b)) return true;
        var cleanA = CleanAlbum(a);
        var cleanB = CleanAlbum(b);
        if (string.IsNullOrEmpty(cleanA) || string.IsNullOrEmpty(cleanB)) return true;
        if (cleanA.Equals("unknownalbum", StringComparison.OrdinalIgnoreCase) ||
            cleanB.Equals("unknownalbum", StringComparison.OrdinalIgnoreCase))
            return true;

        if (string.Equals(cleanA, cleanB, StringComparison.OrdinalIgnoreCase)) return true;

        // "Discovery" vs "Discovery Live 2001" is close enough, but a one- or two-letter album name inside a long one is not.
        var (shorter, longer) = cleanA.Length <= cleanB.Length ? (cleanA, cleanB) : (cleanB, cleanA);
        return shorter.Length >= 4 && longer.Contains(shorter, StringComparison.OrdinalIgnoreCase);
    }

    // Trailing "(2011 Remaster)" style notes that do not make a different recording. "Live", "Acoustic", "Demo",
    // "Instrumental" ... are deliberately not listed: those are different recordings of the same song.
    private static readonly Regex TitleNote = new(
        @"\b(remaster(ed)?|bonus|deluxe|anniversary|stereo|mono|(single|album|radio)\s+(version|edit))\b",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex AlbumNote = new(
        @"\b(remaster(ed)?|bonus|deluxe|edition|anniversary)\b",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static string CleanTitle(string? title) => Normalize(StripTrailingNotes(title, TitleNote));

    public static string CleanArtist(string? artist)
    {
        return Normalize(artist);
    }

    public static string CleanAlbum(string? album) => Normalize(StripTrailingNotes(album, AlbumNote));

    /// <summary>Removes trailing "(...)" or "[...]" groups whose text matches <paramref name="note"/>, repeatedly.</summary>
    private static string StripTrailingNotes(string? text, Regex note)
    {
        if (string.IsNullOrWhiteSpace(text)) return string.Empty;

        var s = text.Trim();
        while (s.Length > 2 && (s[^1] == ')' || s[^1] == ']'))
        {
            var open = s.LastIndexOf(s[^1] == ')' ? '(' : '[');
            if (open <= 0 || !note.IsMatch(s.AsSpan(open + 1, s.Length - open - 2))) break;
            s = s[..open].TrimEnd();
        }
        return s;
    }

    private static string Normalize(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return string.Empty;
        var trimmed = s.Trim();
        var sb = new StringBuilder(trimmed.Length);
        foreach (var c in trimmed)
        {
            if (char.IsLetterOrDigit(c))
                sb.Append(char.ToLowerInvariant(c));
        }
        return sb.ToString();
    }
}
