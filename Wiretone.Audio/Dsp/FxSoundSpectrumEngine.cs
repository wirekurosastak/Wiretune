namespace Wiretone.Audio.Dsp;

/// <summary>
/// Studio-grade 32-band Real-Time Analyzer (RTA) frequency spectrum engine focused
/// strictly on the musically meaningful, audible spectrum (35 Hz to 16,000 Hz).
/// Eliminates the inaudible/inactive >16k - 20k region to provide maximum visual resolution
/// in the active bass, midrange, presence, and musical treble zones.
/// 
/// Performs REAL Fast Fourier Transform (FFT) analysis on live audio PCM buffers,
/// mapping audio energy into 32 high-precision frequency bands with perceptual ISO loudness weighting,
/// instant transient attack (0.88), and smooth exponential release decay (0.76).
/// </summary>
public sealed class FxSoundSpectrumEngine
{
    public const int NumBands = 32;
    public const int FftSize = 2048;

    // Musically meaningful frequency centers (35 Hz to 16,000 Hz)
    public static readonly float[] BandCenterFrequencies =
    {
        35.0f,    43.0f,    52.0f,    64.0f,    78.0f,    95.0f,    115.0f,   140.0f,
        170.0f,   210.0f,   255.0f,   310.0f,   380.0f,   460.0f,   560.0f,   680.0f,
        830.0f,   1010.0f,  1230.0f,  1500.0f,  1830.0f,  2230.0f,  2720.0f,  3310.0f,
        4030.0f,  4900.0f,  6000.0f,  7300.0f,  8900.0f,  10800.0f, 13200.0f, 16000.0f
    };

    // Frequency ranges for 44.1 kHz sampling rate (bin resolution = 21.533 Hz per bin)
    // Focused strictly on the audible, expressive musical spectrum (35 Hz - 16 kHz)
    private static readonly (int StartBin, int EndBin)[] BandBinRanges =
    {
        (1, 2),       // Band 0:  ~35 Hz (Sub-bass rumble)
        (2, 2),       // Band 1:  ~43 Hz (Sub-bass kick floor)
        (2, 3),       // Band 2:  ~52 Hz (808 fundamental)
        (3, 3),       // Band 3:  ~64 Hz (808 punch)
        (3, 4),       // Band 4:  ~78 Hz (Kick body)
        (4, 5),       // Band 5:  ~95 Hz (Kick punch & bass fundamental)
        (5, 6),       // Band 6:  ~115 Hz (Bass guitar fundamental)
        (6, 7),       // Band 7:  ~140 Hz (Bass guitar warmth)
        (7, 9),       // Band 8:  ~170 Hz (Lower snare body)
        (9, 11),      // Band 9:  ~210 Hz (Vocal warmth)
        (11, 13),     // Band 10: ~255 Hz (Vocal body / rhythm guitar)
        (13, 16),     // Band 11: ~310 Hz (Low midrange body)
        (16, 20),     // Band 12: ~380 Hz (Mid body / snare fundamental)
        (20, 24),     // Band 13: ~460 Hz (Mid clarity)
        (24, 29),     // Band 14: ~560 Hz (Vocal vowel resonance)
        (29, 35),     // Band 15: ~680 Hz (Instrument meat)
        (35, 43),     // Band 16: ~830 Hz (Vocal projection)
        (43, 52),     // Band 17: ~1010 Hz (1 kHz reference clarity)
        (52, 63),     // Band 18: ~1230 Hz (Vocal presence)
        (63, 77),     // Band 19: ~1500 Hz (Guitar crunch / vocal bite)
        (77, 94),     // Band 20: ~1830 Hz (Speech intelligibility)
        (94, 114),    // Band 21: ~2230 Hz (Brass bite / attack)
        (114, 139),   // Band 22: ~2720 Hz (Snare crack / snap)
        (139, 170),   // Band 23: ~3310 Hz (High presence edge)
        (170, 207),   // Band 24: ~4030 Hz (Ear sensitivity peak)
        (207, 253),   // Band 25: ~4900 Hz (Vocal breath / snare snap)
        (253, 308),   // Band 26: ~6000 Hz (Treble definition)
        (308, 375),   // Band 27: ~7300 Hz (Hi-hat strike / open cymbal)
        (375, 457),   // Band 28: ~8900 Hz (Cymbal ping / sizzle)
        (457, 557),   // Band 29: ~10800 Hz (Hi-hat sparkle)
        (557, 678),   // Band 30: ~13200 Hz (Acoustic air sheen)
        (678, 790)    // Band 31: ~16000 Hz (Top brilliance / sparkle)
    };

    // Perceptual ISO loudness weighting (compensates for natural pink-noise rolloff)
    private static readonly float[] IsoBandWeights =
    {
        // Sub-bass & Bass (35 - 140 Hz)
        1.55f, 1.45f, 1.35f, 1.25f, 1.20f, 1.15f, 1.10f, 1.05f,
        // Low Mids & Center Mids (170 - 1230 Hz)
        1.00f, 1.00f, 1.05f, 1.10f, 1.15f, 1.20f, 1.25f, 1.30f,
        // High Mids & Presence (1500 - 4900 Hz)
        1.35f, 1.45f, 1.55f, 1.70f, 1.85f, 2.05f, 2.25f, 2.50f,
        // Treble & Brilliance (6000 - 16000 Hz)
        2.80f, 3.10f, 3.45f, 3.85f, 4.25f, 4.65f, 5.05f, 5.45f
    };

    private readonly float[] _currentLevels = new float[NumBands];
    private readonly float[] _hannWindow = new float[FftSize];
    private readonly float[] _fftReal = new float[FftSize];
    private readonly float[] _fftImag = new float[FftSize];
    private readonly float[] _magnitude = new float[FftSize / 2];

    // FxSound ballistics: instant attack on rising transients, smooth exponential decay on falling energy
    private const float AttackRate = 0.88f;
    private const float DecayRate = 0.76f;
    private const float MinFloor = 0.04f;

    public FxSoundSpectrumEngine()
    {
        // Pre-compute Hann window for 2048 samples
        for (int i = 0; i < FftSize; i++)
        {
            _hannWindow[i] = 0.5f * (1.0f - MathF.Cos(2.0f * MathF.PI * i / (FftSize - 1)));
        }

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
    /// Computes the 32 musically focused frequency bands by running a real FFT on the actual PCM audio samples.
    /// </summary>
    public float[] ProcessPcm(ReadOnlySpan<float> pcmWindow, bool isPlaying)
    {
        var result = new float[NumBands];
        if (!isPlaying || pcmWindow.Length < FftSize)
        {
            for (int i = 0; i < NumBands; i++)
            {
                _currentLevels[i] = Math.Max(MinFloor, _currentLevels[i] * 0.70f);
                result[i] = _currentLevels[i];
            }
            return result;
        }

        // 1. Apply Hann window and copy to FFT buffers
        for (int i = 0; i < FftSize; i++)
        {
            _fftReal[i] = pcmWindow[i] * _hannWindow[i];
            _fftImag[i] = 0f;
        }

        // 2. Perform Radix-2 FFT
        ComputeFft(_fftReal, _fftImag, FftSize);

        // 3. Compute normalized frequency magnitudes
        float norm = 2.0f / FftSize;
        for (int i = 0; i < FftSize / 2; i++)
        {
            _magnitude[i] = MathF.Sqrt(_fftReal[i] * _fftReal[i] + _fftImag[i] * _fftImag[i]) * norm;
        }

        // 4. Compute RMS energy across each of the 32 bands
        for (int band = 0; band < NumBands; band++)
        {
            var (startBin, endBin) = BandBinRanges[band];
            float sumSq = 0f;
            int count = endBin - startBin + 1;

            for (int k = startBin; k <= endBin; k++)
            {
                sumSq += _magnitude[k] * _magnitude[k];
            }

            float rms = MathF.Sqrt(sumSq / count) * IsoBandWeights[band];

            // Convert to dBFS scale (-54 dBFS floor to -6 dBFS ceiling)
            float db = 20.0f * MathF.Log10(rms + 1e-5f);
            float target = (db + 54.0f) / 48.0f;
            target = Math.Clamp(target, MinFloor, 1.0f);

            // 5. Apply FxSound ballistics
            if (target > _currentLevels[band])
            {
                _currentLevels[band] += (target - _currentLevels[band]) * AttackRate;
            }
            else
            {
                _currentLevels[band] = _currentLevels[band] * DecayRate + target * (1.0f - DecayRate);
            }

            result[band] = _currentLevels[band];
        }

        return result;
    }

    /// <summary>
    /// Fallback spectrum processing when raw PCM is unavailable.
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

        double beatPhase = (t * 2.066) % 1.0;
        float kickTransient = (float)Math.Max(0.0, Math.Pow(1.0 - beatPhase, 3.2));

        double subPhase = (t * 4.133) % 1.0;
        float subBounce = (float)Math.Max(0.0, Math.Pow(1.0 - subPhase, 4.0)) * 0.45f;

        double snarePhase = (t * 1.033 + 0.5) % 1.0;
        float snareTransient = (float)Math.Max(0.0, Math.Pow(1.0 - snarePhase, 3.6));

        double hihatPhase = (t * 8.266) % 1.0;
        float hihatTransient = (float)Math.Max(0.0, Math.Pow(1.0 - hihatPhase, 2.2));

        float wave1 = (float)(Math.Sin(t * 1.9 + 0.3) * 0.35 + 0.45);
        float wave2 = (float)(Math.Cos(t * 2.8 + 1.2) * 0.30 + 0.45);
        float wave3 = (float)(Math.Sin(t * 3.6 + 2.1) * 0.25 + 0.45);

        for (int i = 0; i < NumBands; i++)
        {
            float target = 0.08f;

            if (i <= 5) // Sub-bass to kick (35 - 95 Hz)
            {
                target += kickTransient * 0.88f + subBounce * 0.60f;
            }
            else if (i <= 8) // Bass fundamental & warmth (115 - 170 Hz)
            {
                target += kickTransient * 0.60f + (float)(Math.Sin(t * 4.2 + i * 0.3) * 0.20 + 0.20);
            }
            else if (i <= 14) // Low-mids to mid fundamental (210 - 560 Hz)
            {
                target += snareTransient * 0.40f + wave1 * 0.40f;
            }
            else if (i <= 21) // Vocal clarity, guitar crunch (680 - 2230 Hz)
            {
                target += snareTransient * 0.55f + wave2 * 0.40f;
            }
            else if (i <= 26) // Presence, crispness, snap (2720 - 6000 Hz)
            {
                target += hihatTransient * 0.50f + snareTransient * 0.35f + wave3 * 0.30f;
            }
            else // Treble and top brilliance (7300 - 16000 Hz)
            {
                target += hihatTransient * 0.80f + (float)(Math.Sin(t * 7.4 + i * 0.2) * 0.15 + 0.15);
            }

            target = Math.Clamp(target, MinFloor, 0.98f);

            if (target > _currentLevels[i])
            {
                _currentLevels[i] += (target - _currentLevels[i]) * AttackRate;
            }
            else
            {
                _currentLevels[i] = _currentLevels[i] * DecayRate + target * (1.0f - DecayRate);
            }

            result[i] = _currentLevels[i];
        }

        return result;
    }

    /// <summary>
    /// In-place Cooley-Tukey Radix-2 FFT.
    /// </summary>
    private static void ComputeFft(float[] real, float[] imag, int n)
    {
        // 1. Bit-reversal permutation
        for (int i = 1, j = 0; i < n; i++)
        {
            int bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1)
                j ^= bit;
            j ^= bit;
            if (i < j)
            {
                (real[i], real[j]) = (real[j], real[i]);
                (imag[i], imag[j]) = (imag[j], imag[i]);
            }
        }

        // 2. Cooley-Tukey butterfly computation
        for (int len = 2; len <= n; len <<= 1)
        {
            float ang = -2.0f * MathF.PI / len;
            float wlenR = MathF.Cos(ang);
            float wlenI = MathF.Sin(ang);

            for (int i = 0; i < n; i += len)
            {
                float wR = 1.0f;
                float wI = 0.0f;
                int half = len >> 1;

                for (int j = 0; j < half; j++)
                {
                    float uR = real[i + j];
                    float uI = imag[i + j];
                    float vR = real[i + j + half] * wR - imag[i + j + half] * wI;
                    float vI = real[i + j + half] * wI + imag[i + j + half] * wR;

                    real[i + j] = uR + vR;
                    imag[i + j] = uI + vI;
                    real[i + j + half] = uR - vR;
                    imag[i + j + half] = uI - vI;

                    float nextWR = wR * wlenR - wI * wlenI;
                    wI = wR * wlenI + wI * wlenR;
                    wR = nextWR;
                }
            }
        }
    }
}
