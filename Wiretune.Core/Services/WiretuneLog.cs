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
    private static readonly object _lock = new();
    private static string? _logFilePath;
    private static StreamWriter? _logWriter;
    private static LogLevel _minLevel = LogLevel.Debug;
    private static bool _initialized = false;

    public static event Action<LogEntry>? OnLogEntry;

    public static string LogFilePath
    {
        get
        {
            if (_logFilePath == null)
            {
                var dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "Wiretune");
                try
                {
                    Directory.CreateDirectory(dir);
                    _logFilePath = Path.Combine(dir, "wiretune.log");
                }
                catch
                {
                    _logFilePath = Path.Combine(Path.GetTempPath(), "wiretune.log");
                }
            }
            return _logFilePath;
        }
    }

    public static LogLevel MinimumLevel
    {
        get => _minLevel;
        set => _minLevel = value;
    }

    public static void Initialize(string? customLogPath = null, LogLevel? minLevel = null)
    {
        lock (_lock)
        {
            if (_initialized && _logWriter != null) return;

            if (minLevel.HasValue)
            {
                _minLevel = minLevel.Value;
            }
            if (!string.IsNullOrEmpty(customLogPath))
            {
                _logFilePath = customLogPath;
                var dir = Path.GetDirectoryName(_logFilePath);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            }

            try
            {
                var path = LogFilePath;
                var fileInfo = new FileInfo(path);
                // Rotate log if larger than 10MB
                if (fileInfo.Exists && fileInfo.Length > 10 * 1024 * 1024)
                {
                    var backupPath = path + ".1";
                    try { File.Delete(backupPath); } catch { }
                    try { File.Move(path, backupPath); } catch { }
                }

                var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                _logWriter = new StreamWriter(stream) { AutoFlush = true };
                _initialized = true;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[WiretuneLog] Failed to open log file: {ex.Message}");
            }
        }

        if (_minLevel <= LogLevel.Info)
        {
            Info("WiretuneLog", $"=== Wiretune Logging Initialized (Log: {LogFilePath}, Level: {_minLevel}) ===");
        }
    }

    public static void Log(LogLevel level, string category, string message, Exception? ex = null)
    {
        if (level < _minLevel) return;

        var entry = new LogEntry(DateTime.UtcNow, level, category, message, ex);

        // 1. Console Output
        try
        {
            var oldColor = Console.ForegroundColor;
            Console.ForegroundColor = level switch
            {
                LogLevel.Error => ConsoleColor.Red,
                LogLevel.Warn => ConsoleColor.Yellow,
                LogLevel.Info => ConsoleColor.Cyan,
                LogLevel.Debug => ConsoleColor.Gray,
                _ => ConsoleColor.DarkGray
            };

            Console.WriteLine(entry.ToString());
            Console.ForegroundColor = oldColor;
        }
        catch
        {
            // Ignore console writing errors in GUI/headless contexts
        }

        // 2. File Output
        lock (_lock)
        {
            if (!_initialized)
            {
                Initialize();
            }

            try
            {
                _logWriter?.WriteLine(entry.ToString());
            }
            catch
            {
                // Never crash application due to logging failure
            }
        }

        // 3. Event dispatch
        try
        {
            OnLogEntry?.Invoke(entry);
        }
        catch
        {
            // Safeguard against subscriber exceptions
        }
    }

    public static void Debug(string category, string message) => Log(LogLevel.Debug, category, message);
    public static void Info(string category, string message) => Log(LogLevel.Info, category, message);
    public static void Warn(string category, string message) => Log(LogLevel.Warn, category, message);
    public static void Error(string category, string message, Exception? ex = null) => Log(LogLevel.Error, category, message, ex);
}
