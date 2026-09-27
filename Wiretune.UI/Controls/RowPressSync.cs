using System;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Threading;
using Avalonia.VisualTree;

namespace Wiretune.UI.Controls;

/// <summary>
/// Synchronizes the tactile press/scale effect of a row button (e.g. cover or track number)
/// with the song title button in the same DataGridRow.
/// </summary>
public static class RowPressSync
{
    public static readonly AttachedProperty<bool> SyncWithTitleProperty =
        AvaloniaProperty.RegisterAttached<Button, bool>("SyncWithTitle", typeof(RowPressSync), false);

    public static bool GetSyncWithTitle(Button button) => button.GetValue(SyncWithTitleProperty);
    public static void SetSyncWithTitle(Button button, bool value) => button.SetValue(SyncWithTitleProperty, value);

    static RowPressSync()
    {
        SyncWithTitleProperty.Changed.AddClassHandler<Button>(OnSyncWithTitleChanged);
    }

    private static void OnSyncWithTitleChanged(Button button, AvaloniaPropertyChangedEventArgs args)
    {
        if (args.NewValue is true)
        {
            DateTime pressedTime = DateTime.MinValue;
            CancellationTokenSource? pendingReleaseCts = null;

            button.PropertyChanged += (s, e) =>
            {
                if (e.Property == Button.IsPressedProperty && e.NewValue is bool isPressed)
                {
                    Dispatcher.UIThread.Post(() =>
                    {
                        var titleButton = FindTitleButton(button);
                        if (titleButton == null)
                        {
                            return;
                        }

                        if (isPressed)
                        {
                            pendingReleaseCts?.Cancel();
                            pendingReleaseCts?.Dispose();
                            pendingReleaseCts = null;

                            pressedTime = DateTime.UtcNow;
                            titleButton.Classes.Set("row-pressed", true);
                        }
                        else
                        {
                            var elapsed = DateTime.UtcNow - pressedTime;
                            const int minDurationMs = 130;

                            if (elapsed.TotalMilliseconds < minDurationMs && pressedTime != DateTime.MinValue)
                            {
                                var remainingMs = (int)(minDurationMs - elapsed.TotalMilliseconds);
                                var cts = new CancellationTokenSource();
                                pendingReleaseCts?.Cancel();
                                pendingReleaseCts?.Dispose();
                                pendingReleaseCts = cts;

                                Task.Delay(remainingMs, cts.Token).ContinueWith(_ =>
                                {
                                    Dispatcher.UIThread.Post(() =>
                                    {
                                        if (!cts.IsCancellationRequested)
                                        {
                                            titleButton.Classes.Set("row-pressed", false);
                                        }
                                    });
                                }, TaskScheduler.Default);
                            }
                            else
                            {
                                titleButton.Classes.Set("row-pressed", false);
                            }
                        }
                    });
                }
            };
        }
    }

    private static Button? FindTitleButton(Button sourceButton)
    {
        var row = sourceButton.FindAncestorOfType<DataGridRow>();
        if (row != null)
        {
            foreach (var visual in row.GetVisualDescendants())
            {
                if (visual is Button btn && btn != sourceButton && btn.Classes.Contains("title"))
                {
                    return btn;
                }
            }
        }
        return null;
    }
}
