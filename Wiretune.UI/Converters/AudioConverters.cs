using System.Globalization;
using Avalonia.Data.Converters;
using Avalonia.Media;
using Wiretune.Core.Models;
using Wiretune.Core.Localization;

namespace Wiretune.UI.Converters;

public class PlayStateToIconConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is PlaybackState state && state == PlaybackState.Playing)
            return Material.Icons.MaterialIconKind.Pause;
        return Material.Icons.MaterialIconKind.Play;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

public class PlayStateToBoolConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        return value is PlaybackState state && state == PlaybackState.Playing;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

public class FavoriteIconConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        return value is true
            ? Material.Icons.MaterialIconKind.Heart
            : Material.Icons.MaterialIconKind.HeartOutline;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

public class FavoriteColorConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        return value is true
            ? new SolidColorBrush(Color.Parse("#FF6B6B")) // CoralAccent
            : new SolidColorBrush(Color.Parse("#737373")); // TextMuted
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

public class QualityBadgeColorConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is bool isHiRes)
        {
            return isHiRes
                ? new SolidColorBrush(Color.Parse("#D05CE3")) // PurpleAccent
                : new SolidColorBrush(Color.Parse("#67C8E0")); // CyanAccent
        }
        if (value is AudioFormat format)
        {
            if (format.IsHiRes) return new SolidColorBrush(Color.Parse("#D05CE3")); // PurpleAccent
            if (format.IsLossless) return new SolidColorBrush(Color.Parse("#67C8E0")); // CyanAccent
        }
        if (value is string s)
        {
            if (s.Contains("Mixed", StringComparison.OrdinalIgnoreCase) || s.Contains("Vegyes", StringComparison.OrdinalIgnoreCase))
                return new SolidColorBrush(Color.Parse("#FF6E6E")); // Reddish / Coral
            if (s.Contains("24bit", StringComparison.OrdinalIgnoreCase) || s.Contains("32bit", StringComparison.OrdinalIgnoreCase)
                || s.Contains("HI-RES", StringComparison.OrdinalIgnoreCase)
                || s.Contains("96kHz", StringComparison.OrdinalIgnoreCase) || s.Contains("88.2kHz", StringComparison.OrdinalIgnoreCase)
                || s.Contains("176.4kHz", StringComparison.OrdinalIgnoreCase) || s.Contains("192kHz", StringComparison.OrdinalIgnoreCase)
                || s.Contains("384kHz", StringComparison.OrdinalIgnoreCase) || s.Contains("DSD", StringComparison.OrdinalIgnoreCase))
                return new SolidColorBrush(Color.Parse("#D05CE3")); // PurpleAccent
            if (s.Contains("16bit", StringComparison.OrdinalIgnoreCase) || s.Contains("CD", StringComparison.OrdinalIgnoreCase)
                || s.Contains("44.1kHz", StringComparison.OrdinalIgnoreCase) || s.Contains("48kHz", StringComparison.OrdinalIgnoreCase)
                || s.Contains("FLAC", StringComparison.OrdinalIgnoreCase) || s.Contains("ALAC", StringComparison.OrdinalIgnoreCase)
                || s.Contains("WAV", StringComparison.OrdinalIgnoreCase))
                return new SolidColorBrush(Color.Parse("#67C8E0")); // CyanAccent
            return new SolidColorBrush(Color.Parse("#A0A6B0")); // TextMuted (high contrast on dark tag background)
        }
        return new SolidColorBrush(Color.Parse("#A0A6B0")); // TextMuted (high contrast on dark tag background)
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

public class ActiveControlBrushConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var isActive = value switch
        {
            bool b => b,
            RepeatMode rm => rm != RepeatMode.Off,
            _ => false
        };

        if (isActive)
        {
            if (value is RepeatMode rm2 && rm2 == RepeatMode.One)
            {
                return new SolidColorBrush(Color.Parse("#D05CE3")); // PurpleAccent for Repeat One
            }

            var paramColor = parameter?.ToString();
            return paramColor switch
            {
                "Lime" => new SolidColorBrush(Color.Parse("#8CFA44")),
                "Purple" => new SolidColorBrush(Color.Parse("#D05CE3")),
                _ => new SolidColorBrush(Color.Parse("#67C8E0")) // CyanAccent default
            };
        }

        return new SolidColorBrush(Color.Parse("#737373")); // TextMuted
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

public class RepeatModeToIconConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is RepeatMode rm)
        {
            return rm switch
            {
                RepeatMode.One => Material.Icons.MaterialIconKind.RepeatOnce,
                _ => Material.Icons.MaterialIconKind.Repeat
            };
        }
        return Material.Icons.MaterialIconKind.Repeat;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

public class IntEqualConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value == null || parameter == null) return false;
        var valStr = value.ToString();
        var paramStr = parameter.ToString();
        return string.Equals(valStr, paramStr, StringComparison.OrdinalIgnoreCase);
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

public class NavActiveBackgroundConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value == null || parameter == null) return Brushes.Transparent;
        var eq = string.Equals(value.ToString(), parameter.ToString(), StringComparison.OrdinalIgnoreCase);
        return eq ? new SolidColorBrush(Color.FromArgb(0x33, 0x67, 0xC8, 0xE0)) : Brushes.Transparent;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

/// <summary>
/// Used by the Android bottom nav bar: returns the active accent colour for the selected tab
/// and the muted text colour for all other tabs so that icons and labels remain visible.
/// </summary>
public class NavActiveTextConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value == null || parameter == null) return new SolidColorBrush(Color.Parse("#737373"));
        var eq = string.Equals(value.ToString(), parameter.ToString(), StringComparison.OrdinalIgnoreCase);
        return eq
            ? new SolidColorBrush(Color.Parse("#67C8E0")) // CyanAccent — active tab
            : new SolidColorBrush(Color.Parse("#737373")); // TextMuted  — inactive tab
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

public class BoolToAdminIconConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        return value is true ? Material.Icons.MaterialIconKind.ShieldAccount : Material.Icons.MaterialIconKind.Account;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

public class BoolToRoleTextConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        return Localizer.Get(value is true ? "RoleAdmin" : "RoleUser");
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}
