namespace Wiretune.Server;

public sealed class ServerOptions
{
    /// <summary>Music library root. Relative paths are resolved against the server's content root.</summary>
    public string? LibraryPath { get; set; }

    /// <summary>Where the server keeps its database, cover cache and log. Defaults to &lt;app data&gt;/Wiretune/Server.</summary>
    public string? DataDirectory { get; set; }

    public int Port { get; set; } = 5200;

    /// <summary>Periodic incremental rescan interval; 0 disables periodic rescans (startup and manual scans still run).</summary>
    public int ScanIntervalMinutes { get; set; } = 30;
}

/// <summary>Resolved, immutable server paths shared by the endpoints and background services.</summary>
public sealed record ServerPaths(string LibraryRoot, string DataDirectory, string CoverCacheDirectory);
