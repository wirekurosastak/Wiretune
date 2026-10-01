using System.Windows.Input;
using Avalonia;
using Avalonia.Controls;

namespace Wiretune.UI.Controls;

/// <summary>An artist tile of the phone layout. <see cref="OpenCommand"/> receives the <c>Artist</c>.</summary>
public partial class PhoneArtistCard : UserControl
{
    public static readonly StyledProperty<ICommand?> OpenCommandProperty =
        AvaloniaProperty.Register<PhoneArtistCard, ICommand?>(nameof(OpenCommand));

    public PhoneArtistCard()
    {
        InitializeComponent();
    }

    public ICommand? OpenCommand
    {
        get => GetValue(OpenCommandProperty);
        set => SetValue(OpenCommandProperty, value);
    }
}
