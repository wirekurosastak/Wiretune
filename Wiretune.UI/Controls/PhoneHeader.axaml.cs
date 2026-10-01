using Avalonia;
using Avalonia.Controls;

namespace Wiretune.UI.Controls;

/// <summary>The title bar of a top-level page of the phone layout.</summary>
public partial class PhoneHeader : UserControl
{
    public static readonly StyledProperty<string?> TitleProperty =
        AvaloniaProperty.Register<PhoneHeader, string?>(nameof(Title));

    public static readonly StyledProperty<object?> SubtitleProperty =
        AvaloniaProperty.Register<PhoneHeader, object?>(nameof(Subtitle));

    public static readonly StyledProperty<bool> ShowSearchProperty =
        AvaloniaProperty.Register<PhoneHeader, bool>(nameof(ShowSearch), true);

    public PhoneHeader()
    {
        InitializeComponent();
    }

    public string? Title
    {
        get => GetValue(TitleProperty);
        set => SetValue(TitleProperty, value);
    }

    /// <summary>A text, or a panel of texts, shown under the title.</summary>
    public object? Subtitle
    {
        get => GetValue(SubtitleProperty);
        set => SetValue(SubtitleProperty, value);
    }

    /// <summary>Shows the search button (default); pages that have nothing to search hide it.</summary>
    public bool ShowSearch
    {
        get => GetValue(ShowSearchProperty);
        set => SetValue(ShowSearchProperty, value);
    }
}
