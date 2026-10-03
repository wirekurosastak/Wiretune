using System.Globalization;
using System.Text.RegularExpressions;

namespace Wiretune.Core.Services;

/// <summary>One line of time-synced lyrics: the text and the moment it starts being sung.</summary>
public readonly record struct LrcLine(TimeSpan Time, string Text)
{
    /// <summary>An empty line is an instrumental gap: when it is current, no line is highlighted.</summary>
    public bool IsBlank => Text.Length == 0;
}

/// <summary>
/// Reads time-synced lyrics in the LRC format (<c>[01:23.45] text</c>). Handles several time tags on one line, the
/// <c>[offset:+250]</c> header, word-level <c>&lt;01:23.45&gt;</c> tags and the <c>[ar:Artist]</c>-style headers.
/// </summary>
public static class LrcParser
{
    private static readonly Regex TimeTag = new(@"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]", RegexOptions.CultureInvariant);
    private static readonly Regex WordTag = new(@"<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>\s?", RegexOptions.CultureInvariant);
    private static readonly Regex OffsetTag = new(@"^\s*\[offset:\s*([+-]?\d+)\s*\]\s*$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    /// <summary>
    /// The timed lines of <paramref name="text"/>, in playing order; an empty list when the text is not synced (plain
    /// lyrics, or fewer than two lines carrying a time tag).
    /// </summary>
    public static IReadOnlyList<LrcLine> Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return Array.Empty<LrcLine>();

        var offset = TimeSpan.Zero;
        var lines = new List<LrcLine>();

        foreach (var raw in text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            var offsetMatch = OffsetTag.Match(raw);
            if (offsetMatch.Success)
            {
                // LRC: a positive offset makes the lyrics appear sooner, so it is subtracted from every time.
                if (int.TryParse(offsetMatch.Groups[1].Value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var ms))
                    offset = TimeSpan.FromMilliseconds(-ms);
                continue;
            }

            var tags = TimeTag.Matches(raw);
            if (tags.Count == 0) continue; // headers ([ar:..]) and untimed lines have no place in a synced list

            // Every time tag sits at the start of the line, so the text is what follows the last one.
            var last = tags[^1];
            var content = WordTag.Replace(raw[(last.Index + last.Length)..], string.Empty).Trim();

            foreach (Match tag in tags)
                lines.Add(new LrcLine(TimeOf(tag), content));
        }

        if (lines.Count(l => !l.IsBlank) < 2) return Array.Empty<LrcLine>();

        // Apply the offset after reading, so a header that comes after the lines still counts. Stable sort keeps the
        // order of lines that share one time.
        var shifted = lines
            .Select(l => l with { Time = l.Time + offset < TimeSpan.Zero ? TimeSpan.Zero : l.Time + offset })
            .Select((l, i) => (l, i))
            .OrderBy(x => x.l.Time).ThenBy(x => x.i)
            .Select(x => x.l)
            .ToList();
        return shifted;
    }

    /// <summary>
    /// The index of the line that is current at <paramref name="position"/>: the last one that started at or before it,
    /// or -1 before the first line. <paramref name="lines"/> must be sorted by time (as <see cref="Parse"/> returns it).
    /// </summary>
    public static int IndexAt(IReadOnlyList<LrcLine> lines, TimeSpan position)
    {
        int lo = 0, hi = lines.Count - 1, found = -1;
        while (lo <= hi)
        {
            var mid = (lo + hi) / 2;
            if (lines[mid].Time <= position)
            {
                found = mid;
                lo = mid + 1;
            }
            else
            {
                hi = mid - 1;
            }
        }
        return found;
    }

    private static TimeSpan TimeOf(Match tag)
    {
        var minutes = int.Parse(tag.Groups[1].Value, CultureInfo.InvariantCulture);
        var seconds = int.Parse(tag.Groups[2].Value, CultureInfo.InvariantCulture);
        // ".5" is half a second, ".50" and ".500" too: pad to milliseconds (whole numbers, so no rounding drift).
        var millis = 0;
        var digits = tag.Groups[3];
        if (digits.Success)
            millis = int.Parse(digits.Value.PadRight(3, '0'), CultureInfo.InvariantCulture);
        return TimeSpan.FromMilliseconds((minutes * 60L + seconds) * 1000 + millis);
    }
}
