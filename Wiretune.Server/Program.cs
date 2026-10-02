using System.Security.Claims;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.RateLimiting;
using Wiretune.Core.Data;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.Server;
using Wiretune.Server.Auth;

var builder = WebApplication.CreateBuilder(args);

var options = builder.Configuration.GetSection("Wiretune").Get<ServerOptions>() ?? new ServerOptions();
builder.Services.Configure<ServerOptions>(builder.Configuration.GetSection("Wiretune"));

var dataDirectory = AppPaths.GetDataDirectory(options.DataDirectory, "Server");
WiretuneLog.Initialize(Path.Combine(dataDirectory, "wiretune-server.log"));
WiretuneLog.Info("Wiretune.Server", "=== Starting Wiretune.Server ===");

var database = new DatabaseManager(Path.Combine(dataDirectory, "wiretune-server.db"));
database.InitializeSchema();
var repository = new LibraryRepository(database);

// A library folder chosen through the admin API wins over the configured one, so it survives restarts.
var paths = new ServerPaths(
    await LoadSavedLibraryRootAsync(repository) ?? ResolveLibraryRoot(options.LibraryPath, builder.Environment.ContentRootPath),
    dataDirectory,
    Path.Combine(dataDirectory, "Covers"));
WiretuneLog.Info("Wiretune.Server", $"Library: '{paths.LibraryRoot}' (exists: {Directory.Exists(paths.LibraryRoot)}), data: '{paths.DataDirectory}'");

builder.Services.AddSingleton(paths);
builder.Services.AddSingleton(database);
builder.Services.AddSingleton(repository);
builder.Services.AddSingleton<MetadataScanner, MetadataScanner>();
builder.Services.AddSingleton<LibraryService>(sp => new LibraryService(
    sp.GetRequiredService<LibraryRepository>(),
    sp.GetRequiredService<MetadataScanner>(),
    paths.CoverCacheDirectory));
builder.Services.AddSingleton(new AuthService(database, await repository.GetOrAddSettingAsync("jwt_secret", AuthService.GenerateSecret)));
builder.Services.AddSingleton<UserDataService>();
builder.Services.AddSingleton(new SetupCode(options.SetupCode));
builder.Services.AddSingleton<LibraryScanService>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<LibraryScanService>());

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer();
builder.Services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
    .Configure<AuthService>((jwt, auth) =>
    {
        jwt.TokenValidationParameters = auth.GetValidationParameters();
        jwt.Events = new JwtBearerEvents
        {
            // Players that cannot send headers (ffplay, Android MediaPlayer) pass the token in the query string.
            // Only the media endpoints accept that, so a URL that ends up in a log cannot drive the management API.
            OnMessageReceived = context =>
            {
                var path = context.Request.Path;
                if (string.IsNullOrEmpty(context.Token) &&
                    IsMediaPath(path) &&
                    context.Request.Query.TryGetValue("token", out var token) &&
                    !string.IsNullOrEmpty(token))
                {
                    context.Token = token;
                }
                return Task.CompletedTask;
            },
            // Tokens live for up to 90 days: deleting an account must end its access immediately.
            OnTokenValidated = async context =>
            {
                // A stream token (the one that ends up in stream URLs) opens the media routes and nothing else.
                if (context.Principal?.HasClaim(AuthService.ScopeClaim, AuthService.StreamScope) == true &&
                    !IsMediaPath(context.Request.Path))
                {
                    context.Fail("A stream token only opens the audio and cover routes.");
                    return;
                }

                var userId = context.Principal?.FindFirstValue(ClaimTypes.NameIdentifier);
                var auth = context.HttpContext.RequestServices.GetRequiredService<AuthService>();
                if (userId == null || !await auth.UserExistsAsync(userId))
                    context.Fail("The account no longer exists.");
            }
        };
    });
builder.Services.AddAuthorizationBuilder()
    .AddPolicy("admin", policy => policy.RequireRole("admin"));

// bcrypt makes every guess expensive for the server, but nothing stops a client from guessing forever.
builder.Services.AddRateLimiter(limiter =>
{
    limiter.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    limiter.OnRejected = async (context, ct) =>
    {
        if (context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
            context.HttpContext.Response.Headers.RetryAfter = ((int)Math.Ceiling(retryAfter.TotalSeconds)).ToString();
        await context.HttpContext.Response.WriteAsJsonAsync(new { Error = "Too many attempts. Try again in a minute." }, ct);
    };
    limiter.AddPolicy("auth", http => RateLimitPartition.GetFixedWindowLimiter(
        http.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions { PermitLimit = 10, Window = TimeSpan.FromMinutes(1) }));
});

// The library listing can be several megabytes of JSON; audio and cover formats are not on the default MIME list.
builder.Services.AddResponseCompression();

if (string.IsNullOrEmpty(builder.Configuration["urls"]) && string.IsNullOrEmpty(builder.Configuration["ASPNETCORE_URLS"]))
{
    builder.WebHost.UseUrls($"http://0.0.0.0:{options.Port}");
}

// The API never accepts uploads; only small JSON bodies (login, setup, library path). The two endpoints that carry
// track lists raise their own limit below.
builder.WebHost.ConfigureKestrel(kestrel => kestrel.Limits.MaxRequestBodySize = 64 * 1024);

var app = builder.Build();

await app.Services.GetRequiredService<LibraryService>().InitializeAsync();

app.UseResponseCompression();
app.UseRateLimiter();

// A playlist can name 20 000 tracks and a device's old data can hold far more: those two routes may read bigger bodies.
// They are only read after authorisation (every route below needs a valid token), so this opens nothing to anonymous callers.
app.Use(async (context, next) =>
{
    const long PlaylistBodyLimit = 4L * 1024 * 1024;
    const long ImportBodyLimit = 32L * 1024 * 1024;

    var path = context.Request.Path;
    long? limit = path.StartsWithSegments("/api/me/data/import") ? ImportBodyLimit
        : path.StartsWithSegments("/api/me/playlists") ? PlaylistBodyLimit
        : null;

    if (limit != null && context.Features.Get<IHttpMaxRequestBodySizeFeature>() is { IsReadOnly: false } feature)
        feature.MaxRequestBodySize = limit;

    await next();
});

app.UseAuthentication();
app.UseAuthorization();

var library = app.Services.GetRequiredService<LibraryService>();
var authService = app.Services.GetRequiredService<AuthService>();
var setupCode = app.Services.GetRequiredService<SetupCode>();

if (!await authService.HasAnyUsersAsync())
{
    WiretuneLog.Warn("Wiretune.Server",
        $"No administrator account exists yet. Create it in the player with the setup code {setupCode.Value}");
}

// ── Auth (anonymous) ──

app.MapGet("/api/auth/setup-required", async () =>
    Results.Ok(new { SetupRequired = !await authService.HasAnyUsersAsync() }));

app.MapPost("/api/auth/setup", async (SetupRequest request) =>
{
    if (AuthService.ValidateCredentials(request.Username, request.Password) is { } error)
        return Results.BadRequest(new { Error = error });

    if (await authService.HasAnyUsersAsync())
        return Results.Conflict(new { Error = "The server is already set up. Sign in instead." });

    if (!setupCode.Matches(request.SetupCode))
    {
        return Results.Json(
            new { Error = "The setup code is missing or wrong. The server prints it in its log when it starts." },
            statusCode: StatusCodes.Status403Forbidden);
    }

    var result = await authService.CreateAdminAsync(new RegisterRequest(request.Username, request.Password));
    return result == null
        ? Results.Conflict(new { Error = "The server is already set up. Sign in instead." })
        : Results.Ok(result);
}).RequireRateLimiting("auth");

app.MapPost("/api/auth/login", async (LoginRequest request) =>
{
    if (string.IsNullOrWhiteSpace(request.Username) || string.IsNullOrEmpty(request.Password))
        return Results.BadRequest(new { Error = "Username and password are required." });

    var result = await authService.LoginAsync(request);
    return result == null ? Results.Unauthorized() : Results.Ok(result);
}).RequireRateLimiting("auth");

// ── Auth (authenticated) ──

app.MapPost("/api/auth/register", async (RegisterRequest request) =>
{
    if (AuthService.ValidateCredentials(request.Username, request.Password) is { } error)
        return Results.BadRequest(new { Error = error });

    var user = await authService.RegisterAsync(request);
    return user == null ? Results.Conflict(new { Error = "Username already taken." }) : Results.Ok(user);
}).RequireAuthorization("admin");

// A short-lived token for stream URLs. Stream tokens themselves are refused here (see OnTokenValidated).
app.MapPost("/api/auth/stream-token", (ClaimsPrincipal principal) =>
{
    var id = principal.FindFirstValue(ClaimTypes.NameIdentifier);
    var name = principal.FindFirstValue(ClaimTypes.Name);
    return id == null || name == null ? Results.Unauthorized() : Results.Ok(authService.CreateStreamToken(id, name));
}).RequireAuthorization();

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
        return Results.BadRequest(new { Error = "You cannot delete your own account." });

    var deleted = await authService.DeleteUserAsync(userId);
    return deleted ? Results.Ok() : Results.NotFound(new { Error = "User not found." });
}).RequireAuthorization("admin");

app.MapGet("/api/config", () => Results.Ok(new ServerConfigInfo(paths.LibraryRoot))).RequireAuthorization("admin");

app.MapPost("/api/config/library-path", async (UpdateLibraryPathRequest request, LibraryScanService scanner) =>
{
    if (string.IsNullOrWhiteSpace(request.NewPath))
        return Results.BadRequest(new { Error = "The folder path must not be empty." });

    string fullPath;
    try
    {
        fullPath = Path.GetFullPath(request.NewPath);
    }
    catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
    {
        return Results.BadRequest(new { Error = "The folder path is not valid." });
    }

    if (!Directory.Exists(fullPath))
        return Results.BadRequest(new { Error = $"The folder does not exist: {fullPath}" });

    await repository.SetSettingAsync("library_path", fullPath);
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

api.MapGet("/tracks", (string? q) => Results.Ok(
    (string.IsNullOrWhiteSpace(q) ? library.Tracks : library.Search(q)).Select(ServerTrackDto.From).ToList()));
api.MapGet("/albums", () => Results.Ok(library.Albums.Select(ServerAlbumDto.From).ToList()));
api.MapGet("/artists", () => Results.Ok(library.Artists.Select(ServerArtistDto.From).ToList()));

api.MapGet("/stream/{trackId}", (string trackId) =>
{
    var track = library.GetTrack(trackId);
    if (track == null || !AppPaths.IsPathUnderRoot(track.FilePath, paths.LibraryRoot) || !File.Exists(track.FilePath))
        return Results.NotFound(new { Error = "Track not found." });

    return Results.File(track.FilePath, AudioFileTypes.GetMimeType(track.FilePath), enableRangeProcessing: true);
});

api.MapGet("/cover/{trackId}", async (string trackId, MetadataScanner scanner, HttpContext http) =>
    await CoverResultAsync(library.GetTrack(trackId), scanner, http));

api.MapGet("/lyrics/{trackId}", async (string trackId, HttpContext http) =>
{
    var track = library.GetTrack(trackId);
    if (track == null || !AppPaths.IsPathUnderRoot(track.FilePath, paths.LibraryRoot)) return Results.NotFound();

    var lyrics = await MetadataScanner.ReadLyricsAsync(track.FilePath, http.RequestAborted);
    return lyrics == null ? Results.NotFound() : Results.Ok(new { lyrics });
});

api.MapGet("/cover/album/{albumId}", async (string albumId, MetadataScanner scanner, HttpContext http) =>
    await CoverResultAsync(library.GetAlbum(albumId)?.Tracks.FirstOrDefault(t => t.HasCoverArt), scanner, http));

// ── The signed-in account's favourites, play counts and playlists (stored on the server, per account) ──

var me = api.MapGroup("/me");

me.MapGet("/data", async (ClaimsPrincipal principal, UserDataService userData) =>
    Results.Ok(await userData.GetAsync(CurrentUserId(principal))));

// One-time hand-over of what a player kept on the device before the server stored it. Union: nothing is removed or lowered.
me.MapPost("/data/import", async (UserDataSnapshot? snapshot, ClaimsPrincipal principal, UserDataService userData) =>
{
    if (UserDataService.ValidateImport(snapshot) is { } error) return Results.BadRequest(new { Error = error });

    var stored = await userData.ImportAsync(CurrentUserId(principal), snapshot!);
    return Results.Ok(new { Favorites = stored.Favorites.Count, Plays = stored.Plays.Count, Playlists = stored.Playlists.Count });
});

me.MapPut("/favorites/{trackId}", (string trackId, ClaimsPrincipal principal, UserDataService userData) =>
    FavoriteResultAsync(trackId, true, principal, userData));

me.MapDelete("/favorites/{trackId}", (string trackId, ClaimsPrincipal principal, UserDataService userData) =>
    FavoriteResultAsync(trackId, false, principal, userData));

me.MapPost("/plays/{trackId}", async (string trackId, ClaimsPrincipal principal, UserDataService userData) =>
{
    if (UserDataRules.ValidateId(trackId) is { } error) return Results.BadRequest(new { Error = error });

    var stats = await userData.RecordPlayAsync(CurrentUserId(principal), trackId);
    return stats == null
        ? Results.Conflict(new { Error = $"An account can keep statistics for at most {UserDataRules.MaxTrackStats} tracks." })
        : Results.Ok(stats);
});

me.MapPut("/playlists/{playlistId}", async (string playlistId, PlaylistUpdate? update, ClaimsPrincipal principal, UserDataService userData) =>
{
    if (UserDataService.ValidatePlaylist(playlistId, update) is { } error) return Results.BadRequest(new { Error = error });

    var saved = await userData.SavePlaylistAsync(CurrentUserId(principal), playlistId, update!);
    return saved == null
        ? Results.Conflict(new { Error = $"An account can have at most {UserDataRules.MaxPlaylists} playlists." })
        : Results.Ok(saved);
});

me.MapDelete("/playlists/{playlistId}", async (string playlistId, ClaimsPrincipal principal, UserDataService userData) =>
    await userData.DeletePlaylistAsync(CurrentUserId(principal), playlistId)
        ? Results.Ok(new { Deleted = true })
        : Results.NotFound(new { Error = "Playlist not found." }));

app.Run();

static bool IsMediaPath(PathString path) => path.StartsWithSegments("/api/stream") || path.StartsWithSegments("/api/cover");

static string CurrentUserId(ClaimsPrincipal principal) =>
    principal.FindFirstValue(ClaimTypes.NameIdentifier) ?? throw new InvalidOperationException("The token carries no account ID.");

static async Task<IResult> FavoriteResultAsync(string trackId, bool favorite, ClaimsPrincipal principal, UserDataService userData)
{
    if (UserDataRules.ValidateId(trackId) is { } error) return Results.BadRequest(new { Error = error });

    return await userData.SetFavoriteAsync(CurrentUserId(principal), trackId, favorite)
        ? Results.Ok(new { TrackId = trackId, IsFavorite = favorite })
        : Results.Conflict(new { Error = $"An account can have at most {UserDataRules.MaxFavorites} favourites." });
}

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

static async Task<string?> LoadSavedLibraryRootAsync(LibraryRepository settings)
{
    var saved = await settings.GetSettingAsync("library_path");
    if (string.IsNullOrWhiteSpace(saved)) return null;
    if (Directory.Exists(saved)) return saved;

    WiretuneLog.Warn("Wiretune.Server", $"Saved library path '{saved}' no longer exists; using the configured one instead.");
    return null;
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
