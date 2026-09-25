namespace Wiretune.Core.Models;

public record AudioOutputDevice
{
    public string Id { get; init; } = "default";
    public string Name { get; init; } = "Rendszer alapértelmezett kimenet";
    public string Description { get; init; } = string.Empty;
    public string DriverType { get; init; } = "PipeWire"; // ALSA, PipeWire, WASAPI, Android
    public string HardwareCard { get; init; } = string.Empty;
    public bool IsExclusiveSupported { get; init; } = true;
    public bool IsBitperfectSupported { get; init; } = true;
    public bool IsDefault { get; init; }
    public List<int> SupportedSampleRates { get; init; } = new() { 44100, 48000, 88200, 96000, 176400, 192000 };
    public List<int> SupportedBitDepths { get; init; } = new() { 16, 24, 32 };

    public string DisplayTitle => string.IsNullOrWhiteSpace(HardwareCard)
        ? Name
        : $"{Name} ({HardwareCard})";
}
