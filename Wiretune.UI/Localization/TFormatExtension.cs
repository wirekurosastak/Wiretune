using System.Globalization;
using Avalonia;
using Avalonia.Data;
using Avalonia.Data.Converters;
using Avalonia.Markup.Xaml;
using Wiretune.Core.Localization;

namespace Wiretune.UI.Localization;

/// <summary>
/// A translated text with placeholders filled from the data context:
/// <c>Text="{loc:TFormat TrackCount, Path=TrackCount}"</c>. Up to three values can be given (<c>Path</c>,
/// <c>Path2</c>, <c>Path3</c>); the text is rebuilt when either a value or the language changes.
/// </summary>
public sealed class TFormatExtension : MarkupExtension
{
    public TFormatExtension() { }

    public TFormatExtension(string key) => Key = key;

    public string Key { get; set; } = string.Empty;

    public string? Path { get; set; }

    public string? Path2 { get; set; }

    public string? Path3 { get; set; }

    public override object ProvideValue(IServiceProvider serviceProvider)
    {
        var binding = new MultiBinding { Converter = new FormatConverter(Key), Mode = BindingMode.OneWay };

        // The first binding only exists to re-run the converter when the language changes.
        binding.Bindings.Add(new Binding(nameof(Localizer.Language)) { Source = Localizer.Instance, Mode = BindingMode.OneWay });
        foreach (var path in new[] { Path, Path2, Path3 })
        {
            if (path != null) binding.Bindings.Add(new Binding(path) { Mode = BindingMode.OneWay });
        }

        return binding;
    }

    private sealed class FormatConverter(string key) : IMultiValueConverter
    {
        public object? Convert(IList<object?> values, Type targetType, object? parameter, CultureInfo culture)
        {
            var args = new object?[Math.Max(0, values.Count - 1)];
            for (var i = 1; i < values.Count; i++)
            {
                // A value that is not available (no album selected, ...) leaves the text unset instead of showing "{0}".
                if (values[i] is UnsetValueType or BindingNotification) return AvaloniaProperty.UnsetValue;
                args[i - 1] = values[i];
            }

            return Localizer.Format(key, args);
        }
    }
}
