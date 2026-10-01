using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using Wiretune.Core.Models;

namespace Wiretune.Core.Services;

public class MetadataScanner
{
    /// <summary>
    /// Placeholders stored for files without an artist / album tag. They are data (they are saved in the library and
    /// group the untagged files together), not interface text, so they do not follow the interface language.
    /// </summary>
    public const string UnknownArtist = "Unknown artist";
    public const string UnknownAlbum = "Unknown album";

    /// <summary>True for the placeholder above, and for the Hungarian one that libraries scanned by older versions contain.</summary>
    public static bool IsUnknownArtist(string? name) =>
        string.Equals(name, UnknownArtist, StringComparison.OrdinalIgnoreCase) || name == "Ismeretlen előadó";

    private static readonly string[] FolderCoverNames =
    {
        "cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.jpeg", "folder.png",
        "front.jpg", "front.jpeg", "front.png", "albumart.jpg", "artwork.jpg"
    };

    public Task<Track?> ReadTrackMetadataAsync(string filePath, string? coverCacheDirectory = null, CancellationToken ct = default)
    {
        return Task.Run(() => ReadTrackMetadata(filePath, coverCacheDirectory, null), ct);
    }

    public Task<List<Track>> ScanDirectoryAsync(
        string rootPath,
        string? coverCacheDirectory = null,
        IProgress<ScanProgressReport>? progress = null,
        CancellationToken ct = default,
        IReadOnlyDictionary<string, Track>? knownTracks = null)
    {
        return Task.Run(async () =>
        {
            if (!Directory.Exists(rootPath)) return new List<Track>();

            var files = Directory.EnumerateFiles(rootPath, "*", new EnumerationOptions
                {
                    IgnoreInaccessible = true,
                    RecurseSubdirectories = true,
                    AttributesToSkip = FileAttributes.System | FileAttributes.Hidden
                })
                .Where(AudioFileTypes.IsSupported)
                .ToList();

            var total = files.Count;
            var processed = 0;
            var results = new ConcurrentBag<Track>();
            var folderCovers = new ConcurrentDictionary<string, string?>(StringComparer.Ordinal);

            await Parallel.ForEachAsync(
                files,
                new ParallelOptions { CancellationToken = ct, MaxDegreeOfParallelism = Math.Clamp(Environment.ProcessorCount, 2, 8) },
                (file, _) =>
                {
                    var track = TryReuse(file, knownTracks) ?? ReadTrackMetadata(file, coverCacheDirectory, folderCovers);
                    if (track != null) results.Add(track);

                    var done = Interlocked.Increment(ref processed);
                    if (progress != null && (done % 10 == 0 || done == total))
                    {
                        progress.Report(new ScanProgressReport
                        {
                            ScannedFiles = done,
                            TotalEstimatedFiles = total,
                            CurrentFile = Path.GetFileName(file),
                            CurrentArtist = track?.Artist ?? string.Empty
                        });
                    }

                    return ValueTask.CompletedTask;
                }).ConfigureAwait(false);

            if (results.Count < total)
                WiretuneLog.Warn("MetadataScanner", $"{total - results.Count} of {total} audio files could not be read and were skipped (details in the debug log).");

            return results.ToList();
        }, ct);
    }

    private const int MaxLyricsLength = 100_000;

    /// <summary>The lyrics stored in the file's tag, or null when there are none or the file cannot be read.</summary>
    public static Task<string?> ReadLyricsAsync(string filePath, CancellationToken ct = default)
    {
        return Task.Run(() =>
        {
            ct.ThrowIfCancellationRequested();
            if (!File.Exists(filePath)) return null;

            try
            {
                using var tagFile = TagLib.File.Create(filePath);
                var lyrics = tagFile.Tag?.Lyrics?.Trim();
                if (string.IsNullOrEmpty(lyrics)) return null;
                return lyrics.Length > MaxLyricsLength ? lyrics[..MaxLyricsLength] : lyrics;
            }
            catch (Exception ex)
            {
                WiretuneLog.Debug("MetadataScanner", $"Cannot read lyrics of '{filePath}': {ex.Message}");
                return null;
            }
        }, ct);
    }

    public Task<byte[]?> ExtractCoverArtAsync(string filePath, CancellationToken ct = default)
    {
        return Task.Run(() =>
        {
            if (!File.Exists(filePath)) return null;

            try
            {
                using var tagFile = TagLib.File.Create(filePath);
                var data = tagFile.Tag?.Pictures?.FirstOrDefault()?.Data?.Data;
                if (data is { Length: > 0 }) return data;
            }
            catch
            {
                // Unreadable tags: fall back to a folder image below.
            }

            var folderCover = FindFolderCover(Path.GetDirectoryName(filePath));
            try
            {
                return folderCover != null ? File.ReadAllBytes(folderCover) : null;
            }
            catch
            {
                return null;
            }
        }, ct);
    }

    public static string ComputeTrackId(string filePath) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(filePath).ToLowerInvariant())))[..32];

    private static Track? TryReuse(string file, IReadOnlyDictionary<string, Track>? knownTracks)
    {
        if (knownTracks == null || !knownTracks.TryGetValue(Path.GetFullPath(file), out var known)) return null;
        if (known.FileModifiedUtc == null) return null;
        if (!string.IsNullOrEmpty(known.CoverArtPath) && !File.Exists(known.CoverArtPath)) return null;

        try
        {
            var info = new FileInfo(file);
            return info.Length == known.FileSizeBytes && info.LastWriteTimeUtc == known.FileModifiedUtc.Value
                ? known
                : null;
        }
        catch
        {
            return null;
        }
    }

    private static Track? ReadTrackMetadata(string filePath, string? coverCacheDirectory, ConcurrentDictionary<string, string?>? folderCoverCache)
    {
        try
        {
            if (!File.Exists(filePath) || !AudioFileTypes.IsSupported(filePath)) return null;

            var fullPath = Path.GetFullPath(filePath);
            var fileInfo = new FileInfo(fullPath);
            using var tagFile = TagLib.File.Create(fullPath);
            var tag = tagFile.Tag;
            var props = tagFile.Properties;

            var title = Clean(tag?.Title) ?? Path.GetFileNameWithoutExtension(fullPath);
            var albumArtist = Clean(tag?.FirstAlbumArtist);
            var artist = Clean(tag?.FirstPerformer) ?? albumArtist ?? UnknownArtist;
            var album = Clean(tag?.Album) ?? UnknownAlbum;

            var streamDescription = props?.Codecs?.FirstOrDefault(c => c != null)?.Description ?? props?.Description;
            var (codec, isLossless) = AudioFileTypes.Describe(fullPath, streamDescription);

            var bitsPerSample = props?.BitsPerSample ?? 0;
            if (bitsPerSample == 0 && isLossless) bitsPerSample = 16;
            if (!isLossless) bitsPerSample = 0;

            var format = new AudioFormat
            {
                Codec = codec,
                SampleRate = props?.AudioSampleRate is > 0 ? props.AudioSampleRate : 44100,
                BitsPerSample = bitsPerSample,
                Channels = props?.AudioChannels is > 0 ? props.AudioChannels : 2,
                BitrateKbps = props?.AudioBitrate ?? 0,
                IsLossless = isLossless
            };

            var dir = Path.GetDirectoryName(fullPath);
            var coverArtPath = CacheEmbeddedCover(tag, coverCacheDirectory, albumArtist ?? artist, album)
                               ?? (folderCoverCache != null && dir != null
                                   ? folderCoverCache.GetOrAdd(dir, FindFolderCover)
                                   : FindFolderCover(dir));
            var hasEmbedded = tag?.Pictures is { Length: > 0 };

            return new Track
            {
                Id = ComputeTrackId(fullPath),
                Title = title,
                Artist = artist,
                Album = album,
                AlbumArtist = albumArtist,
                TrackNumber = tag?.Track > 0 ? (int)tag.Track : null,
                TrackCount = tag?.TrackCount > 0 ? (int)tag.TrackCount : null,
                DiscNumber = tag?.Disc > 0 ? (int)tag.Disc : null,
                Year = tag?.Year > 0 ? (int)tag.Year : null,
                Genre = Clean(tag?.FirstGenre),
                Duration = props?.Duration ?? TimeSpan.Zero,
                FileSizeBytes = fileInfo.Length,
                FileModifiedUtc = fileInfo.LastWriteTimeUtc,
                FilePath = fullPath,
                HasCoverArt = hasEmbedded || coverArtPath != null,
                CoverArtPath = coverArtPath,
                Format = format,
                DateAdded = DateTime.UtcNow
            };
        }
        catch (Exception ex)
        {
            WiretuneLog.Debug("MetadataScanner", $"Skipping unreadable file '{filePath}': {ex.Message}");
            return null;
        }
    }

    private static string? CacheEmbeddedCover(TagLib.Tag? tag, string? coverCacheDirectory, string albumArtist, string album)
    {
        var picture = tag?.Pictures?.FirstOrDefault();
        var data = picture?.Data?.Data;
        if (data is not { Length: > 0 } || string.IsNullOrWhiteSpace(coverCacheDirectory)) return null;

        try
        {
            Directory.CreateDirectory(coverCacheDirectory);
            var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
                $"{albumArtist.ToUpperInvariant()}\u001f{album.ToUpperInvariant()}")))[..16];
            var extension = ImageFormat.IsPng(data) ? ".png" : ".jpg";
            var path = Path.Combine(coverCacheDirectory, $"cover_{hash}{extension}");

            if (!File.Exists(path))
            {
                // Tracks of one album are read in parallel; write to a unique temp file and move it in place.
                var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                File.WriteAllBytes(temp, data);
                try
                {
                    File.Move(temp, path, overwrite: false);
                }
                catch (IOException)
                {
                    File.Delete(temp);
                }
            }

            return path;
        }
        catch (Exception ex)
        {
            WiretuneLog.Debug("MetadataScanner", $"Could not cache embedded cover for '{album}': {ex.Message}");
            return null;
        }
    }

    private static string? FindFolderCover(string? directory)
    {
        if (string.IsNullOrEmpty(directory)) return null;

        try
        {
            var files = Directory.EnumerateFiles(directory)
                .ToDictionary(f => Path.GetFileName(f), f => f, StringComparer.OrdinalIgnoreCase);
            foreach (var name in FolderCoverNames)
            {
                if (files.TryGetValue(name, out var match)) return match;
            }
        }
        catch
        {
            // Unreadable directory: no folder cover.
        }

        return null;
    }

    private static string? Clean(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}

public static class ImageFormat
{
    public static bool IsPng(ReadOnlySpan<byte> data) =>
        data.Length >= 8 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47;

    public static string GetMimeType(ReadOnlySpan<byte> data) => IsPng(data) ? "image/png" : "image/jpeg";

    public static string GetMimeTypeFromPath(string path) =>
        Path.GetExtension(path).Equals(".png", StringComparison.OrdinalIgnoreCase) ? "image/png" : "image/jpeg";
}


