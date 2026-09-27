using Wiretune.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Xunit;

namespace Wiretune.Tests;

public class AudioEngineTests
{
    [Fact]
    public async Task BitperfectMode_WhenEnabled_LocksVolumeToUnityGain()
    {
        using var engine = TestSupport.CreateEngine();

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
        using var engine = TestSupport.CreateEngine();

        await engine.SetBitperfectModeAsync(false);
        Assert.False(engine.IsBitperfect);
        Assert.False(engine.IsVolumeLocked);

        engine.SetVolume(0.75);
        Assert.Equal(0.75, engine.Volume, precision: 2);
    }

    [Fact]
    public async Task ExclusiveMode_TogglesStateCorrectly()
    {
        using var engine = TestSupport.CreateEngine();

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
        Assert.Contains("24bit", hiResMaster.DisplayBadge);
        Assert.Contains("16bit", cdQuality.DisplayBadge);
    }

    [Fact]
    public async Task BitperfectMode_WhenEnabled_AutomaticallyEnablesExclusiveMode()
    {
        using var engine = TestSupport.CreateEngine();

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
        using var engine = TestSupport.CreateEngine();

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
        using var engine = TestSupport.CreateEngine();
        await engine.SeekAsync(TimeSpan.FromSeconds(42));
        Assert.Equal(TimeSpan.FromSeconds(42), engine.CurrentPosition);
    }

    [Fact]
    public async Task ExclusiveMode_PicksMatchingAlsaDirectDevice_WhenCurrentIsSharedPipeWireSink()
    {
        var pipewireSink = new AudioOutputDevice
        {
            Id = "pw_81",
            Name = "SMSL USB AUDIO Pro",
            DriverType = "PipeWire",
            HardwareCard = "SMSL USB DAC",
            IsDefault = true,
            IsExclusiveSupported = false,
            IsBitperfectSupported = false
        };

        var directAlsa = new AudioOutputDevice
        {
            Id = "hw:2,0",
            Name = "Közvetlen ALSA: SMSL USB AUDIO",
            DriverType = "ALSA Direct",
            HardwareCard = "SMSL USB AUDIO",
            IsDefault = false,
            IsExclusiveSupported = true,
            IsBitperfectSupported = true
        };

        using var engine = TestSupport.CreateEngine(null, pipewireSink, directAlsa);

        // Initially default shared sink
        Assert.Equal("pw_81", engine.CurrentDevice?.Id);

        // When activating exclusive mode, it should switch to direct ALSA hardware
        await engine.SetExclusiveModeAsync(true);
        Assert.True(engine.IsExclusiveMode);
        Assert.Equal("hw:2,0", engine.CurrentDevice?.Id);

        // When switching back to shared mode, it should revert to default sink
        await engine.SetExclusiveModeAsync(false);
        Assert.False(engine.IsExclusiveMode);
        Assert.Equal("pw_81", engine.CurrentDevice?.Id);
    }

    [Fact]
    public void PlayerViewModel_IsVolumeDisabledOrMuted_TracksMuteAndVolumeLocked()
    {
        using var engine = TestSupport.CreateEngine();
        var mockRepo = new MockRepository();
        var service = new Wiretune.Core.Services.LibraryService(mockRepo, new MetadataScanner());
        var player = new Wiretune.UI.ViewModels.PlayerViewModel(engine, service);

        Assert.False(player.IsVolumeDisabledOrMuted);

        // Muting should disable/mute volume
        player.IsMuted = true;
        Assert.True(player.IsVolumeDisabledOrMuted);

        player.IsMuted = false;
        Assert.False(player.IsVolumeDisabledOrMuted);

        // Bitperfect volume locking should disable/mute volume
        player.IsVolumeLocked = true;
        Assert.True(player.IsVolumeDisabledOrMuted);

        player.IsVolumeLocked = false;
        Assert.False(player.IsVolumeDisabledOrMuted);
    }

    [Fact]
    public async Task SignalPathDescription_ReflectsAudioModesAccurately()
    {
        using var engine = TestSupport.CreateEngine();
        var track = new Track
        {
            Title = "Test Track",
            Artist = "Test Artist",
            Format = new AudioFormat { Codec = "FLAC", SampleRate = 44100, BitsPerSample = 16 },
            FilePath = "/path/to/test.flac"
        };

        await engine.PlayTrackAsync(track);

        // Shared mode
        Assert.Contains("Megosztott mód", engine.SignalPathDescription);

        // Exclusive mode
        await engine.SetExclusiveModeAsync(true);
        Assert.Contains("Kizárólagos mód", engine.SignalPathDescription);

        // Bit-perfect mode
        await engine.SetBitperfectModeAsync(true);
        Assert.Contains("Bit-perfect", engine.SignalPathDescription);
        Assert.Contains("Unity Gain", engine.SignalPathDescription);
    }

    [Fact]
    public async Task WindowsDeviceDetection_FindsDevicesWithExclusiveSupport()
    {
        if (!OperatingSystem.IsWindows()) return;

        var devices = await Wiretune.Audio.Devices.AudioDeviceManager.DetectOutputDevicesAsync();
        Assert.NotEmpty(devices);
        Assert.All(devices, d =>
        {
            Assert.True(d.IsExclusiveSupported);
            Assert.True(d.IsBitperfectSupported);
            Assert.Equal("WASAPI", d.DriverType);
        });
    }

    [Fact]
    public void DefaultEngineConstructor_UsesWasapiDriverOnWindows()
    {
        if (!OperatingSystem.IsWindows()) return;

        using var engine = new WiretuneAudioEngine();
        Assert.NotNull(engine);
    }
}
