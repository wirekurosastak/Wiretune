using System.ComponentModel;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Xunit;

namespace Wiretune.Tests;

/// <summary>The gold / silver / bronze quality tiers of tracks, albums and playlists.</summary>
public sealed class QualityTierTests
{
    private static AudioFormat Lossless(int sampleRate, int bits, string codec = "FLAC") =>
        new() { Codec = codec, SampleRate = sampleRate, BitsPerSample = bits, IsLossless = true };

    private static AudioFormat Lossy(int kbps, string codec = "MP3", int sampleRate = 44100) =>
        new() { Codec = codec, SampleRate = sampleRate, BitsPerSample = 0, BitrateKbps = kbps, IsLossless = false };

    [Theory]
    [InlineData(44100, 16, QualityTier.Silver)]   // CD quality
    [InlineData(48000, 16, QualityTier.Silver)]   // 48 kHz is still not above 48 kHz
    [InlineData(44100, 24, QualityTier.Gold)]     // 24 bit
    [InlineData(96000, 24, QualityTier.Gold)]
    [InlineData(192000, 24, QualityTier.Gold)]
    [InlineData(96000, 16, QualityTier.Gold)]     // a sample rate above 48 kHz is hi-res as well
    [InlineData(2822400, 1, QualityTier.Gold)]    // DSD64
    public void Lossless_IsSilverAtCdResolution_AndGoldAbove(int sampleRate, int bits, QualityTier expected)
    {
        Assert.Equal(expected, Lossless(sampleRate, bits).Tier);
    }

    [Theory]
    [InlineData("MP3", 320, 44100)]
    [InlineData("AAC", 256, 48000)]
    [InlineData("OGG", 192, 96000)]   // a lossy file is bronze however high its sample rate is
    public void Lossy_IsAlwaysBronze(string codec, int kbps, int sampleRate)
    {
        Assert.Equal(QualityTier.Bronze, Lossy(kbps, codec, sampleRate).Tier);
    }

    [Fact]
    public void TagSpec_ReadsLikeTheTagItBelongsTo()
    {
        Assert.Equal("FLAC 24bit/96kHz", Lossless(96000, 24).TagSpec);
        Assert.Equal("FLAC 16bit/44.1kHz", Lossless(44100, 16).TagSpec);
        Assert.Equal("ALAC 24bit/88.2kHz", Lossless(88200, 24, "alac").TagSpec);
        Assert.Equal("MP3 320kbps", Lossy(320).TagSpec);
    }

    [Fact]
    public void TagText_IsJustTheSpec_TheColourTellsTheTier()
    {
        Assert.Equal("FLAC 24bit/96kHz", QualityTier.Gold.TagText("FLAC 24bit/96kHz"));
        Assert.Equal("FLAC 16bit/44.1kHz", QualityTier.Silver.TagText("FLAC 16bit/44.1kHz"));
        Assert.Equal("MP3 320kbps", QualityTier.Bronze.TagText("MP3 320kbps"));
    }

    [Fact]
    public void TagText_Compact_KeepsOnlyTheFileFormat()
    {
        Assert.Equal("FLAC", QualityTier.Gold.TagText("FLAC 24bit/96kHz", compact: true));
        Assert.Equal("MP3", QualityTier.Bronze.TagText("MP3 320kbps", compact: true));
        Assert.Equal("MIXED", QualityTier.Silver.TagText(QualitySummary.MixedSpec, compact: true));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void TagText_WithoutASpec_IsJustTheTierWord(string? spec)
    {
        Assert.Equal("GOLD", QualityTier.Gold.TagText(spec));
        Assert.Equal("GOLD", QualityTier.Gold.TagText(spec, compact: true));
    }

    [Theory]
    [InlineData(QualityTier.Gold, "GOLD")]
    [InlineData(QualityTier.Silver, "SILVER")]
    [InlineData(QualityTier.Bronze, "BRONZE")]
    public void EveryTier_HasAWordAndAHint(QualityTier tier, string word)
    {
        Assert.Equal(word, tier.Word());
        Assert.DoesNotContain("[", tier.Hint());   // an unknown key renders as "[Key]"
        Assert.False(string.IsNullOrWhiteSpace(tier.Hint()));
    }

    [Fact]
    public void Summary_OfNothing_IsNull()
    {
        Assert.Null(QualitySummary.Of(Array.Empty<AudioFormat>()));
    }

    [Fact]
    public void Summary_OfOneFormat_IsItsTierAndSpec()
    {
        var summary = QualitySummary.Of(new[] { Lossless(96000, 24), Lossless(96000, 24) })!;

        Assert.Equal(QualityTier.Gold, summary.Tier);
        Assert.Equal("FLAC 24bit/96kHz", summary.Spec);
        Assert.False(summary.IsMixed);
    }

    [Fact]
    public void Summary_OfDifferentFormats_IsMixed_AndTakesTheLowestTier()
    {
        var sameTier = QualitySummary.Of(new[] { Lossless(96000, 24), Lossless(192000, 24) })!;
        Assert.True(sameTier.IsMixed);
        Assert.Equal(QualitySummary.MixedSpec, sameTier.Spec);
        Assert.Equal(QualityTier.Gold, sameTier.Tier);

        var hiResAndCd = QualitySummary.Of(new[] { Lossless(96000, 24), Lossless(44100, 16) })!;
        Assert.Equal(QualityTier.Silver, hiResAndCd.Tier);

        var withAnMp3 = QualitySummary.Of(new[] { Lossless(96000, 24), Lossy(320) })!;
        Assert.Equal(QualityTier.Bronze, withAnMp3.Tier);
        Assert.True(withAnMp3.IsMixed);
    }

    [Fact]
    public void Summary_TreatsLossyFilesOfDifferentBitrates_AsDifferentFormats()
    {
        Assert.True(QualitySummary.Of(new[] { Lossy(128), Lossy(320) })!.IsMixed);
        Assert.False(QualitySummary.Of(new[] { Lossy(320), Lossy(320) })!.IsMixed);
        Assert.False(QualitySummary.Of(new[] { Lossless(44100, 16, "FLAC"), Lossless(44100, 16, "flac") })!.IsMixed); // case of the codec name is irrelevant
    }

    [Fact]
    public async Task Albums_CarryTheirTierAndTagSpec()
    {
        var repo = new MockRepository();
        var service = new LibraryService(repo, new MetadataScanner());

        Track Make(string id, string album, AudioFormat format) => new()
        {
            Id = id, Title = id, Artist = "Artist", Album = album, TrackNumber = 1, FilePath = $"/music/{album}/{id}.x", Format = format,
        };

        await repo.SaveTracksBatchAsync(new[]
        {
            Make("g1", "Gold album", Lossless(96000, 24)),
            Make("g2", "Gold album", Lossless(96000, 24)),
            Make("s1", "Silver album", Lossless(44100, 16)),
            Make("b1", "Bronze album", Lossy(320)),
            Make("m1", "Mixed album", Lossless(96000, 24)),
            Make("m2", "Mixed album", Lossy(256)),
        });
        await service.InitializeAsync();

        Album Find(string title) => service.Albums.Single(a => a.Title == title);

        Assert.Equal((QualityTier.Gold, "FLAC 24bit/96kHz"), (Find("Gold album").Tier, Find("Gold album").TagSpec));
        Assert.Equal((QualityTier.Silver, "FLAC 16bit/44.1kHz"), (Find("Silver album").Tier, Find("Silver album").TagSpec));
        Assert.Equal((QualityTier.Bronze, "MP3 320kbps"), (Find("Bronze album").Tier, Find("Bronze album").TagSpec));
        Assert.Equal((QualityTier.Bronze, "MIXED"), (Find("Mixed album").Tier, Find("Mixed album").TagSpec));
        Assert.Equal("MIXED HQ", Find("Mixed album").FormatBadge);   // the long-standing text field is unchanged
        Assert.True(Find("Mixed album").IsHiRes);
    }

    [Fact]
    public void Playlist_ApplyQuality_SetsBadgeTierAndSpec_AndTellsTheUi()
    {
        var playlist = new Playlist();
        var changed = new List<string?>();
        ((INotifyPropertyChanged)playlist).PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        playlist.ApplyQuality(new[]
        {
            TestSupport.MakeTrack("a", "A", sampleRate: 96000, bits: 24),
            TestSupport.MakeTrack("b", "B", sampleRate: 96000, bits: 24),
        });

        Assert.Equal(QualityTier.Gold, playlist.FormatTier);
        Assert.Equal("FLAC 24bit/96kHz", playlist.FormatSpec);
        Assert.Equal("FLAC / 24bit / 96kHz", playlist.FormatBadge);
        Assert.Contains(nameof(Playlist.FormatTier), changed);
        Assert.Contains(nameof(Playlist.FormatSpec), changed);
        Assert.Contains(nameof(Playlist.FormatBadge), changed);

        playlist.ApplyQuality(new[]
        {
            TestSupport.MakeTrack("a", "A", sampleRate: 96000, bits: 24),
            TestSupport.MakeTrack("c", "C", sampleRate: 44100, bits: 16),
        });
        Assert.Equal(QualityTier.Silver, playlist.FormatTier);
        Assert.Equal("MIXED", playlist.FormatSpec);
        Assert.Equal("MIXED HQ", playlist.FormatBadge);
    }

    [Fact]
    public void Playlist_ApplyQuality_OfAnEmptyPlaylist_ClearsTheBadge()
    {
        var playlist = new Playlist { FormatBadge = "FLAC / 16bit / 44.1kHz" };

        playlist.ApplyQuality(Array.Empty<Track>());

        Assert.Equal(string.Empty, playlist.FormatBadge);
        Assert.Equal(string.Empty, playlist.FormatSpec);
    }
}
