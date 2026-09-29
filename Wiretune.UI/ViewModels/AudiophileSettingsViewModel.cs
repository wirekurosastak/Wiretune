using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class AudiophileSettingsViewModel : ObservableObject
{
    private readonly WiretuneAudioEngine _engine;
    private bool _isSyncingWithEngine;

    [ObservableProperty] private bool _isExclusiveMode;
    [ObservableProperty] private bool _isBitperfect;
    [ObservableProperty] private bool _isExclusiveAvailable;
    [ObservableProperty] private bool _isBitperfectAvailable;
    [ObservableProperty] private AudioOutputDevice? _selectedDevice;
    [ObservableProperty] private string _signalPath = string.Empty;
    [ObservableProperty] private string _hardwareStatusText = string.Empty;

    public ObservableCollection<AudioOutputDevice> AvailableDevices { get; } = new();

    public AudiophileSettingsViewModel(WiretuneAudioEngine engine)
    {
        _engine = engine;

        _engine.ExclusiveModeChanged += (_, _) => Ui.Post(SyncWithEngine);
        _engine.BitperfectChanged += (_, _) => Ui.Post(SyncWithEngine);
        _engine.DevicesChanged += (_, _) => Ui.Post(RefreshDevices);
        _engine.TrackChanged += (_, _) => Ui.Post(UpdateSignalPath);

        RefreshDevices();
    }

    public void RefreshDevices()
    {
        _isSyncingWithEngine = true;
        try
        {
            AvailableDevices.Clear();
            foreach (var d in _engine.AvailableDevices) AvailableDevices.Add(d);
            SelectedDevice = AvailableDevices.FirstOrDefault(d => d.Id == _engine.CurrentDevice?.Id);
        }
        finally
        {
            _isSyncingWithEngine = false;
        }

        IsExclusiveAvailable = AvailableDevices.Any(d => d.IsExclusiveSupported);
        IsBitperfectAvailable = AvailableDevices.Any(d => d.IsBitperfectSupported && d.IsExclusiveSupported);
        SyncWithEngine();
    }

    private void SyncWithEngine()
    {
        _isSyncingWithEngine = true;
        try
        {
            IsExclusiveMode = _engine.IsExclusiveMode;
            IsBitperfect = _engine.IsBitperfect;
            SelectedDevice = AvailableDevices.FirstOrDefault(d => d.Id == _engine.CurrentDevice?.Id) ?? SelectedDevice;
        }
        finally
        {
            _isSyncingWithEngine = false;
        }
        UpdateSignalPath();
    }

    private void UpdateSignalPath()
    {
        SignalPath = _engine.SignalPathDescription;
        var dev = _engine.CurrentDevice;
        if (dev == null)
        {
            HardwareStatusText = "Nincs elérhető audio kimenet";
            return;
        }

        var rates = dev.SupportedSampleRates.Count > 0
            ? $"{dev.SupportedSampleRates.Min() / 1000.0:0.#}–{dev.SupportedSampleRates.Max() / 1000.0:0.#} kHz"
            : "ismeretlen";
        var modes = dev.IsBitperfectSupported ? "exclusive / bit-perfect támogatott" : "csak megosztott mód";
        HardwareStatusText = $"{dev.Name} [{dev.DriverType}] • {rates} • {modes}";
    }

    partial void OnIsExclusiveModeChanged(bool value)
    {
        if (!_isSyncingWithEngine) Ui.Forget(_engine.SetExclusiveModeAsync(value), "AudiophileSettings");
    }

    partial void OnIsBitperfectChanged(bool value)
    {
        if (!_isSyncingWithEngine) Ui.Forget(_engine.SetBitperfectModeAsync(value), "AudiophileSettings");
    }

    partial void OnSelectedDeviceChanged(AudioOutputDevice? value)
    {
        if (_isSyncingWithEngine || value == null || value.Id == _engine.CurrentDevice?.Id) return;
        Ui.Forget(ApplyDeviceAsync(value), "AudiophileSettings");
    }

    private async Task ApplyDeviceAsync(AudioOutputDevice device)
    {
        await _engine.SetOutputDeviceAsync(device);
        Ui.Post(SyncWithEngine);
    }

    [RelayCommand]
    public async Task RefreshDevicesAsync()
    {
        await _engine.RefreshDevicesAsync();
        RefreshDevices();
    }
}


