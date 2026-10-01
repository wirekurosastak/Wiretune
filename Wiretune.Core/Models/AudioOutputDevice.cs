using Wiretune.Core.Localization;

namespace Wiretune.Core.Models;

public record AudioOutputDevice
{
    public string Id { get; init; } = "default";

    /// <summary>
    /// Name shown to the user. Devices without an explicit name get a translated "default output" text that is
    /// looked up when read, so it follows the interface language (see <see cref="NameKey"/>).
    /// </summary>
    public string Name
    {
        get => _name ?? Localizer.Get(NameKey ?? "AudioSystemDefaultOutput");
        init => _name = value;
    }

    /// <summary>Key of the translated name to use when <see cref="Name"/> was not set.</summary>
    public string? NameKey { get; init; }

    private readonly string? _name;

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
