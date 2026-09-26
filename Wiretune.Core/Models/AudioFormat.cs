using System.Text.Json.Serialization;

namespace Wiretune.Core.Models;

public record AudioFormat
{
    public string Codec { get; init; } = "FLAC";
    public int SampleRate { get; init; } = 44100;
    public int BitsPerSample { get; init; } = 16;
    public int Channels { get; init; } = 2;
    public int BitrateKbps { get; init; } = 1411;
    public bool IsLossless { get; init; } = true;

    [JsonIgnore]
    public bool IsHiRes => IsLossless && (SampleRate > 48000 || BitsPerSample > 16);

    [JsonIgnore]
    public string DisplayBadge => !IsLossless
        ? $"{Codec.ToUpperInvariant()} / {BitrateKbps}kbps"
        : $"{Codec.ToUpperInvariant()} / {BitsPerSample}bit / {(SampleRate / 1000.0).ToString("0.#", System.Globalization.CultureInfo.InvariantCulture)}kHz";

    [JsonIgnore]
    public string QualityLabel => !IsLossless
        ? $"{Codec.ToUpperInvariant()} • {BitrateKbps} kbps"
        : (SampleRate, BitsPerSample) switch
        {
            (>= 192000, >= 24) => "Ultra Hi-Res Studio Master (192kHz/24b)",
            (>= 96000, >= 24)  => "Hi-Res Studio Master (96kHz/24b)",
            (>= 88200, >= 24)  => "Hi-Res Audio (88.2kHz/24b)",
            (48000, >= 24)     => "Enhanced Studio (48kHz/24b)",
            (44100, >= 24)     => "Hi-Res 24-bit Lossless (44.1kHz/24b)",
            (44100, 16)        => "CD Quality Lossless (16-bit / 44.1 kHz)",
            _                  => $"{BitsPerSample}-bit / {SampleRate / 1000.0:0.#} kHz"
        };
}
