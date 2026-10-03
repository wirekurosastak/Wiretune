using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;
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

    // Synced lyrics: where on the panel the current line rests (a little above the middle, as in other players).
    private const double LyricRestFraction = 0.4;
    private static readonly TimeSpan ManualScrollPause = TimeSpan.FromSeconds(4);

    private PlayerViewModel? _player;
    private DateTime _manualScrollUntil = DateTime.MinValue;
    private int _scrollGeneration;

    public QueueView()
    {
        InitializeComponent();

        DataContextChanged += OnDataContextChanged;
        SyncedLyricsScroll.SizeChanged += OnLyricsSizeChanged;
        // The user scrolling the lyrics themselves (wheel or touch) wins over the automatic scroll for a few seconds.
        SyncedLyricsScroll.AddHandler(PointerWheelChangedEvent, OnLyricsScrolledByUser, RoutingStrategies.Tunnel);
        SyncedLyricsScroll.AddHandler(Gestures.ScrollGestureEvent, OnLyricsScrolledByUser, RoutingStrategies.Tunnel);
    }

    private void OnDataContextChanged(object? sender, EventArgs e)
    {
        if (_player != null) _player.PropertyChanged -= OnPlayerPropertyChanged;
        _player = (DataContext as MainViewModel)?.Player;
        if (_player != null) _player.PropertyChanged += OnPlayerPropertyChanged;
    }

    private void OnPlayerPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(PlayerViewModel.CurrentLyricIndex):
                FollowCurrentLine(animate: true);
                break;
            case nameof(PlayerViewModel.LyricLines):
            case nameof(PlayerViewModel.IsQueueOpen):
                // New lines (or the panel just appeared): wait for the layout, then jump, without gliding, to the right place.
                _manualScrollUntil = DateTime.MinValue;
                Dispatcher.UIThread.Post(() => FollowCurrentLine(animate: false), DispatcherPriority.Loaded);
                break;
        }
    }

    private void OnLyricsSizeChanged(object? sender, SizeChangedEventArgs e)
    {
        // Empty space above and below lets the first and the last line rest at the same height as the others.
        var height = e.NewSize.Height;
        SyncedLyricsItems.Margin = new Thickness(0, height * LyricRestFraction, 0, height * (1 - LyricRestFraction));
        Dispatcher.UIThread.Post(() => FollowCurrentLine(animate: false), DispatcherPriority.Loaded);
    }

    private void OnLyricsScrolledByUser(object? sender, RoutedEventArgs e)
    {
        _manualScrollUntil = DateTime.UtcNow + ManualScrollPause;
        _scrollGeneration++; // stops a glide that is still running, so it does not fight the user's hand
    }

    private void LyricLine_Tapped(object? sender, TappedEventArgs e)
    {
        if (sender is Control { DataContext: LyricLineViewModel line } && _player != null)
        {
            _manualScrollUntil = DateTime.MinValue; // the lyrics follow the song again right away
            _player.SeekToLyric(line);
        }
    }

    /// <summary>Scrolls the synced lyrics so that the line being sung rests at its place; glides when <paramref name="animate"/>.</summary>
    private void FollowCurrentLine(bool animate)
    {
        var player = _player;
        if (player is not { HasSyncedLyrics: true } || !SyncedLyricsScroll.IsEffectivelyVisible) return;
        if (animate && DateTime.UtcNow < _manualScrollUntil) return; // the user is looking around

        var scroll = SyncedLyricsScroll;
        double target;
        if (player.CurrentLyricIndex < 0)
        {
            target = 0; // the song has not reached the first line yet
        }
        else
        {
            if (SyncedLyricsItems.ContainerFromIndex(player.CurrentLyricIndex) is not Control line
                || line.TranslatePoint(default, scroll) is not { } origin)
                return; // not laid out yet; the size change or the next line brings us back here

            var lineCenter = origin.Y + scroll.Offset.Y + line.Bounds.Height / 2;
            target = lineCenter - scroll.Viewport.Height * LyricRestFraction;
        }

        target = Math.Clamp(target, 0, Math.Max(0, scroll.Extent.Height - scroll.Viewport.Height));
        ScrollLyricsTo(target, animate);
    }

    private void ScrollLyricsTo(double target, bool animate)
    {
        var scroll = SyncedLyricsScroll;
        var generation = ++_scrollGeneration;
        var from = scroll.Offset.Y;
        var distance = Math.Abs(target - from);

        if (distance < 0.5) return;
        if (!animate || TopLevel.GetTopLevel(this) is not { } topLevel)
        {
            scroll.Offset = new Vector(scroll.Offset.X, target);
            return;
        }

        // Longer jumps (a seek) take a little longer, but never so long that the next line arrives before the glide ends.
        var duration = TimeSpan.FromMilliseconds(Math.Clamp(380 + distance * 0.4, 450, 800));
        TimeSpan? start = null;

        void Frame(TimeSpan now)
        {
            if (generation != _scrollGeneration) return; // a newer scroll (or the user) took over

            start ??= now;
            var t = Math.Min(1.0, (now - start.Value) / duration);
            var eased = t < 0.5 ? 4 * t * t * t : 1 - Math.Pow(-2 * t + 2, 3) / 2; // ease in-out cubic
            scroll.Offset = new Vector(scroll.Offset.X, from + (target - from) * eased);
            if (t < 1) topLevel.RequestAnimationFrame(Frame);
        }

        topLevel.RequestAnimationFrame(Frame);
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
