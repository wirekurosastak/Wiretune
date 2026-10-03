using Wiretune.Core.Localization;

namespace Wiretune.Core.Models;

/// <summary>
/// How good a recording is, as a three-step medal the whole interface uses for its quality tags:
/// <see cref="Gold"/> is hi-res (24 bit, or a sample rate above 48 kHz), <see cref="Silver"/> is lossless at CD
/// resolution (16 bit), <see cref="Bronze"/> is everything that is not lossless (MP3, AAC, Ogg Vorbis, ...).
/// The numeric order is the quality order, so the lowest tier of a set of tracks is simply the minimum.
/// </summary>
public enum QualityTier
{
    Bronze = 0,
    Silver = 1,
    Gold = 2,
}

/// <summary>The words of a quality tag, in the active interface language.</summary>
public static class QualityTierText
{
    /// <summary>The tier's name as the tag shows it: GOLD, SILVER, BRONZE (ARANY, EZÜST, BRONZ / GOLD, SILBER, BRONZE).</summary>
    public static string Word(this QualityTier tier) => Localizer.Get(tier switch
    {
        QualityTier.Gold => "QualityGold",
        QualityTier.Silver => "QualitySilver",
        _ => "QualityBronze",
    });

    /// <summary>One sentence saying what the tier stands for.</summary>
    public static string Hint(this QualityTier tier) => Localizer.Get(tier switch
    {
        QualityTier.Gold => "QualityGoldHint",
        QualityTier.Silver => "QualitySilverHint",
        _ => "QualityBronzeHint",
    });

    /// <summary>
    /// The text of the tag: just <paramref name="spec"/> (<c>FLAC 24bit/96kHz</c>); the tier itself is told by the
    /// colour of the tag, not by a word. With <paramref name="compact"/> only the first word of the spec, the file
    /// format, is kept (<c>FLAC</c>), for tiles that are too small for more. Without a spec there is nothing else
    /// to show, so the tier word stands alone rather than leaving an empty pill.
    /// </summary>
    public static string TagText(this QualityTier tier, string? spec, bool compact = false)
    {
        if (string.IsNullOrWhiteSpace(spec)) return tier.Word();

        var text = spec.Trim();
        if (compact)
        {
            var space = text.IndexOf(' ');
            if (space > 0) text = text[..space];
        }
        return text;
    }
}

/// <summary>
/// The quality tag of a group of tracks (an album or a playlist): the tier the group is shown in and the short
/// text that follows the tier word, for example <c>FLAC 24bit/96kHz</c> or <c>MIXED</c>.
/// </summary>
/// <param name="Tier">The lowest tier among the tracks: "every track here is at least this good".</param>
/// <param name="Spec">The format of the tracks when they all share one, <see cref="MixedSpec"/> otherwise.</param>
/// <param name="IsMixed">True when the tracks do not all share one format.</param>
public sealed record QualitySummary(QualityTier Tier, string Spec, bool IsMixed)
{
    /// <summary>What the tag says when the tracks are in different formats.</summary>
    public const string MixedSpec = "MIXED";

    /// <summary>
    /// Summarises <paramref name="formats"/>, or returns null when there are none (an empty playlist has no tag).
    /// Two lossy files count as the same format only when their bitrate matches too, so a folder of 128 and
    /// 320 kbps MP3s is "mixed" rather than showing the first file's bitrate for all of them.
    /// </summary>
    public static QualitySummary? Of(IEnumerable<AudioFormat> formats)
    {
        ArgumentNullException.ThrowIfNull(formats);

        AudioFormat? first = null;
        var lowest = QualityTier.Gold;
        var mixed = false;
        foreach (var format in formats)
        {
            if (format.Tier < lowest) lowest = format.Tier;
            if (first == null) first = format;
            else if (!SameSpec(first, format)) mixed = true;
        }

        if (first == null) return null;
        return new QualitySummary(lowest, mixed ? MixedSpec : first.TagSpec, mixed);
    }

    private static bool SameSpec(AudioFormat a, AudioFormat b) =>
        a.IsLossless == b.IsLossless
        && string.Equals(a.Codec, b.Codec, StringComparison.OrdinalIgnoreCase)
        && a.SampleRate == b.SampleRate
        && (a.IsLossless ? a.BitsPerSample == b.BitsPerSample : a.BitrateKbps == b.BitrateKbps);
}
