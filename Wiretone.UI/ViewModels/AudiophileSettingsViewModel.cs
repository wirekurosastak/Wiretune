using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretone.Core.Audio;
using Wiretone.Core.Models;

namespace Wiretone.UI.ViewModels;

public partial class AudiophileSettingsViewModel : ObservableObject
{
    private readonly IAudioEngine _engine;

    [ObservableProperty] private bool _isExclusiveMode;
    [ObservableProperty] private bool _isBitperfect;
    [ObservableProperty] private AudioOutputDevice? _selectedDevice;
    [ObservableProperty] private string _signalPath = string.Empty;
    [ObservableProperty] private string _hardwareStatusText = string.Empty;
    [ObservableProperty] private int _selectedBufferSize = 128;

    public ObservableCollection<AudioOutputDevice> AvailableDevices { get; } = new();
    public List<int> BufferSizeOptions { get; } = new() { 64, 128, 256, 512, 1024 };

    private bool _isSyncingWithEngine;

    public AudiophileSettingsViewModel(IAudioEngine engine)
    {
        _engine = engine;

        IsExclusiveMode = _engine.IsExclusiveMode;
        IsBitperfect = _engine.IsBitperfect;
        SignalPath = _engine.SignalPathDescription;
        RefreshDevices();

        _engine.ExclusiveModeChanged += (_, exc) => Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            _isSyncingWithEngine = true;
            try
            {
                IsExclusiveMode = exc;
            }
            finally
            {
                _isSyncingWithEngine = false;
            }
            UpdateSignalPath();
        });

        _engine.BitperfectChanged += (_, bp) => Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            _isSyncingWithEngine = true;
            try
            {
                IsBitperfect = bp;
            }
            finally
            {
                _isSyncingWithEngine = false;
            }
            UpdateSignalPath();
        });

        _engine.TrackChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(UpdateSignalPath);
    }

    public void RefreshDevices()
    {
        AvailableDevices.Clear();
        foreach (var d in _engine.AvailableDevices)
        {
            AvailableDevices.Add(d);
        }

        SelectedDevice = _engine.CurrentDevice;
        UpdateSignalPath();
    }

    private void UpdateSignalPath()
    {
        SignalPath = _engine.SignalPathDescription;
        var dev = _engine.CurrentDevice;
        HardwareStatusText = dev != null
            ? $"{dev.Name} [{dev.DriverType}] - Támogatott mintavételezés: 44.1 kHz - 192 kHz (Lossless)"
            : "Nincs csatlakoztatott audio eszköz";
    }

    async partial void OnIsExclusiveModeChanged(bool value)
    {
        if (_isSyncingWithEngine) return;
        await _engine.SetExclusiveModeAsync(value);
    }

    async partial void OnIsBitperfectChanged(bool value)
    {
        if (_isSyncingWithEngine) return;
        await _engine.SetBitperfectModeAsync(value);
    }

    async partial void OnSelectedDeviceChanged(AudioOutputDevice? value)
    {
        if (value != null && value != _engine.CurrentDevice)
        {
            await _engine.SetOutputDeviceAsync(value);
            UpdateSignalPath();
        }
    }

    [RelayCommand]
    public async Task RefreshDevicesAsync()
    {
        await _engine.RefreshDevicesAsync();
        RefreshDevices();
    }
}
