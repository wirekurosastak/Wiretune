using Microsoft.Extensions.Options;
using Wiretune.Core.Services;

namespace Wiretune.Server;

/// <summary>
/// Keeps the server library in sync with the music folder: scans at startup, on a fixed interval and
/// whenever a scan is requested through the API. Scans are incremental (unchanged files are not re-read).
/// </summary>
public sealed class LibraryScanService : BackgroundService
{
    private readonly ILibraryService _library;
    private readonly ServerPaths _paths;
    private readonly TimeSpan? _interval;
    private readonly SemaphoreSlim _trigger = new(0, 1);

    public DateTime? LastScanCompletedUtc { get; private set; }
    public string? LastScanError { get; private set; }

    public LibraryScanService(ILibraryService library, ServerPaths paths, IOptions<ServerOptions> options)
    {
        _library = library;
        _paths = paths;
        _interval = options.Value.ScanIntervalMinutes > 0 ? TimeSpan.FromMinutes(options.Value.ScanIntervalMinutes) : null;
    }

    public void RequestScan()
    {
        try
        {
            _trigger.Release();
        }
        catch (SemaphoreFullException)
        {
            // A scan is already pending.
        }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await Task.Yield();

        while (!stoppingToken.IsCancellationRequested)
        {
            await ScanOnceAsync(stoppingToken);

            try
            {
                var waitForTrigger = _trigger.WaitAsync(stoppingToken);
                if (_interval is { } interval)
                {
                    await Task.WhenAny(waitForTrigger, Task.Delay(interval, stoppingToken));
                }
                else
                {
                    await waitForTrigger;
                }
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private async Task ScanOnceAsync(CancellationToken ct)
    {
        var root = _paths.LibraryRoot;
        try
        {
            if (!Directory.Exists(root))
            {
                LastScanError = $"Library folder does not exist: {root}";
                WiretuneLog.Warn("LibraryScan", LastScanError);
                return;
            }

            // An unmounted network share usually shows up as an empty mount point; never wipe the library for that.
            if (_library.Tracks.Count > 0 && !Directory.EnumerateFileSystemEntries(root).Any())
            {
                LastScanError = $"Library folder is empty (unmounted share?): {root}. Keeping the existing index.";
                WiretuneLog.Warn("LibraryScan", LastScanError);
                return;
            }

            var started = DateTime.UtcNow;
            if (await _library.ScanFolderAsync(root, null, ct))
            {
                LastScanCompletedUtc = DateTime.UtcNow;
                LastScanError = null;
                WiretuneLog.Info("LibraryScan",
                    $"Scan complete in {(DateTime.UtcNow - started).TotalSeconds:0.0}s: {_library.Tracks.Count} tracks, {_library.Albums.Count} albums, {_library.Artists.Count} artists.");
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            LastScanError = ex.Message;
            WiretuneLog.Error("LibraryScan", $"Scan failed: {ex.Message}", ex);
        }
    }
}
