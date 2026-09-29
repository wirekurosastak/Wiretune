using System.Security.Claims;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Options;
using Wiretune.Core.Models;
using Wiretune.Core.Data;
using Wiretune.Core.Services;
using Wiretune.Core.Data;
using Wiretune.Server;
using Wiretune.Server.Auth;

var builder = WebApplication.CreateBuilder(args);

var options = builder.Configuration.GetSection("Wiretune").Get<ServerOptions>() ?? new ServerOptions();
builder.Services.Configure<ServerOptions>(builder.Configuration.GetSection("Wiretune"));

var dataDirectory = AppPaths.GetDataDirectory(options.DataDirectory, "Server");
WiretuneLog.Initialize(Path.Combine(dataDirectory, "wiretune-server.log"));
WiretuneLog.Info("Wiretune.Server", "=== Starting Wiretune.Server ===");

var paths = new ServerPaths(
    ResolveLibraryRoot(options.LibraryPath, builder.Environment.ContentRootPath),
    dataDirectory,
    Path.Combine(dataDirectory, "Covers"));
WiretuneLog.Info("Wiretune.Server", $"Library: '{paths.LibraryRoot}' (exists: {Directory.Exists(paths.LibraryRoot)}), data: '{paths.DataDirectory}'");

builder.Services.AddSingleton(paths);
builder.Services.AddSingleton(new DatabaseManager(Path.Combine(dataDirectory, "wiretune-server.db")));
builder.Services.AddSingleton<LibraryRepository, LibraryRepository>();
builder.Services.AddSingleton<MetadataScanner, MetadataScanner>();
builder.Services.AddSingleton<LibraryService>(sp => new LibraryService(
    sp.GetRequiredService<LibraryRepository>(),
    sp.GetRequiredService<MetadataScanner>(),
    paths.CoverCacheDirectory));
builder.Services.AddSingleton<AuthService>();
builder.Services.AddSingleton<LibraryScanService>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<LibraryScanService>());

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer();
builder.Services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
    .Configure<AuthService>((jwt, auth) =>
    {
        jwt.TokenValidationParameters = auth.GetValidationParameters();
        jwt.Events = new JwtBearerEvents
        {
            // Players that cannot send headers (e.g. external media players) may pass the token in the query string.
            OnMessageReceived = context =>
            {
                if (string.IsNullOrEmpty(context.Token) &&
                    context.Request.Query.TryGetValue("token", out var token) &&
                    !string.IsNullOrEmpty(token))
                {
                    context.Token = token;
                }
                return Task.CompletedTask;
            }
        };
    });
builder.Services.AddAuthorizationBuilder()
    .AddPolicy("admin", policy => policy.RequireRole("admin"));

if (string.IsNullOrEmpty(builder.Configuration["urls"]) && string.IsNullOrEmpty(builder.Configuration["ASPNETCORE_URLS"]))
{
    builder.WebHost.UseUrls($"http://0.0.0.0:{options.Port}");
}

var app = builder.Build();

await app.Services.GetRequiredService<LibraryService>().InitializeAsync();

app.UseAuthentication();
app.UseAuthorization();

var library = app.Services.GetRequiredService<LibraryService>();
var authService = app.Services.GetRequiredService<AuthService>();

// ── Auth (anonymous) ──

app.MapGet("/api/auth/setup-required", async () =>
    Results.Ok(new { SetupRequired = !await authService.HasAnyUsersAsync() }));

app.MapPost("/api/auth/setup", async (RegisterRequest request) =>
{
    if (AuthService.ValidateCredentials(request.Username, request.Password) is { } error)
        return Results.BadRequest(new { Error = error });

    var result = await authService.CreateAdminAsync(request);
    return result == null
        ? Results.Conflict(new { Error = "The server is already set up. Sign in instead." })
        : Results.Ok(result);
});

app.MapPost("/api/auth/login", async (LoginRequest request) =>
{
    if (string.IsNullOrWhiteSpace(request.Username) || string.IsNullOrEmpty(request.Password))
        return Results.BadRequest(new { Error = "Username and password are required." });

    var result = await authService.LoginAsync(request);
    return result == null ? Results.Unauthorized() : Results.Ok(result);
});

// ── Auth (authenticated) ──

app.MapPost("/api/auth/register", async (RegisterRequest request) =>
{
    if (AuthService.ValidateCredentials(request.Username, request.Password) is { } error)
        return Results.BadRequest(new { Error = error });

    var user = await authService.RegisterAsync(request);
    return user == null ? Results.Conflict(new { Error = "Username already taken." }) : Results.Ok(user);
}).RequireAuthorization("admin");

app.MapGet("/api/auth/me", async (ClaimsPrincipal principal) =>
{
    var id = principal.FindFirstValue(ClaimTypes.NameIdentifier);
    var user = id == null ? null : await authService.GetUserAsync(id);
    return user == null ? Results.Unauthorized() : Results.Ok(user);
}).RequireAuthorization();

app.MapGet("/api/users", async () =>
{
    var users = await authService.GetAllUsersAsync();
    return Results.Ok(users);
}).RequireAuthorization("admin");

app.MapDelete("/api/users/{userId}", async (string userId, ClaimsPrincipal principal) =>
{
    var currentUserId = principal.FindFirstValue(ClaimTypes.NameIdentifier);
    if (string.Equals(currentUserId, userId, StringComparison.OrdinalIgnoreCase))
        return Results.BadRequest(new { Error = "Saját fiókodat nem törölheted." });

    var deleted = await authService.DeleteUserAsync(userId);
    return deleted ? Results.Ok() : Results.NotFound(new { Error = "A felhasználó nem található." });
}).RequireAuthorization("admin");

app.MapGet("/api/config", () => Results.Ok(new ServerConfigInfo(paths.LibraryRoot))).RequireAuthorization("admin");

app.MapPost("/api/config/library-path", async (UpdateLibraryPathRequest request, LibraryScanService scanner) =>
{
    if (string.IsNullOrWhiteSpace(request.NewPath))
        return Results.BadRequest(new { Error = "A mappa el elérési útja nem lehet üres." });

    var fullPath = Path.GetFullPath(request.NewPath);
    if (!Directory.Exists(fullPath))
        return Results.BadRequest(new { Error = $"A megadott mappa nem létezik: {fullPath}" });

    paths.LibraryRoot = fullPath;
    scanner.RequestScan();
    return Results.Ok(new ServerConfigInfo(paths.LibraryRoot));
}).RequireAuthorization("admin");

// ── Library ──

var api = app.MapGroup("/api").RequireAuthorization();

api.MapGet("/library/status", (LibraryScanService scanner) => Results.Ok(new ServerLibraryStatus(
    library.Tracks.Count,
    library.Albums.Count,
    library.Artists.Count,
    library.IsScanning,
    scanner.LastScanCompletedUtc,
    scanner.LastScanError)));

api.MapPost("/library/scan", (LibraryScanService scanner) =>
{
    scanner.RequestScan();
    return Results.Accepted("/api/library/status", new { Message = "Scan requested." });
}).RequireAuthorization("admin");

api.MapGet("/tracks", (string? q) => Results.Ok(string.IsNullOrWhiteSpace(q) ? library.Tracks : library.Search(q).ToList()));
api.MapGet("/albums", () => Results.Ok(library.Albums));
api.MapGet("/artists", () => Results.Ok(library.Artists));

api.MapGet("/stream/{trackId}", (string trackId) =>
{
    var track = library.GetTrack(trackId);
    if (track == null || !AppPaths.IsPathUnderRoot(track.FilePath, paths.LibraryRoot) || !File.Exists(track.FilePath))
        return Results.NotFound(new { Error = "Track not found." });

    return Results.File(track.FilePath, AudioFileTypes.GetMimeType(track.FilePath), enableRangeProcessing: true);
});

api.MapGet("/cover/{trackId}", async (string trackId, MetadataScanner scanner, HttpContext http) =>
    await CoverResultAsync(library.GetTrack(trackId), scanner, http));

api.MapGet("/cover/album/{albumId}", async (string albumId, MetadataScanner scanner, HttpContext http) =>
    await CoverResultAsync(library.GetAlbum(albumId)?.Tracks.FirstOrDefault(t => t.HasCoverArt), scanner, http));

app.Run();

async Task<IResult> CoverResultAsync(Track? track, MetadataScanner scanner, HttpContext http)
{
    if (track == null || !AppPaths.IsPathUnderRoot(track.FilePath, paths.LibraryRoot)) return Results.NotFound();

    http.Response.Headers.CacheControl = "private, max-age=86400";

    var coverPath = track.CoverArtPath;
    if (!string.IsNullOrEmpty(coverPath) && File.Exists(coverPath) &&
        (AppPaths.IsPathUnderRoot(coverPath, paths.CoverCacheDirectory) || AppPaths.IsPathUnderRoot(coverPath, paths.LibraryRoot)))
    {
        return Results.File(coverPath, ImageFormat.GetMimeTypeFromPath(coverPath));
    }

    var bytes = File.Exists(track.FilePath) ? await scanner.ExtractCoverArtAsync(track.FilePath, http.RequestAborted) : null;
    return bytes is { Length: > 0 } ? Results.Bytes(bytes, ImageFormat.GetMimeType(bytes)) : Results.NotFound();
}

static string ResolveLibraryRoot(string? configured, string contentRoot)
{
    if (!string.IsNullOrWhiteSpace(configured))
    {
        var resolved = Path.GetFullPath(Path.IsPathRooted(configured) ? configured : Path.Combine(contentRoot, configured));
        if (Directory.Exists(resolved)) return resolved;
        WiretuneLog.Warn("Wiretune.Server", $"Configured library path '{resolved}' does not exist.");
    }

    var musicDir = Environment.GetFolderPath(Environment.SpecialFolder.MyMusic);
    if (string.IsNullOrEmpty(musicDir))
        musicDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Music");

    if (string.IsNullOrWhiteSpace(configured) || Directory.Exists(musicDir))
    {
        WiretuneLog.Warn("Wiretune.Server", $"Falling back to the user's music folder: '{musicDir}'. Set Wiretune:LibraryPath to choose another folder.");
        return Path.GetFullPath(musicDir);
    }

    return Path.GetFullPath(Path.IsPathRooted(configured) ? configured : Path.Combine(contentRoot, configured));
}

public partial class Program;



