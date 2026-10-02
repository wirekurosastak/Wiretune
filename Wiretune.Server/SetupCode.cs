using System.Security.Cryptography;
using System.Text;

namespace Wiretune.Server;

/// <summary>
/// The secret that lets the first caller create the administrator account. Without it, whoever reaches a server that starts
/// with an empty data directory first (an unpersisted container volume, a wrong data path) would own the server.
/// The operator reads it from the server's log, or chooses one with <c>Wiretune:SetupCode</c>.
/// </summary>
public sealed class SetupCode
{
    // No 0/O, 1/I/L: the code is read from a log and typed by hand.
    private const string Alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

    private readonly byte[] _normalized;

    public string Value { get; }

    /// <param name="configured">The operator's own code; null or blank makes the server create a random one.</param>
    public SetupCode(string? configured)
    {
        var chosen = configured?.Trim();
        Value = Normalize(chosen).Length == 0 ? Generate() : chosen!;
        _normalized = Encoding.UTF8.GetBytes(Normalize(Value));
    }

    /// <summary>Case, spaces and dashes do not matter, so "abcd efgh" matches "ABCD-EFGH".</summary>
    public bool Matches(string? candidate) =>
        CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(Normalize(candidate)), _normalized);

    private static string Normalize(string? value) =>
        value == null ? string.Empty : new string(value.Where(char.IsLetterOrDigit).ToArray()).ToUpperInvariant();

    private static string Generate()
    {
        var chars = new char[8];
        for (var i = 0; i < chars.Length; i++) chars[i] = Alphabet[RandomNumberGenerator.GetInt32(Alphabet.Length)];
        return $"{new string(chars, 0, 4)}-{new string(chars, 4, 4)}";
    }
}
