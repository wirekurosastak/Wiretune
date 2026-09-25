using Wiretune.Core.Repositories;
using Wiretune.Core.Services;
using Wiretune.Data;

var builder = WebApplication.CreateBuilder(args);

// Register Core & Data services
builder.Services.AddSingleton<DatabaseManager>();
builder.Services.AddSingleton<ILibraryRepository, LibraryRepository>();
builder.Services.AddSingleton<IMetadataScanner, MetadataScanner>();
builder.Services.AddSingleton<ILibraryService, LibraryService>();

builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
    {
        policy.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod();
    });
});

var app = builder.Build();

app.UseCors();

WiretuneLog.Initialize();
WiretuneLog.Info("Wiretune.Server", "=== Starting Wiretune.Server ===");

// Initialize Library Service
var libraryService = app.Services.GetRequiredService<ILibraryService>();
await libraryService.InitializeAsync();

var config = app.Configuration.GetSection("Wiretune");
var configuredPath = config.GetValue<string>("LibraryPath") ?? "WiretuneLibrary";

// Fallback to /home/wirekurosastak/Music if configured path does not exist
if (!Directory.Exists(configuredPath) && Directory.Exists("/home/wirekurosastak/Music"))
{
    configuredPath = "/home/wirekurosastak/Music";
}

WiretuneLog.Info("Wiretune.Server", $"Library path configured: '{configuredPath}' (Exists: {Directory.Exists(configuredPath)})");

if (Directory.Exists(configuredPath))
{
    if (libraryService.Tracks.Count == 0)
    {
        WiretuneLog.Info("Wiretune.Server", $"Kezdeti szkennelés automatikus indítása: '{configuredPath}'");
        _ = Task.Run(async () =>
        {
            try
            {
                await libraryService.ScanFolderAsync(configuredPath, null, CancellationToken.None);
                WiretuneLog.Info("Wiretune.Server", $"Szkennelés kész! Talált zeneszámok száma: {libraryService.Tracks.Count}, Albumok: {libraryService.Albums.Count}, Előadók: {libraryService.Artists.Count}");
            }
            catch (Exception ex)
            {
                WiretuneLog.Error("Wiretune.Server", $"Hiba a szkennelés során: {ex.Message}", ex);
            }
        });
    }
    else
    {
        WiretuneLog.Info("Wiretune.Server", $"Könyvtár betöltve. {libraryService.Tracks.Count} zeneszám elérhető.");
    }
}
else
{
    WiretuneLog.Warn("Wiretune.Server", $"FIGYELEM: A megadott könyvtár ('{configuredPath}') jelenleg nem érhető el a szerveren!");
}

// Endpoints

// 1. Status
app.MapGet("/api/library/status", () => Results.Ok(new
{
    Status = "Online",
    TrackCount = libraryService.Tracks.Count,
    AlbumCount = libraryService.Albums.Count,
    ArtistCount = libraryService.Artists.Count,
    LibraryPath = configuredPath,
    IsScanning = libraryService.IsScanning,
    ServerTime = DateTime.UtcNow
}));

// 2. Scan
app.MapPost("/api/library/scan", async (string? path, CancellationToken ct) =>
{
    var targetPath = !string.IsNullOrWhiteSpace(path) ? path : configuredPath;
    if (!Directory.Exists(targetPath))
    {
        return Results.BadRequest(new { Error = $"A megadott könyvtár nem létezik: {targetPath}" });
    }

    _ = Task.Run(async () =>
    {
        await libraryService.ScanFolderAsync(targetPath, null, CancellationToken.None);
    }, ct);

    return Results.Accepted("/api/library/status", new { Message = $"A könyvtár szkennelése elindult a háttérben: {targetPath}" });
});

// 3. Tracks
app.MapGet("/api/tracks", (string? q) =>
{
    if (libraryService.Tracks.Count == 0 && Directory.Exists(configuredPath) && !libraryService.IsScanning)
    {
        _ = Task.Run(async () =>
        {
            await libraryService.ScanFolderAsync(configuredPath, null, CancellationToken.None);
        });
    }
    var tracks = string.IsNullOrWhiteSpace(q)
        ? libraryService.Tracks
        : libraryService.Search(q);

    return Results.Ok(tracks);
});

// 4. Albums
app.MapGet("/api/albums", () => Results.Ok(libraryService.Albums));

// 5. Artists
app.MapGet("/api/artists", () => Results.Ok(libraryService.Artists));

// 6. Playlists
app.MapGet("/api/playlists", () => Results.Ok(libraryService.Playlists));

// 7. Stream audio with HTTP 206 Partial Content (Range request support)
app.MapGet("/api/stream/{trackId}", (string trackId, HttpContext context) =>
{
    var track = libraryService.Tracks.FirstOrDefault(t => t.Id == trackId);
    if (track == null || !File.Exists(track.FilePath))
    {
        return Results.NotFound(new { Error = "A kért zeneszám nem található a szerveren." });
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

    // Results.File automatically handles HTTP 206 Range requests and byte seeking for lossless streaming!
    return Results.File(track.FilePath, contentType: contentType, enableRangeProcessing: true);
});

// 8. Cover art
app.MapGet("/api/cover/{trackId}", async (string trackId, IMetadataScanner scanner) =>
{
    var track = libraryService.Tracks.FirstOrDefault(t => t.Id == trackId);
    if (track == null || !File.Exists(track.FilePath))
    {
        return Results.NotFound();
    }

    if (!string.IsNullOrEmpty(track.CoverArtPath) && File.Exists(track.CoverArtPath))
    {
        var ext = Path.GetExtension(track.CoverArtPath).ToLowerInvariant();
        var mime = ext == ".png" ? "image/png" : "image/jpeg";
        return Results.File(track.CoverArtPath, mime);
    }

    var coverBytes = await scanner.ExtractCoverArtAsync(track.FilePath);
    if (coverBytes != null && coverBytes.Length > 0)
    {
        return Results.Bytes(coverBytes, "image/jpeg");
    }

    return Results.NotFound();
});

// 9. Album cover art
app.MapGet("/api/cover/album/{albumId}", async (string albumId, IMetadataScanner scanner) =>
{
    var album = libraryService.Albums.FirstOrDefault(a => a.Id == albumId);
    var firstTrack = album?.Tracks.FirstOrDefault();
    if (firstTrack == null || !File.Exists(firstTrack.FilePath))
    {
        return Results.NotFound();
    }

    if (!string.IsNullOrEmpty(firstTrack.CoverArtPath) && File.Exists(firstTrack.CoverArtPath))
    {
        var ext = Path.GetExtension(firstTrack.CoverArtPath).ToLowerInvariant();
        var mime = ext == ".png" ? "image/png" : "image/jpeg";
        return Results.File(firstTrack.CoverArtPath, mime);
    }

    var coverBytes = await scanner.ExtractCoverArtAsync(firstTrack.FilePath);
    if (coverBytes != null && coverBytes.Length > 0)
    {
        return Results.Bytes(coverBytes, "image/jpeg");
    }

    return Results.NotFound();
});

var port = config.GetValue<int>("Port", 5200);
app.Urls.Add($"http://0.0.0.0:{port}");

app.Run();
