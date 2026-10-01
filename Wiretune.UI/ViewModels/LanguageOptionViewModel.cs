using CommunityToolkit.Mvvm.ComponentModel;

namespace Wiretune.UI.ViewModels;

/// <summary>One entry of the language picker.</summary>
public sealed partial class LanguageOptionViewModel(string code, string nativeName) : ObservableObject
{
    public string Code { get; } = code;

    public string NativeName { get; } = nativeName;

    [ObservableProperty] private bool _isSelected;
}
