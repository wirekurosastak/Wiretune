using Avalonia.Data;
using Avalonia.Markup.Xaml;
using Avalonia.Markup.Xaml.MarkupExtensions;
using Wiretune.Core.Localization;

namespace Wiretune.UI.Localization;

/// <summary>
/// XAML markup extension for a translated text: <c>Text="{loc:T NavArtists}"</c>. It binds to the indexer of
/// <see cref="Localizer.Instance"/>, so the text changes in place when the user switches the language.
/// </summary>
public sealed class TExtension : MarkupExtension
{
    public TExtension() { }

    public TExtension(string key) => Key = key;

    public string Key { get; set; } = string.Empty;

    public override object ProvideValue(IServiceProvider serviceProvider) =>
        new ReflectionBindingExtension($"[{Key}]")
        {
            Mode = BindingMode.OneWay,
            Source = Localizer.Instance,
        }.ProvideValue(serviceProvider);
}
