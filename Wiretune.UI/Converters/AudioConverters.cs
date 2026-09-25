using System.Globalization;
using Avalonia.Data.Converters;
using Avalonia.Media;
using Wiretune.Core.Models;

namespace Wiretune.UI.Converters;

public class DurationConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is TimeSpan ts)
        {
            return ts.Hours > 0
                ? ts.ToString(@"h\:mm\:ss")
                : ts.ToString(@"m\:ss");
        }
        if (value is double seconds)
        {
            var t = TimeSpan.FromSeconds(seconds);
            return t.Hours > 0 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");
        }
        return "0:00";
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

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
            if (s.Contains("HI-RES", StringComparison.OrdinalIgnoreCase) || s.Contains("24bit", StringComparison.OrdinalIgnoreCase))
                return new SolidColorBrush(Color.Parse("#D05CE3")); // PurpleAccent
            return new SolidColorBrush(Color.Parse("#67C8E0")); // CyanAccent
        }
        return new SolidColorBrush(Color.Parse("#737373")); // TextMuted
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

public class SpectrumBarHeightConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is double d)
        {
            return Math.Clamp(d * 29.0 + 3.0, 3.0, 32.0);
        }
        if (value is float f)
        {
            return Math.Clamp((double)f * 29.0 + 3.0, 3.0, 32.0);
        }
        return 3.0;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}



