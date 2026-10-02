using Avalonia.Controls;
using Avalonia.Controls.Templates;

namespace Wiretune.UI.Controls;

/// <summary>
/// An <see cref="ItemsControl"/> for the long lists of the phone layout whose rows are really reused while the list scrolls.
/// <para>
/// A virtualizing list keeps the containers of the rows that leave the screen and hands them to the rows that enter it,
/// which is only cheap if the <em>content</em> of a container survives as well. With the stock <see cref="ItemsControl"/> it
/// does not: the containers are <c>ContentPresenter</c>s, and when one is recycled the control clears its content and its
/// template, which throws the row built from the item template away. The next row to use the container builds a new one
/// from the XAML (dozens of controls, their styles and bindings, icon geometries), and on a phone that is tens of
/// kilobytes of garbage and several milliseconds of the UI thread for every row that scrolls into view.
/// </para>
/// <para>
/// Here the container is a plain host that builds the row from <see cref="ItemsControl.ItemTemplate"/> once, the first time
/// it is used. After that a recycled container only receives the next item as its data context (Avalonia sets that
/// itself before it prepares a container) and the bindings of the existing row update in place.
/// </para>
/// The list is styled as an ordinary <see cref="ItemsControl"/> and takes the same item templates.
/// </summary>
public class RecyclingList : ItemsControl
{
    protected override Type StyleKeyOverride => typeof(ItemsControl);

    protected override Control CreateContainerForItemOverride(object? item, int index, object? recycleKey)
    {
        return new RowHost();
    }

    protected override void PrepareContainerForItemOverride(Control container, object? item, int index)
    {
        if (container is RowHost host)
        {
            host.EnsureRow(ItemTemplate, item);
            return;
        }

        base.PrepareContainerForItemOverride(container, item, index);
    }

    /// <summary>Holds the row of one container; the row stays when the container is recycled.</summary>
    private sealed class RowHost : Decorator
    {
        public void EnsureRow(IDataTemplate? template, object? item)
        {
            if (Child != null || template == null) return;

            Child = template.Build(item);
        }
    }
}
