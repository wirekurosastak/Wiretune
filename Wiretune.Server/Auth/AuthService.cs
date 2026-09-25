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
    private readonly DatabaseManager _db;
    private readonly string _jwtSecret;
    private readonly string _issuer = "WiretuneServer";

    public AuthService(DatabaseManager db, string? jwtSecret = null)
    {
        _db = db;
        // Generate or load a persistent JWT secret
        _jwtSecret = jwtSecret ?? LoadOrGenerateSecret(db);
        EnsureDefaultAdmin(db);
    }

    private static void EnsureDefaultAdmin(DatabaseManager db)
    {
        try
        {
            using var conn = db.CreateConnection();
            var count = conn.QueryFirstOrDefault<int>("SELECT COUNT(*) FROM users");
            if (count == 0)
            {
                var hash = BCrypt.Net.BCrypt.HashPassword("admin", workFactor: 10);
                conn.Execute(
                    @"INSERT INTO users (id, username, password_hash, display_name, is_admin, created_at, last_login)
                      VALUES (@Id, 'admin', @Hash, 'Adminisztrátor', 1, @Now, NULL)",
                    new
                    {
                        Id = Guid.NewGuid().ToString("N"),
                        Hash = hash,
                        Now = DateTime.UtcNow.ToString("O")
                    });
            }
        }
        catch
        {
            // Ignore if schema not ready yet
        }
    }

    private static string LoadOrGenerateSecret(DatabaseManager db)
    {
        db.InitializeSchema();
        using var conn = db.CreateConnection();
        var existing = conn.QueryFirstOrDefault<string>(
            "SELECT value FROM settings WHERE key = 'jwt_secret'");
        if (!string.IsNullOrEmpty(existing)) return existing;

        var secret = Convert.ToBase64String(RandomNumberGenerator.GetBytes(64));
        conn.Execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('jwt_secret', @secret)",
            new { secret });
        return secret;
    }

    public async Task<AuthResponse?> LoginAsync(LoginRequest request)
    {
        using var conn = _db.CreateConnection();
        var row = await conn.QueryFirstOrDefaultAsync<dynamic>(
            "SELECT id, username, password_hash, display_name, is_admin, created_at, last_login FROM users WHERE username = @Username COLLATE NOCASE",
            new { request.Username });

        if (row == null) return null;

        string hash = (string)row.password_hash;
        if (!BCrypt.Net.BCrypt.Verify(request.Password, hash)) return null;

        // Update last login
        await conn.ExecuteAsync(
            "UPDATE users SET last_login = @Now WHERE id = @Id",
            new { Now = DateTime.UtcNow.ToString("O"), Id = (string)row.id });

        var user = new UserInfo(
            (string)row.id,
            (string)row.username,
            row.display_name as string,
            Convert.ToBoolean(row.is_admin),
            DateTime.Parse((string)row.created_at, System.Globalization.CultureInfo.InvariantCulture),
            DateTime.UtcNow
        );

        var expiry = request.RememberMe ? TimeSpan.FromDays(90) : TimeSpan.FromHours(24);
        var token = GenerateToken(user, expiry);
        var expiresAt = DateTime.UtcNow.Add(expiry);

        return new AuthResponse(token, user, expiresAt);
    }

    public async Task<AuthResponse?> RegisterAsync(RegisterRequest request)
    {
        using var conn = _db.CreateConnection();

        // Check if user exists
        var exists = await conn.QueryFirstOrDefaultAsync<int>(
            "SELECT COUNT(*) FROM users WHERE username = @Username COLLATE NOCASE",
            new { request.Username });
        if (exists > 0) return null;

        var user = new UserInfo(
            Guid.NewGuid().ToString("N"),
            request.Username.Trim(),
            request.DisplayName?.Trim(),
            false,
            DateTime.UtcNow,
            DateTime.UtcNow
        );

        var passwordHash = BCrypt.Net.BCrypt.HashPassword(request.Password, workFactor: 12);

        await conn.ExecuteAsync(
            @"INSERT INTO users (id, username, password_hash, display_name, is_admin, created_at, last_login)
              VALUES (@Id, @Username, @Hash, @DisplayName, @IsAdmin, @CreatedAt, @LastLogin)",
            new
            {
                user.Id,
                user.Username,
                Hash = passwordHash,
                user.DisplayName,
                IsAdmin = user.IsAdmin ? 1 : 0,
                CreatedAt = user.CreatedAt.ToString("O"),
                LastLogin = user.LastLogin?.ToString("O")
            });

        var token = GenerateToken(user, TimeSpan.FromHours(24));
        return new AuthResponse(token, user, DateTime.UtcNow.AddHours(24));
    }

    public async Task<bool> HasAnyUsersAsync()
    {
        using var conn = _db.CreateConnection();
        var count = await conn.QueryFirstOrDefaultAsync<int>("SELECT COUNT(*) FROM users");
        return count > 0;
    }

    public async Task<AuthResponse?> CreateAdminAsync(RegisterRequest request)
    {
        // Only works if no users exist yet (first-run setup)
        if (await HasAnyUsersAsync()) return null;

        using var conn = _db.CreateConnection();
        var user = new UserInfo(
            Guid.NewGuid().ToString("N"),
            request.Username.Trim(),
            request.DisplayName?.Trim() ?? request.Username.Trim(),
            true,
            DateTime.UtcNow,
            DateTime.UtcNow
        );

        var passwordHash = BCrypt.Net.BCrypt.HashPassword(request.Password, workFactor: 12);

        await conn.ExecuteAsync(
            @"INSERT INTO users (id, username, password_hash, display_name, is_admin, created_at, last_login)
              VALUES (@Id, @Username, @Hash, @DisplayName, 1, @CreatedAt, @LastLogin)",
            new
            {
                user.Id,
                user.Username,
                Hash = passwordHash,
                user.DisplayName,
                CreatedAt = user.CreatedAt.ToString("O"),
                LastLogin = user.LastLogin?.ToString("O")
            });

        var token = GenerateToken(user, TimeSpan.FromHours(24));
        return new AuthResponse(token, user, DateTime.UtcNow.AddHours(24));
    }

    private string GenerateToken(UserInfo user, TimeSpan expiry)
    {
        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(_jwtSecret));
        var creds = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);

        var claims = new[]
        {
            new Claim(ClaimTypes.NameIdentifier, user.Id),
            new Claim(ClaimTypes.Name, user.Username),
            new Claim("display_name", user.DisplayName ?? user.Username),
            new Claim(ClaimTypes.Role, user.IsAdmin ? "admin" : "user")
        };

        var token = new JwtSecurityToken(
            issuer: _issuer,
            audience: "WiretuneClient",
            claims: claims,
            expires: DateTime.UtcNow.Add(expiry),
            signingCredentials: creds
        );

        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    public TokenValidationParameters GetValidationParameters()
    {
        return new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = _issuer,
            ValidateAudience = true,
            ValidAudience = "WiretuneClient",
            ValidateLifetime = true,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(_jwtSecret)),
            ValidateIssuerSigningKey = true,
            ClockSkew = TimeSpan.FromMinutes(5)
        };
    }
}
