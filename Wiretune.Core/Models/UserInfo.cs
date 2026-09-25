namespace Wiretune.Core.Models;

public record UserInfo(
    string Id,
    string Username,
    string? DisplayName,
    bool IsAdmin,
    DateTime CreatedAt,
    DateTime? LastLogin
);

public record LoginRequest(string Username, string Password, bool RememberMe = false);

public record RegisterRequest(string Username, string Password, string? DisplayName = null);

public record AuthResponse(string Token, UserInfo User, DateTime ExpiresAt);
