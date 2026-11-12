using System.IO;

namespace RawLab.Windows;

internal static class X3fModeReset
{
    internal static void SelectX3fMode(this Adjustments settings, X3fMode mode)
    {
        ArgumentNullException.ThrowIfNull(settings);
        settings.X3fMode = mode;
        if (mode != X3fMode.Normal) return;
        settings.AIDenoiseEnabled = false;
        settings.Lens = settings.Lens with { Distortion = false, Tca = false, Vignetting = false };
    }

    internal static Adjustments CreateLensProbe(string path, Adjustments targetSettings, LensSettings lens)
    {
        ArgumentNullException.ThrowIfNull(targetSettings);
        var probe = new Adjustments
        {
            Processing = targetSettings.Processing,
            X3fMode = targetSettings.X3fMode,
            Lens = lens,
        };
        if (lens.Enabled && IsNormalX3f(path, probe))
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,
                "target X3F rendering mode does not support lens correction");
        return probe;
    }

    internal static bool IsNormalX3f(string? path, Adjustments settings) =>
        settings.X3fMode == X3fMode.Normal && (PhotoInput.IsX3f(path) || HasX3fSignature(path));

    private static bool HasX3fSignature(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return false;
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            Span<byte> header = stackalloc byte[4];
            var offset = 0;
            while (offset < header.Length)
            {
                var read = stream.Read(header[offset..]);
                if (read <= 0) return false;
                offset += read;
            }
            return header[0] == (byte)'F' && header[1] == (byte)'O' &&
                   header[2] == (byte)'V' && header[3] == (byte)'b';
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or
                                   ArgumentException or NotSupportedException or
                                   System.Security.SecurityException)
        {
            return false;
        }
    }
}
