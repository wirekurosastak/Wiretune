using Avalonia;
using Avalonia.Media;
using Avalonia.Styling;
using CommunityToolkit.Mvvm.ComponentModel;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;

namespace Wiretune.UI.Services;

public partial class ThemeService : ObservableObject
{
    [ObservableProperty] private IBrush _currentAccentBrush = new SolidColorBrush(Color.Parse("#67C8E0"));
    private AppSection _lastSection = AppSection.Tracks;

    public ThemeService()
    {
        if (Application.Current is { } app)
        {
            app.ActualThemeVariantChanged += (_, _) => UpdateDynamicBackground(_lastSection);
        }
    }

    public bool IsLight => Application.Current is { } app &&
        (app.RequestedThemeVariant == ThemeVariant.Light ||
         (app.RequestedThemeVariant == ThemeVariant.Default && app.ActualThemeVariant == ThemeVariant.Light));

    public void ToggleTheme() => SetTheme(!IsLight);

    public void SetTheme(bool light)
    {
        if (Application.Current is not { } app) return;
        app.RequestedThemeVariant = light ? ThemeVariant.Light : ThemeVariant.Dark;
        OnPropertyChanged(nameof(IsLight));
        UpdateDynamicBackground(_lastSection);
    }

    /// <summary>The accent family a section is drawn in; the colours of each family are in App.axaml.</summary>
    private static string AccentFamily(AppSection section) => section switch
    {
        AppSection.Tracks or AppSection.Settings => "Cyan",
        AppSection.Albums => "Purple",
        AppSection.Artists or AppSection.Favorites => "Coral",
        AppSection.Playlists => "Lime",
        _ => "Cyan"
    };

    /// <summary>A colour of the palette in App.axaml's theme dictionaries; a missing key is logged and drawn as grey.</summary>
    private static Color PaletteColor(Application app, ThemeVariant theme, string key)
    {
        if (app.TryGetResource(key, theme, out var value) && value is Color color) return color;

        WiretuneLog.Warn("ThemeService", $"The palette has no colour '{key}' for the {theme} theme.");
        return Colors.Gray;
    }

    /// <summary>
    /// Recolours the app for a section: the accent (and its hover and pressed shades) and the tint of the window gradient.
    /// The palette itself lives in App.axaml; this only picks from it and writes the result to the keys the styles use.
    /// </summary>
    public void UpdateDynamicBackground(AppSection section)
    {
        _lastSection = section;
        if (Application.Current is not { } app) return;
        var theme = app.ActualThemeVariant;
        bool isDark = theme == ThemeVariant.Dark;

        var family = AccentFamily(section);
        var accentColor  = PaletteColor(app, theme, $"{family}AccentColor");
        var hoverColor   = PaletteColor(app, theme, $"{family}AccentHoverColor");
        var pressedColor = PaletteColor(app, theme, $"{family}AccentPressedColor");
        var startColor   = PaletteColor(app, theme, $"WindowGradient{section}Color");
        var midColor     = PaletteColor(app, theme, "WindowGradientMidColor");

        var accentBrush  = new SolidColorBrush(accentColor);
        var hoverBrush   = new SolidColorBrush(hoverColor);
        var pressedBrush = new SolidColorBrush(pressedColor);
        var fgBrush      = new SolidColorBrush(isDark ? Colors.White : Colors.Black);
        CurrentAccentBrush = accentBrush;

        var windowGradient = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
            EndPoint   = new RelativePoint(1, 1, RelativeUnit.Relative),
            GradientStops = new GradientStops
            {
                new GradientStop(startColor, 0.0),
                new GradientStop(midColor, 0.5),
                new GradientStop(startColor, 1.0)
            }
        };

        // The accent glow (button hover, search focus, now-playing effects) follows the section accent, like the brushes above.
        string AccentArgb(byte alpha) => $"#{alpha:X2}{accentColor.R:X2}{accentColor.G:X2}{accentColor.B:X2}";
        var accentGlow = BoxShadows.Parse($"0 0 18 0 {AccentArgb(isDark ? (byte)0x60 : (byte)0x48)}");

        if (app.Resources is Avalonia.Controls.ResourceDictionary res)
        {
            void ApplyToDictionary(Avalonia.Controls.IResourceDictionary dict)
            {
                dict["PrimaryActionColor"]      = accentColor;
                dict["PrimaryAction"]           = accentBrush;
                dict["PrimaryActionHover"]      = hoverBrush;
                dict["PrimaryActionPressed"]    = pressedBrush;
                dict["PrimaryActionForeground"] = fgBrush;
                dict["SystemAccentColor"]       = accentColor;
                dict["SystemAccentColorBrush"]  = accentBrush;
                dict["HighlightBrush"]          = accentBrush;
                dict["WindowGradient"]          = windowGradient;
                dict["PrimaryActionGlow"]       = accentGlow;

                dict["SliderThumbBackground"]            = accentBrush;
                dict["SliderThumbBackgroundPointerOver"] = hoverBrush;
                dict["SliderThumbBackgroundPressed"]     = pressedBrush;
                dict["SliderTrackValueFill"]             = accentBrush;
                dict["SliderTrackValueFillPointerOver"]  = accentBrush;
                dict["SliderTrackValueFillPressed"]      = pressedBrush;

                dict["TextControlBorderBrushFocused"]     = accentBrush;
                dict["TextControlBorderBrushPointerOver"] = hoverBrush;

                dict["TagBackground"] = new SolidColorBrush(Color.Parse(isDark ? "#1AFFFFFF" : "#1E232A"));
            }

            ApplyToDictionary(res);
            foreach (var kvp in res.ThemeDictionaries)
            {
                if (kvp.Value is Avalonia.Controls.IResourceDictionary subDict)
                {
                    ApplyToDictionary(subDict);
                }
            }
        }
    }
}
