using System.Windows.Input;
using Avalonia;
using Avalonia.Controls;
using Material.Icons;

namespace Wiretune.UI.Controls;

/// <summary>The placeholder of an empty list in the phone layout.</summary>
public partial class PhoneEmptyState : UserControl
{
    public static readonly StyledProperty<MaterialIconKind> IconProperty =
        AvaloniaProperty.Register<PhoneEmptyState, MaterialIconKind>(nameof(Icon), MaterialIconKind.MusicNoteOff);

    public static readonly StyledProperty<string?> TitleProperty =
        AvaloniaProperty.Register<PhoneEmptyState, string?>(nameof(Title));

    public static readonly StyledProperty<string?> HintProperty =
        AvaloniaProperty.Register<PhoneEmptyState, string?>(nameof(Hint));

    public static readonly StyledProperty<string?> ActionTextProperty =
        AvaloniaProperty.Register<PhoneEmptyState, string?>(nameof(ActionText));

    public static readonly StyledProperty<ICommand?> ActionCommandProperty =
        AvaloniaProperty.Register<PhoneEmptyState, ICommand?>(nameof(ActionCommand));

    public static readonly StyledProperty<object?> ActionParameterProperty =
        AvaloniaProperty.Register<PhoneEmptyState, object?>(nameof(ActionParameter));

    public PhoneEmptyState()
    {
        InitializeComponent();
    }

    public MaterialIconKind Icon
    {
        get => GetValue(IconProperty);
        set => SetValue(IconProperty, value);
    }

    public string? Title
    {
        get => GetValue(TitleProperty);
        set => SetValue(TitleProperty, value);
    }

    public string? Hint
    {
        get => GetValue(HintProperty);
        set => SetValue(HintProperty, value);
    }

    /// <summary>Text of the optional button; the button is hidden while it is empty.</summary>
    public string? ActionText
    {
        get => GetValue(ActionTextProperty);
        set => SetValue(ActionTextProperty, value);
    }

    public ICommand? ActionCommand
    {
        get => GetValue(ActionCommandProperty);
        set => SetValue(ActionCommandProperty, value);
    }

    public object? ActionParameter
    {
        get => GetValue(ActionParameterProperty);
        set => SetValue(ActionParameterProperty, value);
    }
}
