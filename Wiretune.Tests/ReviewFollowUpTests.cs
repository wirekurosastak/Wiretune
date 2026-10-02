using System.Diagnostics;
using System.Reflection;
using Microsoft.Data.Sqlite;
using Wiretune.Core.Audio.Drivers;
using Wiretune.Core.Data;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;
using Xunit;

namespace Wiretune.Tests;

/// <summary>Regression tests for the production-readiness review: the small fixes and the documented limits.</summary>
public class ReviewFollowUpTests
{
    // ── Artists ──

    [Fact]
    public async Task ShuffleArtist_TurnsShuffleOn_LikeEveryOtherShuffleCommand()
    {
        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner(), Path.Combine(Path.GetTempPath(), "wiretune-test-covers"));
        await repo.SaveTracksBatchAsync(new[]
        {
            TestSupport.MakeTrack("1", "One", artist: "Solo", album: "A", trackNumber: 1),
            TestSupport.MakeTrack("2", "Two", artist: "Solo", album: "A", trackNumber: 2)
        });
        await library.InitializeAsync();

        var player = new PlayerViewModel(TestSupport.CreateEngine(), library);
        var artists = new ArtistsViewModel(library, player);
        Assert.False(player.IsShuffle);

        artists.ShuffleArtist(library.GetArtistByName("Solo"));

        Assert.True(player.IsShuffle);
        Assert.Equal(2, player.QueueTracks.Count);
    }

    [Fact]
    public void TappingARowOfThePhonesQueue_JumpsToThatEntry()
    {
        var library = new LibraryService(new MockRepository(), new MetadataScanner());
        var player = new PlayerViewModel(TestSupport.CreateEngine(), library);
        var tracks = Enumerable.Range(1, 4).Select(i => TestSupport.MakeTrack($"t{i}", $"Song {i}")).ToArray();
        player.PlayQueue(tracks, tracks[0]);

        // The rows of the queue hand the command their own entry, not the track inside it.
        player.PlayQueueTrack(player.QueueItems[2]);

        Assert.Equal(2, player.CurrentQueueIndex);
    }

    // ── Album artist inference ──

    private static Track InDirectory(string id, string artist, int number)
    {
        var track = TestSupport.MakeTrack(id, $"Song {id}", artist: artist, album: "Mix", trackNumber: number);
        track.FilePath = $"/music/mix/{id}.flac";
        return track;
    }

    [Fact]
    public async Task InferredAlbumArtist_IsShownButNeverStored_SoItCannotOutliveTheFilesItCameFrom()
    {
        var dir = Directory.CreateTempSubdirectory("wiretune_aa_").FullName;
        try
        {
            var repo = new LibraryRepository(new DatabaseManager(Path.Combine(dir, "wiretune.db")));
            await repo.InitializeAsync();
            var library = new LibraryService(repo, new MetadataScanner(), Path.Combine(dir, "covers"));
            await library.InitializeAsync();

            // Two artists in one folder and no album-artist tag: the library presents them as one album.
            await library.ReplaceTracksAsync(new[] { InDirectory("a", "Artist X", 1), InDirectory("b", "Artist Y", 2) });
            Assert.All(library.Tracks, t =>
            {
                Assert.Equal("Various Artists", t.AlbumArtist);
                Assert.True(t.AlbumArtistInferred);
            });

            // The database keeps only what the files' tags say.
            Assert.All(await repo.GetAllTracksAsync(), t => Assert.Null(t.AlbumArtist));

            // One file disappears: what was inferred from the pair must not stay on the one that is left.
            await library.ReplaceTracksAsync(library.Tracks.Where(t => t.Id == "a").ToList());
            var left = library.GetTrack("a")!;
            Assert.Null(left.AlbumArtist);
            Assert.False(left.AlbumArtistInferred);
            Assert.Null((await repo.GetAllTracksAsync()).Single().AlbumArtist);
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            try { Directory.Delete(dir, recursive: true); } catch { }
        }
    }

    [Fact]
    public async Task ATaggedAlbumArtist_IsStored_AndStaysWhatTheTagSays()
    {
        var dir = Directory.CreateTempSubdirectory("wiretune_aa_").FullName;
        try
        {
            var repo = new LibraryRepository(new DatabaseManager(Path.Combine(dir, "wiretune.db")));
            await repo.InitializeAsync();
            var library = new LibraryService(repo, new MetadataScanner(), Path.Combine(dir, "covers"));
            await library.InitializeAsync();

            var tagged = InDirectory("a", "Artist X", 1);
            tagged.AlbumArtist = "The Band";
            await library.ReplaceTracksAsync(new[] { tagged, InDirectory("b", "Artist Y", 2) });

            Assert.False(library.GetTrack("a")!.AlbumArtistInferred);
            Assert.True(library.GetTrack("b")!.AlbumArtistInferred); // takes the album's tagged value
            Assert.Equal("The Band", library.GetTrack("b")!.AlbumArtist);

            var stored = (await repo.GetAllTracksAsync()).ToDictionary(t => t.Id);
            Assert.Equal("The Band", stored["a"].AlbumArtist);
            Assert.Null(stored["b"].AlbumArtist);
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            try { Directory.Delete(dir, recursive: true); } catch { }
        }
    }

    // ── Handing a device's old data to the server ──

    [Fact]
    public async Task WhatIsHandedOverToTheServer_ObeysItsRules_SoOneBadPlaylistCannotBlockTheRest()
    {
        var library = new LibraryService(new MockRepository(), new MetadataScanner(), Path.Combine(Path.GetTempPath(), "wiretune-test-covers"));
        await library.InitializeAsync();
        var remote = TestSupport.MakeTrack("s1", "Server song");
        remote.StreamUrl = "http://wiretune.test/api/stream/s1";
        await library.ReplaceTracksAsync(new[] { remote });
        await library.ToggleFavoriteAsync("s1");

        var lengthy = await library.CreatePlaylistAsync(new string('x', 500), new string('y', 5000));
        await library.AddTrackToPlaylistAsync(lengthy.Id, "s1");

        var data = library.CollectServerTrackUserData();

        Assert.NotNull(data);
        Assert.Equal(new[] { "s1" }, data!.Favorites);
        var sent = Assert.Single(data.Playlists);
        Assert.Equal(UserDataRules.MaxPlaylistNameLength, sent.Name.Length);
        Assert.Equal(UserDataRules.MaxPlaylistDescriptionLength, sent.Description!.Length);
        Assert.Null(Wiretune.Server.UserDataService.ValidateImport(data));
    }

    // ── Covers ──

    private sealed class ListingHandler(string json) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK)
            {
                Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json")
            });
    }

    [Fact]
    public async Task ServerTracks_OfOneAlbum_ShareOneCoverUrl_SoItIsDownloadedOnce()
    {
        Track WithCover(string id, string album, bool hasCover = true)
        {
            var track = TestSupport.MakeTrack(id, $"Song {id}", artist: "Artist", album: album);
            track.HasCoverArt = hasCover;
            return track;
        }

        var listing = new List<Track> { WithCover("1", "Album A"), WithCover("2", "Album A"), WithCover("3", "Album B"), WithCover("4", "Album C", hasCover: false) };
        var json = System.Text.Json.JsonSerializer.Serialize(listing, WiretuneServerFixture.Json);
        using var client = new ServerStreamingClient(new HttpClient(new ListingHandler(json)));

        var tracks = await client.FetchTracksAsync("http://wiretune.test/");

        var albumA = $"http://wiretune.test/api/cover/album/{tracks[0].AlbumId}";
        Assert.Equal(albumA, tracks[0].CoverArtPath);
        Assert.Equal(albumA, tracks[1].CoverArtPath);
        Assert.NotEqual(albumA, tracks[2].CoverArtPath);
        Assert.StartsWith("http://wiretune.test/api/cover/album/", tracks[2].CoverArtPath);
        Assert.Null(tracks[3].CoverArtPath);
        Assert.All(tracks, t => Assert.DoesNotContain("token", t.StreamUrl));
    }

    [Fact]
    public void AlbumId_IgnoresCase_AndFollowsTheAlbumArtist()
    {
        var a = TestSupport.MakeTrack("1", "One", artist: "Artist X", album: "Mix", albumArtist: "Various Artists");
        var b = TestSupport.MakeTrack("2", "Two", artist: "Artist Y", album: "MIX", albumArtist: "various artists");
        var other = TestSupport.MakeTrack("3", "Three", artist: "Artist X", album: "Mix");

        Assert.Equal(a.AlbumId, b.AlbumId);
        Assert.NotEqual(a.AlbumId, other.AlbumId);
    }

    // ── Track identity (documented limits) ──

    [Fact]
    public void TrackIds_AreDerivedFromTheLowerCasedPath_SoPathsDifferingOnlyInCaseShareOne()
    {
        // Documented in docs/server.md: on a case-sensitive file system A.flac and a.flac in one folder collide.
        var folder = Path.Combine(Path.GetTempPath(), "wiretune_ids");
        Assert.Equal(
            MetadataScanner.ComputeTrackId(Path.Combine(folder, "A.flac")),
            MetadataScanner.ComputeTrackId(Path.Combine(folder, "a.flac")));
    }

    [Fact]
    public void TrackIds_ChangeWhenAFileMoves_SoFavoritesOfAMovedLibraryStartOver()
    {
        // Documented in docs/server.md: moving the music folder gives every track a new ID.
        var before = MetadataScanner.ComputeTrackId(Path.Combine(Path.GetTempPath(), "music_old", "song.flac"));
        var after = MetadataScanner.ComputeTrackId(Path.Combine(Path.GetTempPath(), "music_new", "song.flac"));
        Assert.NotEqual(before, after);
    }

    // ── Audio driver ──

    [Fact]
    public async Task DriverCommands_ReturnAtOnce_EvenWhileTheDriverIsBusy_AndRunAfterwards()
    {
        using var driver = new FfmpegAudioDriver();
        var stateLock = typeof(FfmpegAudioDriver).GetField("_stateLock", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(driver)!;

        // Another thread holds the driver's state, as it does while it starts or kills a child process.
        var held = new ManualResetEventSlim();
        var release = new ManualResetEventSlim();
        var holder = Task.Run(() =>
        {
            lock (stateLock)
            {
                held.Set();
                release.Wait();
            }
        });
        Assert.True(held.Wait(TimeSpan.FromSeconds(5)));

        var clock = Stopwatch.StartNew();
        var pending = driver.PauseAsync();
        clock.Stop();

        // The caller (the UI thread in the app) is not made to wait for the state it cannot get.
        Assert.True(clock.ElapsedMilliseconds < 1000, $"PauseAsync blocked its caller for {clock.ElapsedMilliseconds} ms.");
        Assert.False(pending.IsCompleted);

        release.Set();
        await pending.WaitAsync(TimeSpan.FromSeconds(10));
        await holder;
    }

    [Fact]
    public async Task DriverCommands_OnAnIdleDriver_AllCompleteWithoutThrowing()
    {
        using var driver = new FfmpegAudioDriver();

        // Nothing is playing, so pause and resume do nothing and stop changes nothing; commands queue up and finish.
        await Task.WhenAll(driver.PauseAsync(), driver.ResumeAsync(), driver.SeekAsync(TimeSpan.FromSeconds(3)), driver.StopAsync())
            .WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(PlaybackState.Stopped, driver.State);
    }

    // ── Output of the player process ──

    [Theory]
    [InlineData("\u001b[0m")]
    [InlineData("\u001b[K\r")]
    [InlineData("\u001b[2K\u001b[0m\r")]
    [InlineData("\0")]
    public void ALineOfOnlyControlCharacters_IsNotAnErrorMessage(string line)
    {
        // ffplay can exit cleanly after such a line; it must not turn a short track into a failed one.
        Assert.Equal(string.Empty, FfmpegAudioDriver.ReadableText(line));
    }

    [Fact]
    public void ALineOfText_KeepsItsWords_WithoutTheEscapeCodesAroundThem()
    {
        Assert.Equal(
            "Error opening input: No such file",
            FfmpegAudioDriver.ReadableText("\u001b[31mError opening input: No such file\u001b[0m\r"));
    }
}
