using System.Security.Cryptography;
using System.Text;
using Wiretune.Core.Models;

namespace Wiretune.Core.Services;

public class MetadataScanner : IMetadataScanner
{
    private static readonly HashSet<string> SupportedExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".flac", ".mp3", ".wav", ".m4a", ".aac", ".alac", ".ogg", ".opus", ".aiff", ".dsf"
    };

    public Task<Track?> ReadTrackMetadataAsync(string filePath, string? coverCacheDirectory = null, CancellationToken ct = default)
    {
        return Task.Run(() =>
        {
            try
            {
                if (!File.Exists(filePath)) return null;

                var ext = Path.GetExtension(filePath);
                if (!SupportedExtensions.Contains(ext)) return null;

                var fileInfo = new FileInfo(filePath);
                using var tagFile = TagLib.File.Create(filePath);

                var tag = tagFile.Tag;
                var props = tagFile.Properties;

                var title = !string.IsNullOrWhiteSpace(tag?.Title)
                    ? tag.Title.Trim()
                    : Path.GetFileNameWithoutExtension(filePath);

                var artist = !string.IsNullOrWhiteSpace(tag?.FirstPerformer)
                    ? tag.FirstPerformer.Trim()
                    : (!string.IsNullOrWhiteSpace(tag?.FirstAlbumArtist)
                        ? tag.FirstAlbumArtist.Trim()
                        : "Ismeretlen előadó");

                var album = !string.IsNullOrWhiteSpace(tag?.Album)
                    ? tag.Album.Trim()
                    : "Ismeretlen album";

                var genre = tag?.FirstGenre;
                var year = tag?.Year > 0 ? (int?)tag.Year : null;
                var trackNum = tag?.Track > 0 ? (int?)tag.Track : null;
                var trackCount = tag?.TrackCount > 0 ? (int?)tag.TrackCount : null;
                var discNum = tag?.Disc > 0 ? (int?)tag.Disc : null;

                var sampleRate = props?.AudioSampleRate ?? 44100;
                var bitsPerSample = props?.BitsPerSample ?? 16;
                if (bitsPerSample == 0)
                {
                    // Fallback for formats where TagLib reports 0 bits (like some FLAC or lossy)
                    bitsPerSample = ext.Equals(".flac", StringComparison.OrdinalIgnoreCase) ? 16 : 16;
                }

                var codec = !string.IsNullOrWhiteSpace(props?.Description)
                    ? props.Description.ToUpperInvariant()
                    : ext.TrimStart('.').ToUpperInvariant();

                var isLossless = ext.Equals(".flac", StringComparison.OrdinalIgnoreCase) ||
                                 ext.Equals(".wav", StringComparison.OrdinalIgnoreCase) ||
                                 ext.Equals(".alac", StringComparison.OrdinalIgnoreCase) ||
                                 ext.Equals(".aiff", StringComparison.OrdinalIgnoreCase) ||
                                 ext.Equals(".dsf", StringComparison.OrdinalIgnoreCase);

                var format = new AudioFormat
                {
                    Codec = ext.TrimStart('.').ToUpperInvariant(),
                    SampleRate = sampleRate,
                    BitsPerSample = bitsPerSample,
                    Channels = props?.AudioChannels ?? 2,
                    BitrateKbps = props?.AudioBitrate ?? 1411,
                    IsLossless = isLossless
                };

                string? coverArtPath = null;
                var hasCover = tag?.Pictures != null && tag.Pictures.Length > 0;
                string? folderCoverPath = null;

                try
                {
                    var dir = Path.GetDirectoryName(filePath);
                    if (!string.IsNullOrEmpty(dir))
                    {
                        string[] candidates = { "cover.jpg", "cover.png", "cover.jpeg", "folder.jpg", "folder.png", "front.jpg", "front.png", "albumart.jpg", "artwork.jpg" };
                        foreach (var c in candidates)
                        {
                            var p = Path.Combine(dir, c);
                            if (File.Exists(p))
                            {
                                hasCover = true;
                                folderCoverPath = p;
                                break;
                            }
                        }
                    }
                }
                catch
                {
                    // Ignore folder search error
                }

                if (hasCover)
                {
                    if (tag?.Pictures != null && tag.Pictures.Length > 0 && !string.IsNullOrWhiteSpace(coverCacheDirectory))
                    {
                        try
                        {
                            Directory.CreateDirectory(coverCacheDirectory);
                            var hashSource = $"{artist}_{album}";
                            var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(hashSource)))[..16];
                            var coverFileName = $"cover_{hash}.jpg";
                            coverArtPath = Path.Combine(coverCacheDirectory, coverFileName);

                            if (!File.Exists(coverArtPath))
                            {
                                var pic = tag.Pictures[0];
                                if (pic?.Data != null)
                                {
                                    File.WriteAllBytes(coverArtPath, pic.Data.Data);
                                }
                            }
                        }
                        catch
                        {
                            // Ignore cache write failures
                        }
                    }
                    else if (!string.IsNullOrEmpty(folderCoverPath))
                    {
                        coverArtPath = folderCoverPath;
                    }
                }

                return new Track
                {
                    Id = Guid.NewGuid().ToString("N"),
                    Title = title,
                    Artist = artist,
                    Album = album,
                    AlbumArtist = tag?.FirstAlbumArtist,
                    TrackNumber = trackNum,
                    TrackCount = trackCount,
                    DiscNumber = discNum,
                    Year = year,
                    Genre = genre,
                    Duration = props?.Duration ?? TimeSpan.Zero,
                    FileSizeBytes = fileInfo.Length,
                    FilePath = filePath,
                    HasCoverArt = hasCover,
                    CoverArtPath = coverArtPath,
                    Format = format,
                    DateAdded = DateTime.UtcNow
                };
            }
            catch (Exception)
            {
                return null;
            }
        }, ct);
    }

    public async Task<List<Track>> ScanDirectoryAsync(
        string rootPath,
        string? coverCacheDirectory = null,
        IProgress<ScanProgressReport>? progress = null,
        CancellationToken ct = default)
    {
        return await Task.Run(async () =>
        {
            var tracks = new List<Track>();
            if (!Directory.Exists(rootPath)) return tracks;

            var allFiles = Directory.EnumerateFiles(rootPath, "*.*", SearchOption.AllDirectories)
                .Where(f => SupportedExtensions.Contains(Path.GetExtension(f)))
                .ToList();

            int total = allFiles.Count;
            int count = 0;

            foreach (var file in allFiles)
            {
                if (ct.IsCancellationRequested) break;

                var track = await ReadTrackMetadataAsync(file, coverCacheDirectory, ct);
                if (track != null)
                {
                    tracks.Add(track);
                }

                count++;
                if (count % 5 == 0 || count == total)
                {
                    progress?.Report(new ScanProgressReport
                    {
                        ScannedFiles = count,
                        TotalEstimatedFiles = total,
                        CurrentFile = Path.GetFileName(file),
                        CurrentArtist = track?.Artist ?? string.Empty
                    });
                }
            }

            return tracks;
        }, ct);
    }

    public Task<byte[]?> ExtractCoverArtAsync(string filePath, CancellationToken ct = default)
    {
        return Task.Run(() =>
        {
            try
            {
                if (!File.Exists(filePath)) return null;
                using var tagFile = TagLib.File.Create(filePath);
                var pictures = tagFile.Tag?.Pictures;
                if (pictures != null && pictures.Length > 0 && pictures[0]?.Data?.Data != null)
                {
                    return pictures[0].Data.Data;
                }
            }
            catch
            {
                // Fallback to folder check below
            }

            try
            {
                var dir = Path.GetDirectoryName(filePath);
                if (!string.IsNullOrEmpty(dir))
                {
                    string[] candidates = { "cover.jpg", "cover.png", "cover.jpeg", "folder.jpg", "folder.png", "front.jpg", "front.png", "albumart.jpg", "artwork.jpg" };
                    foreach (var c in candidates)
                    {
                        var p = Path.Combine(dir, c);
                        if (File.Exists(p)) return File.ReadAllBytes(p);
                    }
                }
            }
            catch
            {
                // Ignore folder read error
            }

            return null;
        }, ct);
    }
}
