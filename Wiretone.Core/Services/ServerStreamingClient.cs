using System.Net.Http.Json;
using Wiretone.Core.Models;

namespace Wiretone.Core.Services;

public class ServerStreamingClient
{
    private readonly HttpClient _httpClient;

    public ServerStreamingClient(HttpClient? httpClient = null)
    {
        _httpClient = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
    }

    public async Task<bool> PingServerAsync(string baseUrl, CancellationToken ct = default)
    {
        try
        {
            var url = $"{baseUrl.TrimEnd('/')}/api/library/status";
            var response = await _httpClient.GetAsync(url, ct);
            return response.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    public async Task<List<Track>> FetchTracksAsync(string baseUrl, CancellationToken ct = default)
    {
        var cleanBase = baseUrl.TrimEnd('/');
        var url = $"{cleanBase}/api/tracks";
        var tracks = await _httpClient.GetFromJsonAsync<List<Track>>(url, cancellationToken: ct) ?? new List<Track>();

        foreach (var t in tracks)
        {
            t.StreamUrl = $"{cleanBase}/api/stream/{t.Id}";
            t.CoverArtPath = $"{cleanBase}/api/cover/{t.Id}";
            t.HasCoverArt = true;
        }

        return tracks;
    }

    public string GetStreamUrl(string baseUrl, string trackId)
    {
        return $"{baseUrl.TrimEnd('/')}/api/stream/{trackId}";
    }

    public string GetCoverArtUrl(string baseUrl, string trackId)
    {
        return $"{baseUrl.TrimEnd('/')}/api/cover/{trackId}";
    }

    public async Task<bool> TriggerScanAsync(string baseUrl, string? path = null, CancellationToken ct = default)
    {
        try
        {
            var cleanBase = baseUrl.TrimEnd('/');
            var url = $"{cleanBase}/api/library/scan";
            if (!string.IsNullOrWhiteSpace(path))
            {
                url += $"?path={Uri.EscapeDataString(path)}";
            }
            var response = await _httpClient.PostAsync(url, null, ct);
            return response.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }
}
