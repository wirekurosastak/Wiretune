using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Wiretune.Core.Models;

namespace Wiretune.Audio.Devices;

public static class AudioDeviceManager
{
    public static async Task<List<AudioOutputDevice>> DetectOutputDevicesAsync()
    {
        return await Task.Run(() =>
        {
            var devices = new List<AudioOutputDevice>();

            if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
            {
                devices.AddRange(DetectLinuxAlsaAndPipeWireDevices());
            }
            else if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                devices.AddRange(DetectWindowsAudioDevices());
            }

            if (devices.Count == 0)
            {
                devices.Add(new AudioOutputDevice
                {
                    Id = "default",
                    Name = "Alapértelmezett audio kimenet",
                    DriverType = "Default",
                    IsDefault = true,
                    IsExclusiveSupported = false,
                    IsBitperfectSupported = false
                });
            }

            return devices;
        });
    }

    private static List<AudioOutputDevice> DetectLinuxAlsaAndPipeWireDevices()
    {
        var list = new List<AudioOutputDevice>();

        // 1. Check for PipeWire default / sinks via wpctl
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "wpctl",
                Arguments = "status",
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var proc = Process.Start(psi);
            if (proc != null)
            {
                var output = proc.StandardOutput.ReadToEnd();
                proc.WaitForExit(1000);

                var lines = output.Split('\n');
                bool inSinks = false;

                foreach (var line in lines)
                {
                    if (line.Contains("Sinks:"))
                    {
                        inSinks = true;
                        continue;
                    }
                    if (inSinks && (line.Contains("Sources:") || line.Contains("Filters:") || line.Contains("Streams:")))
                    {
                        break;
                    }

                    if (inSinks && line.Contains('.'))
                    {
                        var match = Regex.Match(line, @"(?:(?<default>\*)\s+)?(?<id>\d+)\.\s+(?<name>[^\[]+)(?:\[vol:\s*(?<vol>[^\]]+)\])?");
                        if (match.Success)
                        {
                            var id = match.Groups["id"].Value.Trim();
                            var name = match.Groups["name"].Value.Trim();
                            var isDefault = match.Groups["default"].Success;

                            list.Add(new AudioOutputDevice
                            {
                                Id = $"pw_{id}",
                                Name = name,
                                DriverType = "PipeWire",
                                HardwareCard = name.Contains("SMSL") ? "SMSL USB DAC" : "PipeWire Sink",
                                IsDefault = isDefault,
                                IsExclusiveSupported = true,
                                IsBitperfectSupported = true,
                                SupportedSampleRates = new() { 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000 }
                            });
                        }
                    }
                }
            }
        }
        catch
        {
            // wpctl not available
        }

        // 2. Check for ALSA direct hardware devices via aplay -l
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "aplay",
                Arguments = "-l",
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            psi.EnvironmentVariables["LC_ALL"] = "C"; // Force English output for regex parsing
            using var proc = Process.Start(psi);
            if (proc != null)
            {
                var output = proc.StandardOutput.ReadToEnd();
                proc.WaitForExit(1000);

                // Example: card 2: AUDIO [SMSL USB AUDIO], device 0: USB Audio [USB Audio]
                var matches = Regex.Matches(output, @"card\s+(?<card>\d+):\s+(?<cardName>[^,]+),\s+device\s+(?<dev>\d+):\s+(?<devName>[^\[]+)\[(?<fullName>[^\]]+)\]");
                foreach (Match m in matches)
                {
                    var card = m.Groups["card"].Value;
                    var dev = m.Groups["dev"].Value;
                    var fullName = m.Groups["fullName"].Value.Trim();
                    var cardName = m.Groups["cardName"].Value.Trim();

                    list.Add(new AudioOutputDevice
                    {
                        Id = $"hw:{card},{dev}",
                        Name = $"Közvetlen ALSA: {fullName}",
                        DriverType = "ALSA Direct",
                        HardwareCard = $"hw:{card},{dev} ({cardName})",
                        IsDefault = false,
                        IsExclusiveSupported = true,
                        IsBitperfectSupported = true,
                        SupportedSampleRates = new() { 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000 }
                    });
                }
            }
        }
        catch
        {
            // aplay not available
        }

        // If no default was detected from PipeWire, mark the first device as default
        if (list.Count > 0 && !list.Any(d => d.IsDefault))
        {
            list[0] = list[0] with { IsDefault = true };
        }

        return list;
    }

    private static List<AudioOutputDevice> DetectWindowsAudioDevices()
    {
        // ffplay (SDL) only reaches the shared Windows mixer; exclusive/bit-perfect output is not available here.
        return new List<AudioOutputDevice>
        {
            new AudioOutputDevice
            {
                Id = "wasapi_default",
                Name = "Windows alapértelmezett kimenet",
                DriverType = "WASAPI Shared",
                IsDefault = true,
                IsExclusiveSupported = false,
                IsBitperfectSupported = false
            }
        };
    }
}
