using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;

namespace Wiretune.UI.Services;

public interface ILazyLoad
{
    void EnsureLoaded();
}

/// <summary>
/// Attached behaviour that calls <see cref="ILazyLoad.EnsureLoaded"/> the first time the control scrolls into
/// view, so large non-virtualized grids (albums) only decode the covers the user actually sees.
/// </summary>
public static class ViewportLoad
{
    public static readonly AttachedProperty<ILazyLoad?> TargetProperty =
        AvaloniaProperty.RegisterAttached<Control, ILazyLoad?>("Target", typeof(ViewportLoad));

    static ViewportLoad()
    {
        TargetProperty.Changed.AddClassHandler<Control>((control, e) =>
        {
            control.EffectiveViewportChanged -= OnEffectiveViewportChanged;
            if (e.NewValue is ILazyLoad) control.EffectiveViewportChanged += OnEffectiveViewportChanged;
        });
    }

    public static ILazyLoad? GetTarget(Control control) => control.GetValue(TargetProperty);

    public static void SetTarget(Control control, ILazyLoad? value) => control.SetValue(TargetProperty, value);

    private static void OnEffectiveViewportChanged(object? sender, EffectiveViewportChangedEventArgs e)
    {
        if (sender is not Control control || GetTarget(control) is not { } target) return;

        var viewport = e.EffectiveViewport;
        if (viewport.Width <= 0 || viewport.Height <= 0) return;
        if (!viewport.Intersects(new Rect(control.Bounds.Size))) return;

        control.EffectiveViewportChanged -= OnEffectiveViewportChanged;
        target.EnsureLoaded();
    }
}
