namespace Wiretune.Core.Models;

public record UserInfo(
    string Id,
    string Username,
    bool IsAdmin,
    DateTime CreatedAt,
    DateTime? LastLogin
);

public record LoginRequest(string Username, string Password, bool RememberMe = false);

public record RegisterRequest(string Username, string Password);

/// <summary>
/// First-run administrator setup. <paramref name="SetupCode"/> is the one-time code the server prints in its log when it
/// starts without any account; a server older than that ignores it.
/// </summary>
public record SetupRequest(string Username, string Password, string? SetupCode = null);

public record AuthResponse(string Token, UserInfo User, DateTime ExpiresAt);

/// <summary>
/// A short-lived token that opens only the audio and cover routes. Players put it in stream URLs (which end up as
/// arguments of the decoder process) instead of the login token.
/// </summary>
public record StreamTokenResponse(string Token, DateTime ExpiresAt);

public record ServerLibraryStatus(
    int TrackCount,
    int AlbumCount,
    int ArtistCount,
    bool IsScanning,
    DateTime? LastScanCompletedUtc,
    string? LastScanError
);

public record ServerConfigInfo(string LibraryPath);
public record UpdateLibraryPathRequest(string NewPath);

public static class AuthRules
{
    public const int MinPasswordLength = 8;

    /// <summary>bcrypt silently ignores everything past 72 bytes, so longer passwords are rejected instead of truncated.</summary>
    public const int MaxPasswordBytes = 72;

    public const int MaxUsernameLength = 64;
}
