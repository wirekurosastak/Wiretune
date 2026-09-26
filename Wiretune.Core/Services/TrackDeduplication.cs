using System.Text;
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

        return string.Equals(cleanA, cleanB, StringComparison.OrdinalIgnoreCase) ||
               cleanA.Contains(cleanB, StringComparison.OrdinalIgnoreCase) ||
               cleanB.Contains(cleanA, StringComparison.OrdinalIgnoreCase);
    }

    public static string CleanTitle(string? title)
    {
        if (string.IsNullOrWhiteSpace(title)) return string.Empty;
        var s = title.Trim();

        while (true)
        {
            var openParen = s.LastIndexOf('(');
            var closeParen = s.LastIndexOf(')');
            if (openParen >= 0 && closeParen == s.Length - 1 && closeParen > openParen)
            {
                var inside = s.Substring(openParen + 1, closeParen - openParen - 1).ToLowerInvariant();
                if (inside.Contains("remaster") || inside.Contains("bonus") || inside.Contains("deluxe") ||
                    inside.Contains("edit") || inside.Contains("version") || inside.Contains("anniversary") ||
                    inside.Contains("stereo") || inside.Contains("mono"))
                {
                    s = s.Substring(0, openParen).Trim();
                    continue;
                }
            }

            var openBracket = s.LastIndexOf('[');
            var closeBracket = s.LastIndexOf(']');
            if (openBracket >= 0 && closeBracket == s.Length - 1 && closeBracket > openBracket)
            {
                var inside = s.Substring(openBracket + 1, closeBracket - openBracket - 1).ToLowerInvariant();
                if (inside.Contains("remaster") || inside.Contains("bonus") || inside.Contains("deluxe") ||
                    inside.Contains("edit") || inside.Contains("version") || inside.Contains("anniversary") ||
                    inside.Contains("stereo") || inside.Contains("mono"))
                {
                    s = s.Substring(0, openBracket).Trim();
                    continue;
                }
            }
            break;
        }

        return Normalize(s);
    }

    public static string CleanArtist(string? artist)
    {
        return Normalize(artist);
    }

    public static string CleanAlbum(string? album)
    {
        if (string.IsNullOrWhiteSpace(album)) return string.Empty;
        var s = album.Trim();
        while (true)
        {
            var openParen = s.LastIndexOf('(');
            var closeParen = s.LastIndexOf(')');
            if (openParen >= 0 && closeParen == s.Length - 1 && closeParen > openParen)
            {
                var inside = s.Substring(openParen + 1, closeParen - openParen - 1).ToLowerInvariant();
                if (inside.Contains("remaster") || inside.Contains("bonus") || inside.Contains("deluxe") ||
                    inside.Contains("edition") || inside.Contains("anniversary"))
                {
                    s = s.Substring(0, openParen).Trim();
                    continue;
                }
            }
            break;
        }
        return Normalize(s);
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
