using System.Diagnostics;
using System.Runtime.CompilerServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;

namespace Wiretune.UI.Controls;

/// <summary>
/// Attached behaviour that lets a <see cref="ScrollViewer"/> keep gliding after a flick - on the frame clock.
/// <para>
/// Avalonia's own fling is a <c>DispatcherTimer</c> that fires every 16 ms at the lowest ("Background") priority. On
/// Android that timer is a thread-pool timer that posts to the main looper, and it is re-armed only after each tick has
/// run, so the real interval is 20-30 ms and the list moves at 30-50 steps per second whatever the screen can show -
/// the scroll looks like 30 fps although the finger-driven part of it is smooth. Here the fling is advanced from
/// <see cref="TopLevel.RequestAnimationFrame"/>, the same clock Avalonia's animations run on: one step per frame that
/// is actually presented, in the same layout/commit pass as the frame it belongs to, and by the exact distance the
/// elapsed time calls for, so a late frame jumps further instead of slowing the list down.
/// </para>
/// <para>
/// The glide itself is unchanged (the speed decays to 15 % per second, the curve Avalonia uses); the velocity is
/// estimated from the last 100 ms of the drag. Switching the behaviour on also switches the built-in inertia off.
/// </para>
/// </summary>
public static class SmoothFling
{
    public static readonly AttachedProperty<bool> IsActiveProperty =
        AvaloniaProperty.RegisterAttached<ScrollViewer, bool>("IsActive", typeof(SmoothFling));

    private static readonly ConditionalWeakTable<ScrollViewer, Controller> s_controllers = new();

    /// <summary>Frames per second the last fling was advanced at (for the statistics label); 0 before the first one.</summary>
    public static double LastFlingFps { get; private set; }

    /// <summary>How many frames the last fling lasted.</summary>
    public static int LastFlingFrames { get; private set; }

    static SmoothFling()
    {
        IsActiveProperty.Changed.AddClassHandler<ScrollViewer>((scroll, e) =>
        {
            if (e.NewValue is true)
            {
                if (!s_controllers.TryGetValue(scroll, out _)) s_controllers.Add(scroll, new Controller(scroll));
            }
            else if (s_controllers.TryGetValue(scroll, out var controller))
            {
                controller.Dispose();
                s_controllers.Remove(scroll);
            }
        });
    }

    public static bool GetIsActive(ScrollViewer scroll) => scroll.GetValue(IsActiveProperty);

    public static void SetIsActive(ScrollViewer scroll, bool value) => scroll.SetValue(IsActiveProperty, value);

    private sealed class Controller : IDisposable
    {
        // Fraction of the speed that is left after one second: the decay of Avalonia's own inertia.
        private const double ResistancePerSecond = 0.15;
        private static readonly double Decay = -Math.Log(ResistancePerSecond);

        // Device independent pixels per second.
        private const double MinStartSpeed = 90;
        private const double MaxStartSpeed = 9000;
        private const double StopSpeed = 24;

        // The velocity is read from the drag of the last 100 ms; a finger that rested longer than that before it lifted
        // does not start a fling.
        private const double VelocityWindowSeconds = 0.1;
        private const double StaleSeconds = 0.1;
        private const int MaxSamples = 16;

        private readonly ScrollViewer _scroll;
        private readonly long[] _sampleStamps = new long[MaxSamples];
        private readonly Vector[] _sampleOffsets = new Vector[MaxSamples];
        private int _sampleCount;

        private bool _flinging;
        private int _flingId;
        private Vector _velocity;
        private long _startStamp;
        private long _lastStamp;
        private int _frames;

        public Controller(ScrollViewer scroll)
        {
            _scroll = scroll;
            _scroll.IsScrollInertiaEnabled = false;
            _scroll.AddHandler(InputElement.PointerPressedEvent, OnPointerPressed, RoutingStrategies.Tunnel, handledEventsToo: true);
            _scroll.AddHandler(Gestures.ScrollGestureEvent, OnScrollGesture, RoutingStrategies.Bubble, handledEventsToo: true);
            _scroll.AddHandler(Gestures.ScrollGestureEndedEvent, OnScrollGestureEnded, RoutingStrategies.Bubble, handledEventsToo: true);
            _scroll.DetachedFromVisualTree += OnDetached;
        }

        public void Dispose()
        {
            Stop();
            _scroll.RemoveHandler(InputElement.PointerPressedEvent, OnPointerPressed);
            _scroll.RemoveHandler(Gestures.ScrollGestureEvent, OnScrollGesture);
            _scroll.RemoveHandler(Gestures.ScrollGestureEndedEvent, OnScrollGestureEnded);
            _scroll.DetachedFromVisualTree -= OnDetached;
            _scroll.IsScrollInertiaEnabled = true;
        }

        private void OnDetached(object? sender, VisualTreeAttachmentEventArgs e)
        {
            Stop();
            _sampleCount = 0;
        }

        private void OnPointerPressed(object? sender, PointerPressedEventArgs e)
        {
            // A touch stops a glide that is still going, and starts a new drag.
            _sampleCount = 0;
            if (_flinging) Stop();
        }

        private void OnScrollGesture(object? sender, ScrollGestureEventArgs e)
        {
            if (_flinging) Stop();

            // The scroll presenter has handled the gesture by now (it sits below the ScrollViewer on the way up), so the
            // offset is already the new one.
            if (_sampleCount == MaxSamples)
            {
                Array.Copy(_sampleStamps, 1, _sampleStamps, 0, MaxSamples - 1);
                Array.Copy(_sampleOffsets, 1, _sampleOffsets, 0, MaxSamples - 1);
                _sampleCount--;
            }

            _sampleStamps[_sampleCount] = Stopwatch.GetTimestamp();
            _sampleOffsets[_sampleCount] = _scroll.Offset;
            _sampleCount++;
        }

        private void OnScrollGestureEnded(object? sender, ScrollGestureEndedEventArgs e)
        {
            // The same gesture also reaches the outer ScrollViewers; the first one to see it has used up the samples.
            if (_flinging) return;

            var velocity = EstimateVelocity();
            _sampleCount = 0;

            var speed = velocity.Length;
            if (speed < MinStartSpeed) return;
            if (speed > MaxStartSpeed) velocity *= MaxStartSpeed / speed;

            Start(velocity);
        }

        /// <summary>The offset change per second over the last moments of the drag; zero when there was none.</summary>
        private Vector EstimateVelocity()
        {
            if (_sampleCount < 2) return default;

            var frequency = (double)Stopwatch.Frequency;
            var last = _sampleCount - 1;

            // The finger rested before it lifted.
            if ((Stopwatch.GetTimestamp() - _sampleStamps[last]) / frequency > StaleSeconds) return default;

            var first = last;
            while (first > 0 && (_sampleStamps[last] - _sampleStamps[first - 1]) / frequency <= VelocityWindowSeconds) first--;

            var seconds = (_sampleStamps[last] - _sampleStamps[first]) / frequency;
            if (seconds < 0.012) return default;

            return (_sampleOffsets[last] - _sampleOffsets[first]) * (1.0 / seconds);
        }

        private void Start(Vector velocity)
        {
            _flinging = true;
            _flingId++;
            _velocity = velocity;
            _frames = 0;
            _startStamp = _lastStamp = Stopwatch.GetTimestamp();
            RequestFrame();
        }

        private void RequestFrame()
        {
            if (TopLevel.GetTopLevel(_scroll) is not { } topLevel)
            {
                Stop();
                return;
            }

            var id = _flingId;
            topLevel.RequestAnimationFrame(_ => OnFrame(id));
        }

        private void OnFrame(int id)
        {
            if (!_flinging || id != _flingId) return;

            if (!_scroll.IsEffectivelyVisible)
            {
                Stop();
                return;
            }

            var stamp = Stopwatch.GetTimestamp();
            var t0 = (_lastStamp - _startStamp) / (double)Stopwatch.Frequency;
            var t1 = (stamp - _startStamp) / (double)Stopwatch.Frequency;
            _lastStamp = stamp;
            _frames++;

            // The speed is v0 * e^(-Decay * t), so the distance covered between t0 and t1 is its integral.
            var distance = (Math.Exp(-Decay * t0) - Math.Exp(-Decay * t1)) / Decay;
            var step = _velocity * distance;

            var before = _scroll.Offset;
            _scroll.SetCurrentValue(ScrollViewer.OffsetProperty, before + step);
            var moved = _scroll.Offset - before;

            // The end of the content: the offset is coerced back, and the glide along that axis is over.
            if (Math.Abs(step.X) > 0.01 && Math.Abs(moved.X) < 0.01) _velocity = _velocity.WithX(0);
            if (Math.Abs(step.Y) > 0.01 && Math.Abs(moved.Y) < 0.01) _velocity = _velocity.WithY(0);

            var speed = _velocity.Length * Math.Exp(-Decay * t1);
            if (speed < StopSpeed)
            {
                Stop();
                return;
            }

            RequestFrame();
        }

        private void Stop()
        {
            if (_flinging && _frames > 1)
            {
                var seconds = (_lastStamp - _startStamp) / (double)Stopwatch.Frequency;
                if (seconds > 0)
                {
                    LastFlingFrames = _frames;
                    LastFlingFps = _frames / seconds;
                }
            }

            _flinging = false;
            _flingId++;
        }
    }
}
