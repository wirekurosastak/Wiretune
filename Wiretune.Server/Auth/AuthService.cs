using System.Globalization;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Dapper;
using Microsoft.IdentityModel.Tokens;
using Wiretune.Core.Models;
using Wiretune.Data;

namespace Wiretune.Server.Auth;

public class AuthService
{
    public const string Issuer = "WiretuneServer";
    public const string Audience = "WiretuneClient";
    private const int BcryptWorkFactor = 12;

    private readonly DatabaseManager _db;
    private readonly SymmetricSecurityKey _signingKey;
    private readonly Lazy<string> _dummyHash = new(() => BCrypt.Net.BCrypt.HashPassword(Guid.NewGuid().ToString(), BcryptWorkFactor));

    public AuthService(DatabaseManager db)
    {
        _db = db;
        _db.InitializeSchema();
        _signingKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(LoadOrGenerateSecret()));
    }

    private string LoadOrGenerateSecret()
    {
        using var conn = _db.CreateConnection();
        var existing = conn.QueryFirstOrDefault<string>("SELECT value FROM settings WHERE key = 'jwt_secret'");
        if (!string.IsNullOrEmpty(existing)) return existing;

        var secret = Convert.ToBase64String(RandomNumberGenerator.GetBytes(64));
        conn.Execute("INSERT OR IGNORE INTO settings (key, value) VALUES ('jwt_secret', @secret)", new { secret });
        return conn.QueryFirst<string>("SELECT value FROM settings WHERE key = 'jwt_secret'");
    }

    public static string? ValidateCredentials(string? username, string? password)
    {
        if (string.IsNullOrWhiteSpace(username) || string.IsNullOrEmpty(password))
            return "Username and password are required.";
        var trimmed = username.Trim();
        if (trimmed.Length > AuthRules.MaxUsernameLength || trimmed.Any(char.IsControl))
            return $"Username must be at most {AuthRules.MaxUsernameLength} printable characters.";
        if (password.Length < AuthRules.MinPasswordLength)
            return $"Password must be at least {AuthRules.MinPasswordLength} characters.";
        return null;
    }

    public async Task<bool> HasAnyUsersAsync()
    {
        using var conn = _db.CreateConnection();
        return await conn.ExecuteScalarAsync<long>("SELECT COUNT(*) FROM users") > 0;
    }

    public async Task<AuthResponse?> LoginAsync(LoginRequest request)
    {
        using var conn = _db.CreateConnection();
        var row = await conn.QueryFirstOrDefaultAsync<UserRow>(
            "SELECT id, username, password_hash, is_admin, created_at, last_login FROM users WHERE username = @Username COLLATE NOCASE",
            new { Username = request.Username.Trim() });

        if (row == null)
        {
            // Equalise timing so response time does not reveal whether the username exists.
            BCrypt.Net.BCrypt.Verify(request.Password, _dummyHash.Value);
            return null;
        }

        if (!BCrypt.Net.BCrypt.Verify(request.Password, row.password_hash)) return null;

        var now = DateTime.UtcNow;
        await conn.ExecuteAsync("UPDATE users SET last_login = @Now WHERE id = @Id",
            new { Now = now.ToString("O", CultureInfo.InvariantCulture), Id = row.id });

        var user = row.ToUserInfo() with { LastLogin = now };
        var expiry = request.RememberMe ? TimeSpan.FromDays(90) : TimeSpan.FromHours(24);
        return new AuthResponse(GenerateToken(user, expiry), user, now.Add(expiry));
    }

    /// <summary>Creates the first administrator. Returns null if any account already exists (checked atomically).</summary>
    public async Task<AuthResponse?> CreateAdminAsync(RegisterRequest request)
    {
        var user = NewUser(request, isAdmin: true);
        using var conn = _db.CreateConnection();
        var inserted = await conn.ExecuteAsync("""
            INSERT INTO users (id, username, password_hash, is_admin, created_at, last_login)
            SELECT @Id, @Username, @Hash, 1, @CreatedAt, NULL
            WHERE NOT EXISTS (SELECT 1 FROM users)
            """,
            UserParameters(user, request.Password));

        if (inserted == 0) return null;

        var expiry = TimeSpan.FromDays(90);
        return new AuthResponse(GenerateToken(user, expiry), user, DateTime.UtcNow.Add(expiry));
    }

    /// <summary>Creates a regular user. Returns null if the username is taken.</summary>
    public async Task<UserInfo?> RegisterAsync(RegisterRequest request)
    {
        var user = NewUser(request, isAdmin: false);
        using var conn = _db.CreateConnection();
        var inserted = await conn.ExecuteAsync("""
            INSERT OR IGNORE INTO users (id, username, password_hash, is_admin, created_at, last_login)
            VALUES (@Id, @Username, @Hash, 0, @CreatedAt, NULL)
            """,
            UserParameters(user, request.Password));

        return inserted == 0 ? null : user;
    }

    public async Task<UserInfo?> GetUserAsync(string userId)
    {
        using var conn = _db.CreateConnection();
        var row = await conn.QueryFirstOrDefaultAsync<UserRow>(
            "SELECT id, username, password_hash, is_admin, created_at, last_login FROM users WHERE id = @userId",
            new { userId });
        return row?.ToUserInfo();
    }

    public async Task<List<UserInfo>> GetAllUsersAsync()
    {
        using var conn = _db.CreateConnection();
        var rows = await conn.QueryAsync<UserRow>(
            "SELECT id, username, password_hash, is_admin, created_at, last_login FROM users ORDER BY username ASC");
        return rows.Select(r => r.ToUserInfo()).ToList();
    }

    public async Task<bool> DeleteUserAsync(string userId)
    {
        using var conn = _db.CreateConnection();
        var count = await conn.ExecuteAsync("DELETE FROM users WHERE id = @userId", new { userId });
        return count > 0;
    }

    public TokenValidationParameters GetValidationParameters() => new()
    {
        ValidateIssuer = true,
        ValidIssuer = Issuer,
        ValidateAudience = true,
        ValidAudience = Audience,
        ValidateLifetime = true,
        IssuerSigningKey = _signingKey,
        ValidateIssuerSigningKey = true,
        ClockSkew = TimeSpan.FromMinutes(2),
        NameClaimType = ClaimTypes.Name,
        RoleClaimType = ClaimTypes.Role
    };

    private static UserInfo NewUser(RegisterRequest request, bool isAdmin)
    {
        var username = request.Username.Trim();
        return new UserInfo(Guid.NewGuid().ToString("N"), username, isAdmin, DateTime.UtcNow, null);
    }

    private static object UserParameters(UserInfo user, string password) => new
    {
        user.Id,
        user.Username,
        Hash = BCrypt.Net.BCrypt.HashPassword(password, BcryptWorkFactor),
        CreatedAt = user.CreatedAt.ToString("O", CultureInfo.InvariantCulture)
    };

    private string GenerateToken(UserInfo user, TimeSpan expiry)
    {
        var claims = new[]
        {
            new Claim(ClaimTypes.NameIdentifier, user.Id),
            new Claim(ClaimTypes.Name, user.Username),
            new Claim(ClaimTypes.Role, user.IsAdmin ? "admin" : "user")
        };

        var token = new JwtSecurityToken(
            issuer: Issuer,
            audience: Audience,
            claims: claims,
            expires: DateTime.UtcNow.Add(expiry),
            signingCredentials: new SigningCredentials(_signingKey, SecurityAlgorithms.HmacSha256));

        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    private sealed record UserRow(string id, string username, string password_hash, long is_admin, string created_at, string? last_login)
    {
        public UserInfo ToUserInfo() => new(
            id,
            username,
            is_admin != 0,
            DateTime.Parse(created_at, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal),
            last_login == null ? null : DateTime.Parse(last_login, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal));
    }
}
