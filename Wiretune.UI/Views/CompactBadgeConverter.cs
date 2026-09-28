using System.Globalization;
using System.Text.RegularExpressions;
using Avalonia.Data.Converters;

namespace Wiretune.UI.Controls;

/// <summary>
/// Reduces a format badge to just the file format for small tiles
/// (e.g. "FLAC 24/96" or "24-bit / 96 kHz FLAC" -> "FLAC").
/// Text without a recognised format (e.g. "MIXED HQ") is returned unchanged.
/// </summary>
public sealed class CompactBadgeConverter : IValueConverter
{
    private static readonly Regex Codec = new(
        @"\b(FLAC|WAVE?|ALAC|AIFF?|APE|WV|WMA|MP3|AAC|OGG|OPUS|DSD)\b",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not string s || string.IsNullOrWhiteSpace(s)) return value;
        var m = Codec.Match(s);
        if (!m.Success) return s;
        var name = m.Value.ToUpperInvariant();
        return name == "WAVE" ? "WAV" : name;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
