using Avalonia;
using Avalonia.Controls;

namespace Wiretune.UI.Controls;

/// <summary>
/// A <see cref="Border"/> that is as tall as it is wide: the cover of an album or artist tile.
/// <para>
/// The tiles used to get their height from a binding to their own width (<c>Height="{Binding $self.Bounds.Width}"</c>).
/// That works, but the width is only known after the first layout pass, so every new tile was measured, arranged, had its
/// height changed by the binding and was then laid out a second time - on every row the grid created while scrolling.
/// Here the height simply follows the width that is offered during the measure pass, so one pass is enough.
/// </para>
/// </summary>
public sealed class SquareBorder : Border
{
    protected override Size MeasureOverride(Size availableSize)
    {
        var side = availableSize.Width;

        // No width to take the side from (an unbounded measure): behave like a plain Border.
        if (double.IsInfinity(side) || double.IsNaN(side)) return base.MeasureOverride(availableSize);

        base.MeasureOverride(new Size(side, side));
        return new Size(side, side);
    }
}
