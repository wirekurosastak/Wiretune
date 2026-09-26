using System;
using System.Collections.Generic;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using Wiretune.Core.Models;

namespace Wiretune.UI.ViewModels;

/// <summary>
/// ViewModel representing a playlist card tile in the playlists view.
/// Generates a 2x2 collage of distinct album covers from the playlist's tracks.
/// </summary>
public class PlaylistCardViewModel : ObservableObject
{
    public Playlist Playlist { get; }
    public string Name => Playlist.Name;
    public int TrackCount => Playlist.TrackCount;
    public string FormatBadge => Playlist.FormatBadge;

    public string? Cover0 { get; }
    public string? Cover1 { get; }
    public string? Cover2 { get; }
    public string? Cover3 { get; }

    public bool HasCovers { get; }
    public bool HasSingleCover { get; }
    public bool HasMultipleCovers { get; }
    public string? SingleCoverPath { get; }

    public PlaylistCardViewModel(Playlist playlist, IReadOnlyList<Track> tracks)
    {
        Playlist = playlist;

        // Distinct covers across tracks, grouping by album/artist so duplicates from the same album are skipped
        var distinctTracks = tracks
            .Where(t => !string.IsNullOrWhiteSpace(t.CoverArtPath))
            .DistinctBy(t => string.IsNullOrWhiteSpace(t.Album) ? t.CoverArtPath : $"{t.Album}||{t.EffectiveAlbumArtist}")
            .ToList();

        var distinctCovers = distinctTracks
            .Select(t => t.CoverArtPath!)
            .Distinct()
            .ToList();

        if (distinctCovers.Count == 0)
        {
            HasCovers = false;
            HasSingleCover = false;
            HasMultipleCovers = false;
        }
        else if (distinctCovers.Count == 1)
        {
            HasCovers = true;
            HasSingleCover = true;
            HasMultipleCovers = false;
            SingleCoverPath = distinctCovers[0];
            Cover0 = distinctCovers[0];
            Cover1 = distinctCovers[0];
            Cover2 = distinctCovers[0];
            Cover3 = distinctCovers[0];
        }
        else
        {
            HasCovers = true;
            HasSingleCover = false;
            HasMultipleCovers = true;

            Cover0 = distinctCovers[0];
            Cover1 = distinctCovers[1];

            if (distinctCovers.Count == 2)
            {
                // When only 2 albums are available, fill all 4 slots by repeating
                Cover2 = distinctCovers[1];
                Cover3 = distinctCovers[0];
            }
            else if (distinctCovers.Count == 3)
            {
                Cover2 = distinctCovers[2];
                Cover3 = distinctCovers[0];
            }
            else
            {
                Cover2 = distinctCovers[2];
                Cover3 = distinctCovers[3];
            }
        }
    }
}
