using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Xunit;

namespace Wiretune.Tests;

public class HybridLibraryTests
{
    [Fact]
    public void Deduplication_ExactMatch_IsDetectedAsDuplicate()
    {
        var local = new Track
        {
            Id = "loc-1",
            Title = "Hotel California",
            Artist = "Eagles",
            Album = "Hotel California",
            Duration = TimeSpan.FromSeconds(390),
            FilePath = "/music/hotel.flac",
            StreamUrl = null
        };
        var server = new Track
        {
            Id = "srv-1",
            Title = "Hotel California",
            Artist = "Eagles",
            Album = "Hotel California",
            Duration = TimeSpan.FromSeconds(390),
            FilePath = "/server/hotel.flac",
            StreamUrl = "http://localhost:5200/api/stream/srv-1"
        };

        Assert.True(TrackDeduplication.IsDuplicate(local, server));
    }

    [Fact]
    public void Deduplication_RemasteredTitleAndDifferentAlbum_IsDetectedAsDuplicateWithinDurationTolerance()
    {
        var local = new Track
        {
            Id = "loc-1",
            Title = "Hotel California",
            Artist = "Eagles",
            Album = "Their Greatest Hits",
            Duration = TimeSpan.FromSeconds(390.5),
            FilePath = "/music/hotel.mp3",
            StreamUrl = null
        };
        var server = new Track
        {
            Id = "srv-1",
            Title = "Hotel California (2013 Remaster)",
            Artist = "Eagles",
            Album = "Hotel California (Deluxe Edition)",
            Duration = TimeSpan.FromSeconds(391.2),
            FilePath = "/server/hotel.flac",
            StreamUrl = "http://localhost:5200/api/stream/srv-1"
        };

        Assert.True(TrackDeduplication.IsDuplicate(local, server));
    }

    [Fact]
    public void Deduplication_DifferentSongsOrDifferentArtists_NotDetectedAsDuplicate()
    {
        var local = new Track
        {
            Title = "Take It Easy",
            Artist = "Eagles",
            Duration = TimeSpan.FromSeconds(210)
        };
        var server1 = new Track
        {
            Title = "Take It Easy",
            Artist = "Jackson Browne",
            Duration = TimeSpan.FromSeconds(210)
        };
        var server2 = new Track
        {
            Title = "Desperado",
            Artist = "Eagles",
            Duration = TimeSpan.FromSeconds(210)
        };

        Assert.False(TrackDeduplication.IsDuplicate(local, server1));
        Assert.False(TrackDeduplication.IsDuplicate(local, server2));
    }

    [Fact]
    public void Deduplication_LiveVsStudioDifference_NotDetectedAsDuplicate()
    {
        var local = new Track
        {
            Title = "Hotel California",
            Artist = "Eagles",
            Duration = TimeSpan.FromSeconds(390)
        };
        var server = new Track
        {
            Title = "Hotel California (Live)",
            Artist = "Eagles",
            Duration = TimeSpan.FromSeconds(430)
        };

        Assert.False(TrackDeduplication.IsDuplicate(local, server));
    }

    [Fact]
    public void MergeTracks_DuplicateExists_PrefersLocalTrackAndMergesMetadata()
    {
        var local = new Track
        {
            Id = "loc-1",
            Title = "Comfortably Numb",
            Artist = "Pink Floyd",
            Album = "The Wall",
            Duration = TimeSpan.FromSeconds(382),
            FilePath = "/local/numb.mp3",
            StreamUrl = null,
            IsFavorite = false,
            PlayCount = 2
        };
        var server = new Track
        {
            Id = "srv-1",
            Title = "Comfortably Numb",
            Artist = "Pink Floyd",
            Album = "The Wall",
            Duration = TimeSpan.FromSeconds(382),
            FilePath = "/server/numb.flac",
            StreamUrl = "http://localhost:5200/api/stream/srv-1",
            IsFavorite = true,
            PlayCount = 10,
            HasCoverArt = true,
            CoverArtPath = "http://localhost:5200/api/covers/srv-1"
        };

        var merged = TrackDeduplication.MergeTracks(
            new[] { local },
            new[] { server },
            out var aliased);

        // Only the local track remains
        Assert.Single(merged);
        var track = merged[0];
        Assert.Equal("loc-1", track.Id);
        Assert.Equal("/local/numb.mp3", track.FilePath);
        Assert.Null(track.StreamUrl);
        Assert.True(track.IsLocal);

        // Metadata merged from server duplicate
        Assert.True(track.IsFavorite);
        Assert.Equal(10, track.PlayCount);
        Assert.True(track.HasCoverArt);
        Assert.Equal("http://localhost:5200/api/covers/srv-1", track.CoverArtPath);

        // Alias recorded
        Assert.Equal("loc-1", aliased["srv-1"]);
    }

    [Fact]
    public void MergeTracks_NoDuplicates_IncludesAllTracks()
    {
        var local = new Track
        {
            Id = "loc-1",
            Title = "Song A",
            Artist = "Artist 1",
            Duration = TimeSpan.FromSeconds(180),
            FilePath = "/local/a.mp3"
        };
        var server = new Track
        {
            Id = "srv-1",
            Title = "Song B",
            Artist = "Artist 2",
            Duration = TimeSpan.FromSeconds(200),
            StreamUrl = "http://localhost:5200/api/stream/srv-1"
        };

        var merged = TrackDeduplication.MergeTracks(
            new[] { local },
            new[] { server },
            out var aliased);

        Assert.Equal(2, merged.Count);
        Assert.Contains(merged, t => t.Id == "loc-1" && t.IsLocal);
        Assert.Contains(merged, t => t.Id == "srv-1" && !t.IsLocal);
        Assert.Empty(aliased);
    }

    [Fact]
    public async Task LibraryService_MergeServerTracks_PreservesLocalAndPrefersLocalDuplicates()
    {
        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner());
        await library.InitializeAsync();

        // Local track exists first
        var localTrack = new Track
        {
            Id = "loc-1",
            Title = "Hey Jude",
            Artist = "The Beatles",
            Album = "1",
            Duration = TimeSpan.FromSeconds(431),
            FilePath = "/music/hey_jude.flac",
            StreamUrl = null
        };
        await repo.ReplaceAllTracksAsync(new[] { localTrack });
        await library.InitializeAsync();

        // Server tracks incoming: one duplicate ("Hey Jude"), one new ("Let It Be")
        var serverTracks = new[]
        {
            new Track
            {
                Id = "srv-jude",
                Title = "Hey Jude (Remastered 2015)",
                Artist = "The Beatles",
                Album = "1 (Remastered)",
                Duration = TimeSpan.FromSeconds(431),
                StreamUrl = "http://localhost:5200/api/stream/srv-jude",
                IsFavorite = true
            },
            new Track
            {
                Id = "srv-letitbe",
                Title = "Let It Be",
                Artist = "The Beatles",
                Album = "Let It Be",
                Duration = TimeSpan.FromSeconds(243),
                StreamUrl = "http://localhost:5200/api/stream/srv-letitbe"
            }
        };

        await library.MergeServerTracksAsync(serverTracks);

        // Total should be 2 tracks, not 3
        Assert.Equal(2, library.Tracks.Count);

        // Hey Jude should be the local track (no StreamUrl, local FilePath)
        var heyJude = library.Tracks.First(t => t.Title.StartsWith("Hey Jude"));
        Assert.Equal("loc-1", heyJude.Id);
        Assert.Equal("/music/hey_jude.flac", heyJude.FilePath);
        Assert.Null(heyJude.StreamUrl);
        Assert.True(heyJude.IsLocal);
        Assert.True(heyJude.IsFavorite); // merged from server

        // Let It Be should be from server
        var letItBe = library.Tracks.First(t => t.Title == "Let It Be");
        Assert.Equal("srv-letitbe", letItBe.Id);
        Assert.False(letItBe.IsLocal);
    }

    [Fact]
    public async Task LibraryService_Deduplication_UpdatesPlaylistReferencesToLocalTrack()
    {
        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner());
        await repo.SavePlaylistAsync(new Playlist
        {
            Id = "pl-1",
            Name = "Favorites",
            TrackIds = new List<string> { "srv-jude" }
        });
        await library.InitializeAsync();

        // Local track exists
        var localTrack = new Track
        {
            Id = "loc-jude",
            Title = "Hey Jude",
            Artist = "The Beatles",
            Duration = TimeSpan.FromSeconds(431),
            FilePath = "/music/hey_jude.flac"
        };
        await repo.ReplaceAllTracksAsync(new[] { localTrack });
        await library.InitializeAsync();

        // Merge incoming server track that matches local
        var serverTracks = new[]
        {
            new Track
            {
                Id = "srv-jude",
                Title = "Hey Jude",
                Artist = "The Beatles",
                Duration = TimeSpan.FromSeconds(431),
                StreamUrl = "http://localhost:5200/api/stream/srv-jude"
            }
        };

        await library.MergeServerTracksAsync(serverTracks);

        // The playlist's track ID should now reference loc-jude instead of srv-jude
        var pl = library.GetPlaylist("pl-1");
        Assert.NotNull(pl);
        Assert.Equal("loc-jude", pl!.TrackIds[0]);

        var plTracks = library.GetPlaylistTracks(pl);
        Assert.Single(plTracks);
        Assert.Equal("loc-jude", plTracks[0].Id);
    }

    [Fact]
    public async Task ServerSession_HybridTransitionsAndLogout()
    {
        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner());
        await library.InitializeAsync();

        using var session = new ServerSession(library, repo);
        await session.InitializeAsync();
        Assert.Equal(LibrarySource.None, session.Source);

        // 1. Local files added -> LibrarySource.Local
        var localTrack = new Track
        {
            Id = "loc-1",
            Title = "Local Song",
            Artist = "Local Artist",
            FilePath = "/local/path.flac"
        };
        await repo.ReplaceAllTracksAsync(new[] { localTrack });
        await library.InitializeAsync();
        await session.UseLocalLibraryAsync();
        Assert.Equal(LibrarySource.Local, session.Source);

        // 2. Server tracks merged -> LibrarySource.Hybrid
        var serverTrack = new Track
        {
            Id = "srv-1",
            Title = "Server Song",
            Artist = "Server Artist",
            StreamUrl = "http://server/api/stream/srv-1"
        };
        await library.MergeServerTracksAsync(new[] { serverTrack });
        await session.UseLocalLibraryAsync();
        Assert.Equal(LibrarySource.Hybrid, session.Source);
        Assert.Equal(2, library.Tracks.Count);

        // 3. Logout -> server tracks removed, local tracks remain, LibrarySource falls back to Local
        await session.LogoutAsync();
        Assert.Equal(LibrarySource.Local, session.Source);
        Assert.Single(library.Tracks);
        Assert.Equal("loc-1", library.Tracks[0].Id);
    }
}
