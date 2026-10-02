using Wiretune.Core.Models;

namespace Wiretune.Server;

// What the library routes send over the wire. The server's own Track, Album and Artist objects carry the absolute path of
// each file and of the cover cache; these records carry only what a player can use, so those paths never leave the machine.

/// <summary>
/// A track as listed by <c>GET /api/tracks</c>. <see cref="FilePath"/> is a placeholder (<c>server:{id}</c>): players built
/// before this record existed key their database on it and need a unique non-empty value, but the real path stays on the server.
/// </summary>
public record ServerTrackDto(
    string Id,
    string Title,
    string Artist,
    string Album,
    string? AlbumArtist,
    int? TrackNumber,
    int? TrackCount,
    int? DiscNumber,
    int? Year,
    string? Genre,
    TimeSpan Duration,
    long FileSizeBytes,
    DateTime? FileModifiedUtc,
    string FilePath,
    bool HasCoverArt,
    AudioFormat Format,
    DateTime DateAdded)
{
    public static ServerTrackDto From(Track t) => new(
        t.Id, t.Title, t.Artist, t.Album, t.AlbumArtist,
        t.TrackNumber, t.TrackCount, t.DiscNumber, t.Year, t.Genre,
        t.Duration, t.FileSizeBytes, t.FileModifiedUtc, $"server:{t.Id}", t.HasCoverArt,
        t.Format, t.DateAdded);
}

public record ServerAlbumDto(
    string Id,
    string Title,
    string Artist,
    int? Year,
    string? Genre,
    int TrackCount,
    TimeSpan TotalDuration,
    bool IsHiRes,
    string FormatBadge,
    List<ServerTrackDto> Tracks)
{
    public static ServerAlbumDto From(Album a) => new(
        a.Id, a.Title, a.Artist, a.Year, a.Genre, a.TrackCount, a.TotalDuration, a.IsHiRes, a.FormatBadge,
        a.Tracks.Select(ServerTrackDto.From).ToList());
}

public record ServerArtistDto(string Id, string Name, int AlbumCount, int TrackCount, List<ServerAlbumDto> Albums)
{
    public static ServerArtistDto From(Artist a) => new(
        a.Id, a.Name, a.AlbumCount, a.TrackCount, a.Albums.Select(ServerAlbumDto.From).ToList());
}
