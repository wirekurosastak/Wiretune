using Wiretune.Core.Models;

namespace Wiretune.Core.Services;

public interface IMetadataScanner
{
    Task<Track?> ReadTrackMetadataAsync(string filePath, string? coverCacheDirectory = null, CancellationToken ct = default);

    /// <summary>
    /// Recursively reads every supported audio file below <paramref name="rootPath"/>. Files whose size and
    /// modification time match an entry in <paramref name="knownTracks"/> (keyed by full path) are reused
    /// without re-reading their tags.
    /// </summary>
    Task<List<Track>> ScanDirectoryAsync(
        string rootPath,
        string? coverCacheDirectory = null,
        IProgress<ScanProgressReport>? progress = null,
        CancellationToken ct = default,
        IReadOnlyDictionary<string, Track>? knownTracks = null);

    Task<byte[]?> ExtractCoverArtAsync(string filePath, CancellationToken ct = default);
}
