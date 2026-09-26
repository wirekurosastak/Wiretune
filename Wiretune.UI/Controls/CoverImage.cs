using Avalonia;
using Avalonia.Controls;
using Wiretune.UI.Services;

namespace Wiretune.UI.Controls;

/// <summary>
/// A lightweight image control for rendering cover art decoded at a specified size
/// via <see cref="CoverArtService"/> with automatic caching and recycling support.
/// </summary>
public class CoverImage : Image
{
    public static readonly StyledProperty<string?> SourcePathProperty =
        AvaloniaProperty.Register<CoverImage, string?>(nameof(SourcePath));

    public static readonly StyledProperty<int> DecodeWidthProperty =
        AvaloniaProperty.Register<CoverImage, int>(nameof(DecodeWidth), 64);

    public static readonly StyledProperty<bool> HasBitmapProperty =
        AvaloniaProperty.Register<CoverImage, bool>(nameof(HasBitmap), false);

    private string? _loadedPath;

    public string? SourcePath
    {
        get => GetValue(SourcePathProperty);
        set => SetValue(SourcePathProperty, value);
    }

    public int DecodeWidth
    {
        get => GetValue(DecodeWidthProperty);
        set => SetValue(DecodeWidthProperty, value);
    }

    public bool HasBitmap
    {
        get => GetValue(HasBitmapProperty);
        private set => SetValue(HasBitmapProperty, value);
    }

    static CoverImage()
    {
        SourcePathProperty.Changed.AddClassHandler<CoverImage>((x, _) => x.OnSourcePathChanged());
        DecodeWidthProperty.Changed.AddClassHandler<CoverImage>((x, _) => x.OnSourcePathChanged());
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        LoadImage();
    }

    private void OnSourcePathChanged()
    {
        LoadImage();
    }

    private void LoadImage()
    {
        var path = SourcePath;
        var width = DecodeWidth;

        if (string.IsNullOrWhiteSpace(path))
        {
            _loadedPath = null;
            Source = null;
            HasBitmap = false;
            return;
        }

        if (string.Equals(_loadedPath, path, StringComparison.Ordinal) && Source != null)
        {
            return;
        }

        _loadedPath = path;
        Source = null;
        HasBitmap = false;

        CoverArtService.LoadBitmap(path, width, bmp =>
        {
            if (string.Equals(SourcePath, path, StringComparison.Ordinal))
            {
                Source = bmp;
                HasBitmap = bmp != null;
            }
        });
    }
}
