using Xunit;

namespace Wiretune.Tests;

/// <summary>
/// A <c>[Fact]</c> that is reported as <b>skipped</b> when a command-line tool it needs is not on PATH. A test that
/// returns early instead would report success and hide that nothing ran.
/// </summary>
public sealed class ToolFactAttribute : FactAttribute
{
    public ToolFactAttribute(params string[] tools)
    {
        var missing = tools.Where(tool => !ExternalTools.IsOnPath(tool)).ToList();
        if (missing.Count > 0) Skip = $"Not on PATH: {string.Join(", ", missing)}";
    }
}

internal static class ExternalTools
{
    public static bool IsOnPath(string tool) =>
        (Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Any(dir => File.Exists(Path.Combine(dir, tool)) || File.Exists(Path.Combine(dir, tool + ".exe")));
}
