using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.VisualTree;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;

namespace Wiretune.UI.Views;

public partial class MainView : UserControl
{
    private QueueItemViewModel? _draggedQueueItem;
    private QueueItemViewModel? _hoveredDropTarget;
    private Point _queueDragStartPoint;
    private bool _isDraggingQueue;

    public MainView()
    {
        InitializeComponent();
    }

    /// <summary>Keeps header controls clear of window caption buttons drawn over an extended client area.</summary>
    public void SetCaptionButtonsInset(double right)
    {
        HeaderBar.Padding = new Thickness(24, 0, 24 + right, 0);
    }

    private void HeaderBar_PointerPressed(object? sender, PointerPressedEventArgs e)
    {
        if (VisualRoot is Window window && e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
        {
            if (e.ClickCount == 2)
            {
                window.WindowState = window.WindowState == WindowState.Maximized
                    ? WindowState.Normal
                    : WindowState.Maximized;
            }
            else
            {
                window.BeginMoveDrag(e);
            }
        }
    }

    private void MinimizeWindow_Click(object? sender, RoutedEventArgs e)
    {
        if (VisualRoot is Window window)
        {
            window.WindowState = WindowState.Minimized;
        }
    }

    private void MaximizeWindow_Click(object? sender, RoutedEventArgs e)
    {
        if (VisualRoot is Window window)
        {
            window.WindowState = window.WindowState == WindowState.Maximized
                ? WindowState.Normal
                : WindowState.Maximized;
        }
    }

    private void CloseWindow_Click(object? sender, RoutedEventArgs e)
    {
        if (VisualRoot is Window window)
        {
            window.Close();
        }
    }

    protected override void OnSizeChanged(SizeChangedEventArgs e)
    {
        base.OnSizeChanged(e);
        if (DataContext is MainViewModel vm)
        {
            vm.IsCompactLayout = e.NewSize.Width < MainViewModel.CompactLayoutWidth;
        }
    }

    private void QueueItem_PointerPressed(object? sender, PointerPressedEventArgs e)
    {
        try
        {
            if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;

            if (e.Source is Visual sourceVisual)
            {
                var btn = sourceVisual.FindAncestorOfType<Button>(includeSelf: true);
                if (btn != null && (btn.Classes.Contains("action-btn") || btn.Classes.Contains("remove-btn"))) return;
            }

            if (sender is Border border && border.Tag is QueueItemViewModel item)
            {
                _draggedQueueItem = item;
                _hoveredDropTarget = null;
                _queueDragStartPoint = e.GetPosition(this);
                _isDraggingQueue = false;
            }
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("QueueDrag", $"PointerPressed error: {ex.Message}", ex);
        }
    }

    private void QueueItem_PointerMoved(object? sender, PointerEventArgs e)
    {
        try
        {
            if (_draggedQueueItem == null || !e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;

            var currentPoint = e.GetPosition(this);
            var diff = currentPoint - _queueDragStartPoint;

            if (!_isDraggingQueue && (Math.Abs(diff.Y) > 8 || Math.Abs(diff.X) > 8))
            {
                _isDraggingQueue = true;
            }

            if (_isDraggingQueue)
            {
                var hit = this.InputHitTest(currentPoint) as Visual;
                var targetItem = FindQueueItemFromVisual(hit);

                if (targetItem != null && !ReferenceEquals(targetItem, _hoveredDropTarget))
                {
                    if (_hoveredDropTarget != null) _hoveredDropTarget.IsDropTarget = false;
                    _hoveredDropTarget = targetItem;
                    if (!ReferenceEquals(_hoveredDropTarget, _draggedQueueItem))
                    {
                        _hoveredDropTarget.IsDropTarget = true;
                    }
                }
                e.Handled = true;
            }
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("QueueDrag", $"PointerMoved error: {ex.Message}", ex);
        }
    }

    private void QueueItem_PointerReleased(object? sender, PointerReleasedEventArgs e)
    {
        try
        {
            if (_draggedQueueItem != null)
            {
                if (_hoveredDropTarget != null)
                {
                    _hoveredDropTarget.IsDropTarget = false;
                }

                if (_isDraggingQueue)
                {
                    var target = _hoveredDropTarget ?? FindQueueItemFromVisual(this.InputHitTest(e.GetPosition(this)) as Visual);

                    if (target != null && !ReferenceEquals(target, _draggedQueueItem))
                    {
                        if (DataContext is MainViewModel vm)
                        {
                            vm.Player.MoveQueueTrack(_draggedQueueItem.Index, target.Index);
                        }
                    }
                }
                else
                {
                    if (DataContext is MainViewModel vm)
                    {
                        vm.Player.PlayQueueTrack(_draggedQueueItem.Track);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("QueueDrag", $"PointerReleased error: {ex.Message}", ex);
        }
        finally
        {
            if (_hoveredDropTarget != null) _hoveredDropTarget.IsDropTarget = false;
            _draggedQueueItem = null;
            _hoveredDropTarget = null;
            _isDraggingQueue = false;
            e.Handled = true;
        }
    }

    private void QueueItem_PointerCaptureLost(object? sender, PointerCaptureLostEventArgs e)
    {
        if (_hoveredDropTarget != null) _hoveredDropTarget.IsDropTarget = false;
        _draggedQueueItem = null;
        _hoveredDropTarget = null;
        _isDraggingQueue = false;
    }

    private static QueueItemViewModel? FindQueueItemFromVisual(Visual? visual)
    {
        if (visual == null) return null;
        if (visual is Border b && b.Classes.Contains("queue-item") && b.Tag is QueueItemViewModel q0)
            return q0;
        return visual.GetVisualAncestors()
            .OfType<Border>()
            .FirstOrDefault(border => border.Classes.Contains("queue-item"))?.Tag as QueueItemViewModel;
    }
}

