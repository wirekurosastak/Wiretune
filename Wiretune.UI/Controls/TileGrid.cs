using System.Collections;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;

namespace Wiretune.UI.Controls;

/// <summary>
/// A grid of square-ish tiles (albums, artists) for the phone layout. Avalonia has no virtualizing wrap panel, so
/// the tiles are laid out in rows of as many as fit, and only the rows that are on (or just next to) the screen exist:
/// a library of thousands of albums creates a few dozen controls. Put it inside the page's ScrollViewer.
/// </summary>
/// <remarks>
/// A tile is as wide as the space allows (at least <see cref="MinTileWidth"/>), so every row has the same, known
/// height - tile width plus <see cref="TileExtraHeight"/>, the room for the texts under the cover. That makes the
/// total height exact from the start, which keeps the scroll bar honest.
/// </remarks>
public sealed class TileGrid : Panel
{
    public static readonly StyledProperty<IEnumerable?> ItemsSourceProperty =
        AvaloniaProperty.Register<TileGrid, IEnumerable?>(nameof(ItemsSource));

    public static readonly StyledProperty<IDataTemplate?> ItemTemplateProperty =
        AvaloniaProperty.Register<TileGrid, IDataTemplate?>(nameof(ItemTemplate));

    public static readonly StyledProperty<double> MinTileWidthProperty =
        AvaloniaProperty.Register<TileGrid, double>(nameof(MinTileWidth), 150);

    public static readonly StyledProperty<double> SpacingProperty =
        AvaloniaProperty.Register<TileGrid, double>(nameof(Spacing), 6);

    public static readonly StyledProperty<double> TileExtraHeightProperty =
        AvaloniaProperty.Register<TileGrid, double>(nameof(TileExtraHeight), 48);

    /// <summary>Rows to keep ready above and below the visible area, so a fling does not show empty space.</summary>
    private const int RowsOfMargin = 2;

    /// <summary>Rows created before the first layout has told us how much of the grid is visible.</summary>
    private const int InitialRows = 6;

    /// <summary>Tiles that scrolled away, kept for the next row that needs one: a tile is the expensive part (a cover, a
    /// button, a few texts), a row around it is nothing. Only as many as a few rows are worth.</summary>
    private const int MaxPooledTiles = 40;

    private readonly Dictionary<int, StackPanel> _rows = new();
    private readonly Stack<ContentControl> _tilePool = new();
    private List<object?> _items = new();
    private int _columns = 1;
    private double _tileWidth;
    private Rect _viewport;
    private bool _hasViewport;
    private int _realizedFirst;
    private int _realizedLast = -1;

    static TileGrid()
    {
        AffectsMeasure<TileGrid>(ItemsSourceProperty, ItemTemplateProperty, MinTileWidthProperty, SpacingProperty, TileExtraHeightProperty);
        ItemsSourceProperty.Changed.AddClassHandler<TileGrid>((grid, _) => grid.ResetItems());
        ItemTemplateProperty.Changed.AddClassHandler<TileGrid>((grid, _) => grid.ClearRows());
        SpacingProperty.Changed.AddClassHandler<TileGrid>((grid, _) => grid.ClearRows());
        TileExtraHeightProperty.Changed.AddClassHandler<TileGrid>((grid, _) => grid.ClearRows());
    }

    public TileGrid()
    {
        EffectiveViewportChanged += OnEffectiveViewportChanged;
    }

    public IEnumerable? ItemsSource
    {
        get => GetValue(ItemsSourceProperty);
        set => SetValue(ItemsSourceProperty, value);
    }

    /// <summary>How a tile looks. It gets the item as its DataContext and is stretched to the tile's width.</summary>
    public IDataTemplate? ItemTemplate
    {
        get => GetValue(ItemTemplateProperty);
        set => SetValue(ItemTemplateProperty, value);
    }

    public double MinTileWidth
    {
        get => GetValue(MinTileWidthProperty);
        set => SetValue(MinTileWidthProperty, value);
    }

    public double Spacing
    {
        get => GetValue(SpacingProperty);
        set => SetValue(SpacingProperty, value);
    }

    /// <summary>Height of a tile beyond its (square) cover: the room for the texts below it.</summary>
    public double TileExtraHeight
    {
        get => GetValue(TileExtraHeightProperty);
        set => SetValue(TileExtraHeightProperty, value);
    }

    private double RowHeight => _tileWidth + TileExtraHeight + Spacing;

    private int RowCount => (_items.Count + _columns - 1) / _columns;

    private void ResetItems()
    {
        _items = ItemsSource?.Cast<object?>().ToList() ?? new List<object?>();
        ClearRows();
    }

    private void ClearRows()
    {
        Children.Clear();
        _rows.Clear();
        _tilePool.Clear();
        _realizedFirst = 0;
        _realizedLast = -1;
    }

    /// <summary>Takes a row off the grid and keeps its tiles for reuse.</summary>
    private void ReleaseRow(int index)
    {
        if (!_rows.Remove(index, out var row)) return;

        Children.Remove(row);
        for (var i = row.Children.Count - 1; i >= 0; i--)
        {
            if (row.Children[i] is ContentControl tile && _tilePool.Count < MaxPooledTiles) _tilePool.Push(tile);
        }

        row.Children.Clear();
    }

    private void OnEffectiveViewportChanged(object? sender, EffectiveViewportChangedEventArgs e)
    {
        _viewport = e.EffectiveViewport;
        _hasViewport = true;

        // Only a change in which rows are needed is worth a new layout pass.
        var (first, last) = VisibleRows();
        if (first != _realizedFirst || last != _realizedLast) InvalidateMeasure();
    }

    /// <summary>The first and last row that should exist now; (0, -1) when none should.</summary>
    private (int First, int Last) VisibleRows()
    {
        var rowCount = RowCount;
        var rowHeight = RowHeight;
        if (rowCount == 0 || rowHeight <= 0) return (0, -1);

        if (!_hasViewport) return (0, Math.Min(rowCount - 1, InitialRows - 1));
        if (_viewport.Height <= 0) return (0, -1); // scrolled out of sight or on a hidden page

        var first = (int)Math.Floor(_viewport.Top / rowHeight) - RowsOfMargin;
        var last = (int)Math.Floor(_viewport.Bottom / rowHeight) + RowsOfMargin;
        first = Math.Clamp(first, 0, rowCount - 1);
        last = Math.Clamp(last, 0, rowCount - 1);
        return first > last ? (0, -1) : (first, last);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var width = double.IsInfinity(availableSize.Width) ? MinTileWidth : availableSize.Width;
        var columns = Math.Max(1, (int)Math.Floor((width + Spacing) / (MinTileWidth + Spacing)));
        var tileWidth = Math.Max(1, Math.Floor((width - (columns - 1) * Spacing) / columns));
        if (columns != _columns || Math.Abs(tileWidth - _tileWidth) >= 0.5)
        {
            ClearRows();
            _columns = columns;
            _tileWidth = tileWidth;
        }

        var (first, last) = VisibleRows();
        foreach (var index in _rows.Keys.Where(i => i < first || i > last).ToList()) ReleaseRow(index);

        for (var index = first; index <= last; index++)
        {
            if (_rows.ContainsKey(index)) continue;
            var row = BuildRow(index);
            _rows[index] = row;
            Children.Add(row);
        }

        _realizedFirst = first;
        _realizedLast = last;

        var rowHeight = RowHeight;
        foreach (var row in _rows.Values) row.Measure(new Size(width, rowHeight));
        return new Size(width, RowCount * rowHeight);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var rowHeight = RowHeight;
        foreach (var (index, row) in _rows) row.Arrange(new Rect(0, index * rowHeight, finalSize.Width, rowHeight));
        return finalSize;
    }

    private StackPanel BuildRow(int index)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Spacing };
        var start = index * _columns;
        for (var i = start; i < Math.Min(start + _columns, _items.Count); i++)
        {
            // A tile that scrolled away is given a new album and keeps its controls: the template only has to be built
            // for the first screenful, scrolling afterwards just swaps the data (a row of fresh tiles costs several
            // milliseconds on a phone - a dropped frame every few rows of a fling).
            var tile = _tilePool.Count > 0
                ? _tilePool.Pop()
                : new ContentControl { VerticalAlignment = VerticalAlignment.Top };

            tile.Width = _tileWidth;
            if (!ReferenceEquals(tile.ContentTemplate, ItemTemplate)) tile.ContentTemplate = ItemTemplate;
            tile.Content = _items[i];
            row.Children.Add(tile);
        }

        return row;
    }
}
