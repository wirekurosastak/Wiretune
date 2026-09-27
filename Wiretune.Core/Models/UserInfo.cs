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

public record AuthResponse(string Token, UserInfo User, DateTime ExpiresAt);

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
    public const int MaxUsernameLength = 64;
}
