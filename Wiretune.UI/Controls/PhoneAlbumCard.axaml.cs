using System.Windows.Input;
using Avalonia;
using Avalonia.Controls;

namespace Wiretune.UI.Controls;

/// <summary>An album tile of the phone layout. <see cref="OpenCommand"/> receives the <c>AlbumCardViewModel</c>.</summary>
public partial class PhoneAlbumCard : UserControl
{
    public static readonly StyledProperty<ICommand?> OpenCommandProperty =
        AvaloniaProperty.Register<PhoneAlbumCard, ICommand?>(nameof(OpenCommand));

    public PhoneAlbumCard()
    {
        InitializeComponent();
    }

    public ICommand? OpenCommand
    {
        get => GetValue(OpenCommandProperty);
        set => SetValue(OpenCommandProperty, value);
    }
}
