using Wiretone.Audio.Dsp;
using Xunit;

namespace Wiretone.Tests;

public class FxSoundSpectrumEngineTests
{
    [Fact]
    public void ProcessFrame_Returns10Bands_WithValidNormalizedLevels()
    {
        var engine = new FxSoundSpectrumEngine();
        var bands = engine.ProcessFrame(TimeSpan.FromSeconds(1.0), true);

        Assert.NotNull(bands);
        Assert.Equal(FxSoundSpectrumEngine.NumBands, bands.Length);
        Assert.Equal(10, bands.Length);

        for (int i = 0; i < bands.Length; i++)
        {
            Assert.True(bands[i] >= 0.04f && bands[i] <= 1.0f, $"Band {i} level {bands[i]} was out of bounds");
        }
    }

    [Fact]
    public void ProcessFrame_DynamicResponseAcross10Frequencies()
    {
        var engine = new FxSoundSpectrumEngine();
        
        // Simulate 1 second of audio frames (30 frames at ~33ms intervals)
        float maxBass = 0f;
        float maxMid = 0f;
        float maxTreble = 0f;

        for (int frame = 0; frame < 30; frame++)
        {
            var bands = engine.ProcessFrame(TimeSpan.FromMilliseconds(frame * 33), true);
            maxBass = Math.Max(maxBass, bands[0]);   // 56Hz Sub-bass
            maxMid = Math.Max(maxMid, bands[4]);     // 562Hz Midrange
            maxTreble = Math.Max(maxTreble, bands[9]); // 10kHz Brilliance
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

        // Synthesize pure 100 Hz tone (Band 1 center)
        for (int i = 0; i < pcm.Length; i++)
        {
            pcm[i] = 0.8f * MathF.Sin(2.0f * MathF.PI * 100.0f * i / 44100.0f);
        }

        var bands = engine.ProcessPcm(pcm, true);

        Assert.NotNull(bands);
        Assert.Equal(10, bands.Length);

        // Band 1 (100 Hz) should have very high response
        Assert.True(bands[1] > 0.40f, $"Band 1 (100Hz) should be strongly activated by 100Hz tone, was {bands[1]}");

        // High frequency bands (Band 8: 5.6kHz, Band 9: 10kHz) should remain at baseline floor
        Assert.True(bands[8] < 0.15f, $"Band 8 (5.6kHz) should not respond to 100Hz bass, was {bands[8]}");
        Assert.True(bands[9] < 0.15f, $"Band 9 (10kHz) should not respond to 100Hz bass, was {bands[9]}");
    }

    [Fact]
    public void ProcessPcm_1000HzMidTone_ActivatesMidBandSpecifically()
    {
        var engine = new FxSoundSpectrumEngine();
        float[] pcm = new float[FxSoundSpectrumEngine.FftSize];

        // Synthesize pure 1000 Hz tone (Band 5 center)
        for (int i = 0; i < pcm.Length; i++)
        {
            pcm[i] = 0.8f * MathF.Sin(2.0f * MathF.PI * 1000.0f * i / 44100.0f);
        }

        var bands = engine.ProcessPcm(pcm, true);

        Assert.NotNull(bands);
        Assert.Equal(10, bands.Length);

        // Band 5 (1000 Hz) should be strongly activated
        Assert.True(bands[5] > 0.40f, $"Band 5 (1kHz) should be strongly activated by 1000Hz tone, was {bands[5]}");

        // Low bass (Band 0: 56Hz) should remain low
        Assert.True(bands[0] < 0.15f, $"Band 0 (56Hz) should not respond to 1kHz tone, was {bands[0]}");
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
