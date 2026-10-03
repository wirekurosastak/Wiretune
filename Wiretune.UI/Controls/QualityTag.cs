using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using Avalonia.Threading;
using Wiretune.Core.Localization;
using Wiretune.Core.Models;

namespace Wiretune.UI.Controls;

/// <summary>
/// The quality tag: a small pill in the colour of the tier the recording is in, reading for example
/// <c>FLAC 24bit/96kHz</c> (gold), <c>FLAC 16bit/44.1kHz</c> (silver) or <c>MP3 320kbps</c> (bronze); the colour
/// alone names the tier.
/// Gold is hi-res, silver is lossless at CD resolution, bronze is everything that is not lossless (see
/// <see cref="QualityTier"/>); hovering the tag explains the tier.
/// <para>
/// The pill has a fill and an outline of its own instead of taking the theme's tag background, so the three medal
/// colours keep their contrast in the light and in the dark theme. The tier word follows the interface language.
/// </para>
/// </summary>
public sealed class QualityTag : Border
{
    public static readonly StyledProperty<QualityTier> TierProperty =
        AvaloniaProperty.Register<QualityTag, QualityTier>(nameof(Tier), QualityTier.Silver);

    /// <summary>The text after the tier word, e.g. "FLAC 24bit/96kHz" or "MIXED"; empty shows the tier word alone.</summary>
    public static readonly StyledProperty<string?> SpecProperty =
        AvaloniaProperty.Register<QualityTag, string?>(nameof(Spec));

    /// <summary>For small tiles: only the first word of <see cref="Spec"/> (the file format) follows the tier word.</summary>
    public static readonly StyledProperty<bool> IsCompactProperty =
        AvaloniaProperty.Register<QualityTag, bool>(nameof(IsCompact));

    public static readonly StyledProperty<double> LabelSizeProperty =
        AvaloniaProperty.Register<QualityTag, double>(nameof(LabelSize), 10);

    // Indexed by (int)QualityTier: bronze, silver, gold.
    private static readonly IBrush[] Foregrounds = { Solid("#E39A57"), Solid("#D3DAE3"), Solid("#F5C842") };
    private static readonly IBrush[] Fills = { Solid("#33200F"), Solid("#272C33"), Solid("#2E250E") };
    private static readonly IBrush[] Outlines = { Solid("#8A5428"), Solid("#6C7683"), Solid("#8A6D1F") };

    private readonly TextBlock _label = new()
    {
        FontWeight = FontWeight.Black,
        VerticalAlignment = VerticalAlignment.Center,
        TextTrimming = TextTrimming.CharacterEllipsis,
    };

    static QualityTag()
    {
        TierProperty.Changed.AddClassHandler<QualityTag>((tag, _) => tag.Refresh());
        SpecProperty.Changed.AddClassHandler<QualityTag>((tag, _) => tag.Refresh());
        IsCompactProperty.Changed.AddClassHandler<QualityTag>((tag, _) => tag.Refresh());
        LabelSizeProperty.Changed.AddClassHandler<QualityTag>((tag, _) => tag._label.FontSize = tag.LabelSize);
    }

    public QualityTag()
    {
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(4);
        Padding = new Thickness(6, 1);
        HorizontalAlignment = HorizontalAlignment.Left;
        VerticalAlignment = VerticalAlignment.Center;
        _label.FontSize = LabelSize;
        Child = _label;
        Refresh();
    }

    public QualityTier Tier
    {
        get => GetValue(TierProperty);
        set => SetValue(TierProperty, value);
    }

    public string? Spec
    {
        get => GetValue(SpecProperty);
        set => SetValue(SpecProperty, value);
    }

    public bool IsCompact
    {
        get => GetValue(IsCompactProperty);
        set => SetValue(IsCompactProperty, value);
    }

    public double LabelSize
    {
        get => GetValue(LabelSizeProperty);
        set => SetValue(LabelSizeProperty, value);
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        Localizer.Instance.LanguageChanged += OnLanguageChanged;
        Refresh(); // the language may have changed while the tag was not on screen
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        Localizer.Instance.LanguageChanged -= OnLanguageChanged;
        base.OnDetachedFromVisualTree(e);
    }

    private void OnLanguageChanged(object? sender, EventArgs e)
    {
        if (Dispatcher.UIThread.CheckAccess()) Refresh();
        else Dispatcher.UIThread.Post(Refresh);
    }

    private void Refresh()
    {
        var tier = Tier;
        var index = Index(tier);
        Background = Fills[index];
        BorderBrush = Outlines[index];
        _label.Foreground = Foregrounds[index];
        _label.Text = tier.TagText(Spec, IsCompact);

        // The tooltip explains the tier, and spells out the format when the tag itself only has room for its first word.
        var hint = tier.Hint();
        var spec = Spec;
        ToolTip.SetTip(this, IsCompact && !string.IsNullOrWhiteSpace(spec) ? $"{hint}\n{spec.Trim()}" : hint);
    }

    private static int Index(QualityTier tier) =>
        (uint)(int)tier < (uint)Foregrounds.Length ? (int)tier : (int)QualityTier.Silver;

    private static IBrush Solid(string hex) => new ImmutableSolidColorBrush(Color.Parse(hex));
}
