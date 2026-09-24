using Wiretone.Core.Models;

namespace Wiretone.Core.Services;

public interface IMetadataScanner
{
    Task<Track?> ReadTrackMetadataAsync(string filePath, string? coverCacheDirectory = null, CancellationToken ct = default);
    Task<List<Track>> ScanDirectoryAsync(string rootPath, string? coverCacheDirectory = null, IProgress<ScanProgressReport>? progress = null, CancellationToken ct = default);
    Task<byte[]?> ExtractCoverArtAsync(string filePath, CancellationToken ct = default);
}
