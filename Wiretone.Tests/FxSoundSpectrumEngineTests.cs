using Wiretone.Audio.Dsp;
using Xunit;

namespace Wiretone.Tests;

public class FxSoundSpectrumEngineTests
{
    [Fact]
    public void ProcessFrame_Returns16Bands_WithValidNormalizedLevels()
    {
        var engine = new FxSoundSpectrumEngine();
        var bands = engine.ProcessFrame(TimeSpan.FromSeconds(1.0), true);

        Assert.NotNull(bands);
        Assert.Equal(16, bands.Length);

        for (int i = 0; i < bands.Length; i++)
        {
            Assert.True(bands[i] >= 0.05f && bands[i] <= 1.0f, $"Band {i} level {bands[i]} was out of bounds");
        }
    }

    [Fact]
    public void ProcessFrame_DynamicResponseAcrossFrequencies()
    {
        var engine = new FxSoundSpectrumEngine();
        
        // Simulate 1 second of audio frames (30 frames at ~33ms intervals)
        float maxBass = 0f;
        float maxMid = 0f;
        float maxTreble = 0f;

        for (int frame = 0; frame < 30; frame++)
        {
            var bands = engine.ProcessFrame(TimeSpan.FromMilliseconds(frame * 33), true);
            maxBass = Math.Max(maxBass, bands[0]);
            maxMid = Math.Max(maxMid, bands[7]);
            maxTreble = Math.Max(maxTreble, bands[14]);
        }

        // Bass, mids, and treble should all show active dynamic engagement (> 0.35)
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
            Assert.True(stoppedBands[i] <= 0.12f, $"Band {i} did not decay down to floor level, was {stoppedBands[i]}");
        }
    }
}
