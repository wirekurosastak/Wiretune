using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Xunit;

namespace Wiretune.Tests;

public sealed class DeduplicationTests
{
    [Theory]
    [InlineData("Hotel California (2013 Remaster)", "hotelcalifornia")]
    [InlineData("Hey Jude [Remastered 2015]", "heyjude")]
    [InlineData("Song (Radio Edit) [Remastered]", "song")]
    [InlineData("Monologue (Mono Mix)", "monologue")]
    [InlineData("Song (Single Version)", "song")]
    public void CleanTitle_RemovesNotesThatDoNotChangeTheRecording(string title, string expected)
    {
        Assert.Equal(expected, TrackDeduplication.CleanTitle(title));
    }

    [Theory]
    [InlineData("Song (Live Version)", "songliveversion")]
    [InlineData("Song (Acoustic Version)", "songacousticversion")]
    [InlineData("Song (Credits)", "songcredits")]          // "credits" contains "edit" but is not an edit
    [InlineData("Song (Stereophonic)", "songstereophonic")] // neither is a stereo mix
    [InlineData("Monologue", "monologue")]
    [InlineData("(Remaster)", "remaster")]                  // never reduce a title to nothing
    public void CleanTitle_KeepsWhatMakesARecordingDifferent(string title, string expected)
    {
        Assert.Equal(expected, TrackDeduplication.CleanTitle(title));
    }

    [Fact]
    public void LiveAndStudioVersionsOfTheSameLengthAreNotDuplicates()
    {
        var studio = TestSupport.MakeTrack("a", "Song", "Band", "Album");
        var live = TestSupport.MakeTrack("b", "Song (Live Version)", "Band", "Album");

        Assert.False(TrackDeduplication.IsDuplicate(studio, live));
    }

    [Fact]
    public void RemasterOfTheSameSong_IsADuplicate()
    {
        var original = TestSupport.MakeTrack("a", "Song", "Band", "Album");
        var remaster = TestSupport.MakeTrack("b", "Song (2011 Remaster)", "Band", "Album (Deluxe Edition)");

        Assert.True(TrackDeduplication.IsDuplicate(original, remaster));
    }

    [Theory]
    [InlineData("Discovery", "Discovery Live 2001", true)]
    [InlineData("Discovery", "Discovery (Deluxe Edition)", true)]
    [InlineData("1", "Abbey Road 1969", false)]
    [InlineData("Live", "Live at Wembley", true)]
    [InlineData("Us", "Abbey Road Studios", false)]
    [InlineData("", "Anything", true)]
    [InlineData("Unknown Album", "Anything", true)]
    public void AlbumsMatch_DoesNotLetAShortNameHideInsideALongOne(string a, string b, bool expected)
    {
        Assert.Equal(expected, TrackDeduplication.AlbumsMatch(a, b));
    }
}
