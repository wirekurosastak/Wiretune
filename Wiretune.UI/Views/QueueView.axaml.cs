using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.VisualTree;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;

namespace Wiretune.UI.Views;

/// <summary>
/// The play queue. Rows are reordered by dragging; a press that is released without moving plays the row. The pointer
/// handlers live here because they need hit testing against the list, which a view model cannot do.
/// </summary>
public partial class QueueView : UserControl
{
    private QueueItemViewModel? _draggedQueueItem;
    private QueueItemViewModel? _hoveredDropTarget;
    private Point _queueDragStartPoint;
    private bool _isDraggingQueue;

    public QueueView()
    {
        InitializeComponent();
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
