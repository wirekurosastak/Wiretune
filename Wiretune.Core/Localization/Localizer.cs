using System.ComponentModel;
using System.Globalization;

namespace Wiretune.Core.Localization;

/// <summary>A language the user interface is available in.</summary>
/// <param name="Code">Lower-case ISO 639-1 code; this is what is stored in the settings.</param>
/// <param name="NativeName">The language's name in that language, shown in the language picker.</param>
public sealed record LanguageInfo(string Code, string NativeName);

/// <summary>
/// All user-facing text of Wiretune, in every supported language. The single instance is both the
/// static lookup used by view models and services (<see cref="Get"/>, <see cref="Format"/>) and the
/// binding source of the UI: XAML reads <c>Localizer.Instance[key]</c>, and switching the language
/// raises a change notification for the indexer so every bound text updates in place.
/// </summary>
public sealed class Localizer : INotifyPropertyChanged
{
    public const string Hungarian = "hu";
    public const string English = "en";
    public const string German = "de";

    public static IReadOnlyList<LanguageInfo> Languages { get; } =
    [
        new(Hungarian, "Magyar"),
        new(English, "English"),
        new(German, "Deutsch"),
    ];

    public static Localizer Instance { get; } = new();

    private volatile string _language = English;

    private Localizer() { }

    /// <summary>The active language code (one of <see cref="Languages"/>).</summary>
    public string Language => _language;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Raised after <see cref="Language"/> changed; use it to recompute texts that were formatted earlier.</summary>
    public event EventHandler? LanguageChanged;

    /// <summary>Indexer used by XAML bindings, e.g. <c>[NavArtists]</c>. Unknown keys render as <c>[Key]</c>.</summary>
    public string this[string key] => Lookup(key, _language);

    /// <summary>Switches the language. Returns false for an unsupported or unchanged language.</summary>
    public bool SetLanguage(string? code)
    {
        var normalized = Normalize(code);
        if (normalized == null || normalized == _language) return false;

        _language = normalized;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Language)));
        // Avalonia refreshes an indexer binding when the indexer's own property name ("Item") is announced.
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item"));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item[]"));
        LanguageChanged?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>Maps "de", "de-AT", "HU" ... to a supported code, or null when the language is not supported.</summary>
    public static string? Normalize(string? code)
    {
        if (string.IsNullOrWhiteSpace(code)) return null;

        var two = code.Trim().Split('-', '_')[0].ToLowerInvariant();
        return Languages.Any(l => l.Code == two) ? two : null;
    }

    /// <summary>The language matching the operating system's UI language, English when that one is not supported.</summary>
    public static string DetectSystemLanguage() => Normalize(CultureInfo.CurrentUICulture.Name) ?? English;

    /// <summary>The text for <paramref name="key"/> in the active language.</summary>
    public static string Get(string key) => Lookup(key, Instance._language);

    /// <summary>
    /// Formats the text for <paramref name="key"/> with <paramref name="args"/>. When the first argument is the
    /// integer 1 and the key has a <c>_One</c> variant, that variant is used ("1 track" instead of "1 tracks").
    /// </summary>
    public static string Format(string key, params object?[] args)
    {
        var language = Instance._language;
        var effectiveKey = args.Length > 0 && args[0] is 1 && Strings.All.ContainsKey(key + "_One") ? key + "_One" : key;
        var template = Lookup(effectiveKey, language);
        try
        {
            return string.Format(CultureFor(language), template, args);
        }
        catch (FormatException)
        {
            // A broken template must not take the caller down; the tests check every template against its arguments.
            return template;
        }
    }

    /// <summary>"1 h 5 min" for a duration of an hour or more, "4 min 30 s" below that.</summary>
    public static string FormatTotalDuration(TimeSpan duration) => duration.TotalHours >= 1
        ? Format("DurationHoursMinutes", (int)duration.TotalHours, duration.Minutes)
        : Format("DurationMinutesSeconds", duration.Minutes, duration.Seconds);

    /// <summary>The culture used to format numbers and dates inside translated text.</summary>
    public static CultureInfo CultureFor(string language)
    {
        try
        {
            return CultureInfo.GetCultureInfo(language switch
            {
                Hungarian => "hu-HU",
                German => "de-DE",
                _ => "en-US",
            });
        }
        catch (CultureNotFoundException)
        {
            // Invariant-globalization builds only know the invariant culture.
            return CultureInfo.InvariantCulture;
        }
    }

    private static string Lookup(string key, string language)
    {
        if (!Strings.All.TryGetValue(key, out var texts)) return $"[{key}]";
        return language switch
        {
            Hungarian => texts.Hu,
            German => texts.De,
            _ => texts.En,
        };
    }
}
