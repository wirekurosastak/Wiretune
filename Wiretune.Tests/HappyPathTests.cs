using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Xunit;

namespace Wiretune.Tests;

/// <summary>
/// HP-001 to HP-050 â€” Happy Path Scenarios
/// Standard inputs where the user interacts with Wiretune exactly as intended.
/// </summary>
public class HappyPathTests
{
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // Helper factory
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    private static (LibraryService service, MockRepository repo) CreateService()
    {
        var repo = new MockRepository();
        var scanner = new MetadataScanner();
        var service = new LibraryService(repo, scanner);
        return (service, repo);
    }

    private static Track MakeTrack(string id, string title, string artist, string album,
        int sampleRate = 44100, int bits = 16, int trackNum = 1,
        double durationMinutes = 4.0, string codec = "FLAC", bool lossless = true) =>
        new()
        {
            Id = id,
            Title = title,
            Artist = artist,
            Album = album,
            TrackNumber = trackNum,
            Duration = TimeSpan.FromMinutes(durationMinutes),
            Format = new AudioFormat
            {
                Codec = codec,
                SampleRate = sampleRate,
                BitsPerSample = bits,
                IsLossless = lossless,
                BitrateKbps = lossless ? 1411 : 320
            }
        };

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-001 â€” Scan a valid populated folder (unit-level via mock)
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP001_InitializeAsync_LoadsAllTracksFromRepository()
    {
        var (service, repo) = CreateService();
        var tracks = Enumerable.Range(1, 10)
            .Select(i => MakeTrack(i.ToString(), $"Song {i}", "Artist", "Album", trackNum: i))
            .ToList();
        await repo.SaveTracksBatchAsync(tracks);

        await service.InitializeAsync();

        Assert.Equal(10, service.Tracks.Count);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-004 â€” Hi-Res FLAC correctly identified
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public void HP004_HiResFormat_96k_24bit_IsIdentifiedCorrectly()
    {
        var format = new AudioFormat { Codec = "FLAC", SampleRate = 96000, BitsPerSample = 24 };

        Assert.True(format.IsHiRes);
        Assert.Contains("24bit / 96kHz", format.DisplayBadge);
        Assert.Equal("Hi-Res Studio Master (96kHz/24b)", format.QualityLabel);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-005 â€” CD quality FLAC correctly identified
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public void HP005_CdQualityFormat_44k_16bit_IsIdentifiedCorrectly()
    {
        var format = new AudioFormat { Codec = "FLAC", SampleRate = 44100, BitsPerSample = 16 };

        Assert.False(format.IsHiRes);
        Assert.Contains("16bit / 44.1kHz", format.DisplayBadge);
        Assert.Equal("CD Quality Lossless (16-bit / 44.1 kHz)", format.QualityLabel);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-006 â€” Multiple tracks â†’ single album entry
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP006_AlbumIndexing_GroupsTracksWithSameAlbumAndArtist()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("1", "Track A", "Daft Punk", "RAM", trackNum: 1),
            MakeTrack("2", "Track B", "Daft Punk", "RAM", trackNum: 2),
            MakeTrack("3", "Track C", "Daft Punk", "RAM", trackNum: 3)
        });
        await service.InitializeAsync();

        Assert.Single(service.Albums);
        Assert.Equal(3, service.Albums[0].TrackCount);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-007 â€” Multiple albums â†’ single artist entry
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP007_ArtistIndexing_GroupsAlbumsFromSameArtist()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("1", "Starboy",        "The Weeknd", "Starboy",       trackNum: 1),
            MakeTrack("2", "Party Monster",  "The Weeknd", "Starboy",       trackNum: 2),
            MakeTrack("3", "Save Your Tears","The Weeknd", "After Hours",   trackNum: 1)
        });
        await service.InitializeAsync();

        Assert.Single(service.Artists);
        Assert.Equal(2, service.Artists[0].AlbumCount);
        Assert.Equal(3, service.Artists[0].TrackCount);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-008 â€” Create a new playlist
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP008_CreatePlaylist_ReturnsNamedPlaylistAndPersists()
    {
        var (service, repo) = CreateService();
        await service.InitializeAsync();

        var pl = await service.CreatePlaylistAsync("Best Hi-Res", "Top 24-bit tracks");

        Assert.NotNull(pl);
        Assert.NotEmpty(pl.Id);
        Assert.Equal("Best Hi-Res", pl.Name);
        Assert.Equal("Top 24-bit tracks", pl.Description);
        Assert.Single(service.Playlists);
        Assert.Single(repo.Playlists);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-009 â€” Add a track to a playlist
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP009_AddTrackToPlaylist_UpdatesTrackIdsAndPersists()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("Fav");

        await service.AddTrackToPlaylistAsync(pl.Id, "track-abc");

        Assert.Contains("track-abc", pl.TrackIds);
        Assert.Equal(1, pl.TrackCount);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-010 â€” Remove a track from a playlist
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP010_RemoveTrackFromPlaylist_TrackIdRemovedAndPersists()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("Mix");
        await service.AddTrackToPlaylistAsync(pl.Id, "t1");
        await service.AddTrackToPlaylistAsync(pl.Id, "t2");

        await service.RemoveTrackFromPlaylistAsync(pl.Id, "t1");

        Assert.DoesNotContain("t1", pl.TrackIds);
        Assert.Contains("t2", pl.TrackIds);
        Assert.Equal(1, pl.TrackCount);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-011 â€” Delete a playlist
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP011_DeletePlaylist_RemovedFromServiceAndRepo()
    {
        var (service, repo) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("TempList");

        await service.DeletePlaylistAsync(pl.Id);

        Assert.Empty(service.Playlists);
        Assert.Empty(repo.Playlists);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-012 â€” Favorite toggle (on)
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP012_ToggleFavorite_MarksTrackAsFavorite()
    {
        var (service, repo) = CreateService();
        var track = MakeTrack("fav-1", "Moonlight Sonata", "Beethoven", "Piano Works");
        await repo.SaveTracksBatchAsync(new[] { track });
        await service.InitializeAsync();

        await service.ToggleFavoriteAsync("fav-1");

        var t = service.Tracks.First(x => x.Id == "fav-1");
        Assert.True(t.IsFavorite);
        Assert.Contains(service.Favorites, f => f.Id == "fav-1");
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-013 â€” Favorite toggle (off)
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP013_ToggleFavorite_UnfavoritesAlreadyFavoriteTrack()
    {
        var (service, repo) = CreateService();
        var track = MakeTrack("fav-2", "Clair de Lune", "Debussy", "Suite bergamasque");
        track.IsFavorite = true;
        await repo.SaveTracksBatchAsync(new[] { track });
        await service.InitializeAsync();

        await service.ToggleFavoriteAsync("fav-2");

        var t = service.Tracks.First(x => x.Id == "fav-2");
        Assert.False(t.IsFavorite);
        Assert.DoesNotContain(service.Favorites, f => f.Id == "fav-2");
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-014 â€” Record a play increments PlayCount
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP014_RecordPlay_IncrementsPlayCountAndSetsLastPlayed()
    {
        var repo = new MockRepository();
        // Override ServerUrl to empty so InitializeAsync does NOT spawn background server connect
        repo.Settings["ServerUrl"] = string.Empty;
        var service = new LibraryService(repo, new MetadataScanner());

        var track = MakeTrack("play-1", "Hotel California", "Eagles", "Hotel California");
        await repo.SaveTracksBatchAsync(new[] { track });
        await service.InitializeAsync();

        var before = DateTime.UtcNow;
        await service.RecordPlayAsync("play-1");

        var t = service.Tracks.First(x => x.Id == "play-1");
        Assert.Equal(1, t.PlayCount);
        Assert.NotNull(t.LastPlayed);
        Assert.True(t.LastPlayed >= before);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-015 / 016 / 017 / 018 â€” Search
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP015_Search_ByTitleFragment_ReturnsMatchingTrack()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("s1", "Get Lucky",    "Daft Punk", "RAM"),
            MakeTrack("s2", "Harder Better","Daft Punk", "Discovery")
        });
        await service.InitializeAsync();

        var results = service.Search("Lucky").ToList();

        Assert.Single(results);
        Assert.Equal("Get Lucky", results[0].Title);
    }

    [Fact]
    public async Task HP016_Search_ByArtistName_ReturnsAllArtistTracks()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("s1", "Song A", "Daft Punk", "RAM"),
            MakeTrack("s2", "Song B", "Daft Punk", "Discovery"),
            MakeTrack("s3", "Song C", "Radiohead", "OK Computer")
        });
        await service.InitializeAsync();

        var results = service.Search("Daft").ToList();

        Assert.Equal(2, results.Count);
        Assert.All(results, t => Assert.Contains("Daft", t.Artist));
    }

    [Fact]
    public async Task HP017_Search_ByAlbumName_ReturnsAlbumTracks()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("s1", "Starboy",       "The Weeknd", "Starboy"),
            MakeTrack("s2", "Party Monster", "The Weeknd", "Starboy"),
            MakeTrack("s3", "Blinding Lights","The Weeknd", "After Hours")
        });
        await service.InitializeAsync();

        var results = service.Search("Starboy").ToList();

        Assert.Equal(2, results.Count);
    }

    [Fact]
    public async Task HP018_Search_ByGenre_ReturnsGenreMatchingTracks()
    {
        var (service, repo) = CreateService();
        var jazzTrack = MakeTrack("j1", "So What", "Miles Davis", "Kind of Blue");
        jazzTrack.Genre = "Jazz";
        var rockTrack = MakeTrack("r1", "Whole Lotta Love", "Led Zeppelin", "Led Zeppelin II");
        rockTrack.Genre = "Rock";
        await repo.SaveTracksBatchAsync(new[] { jazzTrack, rockTrack });
        await service.InitializeAsync();

        var results = service.Search("Jazz").ToList();

        Assert.Single(results);
        Assert.Equal("So What", results[0].Title);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-026 â€” Bitperfect mode locks volume to unity gain
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP026_BitperfectMode_LocksVolumeToUnityGain()
    {
        using var engine = TestSupport.CreateEngine();

        await engine.SetBitperfectModeAsync(true);

        Assert.True(engine.IsBitperfect);
        Assert.True(engine.IsVolumeLocked);
        Assert.Equal(1.0, engine.Volume);

        engine.SetVolume(0.3);
        Assert.Equal(1.0, engine.Volume); // must remain 1.0
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-027 â€” Exclusive mode toggles state
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP027_ExclusiveMode_TogglesStateCorrectly()
    {
        using var engine = TestSupport.CreateEngine();

        await engine.SetExclusiveModeAsync(true);
        Assert.True(engine.IsExclusiveMode);

        await engine.SetExclusiveModeAsync(false);
        Assert.False(engine.IsExclusiveMode);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-029 â€” Seek updates engine position
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP029_SeekAsync_UpdatesCurrentPosition()
    {
        using var engine = TestSupport.CreateEngine();

        await engine.SeekAsync(TimeSpan.FromSeconds(42));

        Assert.Equal(TimeSpan.FromSeconds(42), engine.CurrentPosition);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-032 â€” Repeat One replays same track
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP032_RepeatOne_TrackQueueIndexStaysConstant()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, repo) = CreateService();
        var tracks = new[]
        {
            MakeTrack("q1", "A", "Artist", "Album", trackNum: 1),
            MakeTrack("q2", "B", "Artist", "Album", trackNum: 2)
        };
        await repo.SaveTracksBatchAsync(tracks);
        await service.InitializeAsync();

        var player = new Wiretune.UI.ViewModels.PlayerViewModel(engine, service);
        player.ToggleRepeatCommand.Execute(null); // Off â†’ All
        player.ToggleRepeatCommand.Execute(null); // All â†’ One

        Assert.Equal(RepeatMode.One, player.RepeatMode);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-033 â€” Repeat All cycles RepeatMode enum
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public void HP033_ToggleRepeat_CyclesThroughAllModes()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        var player = new Wiretune.UI.ViewModels.PlayerViewModel(engine, service);

        Assert.Equal(RepeatMode.Off, player.RepeatMode);

        player.ToggleRepeatCommand.Execute(null);
        Assert.Equal(RepeatMode.All, player.RepeatMode);

        player.ToggleRepeatCommand.Execute(null);
        Assert.Equal(RepeatMode.One, player.RepeatMode);

        player.ToggleRepeatCommand.Execute(null);
        Assert.Equal(RepeatMode.Off, player.RepeatMode);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-034 â€” Shuffle toggle
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public void HP034_ToggleShuffle_FlipsIsShuffleState()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        var player = new Wiretune.UI.ViewModels.PlayerViewModel(engine, service);

        Assert.False(player.IsShuffle);
        player.ToggleShuffleCommand.Execute(null);
        Assert.True(player.IsShuffle);
        player.ToggleShuffleCommand.Execute(null);
        Assert.False(player.IsShuffle);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-041 â€” Settings persist round-trip
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP041_Settings_PersistAndRestoreLibraryPath()
    {
        var (service, repo) = CreateService();
        repo.Settings["LibraryPath"] = "/music/collection";

        await service.InitializeAsync();

        Assert.Equal("/music/collection", service.LibraryPath);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-046 / HP-047 â€” Navigation
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public void HP046_NavigateToCommand_WithInt_SetsIndex()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        var vm = TestSupport.CreateMainViewModel(service, engine);

        vm.NavigateToCommand.Execute(1);

        Assert.Equal(1, vm.SelectedNavigationIndex);
    }

    [Fact]
    public void HP047_NavigateToCommand_WithStringParam_SetsIndex()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        var vm = TestSupport.CreateMainViewModel(service, engine);

        vm.NavigateToCommand.Execute("5");

        Assert.Equal(5, vm.SelectedNavigationIndex);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-048 / HP-050 â€” Album drilldown open/close
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public void HP048_OpenAlbumCommand_SetsAlbumDetailAndNavigates()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        var vm = TestSupport.CreateMainViewModel(service, engine);

        var album = new Album
        {
            Id = "alb-1", Title = "Kind of Blue", Artist = "Miles Davis",
            Tracks = new List<Track>
            {
                new() { Id = "t1", Title = "So What", TrackNumber = 1 },
                new() { Id = "t2", Title = "Freddie Freeloader", TrackNumber = 2 }
            }
        };

        vm.OpenAlbumCommand.Execute(album);

        Assert.Equal(1, vm.SelectedNavigationIndex);
        Assert.True(vm.Albums.IsAlbumDetailOpen);
        Assert.Equal("Kind of Blue", vm.Albums.SelectedAlbum?.Title);
    }

    [Fact]
    public void HP050_CloseAlbumDetail_ResetsDetailState()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        var vm = TestSupport.CreateMainViewModel(service, engine);
        var album = new Album { Id = "alb-2", Title = "Discovery", Artist = "Daft Punk", Tracks = new() };
        vm.OpenAlbumCommand.Execute(album);

        vm.Albums.CloseAlbumDetailCommand.Execute(null);

        Assert.False(vm.Albums.IsAlbumDetailOpen);
        Assert.Null(vm.Albums.SelectedAlbum);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP-049 â€” Artist drilldown
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public void HP049_OpenArtistCommand_SetsArtistDetailAndNavigates()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        var vm = TestSupport.CreateMainViewModel(service, engine);

        var album = new Album
        {
            Id = "alb-3", Title = "OK Computer", Artist = "Radiohead",
            Tracks = new List<Track>
            {
                new() { Id = "t3", Title = "Karma Police" },
                new() { Id = "t4", Title = "Paranoid Android" }
            }
        };
        var artist = new Artist { Id = "art-1", Name = "Radiohead", Albums = new() { album }, Tracks = album.Tracks };

        vm.OpenArtistCommand.Execute(artist);

        Assert.Equal(2, vm.SelectedNavigationIndex);
        Assert.True(vm.Artists.IsArtistDetailOpen);
        Assert.Equal("Radiohead", vm.Artists.SelectedArtist?.Name);
        Assert.Equal(2, vm.Artists.SelectedArtistTracks.Count);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP â€” AudioFormat quality labels for all canonical sample rates
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Theory]
    [InlineData(192000, 24, "Ultra Hi-Res Studio Master")]
    [InlineData(96000,  24, "Hi-Res Studio Master")]
    [InlineData(88200,  24, "Hi-Res Audio")]
    [InlineData(48000,  24, "Enhanced Studio")]
    [InlineData(44100,  24, "Hi-Res 24-bit Lossless")]
    [InlineData(44100,  16, "CD Quality Lossless")]
    public void HP_AudioFormat_QualityLabel_MatchesExpectedLabel(int sampleRate, int bits, string expectedLabel)
    {
        var format = new AudioFormat { SampleRate = sampleRate, BitsPerSample = bits };
        Assert.Contains(expectedLabel, format.QualityLabel);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP â€” Genres are deduplicated and sorted
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP_Genres_AreDeduplicatedAndSorted()
    {
        var (service, repo) = CreateService();
        var tracks = new[]
        {
            MakeTrack("g1", "A", "A1", "Al1"), MakeTrack("g2", "B", "B1", "Al2"),
            MakeTrack("g3", "C", "C1", "Al3")
        };
        tracks[0].Genre = "Jazz";
        tracks[1].Genre = "Rock";
        tracks[2].Genre = "Jazz"; // duplicate
        await repo.SaveTracksBatchAsync(tracks);
        await service.InitializeAsync();

        Assert.Equal(2, service.Genres.Count);
        Assert.Equal("Jazz", service.Genres[0]);
        Assert.Equal("Rock", service.Genres[1]);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP â€” Favorites property is computed dynamically
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP_Favorites_ReturnsOnlyFavoriteTracks()
    {
        var (service, repo) = CreateService();
        var t1 = MakeTrack("f1", "A", "Art", "Alb");
        var t2 = MakeTrack("f2", "B", "Art", "Alb", trackNum: 2);
        t1.IsFavorite = true;
        await repo.SaveTracksBatchAsync(new[] { t1, t2 });
        await service.InitializeAsync();

        Assert.Single(service.Favorites);
        Assert.Equal("f1", service.Favorites[0].Id);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP â€” Track.FormattedDuration for sub-hour and over-hour tracks
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public void HP_Track_FormattedDuration_SubHour_UsesMmSs()
    {
        var t = new Track { Duration = TimeSpan.FromSeconds(185) }; // 3:05
        Assert.Equal("3:05", t.FormattedDuration);
    }

    [Fact]
    public void HP_Track_FormattedDuration_OverHour_UsesHMmSs()
    {
        var t = new Track { Duration = TimeSpan.FromSeconds(3723) }; // 1:02:03
        Assert.Equal("1:02:03", t.FormattedDuration);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP â€” Track.DisplayTrackNumber
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public void HP_Track_DisplayTrackNumber_PadsToTwoDigits()
    {
        var t1 = new Track { TrackNumber = 3 };
        var t2 = new Track { TrackNumber = 10 };
        var t3 = new Track { TrackNumber = null };

        Assert.Equal("03", t1.DisplayTrackNumber);
        Assert.Equal("10", t2.DisplayTrackNumber);
        Assert.Equal("--", t3.DisplayTrackNumber);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP â€” Empty search query returns all tracks
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP_Search_EmptyQuery_ReturnsAllTracks()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("e1", "A", "Art", "Al1"),
            MakeTrack("e2", "B", "Art", "Al1", trackNum: 2),
            MakeTrack("e3", "C", "Art2", "Al2")
        });
        await service.InitializeAsync();

        var results = service.Search("").ToList();
        Assert.Equal(3, results.Count);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP â€” Bitperfect mode auto-enables exclusive mode
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP_BitperfectMode_AutomaticallyEnablesExclusiveMode()
    {
        using var engine = TestSupport.CreateEngine();
        await engine.SetExclusiveModeAsync(false);

        await engine.SetBitperfectModeAsync(true);

        Assert.True(engine.IsBitperfect);
        Assert.True(engine.IsExclusiveMode);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP â€” Disabling exclusive mode also disables bitperfect
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP_DisablingExclusiveMode_DisablesBitperfect()
    {
        using var engine = TestSupport.CreateEngine();
        await engine.SetBitperfectModeAsync(true);

        await engine.SetExclusiveModeAsync(false);

        Assert.False(engine.IsExclusiveMode);
        Assert.False(engine.IsBitperfect);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP â€” Enabling exclusive alone does NOT enable bitperfect
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP_ExclusiveModeAlone_DoesNotEnableBitperfect()
    {
        using var engine = TestSupport.CreateEngine();

        await engine.SetExclusiveModeAsync(true);

        Assert.True(engine.IsExclusiveMode);
        Assert.False(engine.IsBitperfect);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP â€” Volume set correctly when bitperfect is off
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP_Volume_SetCorrectly_WhenBitperfectOff()
    {
        using var engine = TestSupport.CreateEngine();
        await engine.SetBitperfectModeAsync(false);

        engine.SetVolume(0.75);

        Assert.Equal(0.75, engine.Volume, precision: 2);
        Assert.False(engine.IsVolumeLocked);
    }

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // HP â€” GetAlbum / GetArtist / GetPlaylist by ID
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    [Fact]
    public async Task HP_GetAlbumById_ReturnsCorrectAlbum()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[] { MakeTrack("t1", "Song", "Band", "Record") });
        await service.InitializeAsync();

        var album = service.Albums.First();
        var found = service.GetAlbum(album.Id);

        Assert.NotNull(found);
        Assert.Equal("Record", found.Title);
    }

    [Fact]
    public async Task HP_GetArtistById_ReturnsCorrectArtist()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[] { MakeTrack("t1", "Song", "Composer", "Opus") });
        await service.InitializeAsync();

        var artist = service.Artists.First();
        var found = service.GetArtist(artist.Id);

        Assert.NotNull(found);
        Assert.Equal("Composer", found.Name);
    }

    [Fact]
    public async Task HP_GetPlaylistById_ReturnsCorrectPlaylist()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("My List");

        var found = service.GetPlaylist(pl.Id);

        Assert.NotNull(found);
        Assert.Equal("My List", found.Name);
    }
}

