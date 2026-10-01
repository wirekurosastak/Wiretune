using System.Net;
using System.Net.Http.Json;
using System.Text;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;
using Xunit;

namespace Wiretune.Tests;

public sealed class LyricsAndQueueTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("wiretune_lyrics_").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }

    private static void WriteLyricsTag(string path, string lyrics)
    {
        using var file = TagLib.File.Create(path);
        var tag = file.GetTag(TagLib.TagTypes.Id3v2, create: true);
        tag.Lyrics = lyrics;
        file.Save();
    }

    private string CreateWav(string name, string? lyrics)
    {
        var path = Path.Combine(_dir, name);
        WavFile.Write(path, 44100, seconds: 0.2);
        if (lyrics != null) WriteLyricsTag(path, lyrics);
        return path;
    }

    // ── Reading lyrics ───────────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task ReadLyrics_ReturnsTheTaggedText_TrimmedAndCapped()
    {
        var path = CreateWav("song.wav", "  Line one\nLine two \n");

        Assert.Equal("Line one\nLine two", await MetadataScanner.ReadLyricsAsync(path));
    }

    [Fact]
    public async Task ReadLyrics_IsNullWithoutATag_ForAMissingFile_AndForGarbage()
    {
        Assert.Null(await MetadataScanner.ReadLyricsAsync(CreateWav("plain.wav", lyrics: null)));
        Assert.Null(await MetadataScanner.ReadLyricsAsync(Path.Combine(_dir, "missing.wav")));

        var garbage = Path.Combine(_dir, "garbage.flac");
        await File.WriteAllBytesAsync(garbage, new byte[] { 1, 2, 3, 4 });
        Assert.Null(await MetadataScanner.ReadLyricsAsync(garbage));
    }

    [Fact]
    public async Task ReadLyrics_HonoursCancellation()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => MetadataScanner.ReadLyricsAsync(CreateWav("c.wav", "x"), cts.Token));
    }

    // ── The server endpoint and the client that calls it ─────────────────────────────────────────

    [Fact]
    public async Task Server_ServesLyricsOfATrack_AndAnswers404WhenThereAreNone()
    {
        using var server = new WiretuneServerFixture();
        WriteLyricsTag(Path.Combine(server.LibraryPath, "Artist A", "Album 1", "01 First.wav"), "Sing along");

        var anonymous = server.CreateClient();
        var setup = await anonymous.PostAsJsonAsync("/api/auth/setup", new RegisterRequest("owner", "correct-horse-battery"));
        var auth = (await setup.Content.ReadFromJsonAsync<AuthResponse>(WiretuneServerFixture.Json))!;
        var client = server.CreateClient();
        client.DefaultRequestHeaders.Authorization = new("Bearer", auth.Token);

        var tracks = await server.WaitForTracksAsync(client, 3);
        var tagged = tracks.Single(t => t.FilePath.EndsWith("01 First.wav", StringComparison.Ordinal));
        var untagged = tracks.First(t => t.Id != tagged.Id);

        Assert.Equal(HttpStatusCode.Unauthorized, (await anonymous.GetAsync($"/api/lyrics/{tagged.Id}")).StatusCode);

        var ok = await client.GetFromJsonAsync<Dictionary<string, string>>($"/api/lyrics/{tagged.Id}", WiretuneServerFixture.Json);
        Assert.Equal("Sing along", ok!["lyrics"]);

        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync($"/api/lyrics/{untagged.Id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/api/lyrics/no-such-track")).StatusCode);
    }

    private sealed class ScriptedHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(respond(request));
    }

    [Fact]
    public async Task Client_ReturnsTheLyrics_AndNullForNotFoundOrAnOlderServer()
    {
        using var found = new ServerStreamingClient(new HttpClient(new ScriptedHandler(request =>
        {
            Assert.Equal("/api/lyrics/a%2Fb", request.RequestUri!.AbsolutePath, ignoreCase: true);
            return new(HttpStatusCode.OK) { Content = new StringContent("""{"lyrics":"la la"}""", Encoding.UTF8, "application/json") };
        })));
        Assert.Equal("la la", await found.GetLyricsAsync("http://wiretune.test", "a/b"));

        using var missing = new ServerStreamingClient(new HttpClient(new ScriptedHandler(_ => new(HttpStatusCode.NotFound))));
        Assert.Null(await missing.GetLyricsAsync("http://wiretune.test", "x"));

        using var broken = new ServerStreamingClient(new HttpClient(new ScriptedHandler(_ => new(HttpStatusCode.InternalServerError))));
        await Assert.ThrowsAsync<ServerRequestException>(() => broken.GetLyricsAsync("http://wiretune.test", "x"));
    }

    [Fact]
    public async Task Session_HasNoLyrics_ForLocalTracks_OrWhenSignedOut()
    {
        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner(), Path.Combine(_dir, "covers"));
        await library.InitializeAsync();
        using var session = new ServerSession(library, repo, new ServerStreamingClient(new HttpClient(new ScriptedHandler(_ =>
            throw new InvalidOperationException("no request expected")))));
        await session.InitializeAsync();

        var server = TestSupport.MakeTrack("s1", "Server song");
        server.StreamUrl = "http://wiretune.test/api/stream/s1";

        Assert.Null(await session.GetLyricsAsync(TestSupport.MakeTrack("l1", "Local song")));
        Assert.Null(await session.GetLyricsAsync(server));
    }

    // ── The player shows them, only while the panel is open ──────────────────────────────────────

    private static async Task<bool> WaitUntil(Func<bool> condition)
    {
        for (var i = 0; i < 200 && !condition(); i++) await Task.Delay(10);
        return condition();
    }

    private static PlayerViewModel CreatePlayer(Func<Track, CancellationToken, Task<string?>> provider)
    {
        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner());
        return new PlayerViewModel(TestSupport.CreateEngine(), library) { LyricsProvider = provider };
    }

    [Fact]
    public async Task Player_LoadsLyricsOnlyWhileTheQueuePanelIsOpen_AndForgetsThemWhenTheTrackChanges()
    {
        var requested = new List<string>();
        var player = CreatePlayer((track, _) =>
        {
            requested.Add(track.Id);
            return Task.FromResult<string?>($"Lyrics of {track.Id}");
        });
        var first = TestSupport.MakeTrack("t1", "One");
        var second = TestSupport.MakeTrack("t2", "Two");

        player.CurrentTrack = first;
        await Task.Delay(50);
        Assert.Empty(requested);            // panel closed: nothing is read
        Assert.False(player.HasLyrics);

        player.IsQueueOpen = true;
        Assert.True(await WaitUntil(() => player.CurrentLyrics == "Lyrics of t1"));
        Assert.True(player.HasLyrics);

        player.CurrentTrack = second;       // panel still open: follow the track
        Assert.True(await WaitUntil(() => player.CurrentLyrics == "Lyrics of t2"));

        player.IsQueueOpen = false;
        player.IsQueueOpen = true;          // reopening does not fetch again
        await Task.Delay(50);
        Assert.Equal(new[] { "t1", "t2" }, requested);

        player.CurrentTrack = null;
        Assert.Null(player.CurrentLyrics);
        Assert.False(player.HasLyrics);
    }

    [Fact]
    public async Task Player_IgnoresLyricsThatArriveForATrackThatIsNoLongerPlaying()
    {
        var slow = new TaskCompletionSource<string?>();
        var player = CreatePlayer((track, _) => track.Id == "t1" ? slow.Task : Task.FromResult<string?>("Lyrics of t2"));
        player.IsQueueOpen = true;

        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");
        player.CurrentTrack = TestSupport.MakeTrack("t2", "Two");
        Assert.True(await WaitUntil(() => player.CurrentLyrics == "Lyrics of t2"));

        slow.SetResult("Lyrics of t1 (late)");
        await Task.Delay(50);

        Assert.Equal("Lyrics of t2", player.CurrentLyrics);
    }

    [Fact]
    public async Task Player_SurvivesAFailingLyricsProvider()
    {
        var player = CreatePlayer((_, _) => throw new IOException("disk on fire"));
        player.IsQueueOpen = true;

        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");
        await Task.Delay(50);

        Assert.Null(player.CurrentLyrics);
    }

    // ── Removing tracks from the queue ───────────────────────────────────────────────────────────

    private static (PlayerViewModel Player, Track[] Tracks) CreateQueue(int count = 4, int startAt = 1)
    {
        var library = new LibraryService(new MockRepository(), new MetadataScanner());
        var player = new PlayerViewModel(TestSupport.CreateEngine(), library);
        var tracks = Enumerable.Range(1, count).Select(i => TestSupport.MakeTrack($"t{i}", $"Song {i}")).ToArray();
        player.PlayQueue(tracks, tracks[startAt]);
        return (player, tracks);
    }

    [Fact]
    public void RemovingThePlayingTrack_ContinuesWithTheNextOne_NotTheFirst()
    {
        var (player, tracks) = CreateQueue(startAt: 1);

        player.RemoveQueueTrack(tracks[1]);

        Assert.Equal(new[] { "Song 1", "Song 3", "Song 4" }, player.QueueTracks.Select(t => t.Title));
        Assert.Equal(1, player.CurrentQueueIndex);
        Assert.Equal("Song 3", player.QueueTracks[player.CurrentQueueIndex].Title);
        Assert.True(player.QueueItems[1].IsCurrent);
    }

    [Fact]
    public void RemovingThePlayingTrack_WhenItIsTheLast_EndsThePlaybackInsteadOfRestarting()
    {
        var (player, tracks) = CreateQueue(startAt: 3);

        player.RemoveQueueTrack(tracks[3]);

        Assert.Equal(3, player.QueueTracks.Count);
        Assert.DoesNotContain(player.QueueItems, item => item.IsCurrent);
    }

    [Fact]
    public void RemovingThePlayingTrack_WithRepeatAll_WrapsAroundToTheFirst()
    {
        var (player, tracks) = CreateQueue(startAt: 3);
        player.RepeatMode = RepeatMode.All;

        player.RemoveQueueTrack(tracks[3]);

        Assert.Equal(0, player.CurrentQueueIndex);
    }

    [Fact]
    public void RemovingTheOnlyTrack_EmptiesTheQueue()
    {
        var (player, tracks) = CreateQueue(count: 1, startAt: 0);

        player.RemoveQueueTrack(tracks[0]);

        Assert.Empty(player.QueueTracks);
        Assert.Empty(player.QueueItems);
    }

    [Theory]
    [InlineData(0, 1)]   // a track before the playing one: the index moves down
    [InlineData(3, 2)]   // a track after it: the index stays
    public void RemovingAnotherTrack_KeepsThePlayingTrackCurrent(int removeIndex, int expectedCurrentIndex)
    {
        var (player, tracks) = CreateQueue(startAt: 2);

        player.RemoveQueueTrack(tracks[removeIndex]);

        Assert.Equal(expectedCurrentIndex, player.CurrentQueueIndex);
        Assert.Equal("Song 3", player.QueueTracks[player.CurrentQueueIndex].Title);
    }

    [Fact]
    public void RemovingATrackWhileShuffled_DoesNotBringItBackWhenShuffleIsTurnedOff()
    {
        var (player, tracks) = CreateQueue(startAt: 0);
        player.IsShuffle = true;
        var victim = player.QueueTracks.Last();

        player.RemoveQueueTrack(victim);
        player.IsShuffle = false;

        Assert.DoesNotContain(victim, player.QueueTracks);
        Assert.Equal(tracks.Length - 1, player.QueueTracks.Count);
    }
}
