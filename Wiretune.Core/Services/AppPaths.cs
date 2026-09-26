namespace Wiretune.Core.Services;

public static class AppPaths
{
    public const string DataDirectoryEnvironmentVariable = "WIRETUNE_DATA_DIR";

    /// <summary>
    /// Resolves (and creates) the Wiretune data directory. Precedence: explicit override,
    /// WIRETUNE_DATA_DIR, then the per-user application data folder. The server passes a
    /// subdirectory so it never shares a database with a client running on the same machine.
    /// </summary>
    public static string GetDataDirectory(string? overridePath = null, string? subdirectory = null)
    {
        string root;
        if (!string.IsNullOrWhiteSpace(overridePath))
        {
            root = overridePath;
            subdirectory = null;
        }
        else if (Environment.GetEnvironmentVariable(DataDirectoryEnvironmentVariable) is { Length: > 0 } fromEnv)
        {
            root = fromEnv;
        }
        else
        {
            root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Wiretune");
        }

        var dir = Path.GetFullPath(string.IsNullOrEmpty(subdirectory) ? root : Path.Combine(root, subdirectory));
        Directory.CreateDirectory(dir);
        return dir;
    }

    /// <summary>
    /// True when <paramref name="path"/> resolves to <paramref name="root"/> or a location inside it.
    /// Compares whole path segments so "/music2" is not treated as inside "/music".
    /// </summary>
    public static bool IsPathUnderRoot(string path, string root)
    {
        if (string.IsNullOrWhiteSpace(path) || string.IsNullOrWhiteSpace(root)) return false;

        var fullPath = Path.GetFullPath(path);
        var fullRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        var comparison = OperatingSystem.IsWindows() || OperatingSystem.IsMacOS()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;

        if (string.Equals(fullPath, fullRoot, comparison)) return true;
        return fullPath.StartsWith(fullRoot + Path.DirectorySeparatorChar, comparison);
    }
}
