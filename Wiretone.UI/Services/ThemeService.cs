using Avalonia;
using Avalonia.Media;
using Avalonia.Styling;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Wiretone.UI.Services;

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

        string[] darkAccents  = { "#67C8E0", "#D05CE3", "#FF6B6B", "#AEEA00", "#FF6B6B", "#67C8E0" };
        string[] lightAccents = { "#3A9FB8", "#A03BB5", "#D94A4A", "#7FB800", "#D94A4A", "#3A9FB8" };
        string activeAccent = isDark ? darkAccents[tabIndex % darkAccents.Length] : lightAccents[tabIndex % lightAccents.Length];

        var accentColor = Color.Parse(activeAccent);
        var accentBrush = new SolidColorBrush(accentColor);
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

        if (app.Resources is Avalonia.Controls.ResourceDictionary res)
        {
            res["PrimaryActionColor"] = accentColor;
            res["PrimaryAction"]      = accentBrush;
            res["SystemAccentColor"] = accentColor;
            res["SystemAccentColorBrush"] = accentBrush;
            res["HighlightBrush"] = accentBrush;

            var startColor = Color.Parse(start);
            var midColor   = Color.Parse(mid);

            res["WindowGradient"] = new LinearGradientBrush
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
        }
    }
}
