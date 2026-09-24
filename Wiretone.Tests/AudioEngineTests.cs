using Wiretone.Audio;
using Wiretone.Core.Models;
using Xunit;

namespace Wiretone.Tests;

public class AudioEngineTests
{
    [Fact]
    public async Task BitperfectMode_WhenEnabled_LocksVolumeToUnityGain()
    {
        using var engine = new WiretoneAudioEngine();

        // Enable Bitperfect
        await engine.SetBitperfectModeAsync(true);

        Assert.True(engine.IsBitperfect);
        Assert.True(engine.IsVolumeLocked);
        Assert.Equal(1.0, engine.Volume);

        // Attempt to lower volume while bitperfect is active
        engine.SetVolume(0.5);

        // Must remain 1.0 (Unity gain 0dB) to avoid digital attenuation of bits
        Assert.Equal(1.0, engine.Volume);
    }

    [Fact]
    public async Task BitperfectMode_WhenDisabled_AllowsVolumeAdjustment()
    {
        using var engine = new WiretoneAudioEngine();

        await engine.SetBitperfectModeAsync(false);
        Assert.False(engine.IsBitperfect);
        Assert.False(engine.IsVolumeLocked);

        engine.SetVolume(0.75);
        Assert.Equal(0.75, engine.Volume, precision: 2);
    }

    [Fact]
    public async Task ExclusiveMode_TogglesStateCorrectly()
    {
        using var engine = new WiretoneAudioEngine();

        await engine.SetExclusiveModeAsync(true);
        Assert.True(engine.IsExclusiveMode);

        await engine.SetExclusiveModeAsync(false);
        Assert.False(engine.IsExclusiveMode);
    }

    [Fact]
    public void HiResAudioFormat_CorrectlyIdentified()
    {
        var cdQuality = new AudioFormat
        {
            Codec = "FLAC",
            SampleRate = 44100,
            BitsPerSample = 16
        };

        var hiResMaster = new AudioFormat
        {
            Codec = "FLAC",
            SampleRate = 96000,
            BitsPerSample = 24
        };

        var dsdFormat = new AudioFormat
        {
            Codec = "FLAC",
            SampleRate = 192000,
            BitsPerSample = 24
        };

        Assert.False(cdQuality.IsHiRes);
        Assert.True(hiResMaster.IsHiRes);
        Assert.True(dsdFormat.IsHiRes);
        Assert.Contains("96", hiResMaster.DisplayBadge);
        Assert.Contains("HI-RES LOSSLESS", hiResMaster.DisplayBadge);
        Assert.Contains("CD LOSSLESS", cdQuality.DisplayBadge);
    }

    [Fact]
    public async Task BitperfectMode_WhenEnabled_AutomaticallyEnablesExclusiveMode()
    {
        using var engine = new WiretoneAudioEngine();

        await engine.SetExclusiveModeAsync(false);
        Assert.False(engine.IsExclusiveMode);
        Assert.False(engine.IsBitperfect);

        // Enabling Bit-perfect must automatically activate Exclusive Hardware mode
        await engine.SetBitperfectModeAsync(true);
        Assert.True(engine.IsBitperfect);
        Assert.True(engine.IsExclusiveMode);
    }

    [Fact]
    public async Task ExclusiveMode_WhenDisabledWhileBitperfectActive_DisablesBitperfectMode()
    {
        using var engine = new WiretoneAudioEngine();

        await engine.SetBitperfectModeAsync(true);
        Assert.True(engine.IsBitperfect);
        Assert.True(engine.IsExclusiveMode);

        // Disabling Exclusive mode forces shared mixer, which voids bit-perfect playback
        await engine.SetExclusiveModeAsync(false);
        Assert.False(engine.IsExclusiveMode);
        Assert.False(engine.IsBitperfect);
    }

    [Fact]
    public async Task SeekAsync_UpdatesEnginePosition()
    {
        using var engine = new WiretoneAudioEngine();
        await engine.SeekAsync(TimeSpan.FromSeconds(42));
        Assert.Equal(TimeSpan.FromSeconds(42), engine.CurrentPosition);
    }
}
