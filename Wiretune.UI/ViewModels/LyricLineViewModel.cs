using CommunityToolkit.Mvvm.ComponentModel;

namespace Wiretune.UI.ViewModels;

/// <summary>One line of time-synced lyrics as the queue panel shows it; the state drives its highlight.</summary>
public partial class LyricLineViewModel : ObservableObject
{
    public LyricLineViewModel(TimeSpan time, string text)
    {
        Time = time;
        Text = text;
    }

    public TimeSpan Time { get; }
    public string Text { get; }

    /// <summary>An instrumental gap: shown as a small space, never highlighted.</summary>
    public bool IsBlank => Text.Length == 0;

    /// <summary>The line being sung right now.</summary>
    [ObservableProperty] private bool _isActive;

    /// <summary>A line that has already been sung (shown dimmer than the ones still to come).</summary>
    [ObservableProperty] private bool _isPast;
}
