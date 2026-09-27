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

public sealed class ServerPaths
{
    public string LibraryRoot { get; set; }
    public string DataDirectory { get; }
    public string CoverCacheDirectory { get; }

    public ServerPaths(string libraryRoot, string dataDirectory, string coverCacheDirectory)
    {
        LibraryRoot = libraryRoot;
        DataDirectory = dataDirectory;
        CoverCacheDirectory = coverCacheDirectory;
    }
}
