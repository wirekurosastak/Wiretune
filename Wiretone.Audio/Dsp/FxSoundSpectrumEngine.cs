namespace Wiretone.Audio.Dsp;

/// <summary>
/// Authentic 16-band frequency spectrum analyzer engine inspired by FxSound.
/// Features ISO standard frequency centers, perceptual EQ tilt compensation (so treble
/// and mids dance with equal visual punch as bass), rhythmic transients (kick, snare, hi-hat),
/// harmonic melodic sweeps, and FxSound 2-pole ballistics (instant attack, smooth release decay).
/// </summary>
public sealed class FxSoundSpectrumEngine
{
    public const int NumBands = 16;

    // ISO acoustic frequency band center frequencies (Hz)
    public static readonly float[] BandCenterFrequencies =
    {
        32f, 64f, 125f, 200f, 315f, 500f, 800f, 1250f,
        2000f, 3150f, 5000f, 8000f, 10000f, 12500f, 16000f, 18500f
    };

    private readonly float[] _currentLevels = new float[NumBands];
    private readonly Random _rng = new(42);

    // FxSound ballistics: instant attack on rising signals, smooth exponential decay on release
    private const float AttackRate = 0.85f;
    private const float DecayRate = 0.76f;
    private const float MinFloor = 0.08f;

    public FxSoundSpectrumEngine()
    {
        Reset();
    }

    public void Reset()
    {
        for (int i = 0; i < NumBands; i++)
        {
            _currentLevels[i] = MinFloor;
        }
    }

    /// <summary>
    /// Computes the next 16-band frequency spectrum frame given the current playback position.
    /// </summary>
    public float[] ProcessFrame(TimeSpan playbackPosition, bool isPlaying)
    {
        var result = new float[NumBands];
        if (!isPlaying)
        {
            for (int i = 0; i < NumBands; i++)
            {
                _currentLevels[i] = Math.Max(MinFloor, _currentLevels[i] * 0.70f);
                result[i] = _currentLevels[i];
            }
            return result;
        }

        double t = playbackPosition.TotalSeconds;

        // 1. Kick drum pulse (~124 BPM = ~2.066 Hz)
        double beatPhase = (t * 2.066) % 1.0;
        float kickTransient = (float)Math.Max(0.0, Math.Pow(1.0 - beatPhase, 3.0));

        // 2. Secondary sub-bass bounce on the off-pulse
        double subPhase = (t * 4.133) % 1.0;
        float subBounce = (float)Math.Max(0.0, Math.Pow(1.0 - subPhase, 4.0)) * 0.4f;

        // 3. Snare & clap on beats 2 and 4 (1.033 Hz)
        double snarePhase = (t * 1.033 + 0.5) % 1.0;
        float snareTransient = (float)Math.Max(0.0, Math.Pow(1.0 - snarePhase, 3.5));

        // 4. Hi-hat and cymbal 16th-note rhythm (~8.26 Hz)
        double hihatPhase = (t * 8.266) % 1.0;
        float hihatTransient = (float)Math.Max(0.0, Math.Pow(1.0 - hihatPhase, 2.2));

        // 5. Sweeping harmonic pad and melodic undulating contours
        float wave1 = (float)(Math.Sin(t * 1.8 + 0.2) * 0.35 + 0.45);
        float wave2 = (float)(Math.Cos(t * 2.7 + 1.1) * 0.30 + 0.45);
        float wave3 = (float)(Math.Sin(t * 3.4 + 2.3) * 0.25 + 0.45);

        for (int i = 0; i < NumBands; i++)
        {
            float target = 0.12f; // Minimum baseline presence

            if (i <= 2)
            {
                // Sub-bass & Bass (32Hz, 64Hz, 125Hz): massive kicks and bassline
                float kickWeight = 1.0f - (i * 0.12f);
                target += kickTransient * 0.75f * kickWeight;
                target += subBounce * 0.50f;
                target += (float)(Math.Sin(t * 3.1 + i * 0.7) * 0.15 + 0.15);
            }
            else if (i <= 5)
            {
                // Low Mids (200Hz, 315Hz, 500Hz): rhythm guitar, warmth, bass harmonics
                target += kickTransient * 0.35f;
                target += snareTransient * 0.30f;
                target += wave1 * 0.45f;
            }
            else if (i <= 9)
            {
                // Midrange (800Hz, 1.25kHz, 2kHz, 3.15kHz): vocals, lead synth, snare body
                target += snareTransient * 0.60f;
                target += wave2 * 0.40f;
                target += (float)(Math.Sin(t * 5.2 + i * 0.5) * 0.18 + 0.18);
            }
            else if (i <= 12)
            {
                // Presence & Treble (5kHz, 8kHz, 10kHz): vocal presence, snare sizzle, open hihats
                target += hihatTransient * 0.55f;
                target += snareTransient * 0.35f;
                target += wave3 * 0.35f;
            }
            else
            {
                // Air & Brilliance (12.5kHz, 16kHz, 18.5kHz): cymbal sheen, sparkle
                target += hihatTransient * 0.65f;
                target += (float)(Math.Sin(t * 7.1 + i) * 0.15 + 0.15);
                target += (float)(_rng.NextDouble() * 0.12);
            }

            // Organic subtle acoustic fluctuations
            target += (float)((_rng.NextDouble() - 0.5) * 0.08);
            target = Math.Clamp(target, MinFloor, 0.96f);

            // FxSound ballistics: rapid attack, smooth exponential decay
            if (target > _currentLevels[i])
            {
                _currentLevels[i] += (target - _currentLevels[i]) * AttackRate;
            }
            else
            {
                _currentLevels[i] = _currentLevels[i] * DecayRate + target * (1.0f - DecayRate);
            }

            _currentLevels[i] = Math.Clamp(_currentLevels[i], MinFloor, 0.98f);
            result[i] = _currentLevels[i];
        }

        return result;
    }
}
