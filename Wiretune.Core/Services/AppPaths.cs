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
        if (!Directory.Exists(dir))
        {
            // The directory holds the client's access token or the server's token-signing key, so a directory
            // created here is private to the current user. An existing one is left as the admin set it up.
            if (OperatingSystem.IsWindows())
                Directory.CreateDirectory(dir);
            else
                Directory.CreateDirectory(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        return dir;
    }

    /// <summary>
    /// True when <paramref name="path"/> resolves to <paramref name="root"/> or a location inside it.
    /// Compares whole path segments so "/music2" is not treated as inside "/music".
    /// </summary>
    public static bool IsPathUnderRoot(string path, string root)
    {
        if (string.IsNullOrWhiteSpace(path) || string.IsNullOrWhiteSpace(root)) return false;

        string fullPath, fullRoot;
        try
        {
            fullPath = Path.GetFullPath(path);
            fullRoot = Path.GetFullPath(root);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }

        var comparison = OperatingSystem.IsWindows() || OperatingSystem.IsMacOS()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;

        // A filesystem root ("/" or "C:\") already ends with a separator; any other root gets one appended.
        var prefix = Path.EndsInDirectorySeparator(fullRoot) ? fullRoot : fullRoot + Path.DirectorySeparatorChar;
        return string.Equals(fullPath, prefix.TrimEnd(Path.DirectorySeparatorChar), comparison) ||
               fullPath.StartsWith(prefix, comparison);
    }
}
