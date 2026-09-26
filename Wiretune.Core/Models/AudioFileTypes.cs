namespace Wiretune.Core.Models;

/// <summary>
/// Single source of truth for which audio files Wiretune indexes, how they are labelled and
/// which MIME type the server streams them with.
/// </summary>
public static class AudioFileTypes
{
    private sealed record FileType(string Codec, bool IsLossless, string MimeType);

    private static readonly Dictionary<string, FileType> Types = new(StringComparer.OrdinalIgnoreCase)
    {
        [".flac"] = new("FLAC", true, "audio/flac"),
        [".wav"] = new("WAV", true, "audio/wav"),
        [".aiff"] = new("AIFF", true, "audio/aiff"),
        [".aif"] = new("AIFF", true, "audio/aiff"),
        [".wv"] = new("WAVPACK", true, "audio/x-wavpack"),
        [".ape"] = new("APE", true, "audio/x-ape"),
        [".dsf"] = new("DSD", true, "audio/x-dsf"),
        [".m4a"] = new("AAC", false, "audio/mp4"),
        [".aac"] = new("AAC", false, "audio/aac"),
        [".mp3"] = new("MP3", false, "audio/mpeg"),
        [".ogg"] = new("VORBIS", false, "audio/ogg"),
        [".opus"] = new("OPUS", false, "audio/ogg"),
    };

    public static IReadOnlyCollection<string> SupportedExtensions => Types.Keys;

    public static bool IsSupported(string path) => Types.ContainsKey(Path.GetExtension(path));

    public static string GetMimeType(string path) =>
        Types.TryGetValue(Path.GetExtension(path), out var type) ? type.MimeType : "application/octet-stream";

    /// <summary>
    /// Codec label and losslessness for a file. MP4 containers are only known to hold ALAC
    /// (lossless) once the stream description has been read.
    /// </summary>
    public static (string Codec, bool IsLossless) Describe(string path, string? streamDescription = null)
    {
        var ext = Path.GetExtension(path);
        if (ext.Equals(".m4a", StringComparison.OrdinalIgnoreCase) &&
            streamDescription?.Contains("alac", StringComparison.OrdinalIgnoreCase) == true)
        {
            return ("ALAC", true);
        }

        return Types.TryGetValue(ext, out var type)
            ? (type.Codec, type.IsLossless)
            : (ext.TrimStart('.').ToUpperInvariant(), false);
    }
}
