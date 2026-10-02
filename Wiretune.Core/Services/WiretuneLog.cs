using System.Text.RegularExpressions;

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
        // Exception.ToString() keeps the type, message, inner exceptions and stack trace.
        var exStr = Exception != null ? $" | Exception: {Exception}" : "";
        return WiretuneLog.Redact($"[{Timestamp:yyyy-MM-dd HH:mm:ss.fff}] [{Level.ToString().ToUpperInvariant(),-5}] [{Category}] {Message}{exStr}");
    }
}

public static class WiretuneLog
{
    private const long MaxLogBytes = 10 * 1024 * 1024;
    private static readonly Regex TokenPattern = new(@"token=[^&\s""']+", RegexOptions.CultureInvariant);
    private static readonly object _lock = new();
    private static string? _logFilePath;
    private static StreamWriter? _logWriter;
    private static long _bytesWritten;
    private static bool _initAttempted;

    public static event Action<LogEntry>? OnLogEntry;

    /// <summary>
    /// Info by default: Debug lines carry paths, server addresses and device names. <c>WIRETUNE_LOG_LEVEL</c>
    /// (Trace, Debug, Info, Warn, Error) raises or lowers it for a troubleshooting session.
    /// </summary>
    public static LogLevel MinimumLevel { get; set; } =
        Enum.TryParse<LogLevel>(Environment.GetEnvironmentVariable("WIRETUNE_LOG_LEVEL"), ignoreCase: true, out var configured)
            ? configured
            : LogLevel.Info;

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

            _initAttempted = true;
            _logFilePath = customLogPath ?? _logFilePath ?? DefaultLogPath();
            path = _logFilePath;

            OpenWriterLocked(path);
        }

        Info("WiretuneLog", $"=== Wiretune logging initialized (Log: {path}, Level: {MinimumLevel}) ===");
    }

    /// <summary>Opens the log for appending, first moving an oversized file to <c>.1</c> (one backup is kept). Call under the lock.</summary>
    private static void OpenWriterLocked(string path)
    {
        try
        {
            _logWriter?.Dispose();
            _logWriter = null;

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
            // If the rotation above failed (file in use), don't retry it on every line: count from zero again.
            _bytesWritten = stream.Length > MaxLogBytes ? 0 : stream.Length;
            _logWriter = new StreamWriter(stream) { AutoFlush = true };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[WiretuneLog] Failed to open log file '{path}': {ex.Message}");
        }
    }

    /// <summary>Appends a line and rotates when the file grows past the limit, so long-running servers stay bounded. Call under the lock.</summary>
    private static void WriteLineLocked(string line)
    {
        if (_logWriter == null) return;

        try
        {
            _logWriter.WriteLine(line);
            _bytesWritten += line.Length + Environment.NewLine.Length;
            if (_bytesWritten > MaxLogBytes && _logFilePath != null) OpenWriterLocked(_logFilePath);
        }
        catch
        {
            // Logging must never take the application down.
        }
    }

    public static void Log(LogLevel level, string category, string message, Exception? ex = null)
    {
        if (level < MinimumLevel) return;

        var entry = new LogEntry(DateTime.Now, level, category, Redact(message), ex);
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
            else WriteLineLocked(line);
        }

        if (needsInit)
        {
            Initialize();
            lock (_lock) WriteLineLocked(line);
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

    /// <summary>
    /// Replaces the value of every <c>token=</c> query parameter with <c>***</c>. Stream URLs carry the access token
    /// that way, and they end up in messages and exception texts from every driver, so each log line passes through here.
    /// </summary>
    public static string Redact(string text) => TokenPattern.Replace(text, "token=***");

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
