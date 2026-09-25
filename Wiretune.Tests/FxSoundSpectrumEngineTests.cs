using Wiretune.Audio.Dsp;
using Xunit;

namespace Wiretune.Tests;

public class FxSoundSpectrumEngineTests
{
    [Fact]
    public void ProcessFrame_Returns32Bands_WithValidNormalizedLevels()
    {
        var engine = new FxSoundSpectrumEngine();
        var bands = engine.ProcessFrame(TimeSpan.FromSeconds(1.0), true);

        Assert.NotNull(bands);
        Assert.Equal(FxSoundSpectrumEngine.NumBands, bands.Length);
        Assert.Equal(32, bands.Length);

        for (int i = 0; i < bands.Length; i++)
        {
            Assert.True(bands[i] >= 0.04f && bands[i] <= 1.0f, $"Band {i} level {bands[i]} was out of bounds");
        }
    }

    [Fact]
    public void ProcessFrame_DynamicResponseAcross32Frequencies()
    {
        var engine = new FxSoundSpectrumEngine();
        
        // Simulate 1 second of audio frames (30 frames at ~33ms intervals)
        float maxBass = 0f;
        float maxMid = 0f;
        float maxTreble = 0f;

        for (int frame = 0; frame < 30; frame++)
        {
            var bands = engine.ProcessFrame(TimeSpan.FromMilliseconds(frame * 33), true);
            maxBass = Math.Max(maxBass, bands[2]);    // 52Hz Sub-bass
            maxMid = Math.Max(maxMid, bands[17]);    // 1010Hz Midrange
            maxTreble = Math.Max(maxTreble, bands[29]); // 10.8kHz Brilliance
        }

        Assert.True(maxBass > 0.35f, $"Max bass {maxBass} should show energetic response");
        Assert.True(maxMid > 0.35f, $"Max mid {maxMid} should show energetic response");
        Assert.True(maxTreble > 0.35f, $"Max treble {maxTreble} should show energetic response");
    }

    [Fact]
    public void ProcessFrame_WhenStopped_DecaysSmoothlyToMinimum()
    {
        var engine = new FxSoundSpectrumEngine();

        // Run while playing to build up levels
        engine.ProcessFrame(TimeSpan.FromSeconds(0.5), true);
        var activeBands = engine.ProcessFrame(TimeSpan.FromSeconds(1.0), true);

        // Process frames while stopped
        float[] stoppedBands = activeBands;
        for (int i = 0; i < 20; i++)
        {
            stoppedBands = engine.ProcessFrame(TimeSpan.FromSeconds(1.0), false);
        }

        for (int i = 0; i < stoppedBands.Length; i++)
        {
            Assert.True(stoppedBands[i] <= 0.10f, $"Band {i} did not decay down to floor level, was {stoppedBands[i]}");
        }
    }

    [Fact]
    public void ProcessPcm_100HzBassTone_ActivatesBassBandsSpecifically()
    {
        var engine = new FxSoundSpectrumEngine();
        float[] pcm = new float[FxSoundSpectrumEngine.FftSize];

        // Synthesize pure 100 Hz tone (Bands 5 and 6 center = 95 Hz and 115 Hz)
        for (int i = 0; i < pcm.Length; i++)
        {
            pcm[i] = 0.8f * MathF.Sin(2.0f * MathF.PI * 100.0f * i / 44100.0f);
        }

        var bands = engine.ProcessPcm(pcm, true);

        Assert.NotNull(bands);
        Assert.Equal(32, bands.Length);

        // Band 5 (95 Hz) or Band 6 (115 Hz) should have very high response
        float bassPeak = Math.Max(bands[5], bands[6]);
        Assert.True(bassPeak > 0.40f, $"Bass bands around 100Hz should be strongly activated, was {bassPeak}");

        // High frequency bands (Band 29: 10.8kHz, Band 31: 16kHz) should remain at baseline floor
        Assert.True(bands[29] < 0.15f, $"Band 29 (10.8kHz) should not respond to 100Hz bass, was {bands[29]}");
        Assert.True(bands[31] < 0.15f, $"Band 31 (16kHz) should not respond to 100Hz bass, was {bands[31]}");
    }

    [Fact]
    public void ProcessPcm_1000HzMidTone_ActivatesMidBandSpecifically()
    {
        var engine = new FxSoundSpectrumEngine();
        float[] pcm = new float[FxSoundSpectrumEngine.FftSize];

        // Synthesize pure 1000 Hz tone (Band 17 center = 1010 Hz)
        for (int i = 0; i < pcm.Length; i++)
        {
            pcm[i] = 0.8f * MathF.Sin(2.0f * MathF.PI * 1000.0f * i / 44100.0f);
        }

        var bands = engine.ProcessPcm(pcm, true);

        Assert.NotNull(bands);
        Assert.Equal(32, bands.Length);

        // Band 17 (1010 Hz) should be strongly activated
        Assert.True(bands[17] > 0.40f, $"Band 17 (1010Hz) should be strongly activated by 1000Hz tone, was {bands[17]}");

        // Low sub-bass (Band 0: 35Hz) should remain low
        Assert.True(bands[0] < 0.15f, $"Band 0 (35Hz) should not respond to 1kHz tone, was {bands[0]}");
    }

    [Fact]
    public void ProcessPcm_Silence_StaysAtRestingFloor()
    {
        var engine = new FxSoundSpectrumEngine();
        float[] silence = new float[FxSoundSpectrumEngine.FftSize];

        var bands = engine.ProcessPcm(silence, true);

        for (int i = 0; i < bands.Length; i++)
        {
            Assert.True(bands[i] <= 0.08f, $"Band {i} should remain at resting floor during silence, was {bands[i]}");
        }
    }
}
