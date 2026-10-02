using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using Wiretune.Core.Localization;
using Wiretune.Core.Services;
using Xunit;

namespace Wiretune.Tests;

/// <summary>
/// The language is process-wide state. Pinning it to English for the whole test run keeps every other
/// test independent of the machine's culture; the tests in <see cref="LocalizationTests"/> change it
/// and put it back, and run alone (see <see cref="LocalizationCollection"/>).
/// </summary>
internal static class TestLanguage
{
    [ModuleInitializer]
    internal static void PinToEnglish() => Localizer.Instance.SetLanguage(Localizer.English);
}

[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class LocalizationCollection
{
    public const string Name = "Localization";
}

[Collection(LocalizationCollection.Name)]
public sealed partial class LocalizationTests : IDisposable
{
    private static readonly string[] AllLanguages = [Localizer.Hungarian, Localizer.English, Localizer.German];

    public LocalizationTests() => Localizer.Instance.SetLanguage(Localizer.English);

    public void Dispose() => Localizer.Instance.SetLanguage(Localizer.English);

    private static IEnumerable<(string Key, string Language, string Text)> AllTexts() =>
        Strings.All.SelectMany(kv => new[]
        {
            (kv.Key, Localizer.Hungarian, kv.Value.Hu),
            (kv.Key, Localizer.English, kv.Value.En),
            (kv.Key, Localizer.German, kv.Value.De),
        });

    [GeneratedRegex(@"\{(\d+)(?:,[^}:]*)?(?::[^}]*)?\}")]
    private static partial Regex PlaceholderPattern();

    private static SortedSet<int> Placeholders(string text) =>
        new(PlaceholderPattern().Matches(text).Select(m => int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)));

    // ── The dictionary itself ─────────────────────────────────────────────────────────────────────

    [Fact]
    public void EveryText_IsFilledInAndTidy()
    {
        foreach (var (key, language, text) in AllTexts())
        {
            Assert.False(string.IsNullOrWhiteSpace(text), $"{key} has no {language} text");
            Assert.True(text == text.Trim(), $"{key} ({language}) has leading or trailing whitespace");
            Assert.DoesNotContain('\r', text);
            Assert.DoesNotContain("TODO", text, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public void Keys_ArePascalCaseIdentifiers()
    {
        foreach (var key in Strings.All.Keys)
            Assert.Matches(@"^[A-Z][A-Za-z0-9]*(_One)?$", key);
    }

    [Fact]
    public void EveryKey_UsesTheSamePlaceholdersInEveryLanguage()
    {
        foreach (var (key, (hu, en, de)) in Strings.All)
        {
            Assert.True(Placeholders(en).SetEquals(Placeholders(hu)), $"{key}: Hungarian placeholders differ from English");
            Assert.True(Placeholders(en).SetEquals(Placeholders(de)), $"{key}: German placeholders differ from English");
        }
    }

    [Fact]
    public void EveryText_FormatsWithoutThrowing()
    {
        foreach (var (key, language, text) in AllTexts())
        {
            var arguments = new object[Placeholders(text).DefaultIfEmpty(-1).Max() + 1];
            Array.Fill(arguments, "x");
            var ex = Record.Exception(() => string.Format(Localizer.CultureFor(language), text, arguments));
            Assert.True(ex == null, $"{key} ({language}) is not a valid format string: {ex?.Message}");
        }
    }

    [Fact]
    public void SingularVariants_HaveABaseKeyThatTakesTheCountFirst()
    {
        foreach (var key in Strings.All.Keys.Where(k => k.EndsWith("_One", StringComparison.Ordinal)))
        {
            var baseKey = key[..^"_One".Length];
            Assert.True(Strings.All.ContainsKey(baseKey), $"{key} has no base key {baseKey}");
            Assert.Contains(0, Placeholders(Strings.All[baseKey].En));
            Assert.Contains(0, Placeholders(Strings.All[key].En));
        }
    }

    [Fact]
    public void GermanAndHungarian_AreActuallyTranslated()
    {
        // A few words really are the same in all languages (product names, "Album"); most texts are not.
        var translatedToGerman = Strings.All.Count(kv => kv.Value.De != kv.Value.En);
        var translatedToHungarian = Strings.All.Count(kv => kv.Value.Hu != kv.Value.En);

        Assert.True(translatedToGerman > Strings.All.Count * 0.85, $"only {translatedToGerman}/{Strings.All.Count} German texts differ from English");
        Assert.True(translatedToHungarian > Strings.All.Count * 0.85, $"only {translatedToHungarian}/{Strings.All.Count} Hungarian texts differ from English");
    }

    // ── Keys used by the code and the XAML must exist, and every key must be used ────────────────────

    private static string? FindRepositoryRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "Wiretune.slnx"))) return dir.FullName;
        return null;
    }

    private static IEnumerable<string> SourceFiles(string root, string pattern) =>
        new[] { "Wiretune.Core", "Wiretune.UI", "Wiretune.Desktop", "Wiretune.Android", "Wiretune.Server" }
            .Select(project => Path.Combine(root, project))
            .Where(Directory.Exists)
            .SelectMany(dir => Directory.EnumerateFiles(dir, pattern, SearchOption.AllDirectories))
            .Where(path => !path.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}") &&
                           !path.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}"));

    [GeneratedRegex(@"\{loc:T(?:Format)?\s+([A-Za-z0-9_]+)")]
    private static partial Regex XamlKeyPattern();

    [GeneratedRegex(@"(?:Localizer\.(?:Get|Format)\(|Localizer\.Instance\[|SetState\([^,()]+,|NameKey\s*=|MessageKey\s*[:=])\s*""([A-Za-z0-9_]+)""")]
    private static partial Regex CodeKeyPattern();

    [Fact]
    public void KeysUsedInXamlAndCode_AllExist()
    {
        var root = FindRepositoryRoot();
        if (root == null) return; // tests run away from the sources

        var missing = new List<string>();
        foreach (var file in SourceFiles(root, "*.axaml"))
            foreach (Match m in XamlKeyPattern().Matches(File.ReadAllText(file)))
                if (!Strings.All.ContainsKey(m.Groups[1].Value)) missing.Add($"{Path.GetFileName(file)}: {m.Groups[1].Value}");

        foreach (var file in SourceFiles(root, "*.cs").Where(f => Path.GetFileName(f) != "Strings.cs"))
            foreach (Match m in CodeKeyPattern().Matches(File.ReadAllText(file)))
                if (!Strings.All.ContainsKey(m.Groups[1].Value)) missing.Add($"{Path.GetFileName(file)}: {m.Groups[1].Value}");

        Assert.True(missing.Count == 0, "Unknown localization keys: " + string.Join(", ", missing));
    }

    [Fact]
    public void EveryKey_IsUsedSomewhere()
    {
        var root = FindRepositoryRoot();
        if (root == null) return;

        var code = string.Join('\n', SourceFiles(root, "*.cs").Where(f => Path.GetFileName(f) != "Strings.cs").Select(File.ReadAllText));
        var xaml = string.Join('\n', SourceFiles(root, "*.axaml").Select(File.ReadAllText));

        var unused = Strings.All.Keys
            .Where(k => !k.EndsWith("_One", StringComparison.Ordinal))
            .Where(k => !code.Contains($"\"{k}\"", StringComparison.Ordinal) &&
                        !Regex.IsMatch(xaml, $@"\{{loc:T(?:Format)?\s+{k}\b"))
            .ToList();

        Assert.True(unused.Count == 0, "Unused localization keys: " + string.Join(", ", unused));
    }

    // ── Lookup and formatting ─────────────────────────────────────────────────────────────────────

    [Theory]
    [InlineData(Localizer.Hungarian, "Bezárás")]
    [InlineData(Localizer.English, "Close")]
    [InlineData(Localizer.German, "Schließen")]
    public void Get_ReturnsTheTextOfTheActiveLanguage(string language, string expected)
    {
        Localizer.Instance.SetLanguage(language);

        Assert.Equal(expected, Localizer.Get("Close"));
        Assert.Equal(expected, Localizer.Instance["Close"]);
    }

    [Fact]
    public void UnknownKey_IsShownInBracketsInsteadOfThrowing()
    {
        Assert.Equal("[NoSuchKey]", Localizer.Get("NoSuchKey"));
        Assert.Equal("[NoSuchKey]", Localizer.Format("NoSuchKey", 3));
    }

    [Theory]
    [InlineData(Localizer.Hungarian, 1, "1 szám")]
    [InlineData(Localizer.Hungarian, 2, "2 szám")]
    [InlineData(Localizer.English, 0, "0 tracks")]
    [InlineData(Localizer.English, 1, "1 track")]
    [InlineData(Localizer.English, 2, "2 tracks")]
    [InlineData(Localizer.German, 1, "1 Titel")]
    [InlineData(Localizer.German, 5, "5 Titel")]
    public void Format_PicksTheSingularOnlyForExactlyOne(string language, int count, string expected)
    {
        Localizer.Instance.SetLanguage(language);

        Assert.Equal(expected, Localizer.Format("TrackCount", count));
    }

    [Fact]
    public void Format_DoesNotUseTheSingularForOtherNumberTypes()
    {
        Assert.Equal("1 tracks", Localizer.Format("TrackCount", 1L));
    }

    [Theory]
    [InlineData(Localizer.Hungarian, "1 óra 5 perc")]
    [InlineData(Localizer.English, "1 h 5 min")]
    [InlineData(Localizer.German, "1 Std. 5 Min.")]
    public void FormatTotalDuration_WithHours(string language, string expected)
    {
        Localizer.Instance.SetLanguage(language);

        Assert.Equal(expected, Localizer.FormatTotalDuration(TimeSpan.FromMinutes(65)));
    }

    [Theory]
    [InlineData(Localizer.Hungarian, "4 perc 30 mp")]
    [InlineData(Localizer.English, "4 min 30 s")]
    [InlineData(Localizer.German, "4 Min. 30 Sek.")]
    public void FormatTotalDuration_BelowAnHour(string language, string expected)
    {
        Localizer.Instance.SetLanguage(language);

        Assert.Equal(expected, Localizer.FormatTotalDuration(TimeSpan.FromSeconds(270)));
    }

    // ── Choosing and switching the language ───────────────────────────────────────────────────────

    [Theory]
    [InlineData("hu", "hu")]
    [InlineData("HU", "hu")]
    [InlineData("de-AT", "de")]
    [InlineData("en_GB", "en")]
    [InlineData(" en-US ", "en")]
    [InlineData("fr", null)]
    [InlineData("", null)]
    [InlineData("   ", null)]
    [InlineData(null, null)]
    public void Normalize_MapsRegionalCodesAndRejectsUnsupportedOnes(string? input, string? expected)
    {
        Assert.Equal(expected, Localizer.Normalize(input));
    }

    [Fact]
    public void SetLanguage_NotifiesBindingsAndListeners_OnlyWhenTheLanguageChanges()
    {
        var changed = new List<string?>();
        var languageChanged = 0;
        var instance = Localizer.Instance;
        instance.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        instance.LanguageChanged += (_, _) => languageChanged++;

        Assert.True(instance.SetLanguage(Localizer.German));

        // "Item" is what makes Avalonia re-read every {loc:T ...} binding, which goes through the indexer.
        Assert.Contains("Item", changed);
        Assert.Contains("Language", changed);
        Assert.Equal(1, languageChanged);

        Assert.False(instance.SetLanguage(Localizer.German));  // unchanged
        Assert.False(instance.SetLanguage("fr"));               // unsupported
        Assert.False(instance.SetLanguage(null));
        Assert.Equal(1, languageChanged);
        Assert.Equal(Localizer.German, instance.Language);
    }

    [Fact]
    public void Languages_AreTheOnesTheDictionaryKnows()
    {
        Assert.Equal(AllLanguages.OrderBy(x => x), Localizer.Languages.Select(l => l.Code).OrderBy(x => x));
        Assert.All(Localizer.Languages, l => Assert.False(string.IsNullOrWhiteSpace(l.NativeName)));
    }

    // ── Texts that were formatted earlier follow the language ─────────────────────────────────────────

    [Fact]
    public async Task SessionStatus_IsRenderedOnDemand_SoItFollowsTheLanguage()
    {
        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner(), Path.Combine(Path.GetTempPath(), "wiretune_loc_" + Guid.NewGuid().ToString("N")));
        await library.InitializeAsync();
        using var session = new ServerSession(library, repo);
        await session.InitializeAsync();

        await session.ConnectAsync("http://user:secret@host");

        Assert.Contains("Invalid server address", session.StatusMessage);
        Localizer.Instance.SetLanguage(Localizer.German);
        Assert.Contains("Ungültige Serveradresse", session.StatusMessage);
        Localizer.Instance.SetLanguage(Localizer.Hungarian);
        Assert.Contains("Érvénytelen szervercím", session.StatusMessage);
    }

    [Fact]
    public async Task LanguagePreference_IsStoredAsASetting()
    {
        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner(), Path.Combine(Path.GetTempPath(), "wiretune_loc_" + Guid.NewGuid().ToString("N")));
        await library.InitializeAsync();

        Assert.Null(await library.GetPreferenceAsync("Language"));

        await library.SetPreferenceAsync("Language", "de");

        Assert.Equal("de", await library.GetPreferenceAsync("Language"));
        Assert.Equal("de", repo.Settings["Preference.Language"]);
    }
}
