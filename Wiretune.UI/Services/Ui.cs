using Avalonia.Threading;
using Wiretune.Core.Services;

namespace Wiretune.UI.Services;

internal static class Ui
{
    /// <summary>Runs <paramref name="action"/> on the UI thread: inline when already there, otherwise queued.</summary>
    public static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }

    /// <summary>Awaits a fire-and-forget operation and logs failures instead of losing them.</summary>
    public static async void Forget(Task task, string category)
    {
        try
        {
            await task;
        }
        catch (Exception ex)
        {
            WiretuneLog.Error(category, ex.Message, ex);
        }
    }
}
