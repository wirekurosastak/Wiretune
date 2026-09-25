using System.Security.Claims;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Wiretune.Core.Models;
using Wiretune.Core.Repositories;
using Wiretune.Core.Services;
using Wiretune.Data;
using Wiretune.Server.Auth;

var builder = WebApplication.CreateBuilder(args);

// Register Core & Data services
builder.Services.AddSingleton<DatabaseManager>();
builder.Services.AddSingleton<ILibraryRepository, LibraryRepository>();
builder.Services.AddSingleton<IMetadataScanner, MetadataScanner>();
builder.Services.AddSingleton<ILibraryService, LibraryService>();
builder.Services.AddSingleton<AuthService>();
builder.Services.AddCors();

// JWT Authentication — configured after build so AuthService can generate keys
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.Events = new JwtBearerEvents
        {
            OnMessageReceived = context =>
            {
                var token = context.Request.Query["token"].FirstOrDefault()
                            ?? context.Request.Query["access_token"].FirstOrDefault();
                if (!string.IsNullOrEmpty(token))
                {
                    context.Token = token;
                }
                return Task.CompletedTask;
            }
        };
    });
builder.Services.AddAuthorization();

var app = builder.Build();

// Ensure database schema is initialized before services query it
var db = app.Services.GetRequiredService<DatabaseManager>();
db.InitializeSchema();

// Configure JWT validation parameters from AuthService
var authService = app.Services.GetRequiredService<AuthService>();
app.Services.GetRequiredService<Microsoft.Extensions.Options.IOptionsMonitor<JwtBearerOptions>>().CurrentValue.TokenValidationParameters = authService.GetValidationParameters();

// CORS — restrict to localhost and LAN by default
app.UseCors(policy => policy
    .AllowAnyOrigin()
    .AllowAnyHeader()
    .AllowAnyMethod());

app.UseAuthentication();
app.UseAuthorization();

WiretuneLog.Initialize();
WiretuneLog.Info("Wiretune.Server", "=== Starting Wiretune.Server ===");

// Initialize Library Service (without self-connection attempt)
var libraryService = app.Services.GetRequiredService<ILibraryService>();
await libraryService.InitializeAsync();

var config = app.Configuration.GetSection("Wiretune");
var configuredPath = config.GetValue<string>("LibraryPath");
var userMusicDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Music");
if (string.IsNullOrWhiteSpace(configuredPath) || (!Directory.Exists(configuredPath) && Directory.Exists(userMusicDir)))
{
    configuredPath = userMusicDir;
}

WiretuneLog.Info("Wiretune.Server", $"Library path configured: '{configuredPath}' (Exists: {Directory.Exists(configuredPath)})");

if (Directory.Exists(configuredPath) && libraryService.Tracks.Count == 0)
{
    WiretuneLog.Info("Wiretune.Server", $"Starting initial scan: '{configuredPath}'");
    _ = Task.Run(async () =>
    {
        try
        {
            await libraryService.ScanFolderAsync(configuredPath, null, CancellationToken.None);
            WiretuneLog.Info("Wiretune.Server", $"Scan complete! Tracks: {libraryService.Tracks.Count}, Albums: {libraryService.Albums.Count}, Artists: {libraryService.Artists.Count}");
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("Wiretune.Server", $"Scan error: {ex.Message}", ex);
        }
    });
}

// ── Auth Endpoints (unauthenticated) ──

app.MapGet("/api/auth/setup-required", async () =>
{
    var hasUsers = await authService.HasAnyUsersAsync();
    return Results.Ok(new { SetupRequired = !hasUsers });
});

app.MapPost("/api/auth/setup", async (RegisterRequest request) =>
{
    if (string.IsNullOrWhiteSpace(request.Username) || string.IsNullOrWhiteSpace(request.Password))
        return Results.BadRequest(new { Error = "Username and password are required." });
    if (request.Password.Length < 6)
        return Results.BadRequest(new { Error = "Password must be at least 6 characters." });

    var result = await authService.CreateAdminAsync(request);
    if (result == null)
        return Results.Conflict(new { Error = "Admin account already exists. Use /api/auth/login instead." });

    return Results.Ok(result);
});

app.MapPost("/api/auth/login", async (LoginRequest request) =>
{
    if (string.IsNullOrWhiteSpace(request.Username) || string.IsNullOrWhiteSpace(request.Password))
        return Results.BadRequest(new { Error = "Username and password are required." });

    var result = await authService.LoginAsync(request);
    if (result == null)
        return Results.Unauthorized();

    return Results.Ok(result);
});

app.MapPost("/api/auth/register", async (RegisterRequest request, ClaimsPrincipal user) =>
{
    // Only admins can create new accounts
    if (!user.Identity?.IsAuthenticated ?? true)
        return Results.Unauthorized();
    if (!user.IsInRole("admin"))
        return Results.Forbid();

    if (string.IsNullOrWhiteSpace(request.Username) || string.IsNullOrWhiteSpace(request.Password))
        return Results.BadRequest(new { Error = "Username and password are required." });
    if (request.Password.Length < 6)
        return Results.BadRequest(new { Error = "Password must be at least 6 characters." });

    var result = await authService.RegisterAsync(request);
    if (result == null)
        return Results.Conflict(new { Error = "Username already taken." });

    return Results.Ok(result);
}).RequireAuthorization();

app.MapGet("/api/auth/me", (ClaimsPrincipal user) =>
{
    if (!user.Identity?.IsAuthenticated ?? true)
        return Results.Unauthorized();

    return Results.Ok(new
    {
        Id = user.FindFirst(ClaimTypes.NameIdentifier)?.Value,
        Username = user.FindFirst(ClaimTypes.Name)?.Value,
        DisplayName = user.FindFirst("display_name")?.Value,
        Role = user.FindFirst(ClaimTypes.Role)?.Value
    });
}).RequireAuthorization();

// ── Library Endpoints (authenticated) ──

app.MapGet("/api/library/status", () => Results.Ok(new
{
    Status = "Online",
    TrackCount = libraryService.Tracks.Count,
    AlbumCount = libraryService.Albums.Count,
    ArtistCount = libraryService.Artists.Count,
    LibraryPath = configuredPath,
    IsScanning = libraryService.IsScanning,
    ServerTime = DateTime.UtcNow
})).RequireAuthorization();

// Scan — with path traversal protection
app.MapPost("/api/library/scan", async (string? path, CancellationToken ct) =>
{
    var targetPath = !string.IsNullOrWhiteSpace(path) ? path : configuredPath;

    // Path traversal protection: only allow scanning within the configured library root
    var canonicalTarget = Path.GetFullPath(targetPath);
    var canonicalLibrary = Path.GetFullPath(configuredPath);
    if (!canonicalTarget.StartsWith(canonicalLibrary, StringComparison.OrdinalIgnoreCase))
    {
        return Results.Forbid();
    }

    if (!Directory.Exists(canonicalTarget))
    {
        return Results.BadRequest(new { Error = $"Directory does not exist: {targetPath}" });
    }

    if (!libraryService.IsScanning)
    {
        _ = Task.Run(async () =>
        {
            await libraryService.ScanFolderAsync(canonicalTarget, null, CancellationToken.None);
        }, ct);
    }

    return Results.Accepted("/api/library/status", new { Message = $"Scan started: {targetPath}" });
}).RequireAuthorization();

app.MapGet("/api/tracks", (string? q) =>
{
    var tracks = string.IsNullOrWhiteSpace(q)
        ? libraryService.Tracks
        : libraryService.Search(q);
    return Results.Ok(tracks);
}).RequireAuthorization();

app.MapGet("/api/albums", () => Results.Ok(libraryService.Albums)).RequireAuthorization();
app.MapGet("/api/artists", () => Results.Ok(libraryService.Artists)).RequireAuthorization();
app.MapGet("/api/playlists", () => Results.Ok(libraryService.Playlists)).RequireAuthorization();

// Stream audio with HTTP 206 Partial Content
app.MapGet("/api/stream/{trackId}", (string trackId, HttpContext context) =>
{
    var track = libraryService.Tracks.FirstOrDefault(t => t.Id == trackId);
    if (track == null || !File.Exists(track.FilePath))
    {
        return Results.NotFound(new { Error = "Track not found." });
    }

    // Validate file is within library path
    var canonicalFile = Path.GetFullPath(track.FilePath);
    var canonicalLib = Path.GetFullPath(configuredPath);
    if (!canonicalFile.StartsWith(canonicalLib, StringComparison.OrdinalIgnoreCase))
    {
        return Results.Forbid();
    }

    var contentType = Path.GetExtension(track.FilePath).ToLowerInvariant() switch
    {
        ".flac" => "audio/flac",
        ".mp3" => "audio/mpeg",
        ".wav" => "audio/wav",
        ".m4a" => "audio/mp4",
        ".aac" => "audio/aac",
        ".ogg" => "audio/ogg",
        _ => "application/octet-stream"
    };

    return Results.File(track.FilePath, contentType: contentType, enableRangeProcessing: true);
}).RequireAuthorization();

// Cover art
app.MapGet("/api/cover/{trackId}", async (string trackId, IMetadataScanner scanner) =>
{
    var track = libraryService.Tracks.FirstOrDefault(t => t.Id == trackId);
    if (track == null || !File.Exists(track.FilePath))
        return Results.NotFound();

    if (!string.IsNullOrEmpty(track.CoverArtPath) && File.Exists(track.CoverArtPath))
    {
        var ext = Path.GetExtension(track.CoverArtPath).ToLowerInvariant();
        var mime = ext == ".png" ? "image/png" : "image/jpeg";
        return Results.File(track.CoverArtPath, mime);
    }

    var coverBytes = await scanner.ExtractCoverArtAsync(track.FilePath);
    if (coverBytes != null && coverBytes.Length > 0)
        return Results.Bytes(coverBytes, "image/jpeg");

    return Results.NotFound();
}).RequireAuthorization();

app.MapGet("/api/cover/album/{albumId}", async (string albumId, IMetadataScanner scanner) =>
{
    var album = libraryService.Albums.FirstOrDefault(a => a.Id == albumId);
    var firstTrack = album?.Tracks.FirstOrDefault();
    if (firstTrack == null || !File.Exists(firstTrack.FilePath))
        return Results.NotFound();

    if (!string.IsNullOrEmpty(firstTrack.CoverArtPath) && File.Exists(firstTrack.CoverArtPath))
    {
        var ext = Path.GetExtension(firstTrack.CoverArtPath).ToLowerInvariant();
        var mime = ext == ".png" ? "image/png" : "image/jpeg";
        return Results.File(firstTrack.CoverArtPath, mime);
    }

    var coverBytes = await scanner.ExtractCoverArtAsync(firstTrack.FilePath);
    if (coverBytes != null && coverBytes.Length > 0)
        return Results.Bytes(coverBytes, "image/jpeg");

    return Results.NotFound();
}).RequireAuthorization();

var port = config.GetValue<int>("Port", 5200);
app.Urls.Add($"http://0.0.0.0:{port}");

app.Run();
