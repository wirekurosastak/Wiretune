namespace Wiretune.Core.Services;

public enum LogLevel
{
    Trace = 0,
    Debug = 1,
    Info = 2,
    Warn = 3,
    Error = 4
}

public record LogEntry(
    DateTime Timestamp,
    LogLevel Level,
    string Category,
    string Message,
    Exception? Exception = null
)
{
    public override string ToString()
    {
        var exStr = Exception != null ? $" | Exception: {Exception.GetType().Name}: {Exception.Message}\n{Exception.StackTrace}" : "";
        return $"[{Timestamp:yyyy-MM-dd HH:mm:ss.fff}] [{Level.ToString().ToUpperInvariant(),-5}] [{Category}] {Message}{exStr}";
    }
}

public static class WiretuneLog
{
    private const long MaxLogBytes = 10 * 1024 * 1024;
    private static readonly object _lock = new();
    private static string? _logFilePath;
    private static StreamWriter? _logWriter;
    private static bool _initAttempted;

    public static event Action<LogEntry>? OnLogEntry;

    public static LogLevel MinimumLevel { get; set; } = LogLevel.Debug;

    public static string LogFilePath
    {
        get
        {
            lock (_lock)
            {
                return _logFilePath ??= DefaultLogPath();
            }
        }
    }

    /// <summary>
    /// Opens the log file. Calling it again with a different path switches files (the server uses its own
    /// data directory); calling it without arguments after a successful open is a no-op.
    /// </summary>
    public static void Initialize(string? customLogPath = null, LogLevel? minLevel = null)
    {
        if (minLevel.HasValue) MinimumLevel = minLevel.Value;

        string path;
        lock (_lock)
        {
            if (_logWriter != null && (customLogPath == null || customLogPath == _logFilePath)) return;

            _logWriter?.Dispose();
            _logWriter = null;
            _initAttempted = true;
            _logFilePath = customLogPath ?? _logFilePath ?? DefaultLogPath();
            path = _logFilePath;

            try
            {
                var dir = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

                var info = new FileInfo(path);
                if (info.Exists && info.Length > MaxLogBytes)
                {
                    var backup = path + ".1";
                    try { File.Delete(backup); } catch { }
                    try { File.Move(path, backup); } catch { }
                }

                var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                _logWriter = new StreamWriter(stream) { AutoFlush = true };
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[WiretuneLog] Failed to open log file '{path}': {ex.Message}");
            }
        }

        Info("WiretuneLog", $"=== Wiretune logging initialized (Log: {path}, Level: {MinimumLevel}) ===");
    }

    public static void Log(LogLevel level, string category, string message, Exception? ex = null)
    {
        if (level < MinimumLevel) return;

        var entry = new LogEntry(DateTime.Now, level, category, message, ex);
        var line = entry.ToString();

        try
        {
            if (level >= LogLevel.Warn) Console.Error.WriteLine(line);
            else Console.WriteLine(line);
        }
        catch
        {
            // No console in GUI/headless contexts.
        }

        var needsInit = false;
        lock (_lock)
        {
            if (!_initAttempted) needsInit = true;
            else
            {
                try { _logWriter?.WriteLine(line); } catch { }
            }
        }

        if (needsInit)
        {
            Initialize();
            lock (_lock)
            {
                try { _logWriter?.WriteLine(line); } catch { }
            }
        }

        try
        {
            OnLogEntry?.Invoke(entry);
        }
        catch
        {
            // Subscriber failures must never break logging.
        }
    }

    public static void Debug(string category, string message) => Log(LogLevel.Debug, category, message);
    public static void Info(string category, string message) => Log(LogLevel.Info, category, message);
    public static void Warn(string category, string message) => Log(LogLevel.Warn, category, message);
    public static void Error(string category, string message, Exception? ex = null) => Log(LogLevel.Error, category, message, ex);

    private static string DefaultLogPath()
    {
        try
        {
            return Path.Combine(AppPaths.GetDataDirectory(), "wiretune.log");
        }
        catch
        {
            return Path.Combine(Path.GetTempPath(), "wiretune.log");
        }
    }
}
