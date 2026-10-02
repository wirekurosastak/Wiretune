using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using Avalonia;

namespace Wiretune.UI.Services;

/// <summary>
/// Tells whether Avalonia is drawing with the GPU or with the CPU. On Android Avalonia tries the GPU (EGL) first and falls
/// back to the much slower software renderer without any message, so the app asks and says so.
/// </summary>
public static class RenderingInfo
{
    private static bool? s_result;

    /// <summary>
    /// Name of the drawing back end Avalonia ended up with: "Egl" (OpenGL ES), "Vulkan" or "Software". Known after
    /// <see cref="IsGpuRendering"/> has been called once.
    /// </summary>
    public static string? Backend { get; private set; }

    /// <summary>
    /// Set by the Android head: chooses which renderer the next start of the app uses (once) and returns a message that
    /// says what was chosen. Lets the statistics label switch between OpenGL, Vulkan and software rendering, so the
    /// three can be compared on the phone without a new build.
    /// </summary>
    public static Func<string>? CycleNextRenderer { get; set; }

    /// <summary>
    /// Set by the Android head: two lines about the refresh rate the app asks the display for and about the CPU
    /// performance hint it gives the system (see DisplayPerformance), for the statistics panel.
    /// </summary>
    public static Func<string>? PerformanceStatus { get; set; }

    /// <summary>
    /// Set by the Android head: how the refresh rate is chosen right now ("Auto" or a fixed rate), for the chip of the
    /// statistics panel.
    /// </summary>
    public static Func<string>? RefreshModeLabel { get; set; }

    /// <summary>
    /// Set by the Android head: moves to the next way of choosing the refresh rate (automatic, then each rate the display
    /// offers, highest first) and returns a message that says what was chosen. Lets the rates be compared on the phone.
    /// </summary>
    public static Func<string>? CycleRefreshMode { get; set; }

    /// <summary>
    /// Set by the Android head: where the window, the app's view and the layouts between them are on the screen, and how tall
    /// the system bars are, for the statistics panel. It is what tells why the app does not reach under the status bar and
    /// the navigation bar, if it does not.
    /// </summary>
    public static Func<string>? WindowStatus { get; set; }

    /// <summary>
    /// Avalonia's service locator is not part of its public API (it is left out of the assemblies an app compiles against),
    /// so the few platform services the diagnostics need are reached by reflection. Returns null when the service (or the
    /// locator itself) cannot be found: this is only a diagnostic.
    /// </summary>
    public static object? GetPlatformService(Type serviceType) =>
        TryGetPlatformService(serviceType, out var service) ? service : null;

    /// <summary>
    /// Like <see cref="GetPlatformService"/>, but says whether the lookup itself worked: it can succeed and still find
    /// nothing (the service is simply not registered).
    /// </summary>
    [UnconditionalSuppressMessage("Trimming", "IL2075", Justification = "Diagnostic only; a missing member just yields 'lookup failed'.")]
    private static bool TryGetPlatformService(Type serviceType, out object? service)
    {
        service = null;
        try
        {
            var locatorType = typeof(AvaloniaObject).Assembly.GetType("Avalonia.AvaloniaLocator");
            if (locatorType == null) return false;

            var locator = locatorType
                .GetProperty("Current", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static)
                ?.GetValue(null);
            var getService = locator?.GetType().GetMethod("GetService", new[] { typeof(Type) });
            if (locator == null || getService == null) return false;

            service = getService.Invoke(locator, new object[] { serviceType });
            return true;
        }
        catch (Exception)
        {
            service = null;
            return false;
        }
    }

    /// <summary>
    /// True when the GPU draws, false when the software renderer does, null when it cannot be told.
    /// </summary>
    public static bool? IsGpuRendering()
    {
        if (s_result != null) return s_result;

        try
        {
            var graphicsType = typeof(AvaloniaObject).Assembly.GetType("Avalonia.Platform.IPlatformGraphics");
            if (graphicsType == null || !TryGetPlatformService(graphicsType, out var graphics)) return null;

            // The locator answers null when the GPU is not in use.
            s_result = graphics != null;

            // "EglPlatformGraphics" -> "Egl", "VulkanPlatformGraphics" -> "Vulkan"
            Backend = graphics == null ? "Software" : graphics.GetType().Name.Replace("PlatformGraphics", "");
            return s_result;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
