using Avalonia;
using Avalonia.Media;
using Avalonia.Styling;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Wiretune.UI.Services;

public partial class ThemeService : ObservableObject
{
    [ObservableProperty] private IBrush _currentAccentBrush = new SolidColorBrush(Color.Parse("#67C8E0"));
    private int _lastIndex = 0;

    public ThemeService()
    {
        if (Application.Current is { } app)
        {
            app.ActualThemeVariantChanged += (_, _) => UpdateDynamicBackground(_lastIndex);
        }
    }

    public void ToggleTheme()
    {
        if (Application.Current is not { } app) return;
        var isLight = app.RequestedThemeVariant == ThemeVariant.Light ||
                      (app.RequestedThemeVariant == ThemeVariant.Default && app.ActualThemeVariant == ThemeVariant.Light);
        app.RequestedThemeVariant = isLight ? ThemeVariant.Dark : ThemeVariant.Light;
        UpdateDynamicBackground(_lastIndex);
    }

    public void UpdateDynamicBackground(int tabIndex)
    {
        _lastIndex = tabIndex;
        if (Application.Current is not { } app) return;
        bool isDark = app.ActualThemeVariant == ThemeVariant.Dark;

        string[] darkAccents        = { "#67C8E0", "#D05CE3", "#FF6B6B", "#AEEA00", "#FF6B6B", "#67C8E0" };
        string[] lightAccents       = { "#3A9FB8", "#A03BB5", "#D94A4A", "#7FB800", "#D94A4A", "#3A9FB8" };
        string[] darkHoverAccents   = { "#8BE0F5", "#DF7DF0", "#FF8585", "#C2FF1A", "#FF8585", "#8BE0F5" };
        string[] lightHoverAccents  = { "#52B3CC", "#B848CF", "#E85D5D", "#91CF05", "#E85D5D", "#52B3CC" };
        string[] darkPressedAccents = { "#4FB0C8", "#B835CD", "#E05555", "#95CA00", "#E05555", "#4FB0C8" };
        string[] lightPressedAccents= { "#2A8F98", "#88289E", "#B83535", "#6B9900", "#B83535", "#2A8F98" };
        string[] fgColors           = { "#000000", "#FFFFFF", "#FFFFFF", "#000000", "#FFFFFF", "#000000" };

        string activeAccent  = isDark ? darkAccents[tabIndex % darkAccents.Length] : lightAccents[tabIndex % lightAccents.Length];
        string activeHover   = isDark ? darkHoverAccents[tabIndex % darkHoverAccents.Length] : lightHoverAccents[tabIndex % lightHoverAccents.Length];
        string activePressed = isDark ? darkPressedAccents[tabIndex % darkPressedAccents.Length] : lightPressedAccents[tabIndex % lightPressedAccents.Length];
        string activeFg      = fgColors[tabIndex % fgColors.Length];

        var accentColor  = Color.Parse(activeAccent);
        var accentBrush  = new SolidColorBrush(accentColor);
        var hoverColor   = Color.Parse(activeHover);
        var hoverBrush   = new SolidColorBrush(hoverColor);
        var pressedColor = Color.Parse(activePressed);
        var pressedBrush = new SolidColorBrush(pressedColor);
        var fgBrush      = new SolidColorBrush(Color.Parse(activeFg));
        CurrentAccentBrush = accentBrush;

        (string start, string mid) = (tabIndex, isDark) switch
        {
            (0, true)  => ("#051522", "#000000"), // Tracks Dark: Deep Cyan
            (1, true)  => ("#1F0833", "#000000"), // Albums Dark: Deep Purple
            (2, true)  => ("#2B0C0C", "#000000"), // Artists Dark: Deep Coral
            (3, true)  => ("#142400", "#000000"), // Playlists Dark: Deep Lime
            (4, true)  => ("#260D12", "#000000"), // Favorites Dark: Deep Rose/Coral
            (5, true)  => ("#091824", "#000000"), // Settings Dark: Deep Cyan/Slate
            (0, false) => ("#E8F7FC", "#EEF1F5"), // Tracks Light: Soft Ice Cyan
            (1, false) => ("#F3E9FF", "#EEF1F5"), // Albums Light: Soft Lavender
            (2, false) => ("#FFECEC", "#EEF1F5"), // Artists Light: Soft Coral/Rose
            (3, false) => ("#EEF9E6", "#EEF1F5"), // Playlists Light: Soft Mint/Lime
            (4, false) => ("#FFF0F2", "#EEF1F5"), // Favorites Light: Soft Rose/Pink
            (5, false) => ("#E8F7FC", "#EEF1F5"), // Settings Light: Soft Ice Cyan
            (_, true)  => ("#08080C", "#000000"), // Dark fallback
            (_, false) => ("#F5F7FA", "#EEF1F5")  // Light fallback
        };

        var startColor = Color.Parse(start);
        var midColor   = Color.Parse(mid);

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
