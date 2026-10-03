using Wiretune.Core.Services;
using Xunit;

namespace Wiretune.Tests;

public sealed class LrcParserTests
{
    private const string Song =
        "[ar:Anita Baker]\n[ti:Caught Up in the Rapture]\n" +
        "[00:02.56] Pa, pa, pa, pa\n[00:05.46]\n[00:20.85] When we met, I always knew\n[01:12.75]Nothing else can compare\n";

    [Fact]
    public void Parse_ReadsTimesAndText_AndSkipsHeaders()
    {
        var lines = LrcParser.Parse(Song);

        Assert.Equal(4, lines.Count);
        Assert.Equal(TimeSpan.FromSeconds(2.56), lines[0].Time);
        Assert.Equal("Pa, pa, pa, pa", lines[0].Text);
        Assert.True(lines[1].IsBlank);
        Assert.Equal(TimeSpan.FromSeconds(72.75), lines[3].Time);
    }

    [Fact]
    public void Parse_PlainText_IsNotSynced()
    {
        Assert.Empty(LrcParser.Parse("Just words\nwithout any times"));
        Assert.Empty(LrcParser.Parse(null));
        Assert.Empty(LrcParser.Parse("[00:01.00] only one timed line"));
    }

    [Fact]
    public void Parse_LineWithSeveralTimeTags_RepeatsAndSorts()
    {
        var lines = LrcParser.Parse("[00:30.00][01:10.00]Chorus\n[00:10.00]Verse\n");

        Assert.Equal(new[] { "Verse", "Chorus", "Chorus" }, lines.Select(l => l.Text));
        Assert.Equal(new[] { 10.0, 30.0, 70.0 }, lines.Select(l => l.Time.TotalSeconds));
    }

    [Fact]
    public void Parse_DropsWordTimestamps_AndUnderstandsFractionLengths()
    {
        var lines = LrcParser.Parse("[00:01.5]<00:01.50>Hello <00:02.00>world\n[00:03.123]Next\n");

        Assert.Equal("Hello world", lines[0].Text);
        Assert.Equal(TimeSpan.FromSeconds(1.5), lines[0].Time);
        Assert.Equal(TimeSpan.FromSeconds(3.123), lines[1].Time);
    }

    [Fact]
    public void Parse_AppliesTheOffsetHeader()
    {
        var lines = LrcParser.Parse("[offset:+500]\n[00:10.00]A\n[00:20.00]B\n");

        Assert.Equal(TimeSpan.FromSeconds(9.5), lines[0].Time); // positive offset: lyrics appear sooner
        Assert.Equal(TimeSpan.FromSeconds(19.5), lines[1].Time);
    }

    [Fact]
    public void IndexAt_FindsTheCurrentLine()
    {
        var lines = LrcParser.Parse(Song);

        Assert.Equal(-1, LrcParser.IndexAt(lines, TimeSpan.FromSeconds(1)));   // before the first line
        Assert.Equal(0, LrcParser.IndexAt(lines, TimeSpan.FromSeconds(2.56))); // exactly on it
        Assert.Equal(1, LrcParser.IndexAt(lines, TimeSpan.FromSeconds(10)));   // in the gap
        Assert.Equal(2, LrcParser.IndexAt(lines, TimeSpan.FromSeconds(60)));
        Assert.Equal(3, LrcParser.IndexAt(lines, TimeSpan.FromMinutes(10)));   // after the last
    }
}
