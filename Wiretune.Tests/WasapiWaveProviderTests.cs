using NAudio.Wave;
using Wiretune.Core.Audio.Dsp;
using Wiretune.Core.Audio.Drivers;
using Xunit;

namespace Wiretune.Tests;

/// <summary>
/// The WASAPI driver itself needs Windows, but the wave provider that applies the software volume and feeds the
/// spectrum analyser is plain byte arithmetic and can be checked anywhere.
/// </summary>
public class WasapiWaveProviderTests
{
    private sealed class FixedSource(WaveFormat format, byte[] data) : IWaveProvider
    {
        public WaveFormat WaveFormat => format;

        public int Read(byte[] buffer, int offset, int count)
        {
            var n = Math.Min(count, data.Length);
            Array.Copy(data, 0, buffer, offset, n);
            return n;
        }
    }

    private static WasapiAudioDriver.SpectrumAndVolumeWaveProvider Provider(WaveFormat format, byte[] data, double volume, bool bitperfect = false) =>
        new(new FixedSource(format, data), new FxSoundSpectrumEngine(), _ => { }) { Volume = volume, IsBitperfect = bitperfect };

    private static byte[] Read(WasapiAudioDriver.SpectrumAndVolumeWaveProvider provider, int length)
    {
        var buffer = new byte[length];
        Assert.Equal(length, provider.Read(buffer, 0, length));
        return buffer;
    }

    [Fact]
    public void Volume_Scales16BitSamples()
    {
        var input = BitConverter.GetBytes((short)32767).Concat(BitConverter.GetBytes((short)-32768)).ToArray();

        var output = Read(Provider(new WaveFormat(44100, 16, 1), input, 0.5), 4);

        Assert.Equal(16383, BitConverter.ToInt16(output, 0));
        Assert.Equal(-16384, BitConverter.ToInt16(output, 2));
    }

    [Fact]
    public void Volume_Scales24BitSamples_WhichHiResFlacDecodesTo()
    {
        static byte[] Pcm24(int value) => new[] { (byte)value, (byte)(value >> 8), (byte)(value >> 16) };
        var input = Pcm24(8388607).Concat(Pcm24(-8388608)).Concat(Pcm24(1000)).ToArray();

        var output = Read(Provider(new WaveFormat(96000, 24, 1), input, 0.5), 9);

        static int Sample24(byte[] b, int i) => b[i] | (b[i + 1] << 8) | ((sbyte)b[i + 2] << 16);
        Assert.Equal(4194303, Sample24(output, 0));
        Assert.Equal(-4194304, Sample24(output, 3));
        Assert.Equal(500, Sample24(output, 6));
    }

    [Fact]
    public void Volume_Scales32BitIntegerSamples()
    {
        var input = BitConverter.GetBytes(int.MaxValue).Concat(BitConverter.GetBytes(int.MinValue)).ToArray();

        var output = Read(Provider(new WaveFormat(192000, 32, 1), input, 0.5), 8);

        Assert.Equal(1073741823, BitConverter.ToInt32(output, 0));
        Assert.Equal(-1073741824, BitConverter.ToInt32(output, 4));
    }

    [Fact]
    public void Volume_ScalesFloatSamples()
    {
        var input = BitConverter.GetBytes(1.0f).Concat(BitConverter.GetBytes(-0.5f)).ToArray();

        var output = Read(Provider(WaveFormat.CreateIeeeFloatWaveFormat(48000, 1), input, 0.5), 8);

        Assert.Equal(0.5f, BitConverter.ToSingle(output, 0));
        Assert.Equal(-0.25f, BitConverter.ToSingle(output, 4));
    }

    [Fact]
    public void FullVolume_AndBitPerfectMode_LeaveTheSamplesUntouched()
    {
        var input = BitConverter.GetBytes(12345).Concat(BitConverter.GetBytes(-54321)).ToArray();
        var format = new WaveFormat(96000, 32, 1);

        Assert.Equal(input, Read(Provider(format, input, 1.0), 8));
        Assert.Equal(input, Read(Provider(format, input, 0.3, bitperfect: true), 8));
    }

    private static int LoudestBand(int sampleRate, double toneHz)
    {
        float[] bands = new float[FxSoundSpectrumEngine.NumBands];
        var frames = 8192;
        var data = new byte[frames * 2];
        for (var i = 0; i < frames; i++)
        {
            var sample = (short)(Math.Sin(2 * Math.PI * toneHz * i / sampleRate) * 20000);
            BitConverter.TryWriteBytes(new Span<byte>(data, i * 2, 2), sample);
        }

        var provider = new WasapiAudioDriver.SpectrumAndVolumeWaveProvider(
            new FixedSource(new WaveFormat(sampleRate, 16, 1), data), new FxSoundSpectrumEngine(), b => bands = b);
        Read(provider, data.Length);
        for (var i = 0; i < 5; i++) provider.RenderSpectrum(); // let the analyser's smoothing settle

        return Array.IndexOf(bands, bands.Max());
    }

    [Fact]
    public void Spectrum_PutsTheSameToneInTheSameBand_AtEverySampleRate()
    {
        var at44 = LoudestBand(44100, 5000);
        var at96 = LoudestBand(96000, 5000);
        var at192 = LoudestBand(192000, 5000);

        Assert.InRange(Math.Abs(at96 - at44), 0, 1);
        Assert.InRange(Math.Abs(at192 - at44), 0, 1);
    }
}
