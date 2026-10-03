using System.Net;
using System.Text;
using System.Text.Json;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;
using Xunit;

namespace Wiretune.Tests;

/// <summary>The LRCLIB lookup, against a stub of the service and a throw-away cache folder.</summary>
public sealed class OnlineLyricsTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("wiretune_onlinelyrics_").FullName;
    private DateTime _now = new(2026, 10, 1, 12, 0, 0, DateTimeKind.Utc);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }

    private sealed class StubHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        private readonly List<string> _requests = new();

        public StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond)
            : this((request, _) => Task.FromResult(respond(request)))
        {
        }

        public IReadOnlyList<string> Requests
        {
            get { lock (_requests) return _requests.ToList(); }
        }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            lock (_requests) _requests.Add(request.RequestUri!.PathAndQuery);
            return respond(request, cancellationToken);
        }
    }

    private static HttpResponseMessage Json(string body, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    private static HttpResponseMessage NotFound() =>
        Json("""{"code":404,"name":"TrackNotFound","message":"Failed to find specified track"}""", HttpStatusCode.NotFound);

    private OnlineLyrics Create(StubHandler handler, string? cache = null) =>
        new(new HttpClient(handler) { BaseAddress = new Uri("https://lrclib.test/") }, cache ?? _dir, () => _now);

    private static Track Song(string title = "Song", string artist = "Artist", string album = "Album") =>
        TestSupport.MakeTrack("t1", title, artist, album, minutes: 3.0);

    // ── Finding lyrics ───────────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task Find_UsesTheExactMatch_AndKeepsTheAnswerForNextTime()
    {
        var handler = new StubHandler(_ => Json("""
            {"id":1,"trackName":"Song","artistName":"Artist","albumName":"Album","duration":180,"instrumental":false,
             "plainLyrics":"Line one\r\nLine two\r\n","syncedLyrics":"[00:01.00] Line one\n[00:03.00] Line two"}
            """));
        using var lyrics = Create(handler);

        Assert.Equal("Line one\nLine two", await lyrics.FindAsync(Song()));
        Assert.Equal("/api/get?artist_name=Artist&track_name=Song&album_name=Album&duration=180", Assert.Single(handler.Requests));

        // The second time the answer comes from the cache folder, not from the network.
        Assert.Equal("Line one\nLine two", await lyrics.FindAsync(Song()));
        Assert.Single(handler.Requests);
        Assert.Single(Directory.GetFiles(_dir, "*.json"));
    }

    [Fact]
    public async Task Find_EscapesWhatItSends()
    {
        var handler = new StubHandler(_ => Json("""{"plainLyrics":"x"}"""));
        using var lyrics = Create(handler);

        await lyrics.FindAsync(Song("Rock & Roll? #1", "AC/DC", "Back in Black"));

        var request = Assert.Single(handler.Requests);
        Assert.Contains("artist_name=AC%2FDC", request);
        Assert.Contains("track_name=Rock%20%26%20Roll%3F%20%231", request);
        Assert.Contains("album_name=Back%20in%20Black", request);
    }

    [Fact]
    public async Task Find_WhenThereIsNoExactMatch_SearchesAndTakesTheSameSongClosestInLength()
    {
        var handler = new StubHandler(request => request.RequestUri!.AbsolutePath == "/api/get"
            ? NotFound()
            : Json("""
                [
                  {"trackName":"Song","artistName":"Artist","albumName":"Live","duration":240,"plainLyrics":"live version"},
                  {"trackName":"Song","artistName":"Artist","albumName":"Greatest hits","duration":183,"plainLyrics":"hits version"},
                  {"trackName":"Song (Remastered)","artistName":"Artist","albumName":"Album","duration":181,"plainLyrics":"remaster"},
                  {"trackName":"Another Song","artistName":"Artist","albumName":"Album","duration":180,"plainLyrics":"wrong song"},
                  {"trackName":"Song","artistName":"Someone Else","albumName":"Album","duration":180,"plainLyrics":"wrong artist"}
                ]
                """));
        using var lyrics = Create(handler);

        Assert.Equal("remaster", await lyrics.FindAsync(Song()));
        Assert.Equal(2, handler.Requests.Count);
        Assert.Equal("/api/search?track_name=Song&artist_name=Artist", handler.Requests[1]);
    }

    [Fact]
    public async Task Find_WithoutAKnownAlbum_GoesStraightToTheSearch()
    {
        var handler = new StubHandler(_ => Json("""[{"trackName":"Song","artistName":"Artist","duration":180,"plainLyrics":"found"}]"""));
        using var lyrics = Create(handler);

        Assert.Equal("found", await lyrics.FindAsync(Song(album: MetadataScanner.UnknownAlbum)));
        Assert.StartsWith("/api/search?", Assert.Single(handler.Requests));
    }

    [Fact]
    public async Task Find_WhenTheTagNamesSeveralArtists_TriesTheFirstOneToo()
    {
        var handler = new StubHandler(request =>
            request.RequestUri!.Query.Contains("artist_name=Artist%20feat.%20Guest")
                ? Json("[]")
                : request.RequestUri.AbsolutePath == "/api/get"
                    ? NotFound()
                    : Json("""[{"trackName":"Song","artistName":"Artist","duration":180,"plainLyrics":"found under the first artist"}]"""));
        using var lyrics = Create(handler);

        Assert.Equal("found under the first artist", await lyrics.FindAsync(Song(artist: "Artist feat. Guest")));
    }

    [Fact]
    public async Task Find_OfATimeSyncedOnlyRecord_DropsTheTimestamps()
    {
        var handler = new StubHandler(_ => Json("""
            {"instrumental":false,"plainLyrics":null,
             "syncedLyrics":"[ar:Artist]\n[ti:Song]\n[00:12.34] Hello\n[00:15.00][00:30.00] World <00:15.50>again\n[00:40.00]"}
            """));
        using var lyrics = Create(handler);

        Assert.Equal("Hello\nWorld again", await lyrics.FindAsync(Song()));
    }

    [Fact]
    public async Task Find_OfAnInstrumental_IsNull_AndNotAskedAgainForAWeek()
    {
        var handler = new StubHandler(request => request.RequestUri!.AbsolutePath == "/api/get"
            ? Json("""{"instrumental":true,"plainLyrics":null,"syncedLyrics":null}""")
            : Json("[]"));
        using var lyrics = Create(handler);

        Assert.Null(await lyrics.FindAsync(Song()));
        var asked = handler.Requests.Count;
        Assert.Equal(2, asked);   // the exact match, then the search

        _now += TimeSpan.FromDays(6);
        Assert.Null(await lyrics.FindAsync(Song()));
        Assert.Equal(asked, handler.Requests.Count);   // still remembered

        _now += TimeSpan.FromDays(2);   // eight days after the first look
        Assert.Null(await lyrics.FindAsync(Song()));
        Assert.Equal(asked * 2, handler.Requests.Count);   // asked again
    }

    [Fact]
    public async Task Find_KeepsFoundLyricsForever()
    {
        var handler = new StubHandler(_ => Json("""{"plainLyrics":"keep me"}"""));
        using var lyrics = Create(handler);

        await lyrics.FindAsync(Song());
        _now += TimeSpan.FromDays(800);

        Assert.Equal("keep me", await lyrics.FindAsync(Song()));
        Assert.Single(handler.Requests);
    }

    // ── Failing and not trying ───────────────────────────────────────────────────────────────────

    [Fact]
    public async Task Find_WhenTheServiceCannotBeReached_Throws_AndRemembersNothing()
    {
        var down = true;
        var handler = new StubHandler(_ => down ? Json("{}", HttpStatusCode.ServiceUnavailable) : Json("""{"plainLyrics":"back again"}"""));
        using var lyrics = Create(handler);

        await Assert.ThrowsAsync<HttpRequestException>(() => lyrics.FindAsync(Song()));
        Assert.Empty(Directory.GetFiles(_dir, "*.json"));   // a failure is not "no lyrics"

        down = false;
        Assert.Equal("back again", await lyrics.FindAsync(Song()));
    }

    [Fact]
    public async Task Find_WhenTheConnectionDrops_ThrowsTheNetworkError()
    {
        var handler = new StubHandler((Func<HttpRequestMessage, HttpResponseMessage>)(_ => throw new HttpRequestException("no route to host")));
        using var lyrics = Create(handler);

        await Assert.ThrowsAsync<HttpRequestException>(() => lyrics.FindAsync(Song()));
    }

    [Fact]
    public async Task Find_RefusesAnUnreasonablyLargeAnswer()
    {
        var handler = new StubHandler(_ => Json("{\"plainLyrics\":\"" + new string('a', 2 * 1024 * 1024) + "\"}"));
        using var lyrics = Create(handler);

        await Assert.ThrowsAsync<HttpRequestException>(() => lyrics.FindAsync(Song()));
    }

    [Fact]
    public async Task Find_CanBeCancelled()
    {
        var handler = new StubHandler(async (_, ct) =>
        {
            await Task.Delay(Timeout.Infinite, ct);
            return Json("{}");
        });
        using var lyrics = Create(handler);
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => lyrics.FindAsync(Song(), cts.Token));
    }

    [Theory]
    [InlineData("Song", "Unknown artist")]
    [InlineData("Song", "Ismeretlen előadó")]
    [InlineData("Song", "   ")]
    [InlineData("   ", "Artist")]
    [InlineData("Unknown Title", "Artist")]
    public async Task Find_DoesNotAsk_ForATrackThatIsTooAnonymous(string title, string artist)
    {
        var handler = new StubHandler(_ => Json("""{"plainLyrics":"x"}"""));
        using var lyrics = Create(handler);

        Assert.Null(await lyrics.FindAsync(Song(title, artist)));
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task Find_DoesNotAsk_WhenTheEnvironmentSwitchesTheLookupOff()
    {
        var previous = Environment.GetEnvironmentVariable(OnlineLyrics.DisableEnvironmentVariable);
        Environment.SetEnvironmentVariable(OnlineLyrics.DisableEnvironmentVariable, "1");
        try
        {
            var handler = new StubHandler(_ => Json("""{"plainLyrics":"x"}"""));
            using var lyrics = Create(handler);

            Assert.Null(await lyrics.FindAsync(Song()));
            Assert.Empty(handler.Requests);
        }
        finally
        {
            Environment.SetEnvironmentVariable(OnlineLyrics.DisableEnvironmentVariable, previous);
        }
    }

    [Fact]
    public async Task Find_IgnoresAnUnreadableCacheEntry()
    {
        var handler = new StubHandler(_ => Json("""{"plainLyrics":"fresh"}"""));
        using var lyrics = Create(handler);
        var key = OnlineLyrics.LyricsQuery.From(Song())!.CacheKey;
        await File.WriteAllTextAsync(Path.Combine(_dir, key + ".json"), "{ this is not json");

        Assert.Equal("fresh", await lyrics.FindAsync(Song()));
        Assert.Single(handler.Requests);
        Assert.Equal("fresh", await lyrics.FindAsync(Song()));   // and the entry was repaired
        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task Find_WithoutACacheFolder_StillWorks()
    {
        var handler = new StubHandler(_ => Json("""{"plainLyrics":"x"}"""));
        using var lyrics = new OnlineLyrics(new HttpClient(handler) { BaseAddress = new Uri("https://lrclib.test/") }, cacheDirectory: null);

        Assert.Equal("x", await lyrics.FindAsync(Song()));
        Assert.Equal("x", await lyrics.FindAsync(Song()));
        Assert.Equal(2, handler.Requests.Count);
    }

    [Fact]
    public void CacheKey_IsStable_AndDoesNotLeakTheTags()
    {
        var key = OnlineLyrics.LyricsQuery.From(Song("Secret Title", "Secret Artist"))!.CacheKey;

        Assert.Equal(key, OnlineLyrics.LyricsQuery.From(Song("secret title", "SECRET ARTIST"))!.CacheKey);
        Assert.NotEqual(key, OnlineLyrics.LyricsQuery.From(Song("Another Title", "Secret Artist"))!.CacheKey);
        Assert.Matches("^[0-9a-f]{32}$", key);
    }

    // ── Reading an answer ────────────────────────────────────────────────────────────────────────

    [Theory]
    [InlineData("[00:12.34] Hello", "Hello")]
    [InlineData("[01:02] Hello", "Hello")]
    [InlineData("[00:15.00][00:30.00] Chorus", "Chorus")]
    [InlineData("[00:12.340]   Spaced", "Spaced")]
    [InlineData("No tag here", "No tag here")]
    [InlineData("[ar:Artist]\n[00:01.00] First\n\n[00:05.00] Third", "First\n\nThird")]
    [InlineData("[00:01.00] Un <00:01.50>deux <00:02.00>trois", "Un deux trois")]
    public void StripTimestamps_LeavesJustTheWords(string lrc, string expected)
    {
        Assert.Equal(expected, OnlineLyrics.StripTimestamps(lrc));
    }

    [Theory]
    [InlineData("Artist", new[] { "Artist" })]
    [InlineData("Artist feat. Guest", new[] { "Artist feat. Guest", "Artist" })]
    [InlineData("Artist; Other", new[] { "Artist; Other", "Artist" })]
    [InlineData("Artist & Other", new[] { "Artist & Other", "Artist" })]
    [InlineData("Artist ft. Guest, Other", new[] { "Artist ft. Guest, Other", "Artist" })]
    public void ArtistCandidates_AreTheTagThenTheFirstArtist(string artist, string[] expected)
    {
        Assert.Equal(expected, OnlineLyrics.ArtistCandidates(artist).ToArray());
    }

    [Theory]
    [InlineData("Song", "Song", true)]
    [InlineData("song!", "SONG", true)]
    [InlineData("Song (Remastered 2011)", "Song", true)]
    [InlineData("Song [Live]", "Song", true)]
    [InlineData("Song - Single Edit", "Song", true)]
    [InlineData("Song", "Song (feat. Guest)", true)]
    [InlineData("Song (feat. Guest)", "Song (feat. Guest)", true)]
    [InlineData(null, "Song", true)]            // the record does not say: cannot be ruled out
    [InlineData("Another Song", "Song", false)] // containing the title is not the same song
    [InlineData("Song Two", "Song", false)]
    [InlineData("Other", "Song", false)]
    [InlineData("(Untitled)", "(Untitled)", true)]
    public void SimilarTitle_AcceptsTheSameSongUnderADifferentSpelling_ButNotAnotherSong(string? found, string wanted, bool expected)
    {
        Assert.Equal(expected, OnlineLyrics.SimilarTitle(found, wanted));
    }

    [Theory]
    [InlineData("Artist", "Artist", true)]
    [InlineData("ARTIST", "artist!", true)]
    [InlineData("Artist feat. Guest", "Artist", true)]
    [InlineData("Artist", "Artist & Friends", true)]
    [InlineData(null, "Artist", true)]
    [InlineData("Someone Else", "Artist", false)]
    [InlineData("AB", "ABC", false)]            // a name of one or two letters proves nothing
    public void SimilarArtist_AcceptsTheSameActWithMoreOrFewerNames(string? found, string wanted, bool expected)
    {
        Assert.Equal(expected, OnlineLyrics.SimilarArtist(found, wanted));
    }

    [Fact]
    public void TextOf_PrefersThePlainText_AndCapsTheLength()
    {
        using var plain = JsonDocument.Parse("""{"plainLyrics":"plain","syncedLyrics":"[00:01.00] synced"}""");
        Assert.Equal("plain", OnlineLyrics.TextOf(plain.RootElement));

        using var huge = JsonDocument.Parse("{\"plainLyrics\":\"" + new string('x', 150_000) + "\"}");
        Assert.Equal(100_000, OnlineLyrics.TextOf(huge.RootElement)!.Length);

        using var empty = JsonDocument.Parse("""{"plainLyrics":"  ","syncedLyrics":""}""");
        Assert.Null(OnlineLyrics.TextOf(empty.RootElement));
    }
}

/// <summary>What the player does with the two sources of lyrics: the track's own tags first, then the internet.</summary>
public sealed class OnlineLyricsPlayerTests
{
    private static async Task<bool> WaitUntil(Func<bool> condition)
    {
        for (var i = 0; i < 300 && !condition(); i++) await Task.Delay(10);
        return condition();
    }

    private static PlayerViewModel CreatePlayer(
        Func<Track, CancellationToken, Task<string?>>? own = null,
        Func<Track, CancellationToken, Task<string?>>? online = null)
    {
        var library = new LibraryService(new MockRepository(), new MetadataScanner());
        return new PlayerViewModel(TestSupport.CreateEngine(), library) { LyricsProvider = own, OnlineLyricsProvider = online };
    }

    private static Task<string?> Nothing(Track _, CancellationToken __) => Task.FromResult<string?>(null);

    [Fact]
    public async Task OwnLyrics_AreUsed_WithoutAskingTheInternet()
    {
        var asked = 0;
        var player = CreatePlayer(
            own: (_, _) => Task.FromResult<string?>("From the tag"),
            online: (_, _) => { asked++; return Task.FromResult<string?>("From the internet"); });
        player.IsQueueOpen = true;

        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");

        Assert.True(await WaitUntil(() => player.HasLyrics));
        Assert.Equal("From the tag", player.CurrentLyrics);
        Assert.Equal(LyricsOrigin.Tags, player.LyricsOrigin);
        Assert.Equal("Source: the track's own tags", player.LyricsSourceText);
        Assert.Equal(0, asked);
    }

    [Fact]
    public async Task ATrackWithoutLyrics_IsLookedUpOnline_AndTheSourceIsCredited()
    {
        var player = CreatePlayer(own: Nothing, online: (_, _) => Task.FromResult<string?>("From the internet"));
        player.IsQueueOpen = true;

        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");

        Assert.True(await WaitUntil(() => player.HasLyrics));
        Assert.Equal("From the internet", player.CurrentLyrics);
        Assert.Equal(LyricsOrigin.Online, player.LyricsOrigin);
        Assert.Equal("Source: LRCLIB", player.LyricsSourceText);
        Assert.False(player.IsLoadingLyrics);
        Assert.False(player.ShowLyricsEmptyState);
        Assert.False(player.LyricsLookupFailed);
    }

    [Fact]
    public async Task TheInternetIsOnlyAskedWhileThePanelIsOpen()
    {
        var asked = 0;
        var player = CreatePlayer(own: Nothing, online: (_, _) => { asked++; return Task.FromResult<string?>("x"); });

        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");
        await Task.Delay(50);
        Assert.Equal(0, asked);
        Assert.False(player.IsLoadingLyrics);

        player.IsQueueOpen = true;
        Assert.True(await WaitUntil(() => player.HasLyrics));
        Assert.Equal(1, asked);
    }

    [Fact]
    public async Task WithTheLookupSwitchedOff_NothingIsSent_AndThePanelPointsToTheSetting()
    {
        var asked = 0;
        var player = CreatePlayer(own: Nothing, online: (_, _) => { asked++; return Task.FromResult<string?>("x"); });
        player.IsOnlineLyricsEnabled = false;
        player.IsQueueOpen = true;

        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");

        Assert.True(await WaitUntil(() => player.ShowLyricsEmptyState));
        Assert.Equal(0, asked);
        Assert.Contains("Settings", player.LyricsEmptyText);
        Assert.Equal(LyricsOrigin.None, player.LyricsOrigin);
    }

    [Fact]
    public async Task WhenNothingIsFound_ThePanelSaysSo()
    {
        var player = CreatePlayer(own: Nothing, online: Nothing);
        player.IsQueueOpen = true;

        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");

        Assert.True(await WaitUntil(() => player.ShowLyricsEmptyState));
        Assert.Equal("No lyrics found for this track.", player.LyricsEmptyText);
        Assert.False(player.LyricsLookupFailed);
        Assert.Equal(string.Empty, player.LyricsSourceText);
    }

    [Fact]
    public async Task WhileLooking_ThePanelShowsASearchNote_NotTheEmptyMessage()
    {
        var pending = new TaskCompletionSource<string?>();
        var player = CreatePlayer(own: Nothing, online: (_, _) => pending.Task);
        player.IsQueueOpen = true;

        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");

        Assert.True(player.IsLoadingLyrics);
        Assert.False(player.ShowLyricsEmptyState);

        pending.SetResult("Done");
        Assert.True(await WaitUntil(() => player.HasLyrics));
        Assert.False(player.IsLoadingLyrics);
    }

    [Fact]
    public async Task WhenTheServiceCannotBeReached_ThePanelSaysThat_AndReopeningItTriesAgain()
    {
        var asked = 0;
        var player = CreatePlayer(own: Nothing, online: (_, _) =>
        {
            asked++;
            return Task.FromException<string?>(new HttpRequestException("offline"));
        });
        player.IsQueueOpen = true;

        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");

        Assert.True(await WaitUntil(() => player.LyricsLookupFailed));
        Assert.True(player.ShowLyricsEmptyState);
        Assert.False(player.IsLoadingLyrics);
        Assert.Contains("Couldn't reach", player.LyricsEmptyText);
        Assert.Equal(1, asked);

        player.IsQueueOpen = false;
        player.IsQueueOpen = true;
        Assert.True(await WaitUntil(() => asked == 2));
    }

    [Fact]
    public async Task AFailingOwnProvider_DoesNotStopTheInternetLookup()
    {
        var player = CreatePlayer(own: (_, _) => throw new IOException("disk on fire"), online: (_, _) => Task.FromResult<string?>("Online"));
        player.IsQueueOpen = true;

        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");

        Assert.True(await WaitUntil(() => player.HasLyrics));
        Assert.Equal(LyricsOrigin.Online, player.LyricsOrigin);
    }

    [Fact]
    public async Task SwitchingTheLookupOn_WhileATrackWithoutLyricsIsOpen_LooksItUpAtOnce()
    {
        var player = CreatePlayer(own: Nothing, online: (_, _) => Task.FromResult<string?>("Online"));
        player.IsOnlineLyricsEnabled = false;
        player.IsQueueOpen = true;
        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");
        Assert.True(await WaitUntil(() => player.ShowLyricsEmptyState));

        player.IsOnlineLyricsEnabled = true;

        Assert.True(await WaitUntil(() => player.HasLyrics));
        Assert.Equal(LyricsOrigin.Online, player.LyricsOrigin);
    }

    [Fact]
    public async Task SwitchingTheLookupOff_RemovesLyricsThatCameFromTheInternet_ButNotTheTagged()
    {
        var player = CreatePlayer(own: Nothing, online: (_, _) => Task.FromResult<string?>("Online"));
        player.IsQueueOpen = true;
        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");
        Assert.True(await WaitUntil(() => player.HasLyrics));

        player.IsOnlineLyricsEnabled = false;

        Assert.True(await WaitUntil(() => !player.HasLyrics && !player.IsLoadingLyrics));
        Assert.Equal(LyricsOrigin.None, player.LyricsOrigin);

        var tagged = CreatePlayer(own: (_, _) => Task.FromResult<string?>("Tagged"), online: (_, _) => Task.FromResult<string?>("Online"));
        tagged.IsQueueOpen = true;
        tagged.CurrentTrack = TestSupport.MakeTrack("t1", "One");
        Assert.True(await WaitUntil(() => tagged.HasLyrics));

        tagged.IsOnlineLyricsEnabled = false;
        await Task.Delay(50);
        Assert.Equal("Tagged", tagged.CurrentLyrics);
    }

    [Fact]
    public async Task ASlowLookup_ForATrackThatIsNoLongerPlaying_IsIgnored()
    {
        var slow = new TaskCompletionSource<string?>();
        var player = CreatePlayer(own: Nothing, online: (track, _) => track.Id == "t1" ? slow.Task : Task.FromResult<string?>("Lyrics of t2"));
        player.IsQueueOpen = true;

        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");
        player.CurrentTrack = TestSupport.MakeTrack("t2", "Two");
        Assert.True(await WaitUntil(() => player.CurrentLyrics == "Lyrics of t2"));

        slow.SetResult("Lyrics of t1 (late)");
        await Task.Delay(50);

        Assert.Equal("Lyrics of t2", player.CurrentLyrics);
        Assert.False(player.IsLoadingLyrics);
    }

    [Fact]
    public async Task ChangingTheTrack_CancelsTheLookupOfThePreviousOne()
    {
        CancellationToken firstToken = default;
        var player = CreatePlayer(own: Nothing, online: (track, ct) =>
        {
            if (track.Id != "t1") return Task.FromResult<string?>("Lyrics of t2");
            firstToken = ct;
            return Task.Delay(Timeout.Infinite, ct).ContinueWith<string?>(_ => null, TaskScheduler.Default);
        });
        player.IsQueueOpen = true;

        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");
        Assert.True(await WaitUntil(() => firstToken.CanBeCanceled));
        player.CurrentTrack = TestSupport.MakeTrack("t2", "Two");

        Assert.True(await WaitUntil(() => firstToken.IsCancellationRequested));
        Assert.True(await WaitUntil(() => player.CurrentLyrics == "Lyrics of t2"));
    }

    [Fact]
    public async Task ClearingTheQueue_ForgetsEverythingAboutTheLyrics()
    {
        var player = CreatePlayer(own: Nothing, online: (_, _) => Task.FromResult<string?>("Online"));
        player.IsQueueOpen = true;
        player.CurrentTrack = TestSupport.MakeTrack("t1", "One");
        Assert.True(await WaitUntil(() => player.HasLyrics));

        player.CurrentTrack = null;

        Assert.False(player.HasLyrics);
        Assert.Equal(LyricsOrigin.None, player.LyricsOrigin);
        Assert.False(player.IsLoadingLyrics);
    }
}
