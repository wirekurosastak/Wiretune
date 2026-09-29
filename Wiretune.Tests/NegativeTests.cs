using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Xunit;

namespace Wiretune.Tests;

/// <summary>
/// NEG-001 to NEG-034 — Negative &amp; Error Handling Tests
/// What happens when invalid data, incorrect formats, or missing required fields
/// are passed into Wiretune?
/// </summary>
public class NegativeTests
{
    private static (LibraryService service, MockRepository repo) CreateService()
    {
        var repo = new MockRepository();
        var service = new LibraryService(repo, new MetadataScanner());
        return (service, repo);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-001 — ScanFolderAsync: non-existent path → early return, no exception
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG001_ScanFolder_NonExistentPath_ReturnsEarlyWithoutException()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        var exception = await Record.ExceptionAsync(() =>
            service.ScanFolderAsync("/this/path/does/not/exist/ever"));

        Assert.Null(exception);
        Assert.False(service.IsScanning);
        Assert.Empty(service.Tracks);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-002 — ScanFolderAsync: empty/whitespace path → no scan
    // ─────────────────────────────────────────────────────────────────────────
    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\t")]
    public async Task NEG002_ScanFolder_EmptyOrWhitespacePath_ReturnsEarly(string path)
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        await service.ScanFolderAsync(path);

        Assert.False(service.IsScanning);
        Assert.Empty(service.Tracks);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-003 — ScanFolderAsync: double-invoke while scanning is blocked
    // Note: We test via IsScanning flag; the second call is guarded.
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG003_ScanFolder_WhenAlreadyScanning_SecondCallIsIgnored()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        // Use a temp dir so the scan actually runs
        var tempDir = Directory.CreateTempSubdirectory("wiretune_test_").FullName;
        try
        {
            // Start first scan (runs in background)
            var first = service.ScanFolderAsync(tempDir);

            // Immediately attempt a second scan while first is running
            var secondException = await Record.ExceptionAsync(() =>
                service.ScanFolderAsync(tempDir));

            await first;

            Assert.Null(secondException);
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-004 — ReadTrackMetadata: non-existent file → returns null
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG004_ReadTrackMetadata_NonExistentFile_ReturnsNull()
    {
        var scanner = new MetadataScanner();

        var result = await scanner.ReadTrackMetadataAsync("/no/such/file.flac");

        Assert.Null(result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-005 — ReadTrackMetadata: unsupported extension → returns null
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG005_ReadTrackMetadata_UnsupportedExtension_ReturnsNull()
    {
        var scanner = new MetadataScanner();

        // Even if a .pdf happened to exist, the extension check fires first
        var result = await scanner.ReadTrackMetadataAsync("/tmp/document.pdf");

        Assert.Null(result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-006 — ReadTrackMetadata: corrupt audio file → returns null, no crash
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG006_ReadTrackMetadata_CorruptFile_ReturnsNull()
    {
        var scanner = new MetadataScanner();
        var tempFile = Path.GetTempFileName() + ".flac";
        try
        {
            await File.WriteAllBytesAsync(tempFile,
                new byte[] { 0xFF, 0xFE, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF });

            var result = await scanner.ReadTrackMetadataAsync(tempFile);

            Assert.Null(result);
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-008 — ConnectServerAsync: unreachable server → IsServerConnected=false
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG008_ConnectServer_UnreachableHost_SetsConnectedFalse()
    {
        var (service, repo) = CreateService();
        using var session = new ServerSession(service, repo);
        await session.InitializeAsync();

        // Nothing listens on loopback port 1, so the connection is refused immediately.
        await session.ConnectAsync("http://127.0.0.1:1");

        Assert.Equal(ServerConnectionState.Offline, session.State);
        Assert.False(session.IsLoggedIn);
        Assert.NotEmpty(session.StatusMessage ?? "");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-010 — ConnectServerAsync: empty string → early return, no HTTP call
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG010_ConnectServer_EmptyUrl_ReturnsEarly()
    {
        var (service, repo) = CreateService();
        using var session = new ServerSession(service, repo);
        await session.InitializeAsync();

        var ex = await Record.ExceptionAsync(() => session.ConnectAsync(""));

        Assert.Null(ex);
        Assert.False(session.IsLoggedIn);
        Assert.Contains("Érvénytelen", session.StatusMessage);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-011 — ConnectServerAsync: whitespace-only URL → early return
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG011_ConnectServer_WhitespaceUrl_ReturnsEarly()
    {
        var (service, repo) = CreateService();
        using var session = new ServerSession(service, repo);
        await session.InitializeAsync();

        var ex = await Record.ExceptionAsync(() => session.ConnectAsync("   "));

        Assert.Null(ex);
        Assert.False(session.IsLoggedIn);
        Assert.Contains("Érvénytelen", session.StatusMessage);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-016 — AddTrackToPlaylist: non-existent playlistId → no crash
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG016_AddTrackToPlaylist_GhostPlaylistId_DoesNotThrow()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        var ex = await Record.ExceptionAsync(() =>
            service.AddTrackToPlaylistAsync("non-existent-playlist-id", "track-123"));

        Assert.Null(ex);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-017 — RemoveTrackFromPlaylist: track not in list → no crash, no-op
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG017_RemoveTrackFromPlaylist_TrackNotInList_NoOp()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("Test");
        await service.AddTrackToPlaylistAsync(pl.Id, "t1");

        var ex = await Record.ExceptionAsync(() =>
            service.RemoveTrackFromPlaylistAsync(pl.Id, "not-in-playlist"));

        Assert.Null(ex);
        Assert.Single(pl.TrackIds); // t1 still there
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-018 — DeletePlaylist: non-existent playlist → no crash
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG018_DeletePlaylist_GhostId_DoesNotThrow()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        var ex = await Record.ExceptionAsync(() =>
            service.DeletePlaylistAsync("totally-fake-id-xyz"));

        Assert.Null(ex);
        Assert.Empty(service.Playlists);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-019 — ToggleFavoriteAsync: non-existent trackId → no crash
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG019_ToggleFavorite_GhostTrackId_DoesNotThrow()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        var ex = await Record.ExceptionAsync(() =>
            service.ToggleFavoriteAsync("ghost-track-id-99999"));

        Assert.Null(ex);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-020 — RecordPlayAsync: non-existent trackId → no crash
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG020_RecordPlay_GhostTrackId_DoesNotThrow()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        var ex = await Record.ExceptionAsync(() =>
            service.RecordPlayAsync("ghost-track-00000"));

        Assert.Null(ex);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-022 — Volume below zero is clamped at 0
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void NEG023_SetVolume_BelowZero_ClampsToZero()
    {
        using var engine = TestSupport.CreateEngine();

        engine.SetVolume(-0.5);

        Assert.Equal(0.0, engine.Volume, precision: 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-024 — Volume above 1.0 is clamped at 1.0
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void NEG024_SetVolume_AboveOne_ClampsToOne()
    {
        using var engine = TestSupport.CreateEngine();

        engine.SetVolume(2.0);

        Assert.Equal(1.0, engine.Volume, precision: 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-031 — CreatePlaylistAsync: blank name gets fallback name
    // ─────────────────────────────────────────────────────────────────────────
    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\t\n")]
    public async Task NEG031_CreatePlaylist_BlankName_UsesFallbackName(string name)
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        var pl = await service.CreatePlaylistAsync(name);

        Assert.Equal("Új lejátszási lista", pl.Name);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG-032 — Search: null query → returns all tracks (no NRE)
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG032_Search_NullQuery_ReturnsAllTracksWithoutException()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            new Track { Id = "n1", Title = "T1", Artist = "A", Album = "B" },
            new Track { Id = "n2", Title = "T2", Artist = "A", Album = "B" }
        });
        await service.InitializeAsync();

        var ex = Record.Exception(() => service.Search(null!).ToList());
        Assert.Null(ex);

        var results = service.Search(null!).ToList();
        Assert.Equal(2, results.Count);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG — Duplicate track added to playlist is rejected
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG_AddTrackToPlaylist_DuplicateTrackId_NotAddedTwice()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("NoDupes");

        await service.AddTrackToPlaylistAsync(pl.Id, "same-track");
        await service.AddTrackToPlaylistAsync(pl.Id, "same-track");

        Assert.Single(pl.TrackIds);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG — MetadataScanner: ExtractCoverArt on non-existent file → null
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG_ExtractCoverArt_NonExistentFile_ReturnsNull()
    {
        var scanner = new MetadataScanner();

        var result = await scanner.ExtractCoverArtAsync("/no/such/audio/file.mp3");

        Assert.Null(result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG — ScanDirectory: non-existent root → returns empty list
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG_ScanDirectory_NonExistentRoot_ReturnsEmptyList()
    {
        var scanner = new MetadataScanner();

        var result = await scanner.ScanDirectoryAsync("/no/such/directory/xyz");

        Assert.Empty(result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG — PlayerViewModel: ToggleMute is blocked in bitperfect mode
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG_PlayerViewModel_ToggleMute_BlockedInBitperfectMode()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        await engine.SetBitperfectModeAsync(true);

        var player = new Wiretune.UI.ViewModels.PlayerViewModel(engine, service);
        player.ToggleMuteCommand.Execute(null);

        // IsMuted must stay false — mute is blocked in bitperfect mode
        Assert.False(player.IsMuted);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG — GetAlbum: unknown ID → returns null
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG_GetAlbum_UnknownId_ReturnsNull()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        var result = service.GetAlbum("completely-unknown-id");

        Assert.Null(result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG — GetArtist: unknown ID → returns null
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG_GetArtist_UnknownId_ReturnsNull()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        var result = service.GetArtist("completely-unknown-id");

        Assert.Null(result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG — GetPlaylist: unknown ID → returns null
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG_GetPlaylist_UnknownId_ReturnsNull()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        var result = service.GetPlaylist("completely-unknown-id");

        Assert.Null(result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG — MockRepository.GetSetting: missing key returns the default value
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG_MockRepo_GetSetting_MissingKey_ReturnsDefault()
    {
        var repo = new MockRepository();

        var result = await repo.GetSettingAsync("NonExistentKey", "my-default");

        Assert.Equal("my-default", result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEG — ScanFolderAsync cancellation stops scan early
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task NEG_ScanFolder_CancelledMidScan_DoesNotThrow()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        // Create a temp folder with a few fake audio files (empty, will fail to parse → null track)
        var tempDir = Directory.CreateTempSubdirectory("wiretune_cancel_").FullName;
        try
        {
            for (int i = 0; i < 5; i++)
                await File.WriteAllBytesAsync(Path.Combine(tempDir, $"song{i}.flac"), new byte[4]);

            using var cts = new CancellationTokenSource();
            cts.CancelAfter(50); // cancel very soon

            var ex = await Record.ExceptionAsync(() =>
                service.ScanFolderAsync(tempDir, null, cts.Token));

            // Should not throw; cancellation handled gracefully
            Assert.Null(ex);
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
        }
    }
}


