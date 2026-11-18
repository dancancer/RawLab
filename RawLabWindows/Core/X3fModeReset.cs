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

    internal static bool RepairLegacyNormalX3f(this Adjustments settings, bool isX3f)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (!isX3f || settings.X3fMode != X3fMode.Normal ||
            (!settings.Lens.Enabled && !settings.AIDenoiseEnabled))
            return false;
        settings.SelectX3fMode(X3fMode.Normal);
        return true;
    }

    internal static bool RepairLegacyNormalX3f(this Adjustments settings, string? path)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (settings.X3fMode != X3fMode.Normal ||
            (!settings.Lens.Enabled && !settings.AIDenoiseEnabled))
            return false;
        return settings.RepairLegacyNormalX3f(IsX3fInput(path));
    }

    internal static (AdjustmentSnapshot Settings, bool Changed) RepairLegacyNormalX3f(
        AdjustmentSnapshot snapshot, bool isX3f)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var settings = snapshot.Restore();
        if (!settings.RepairLegacyNormalX3f(isX3f))
            return (snapshot.Copy(), false);
        var repaired = settings.Capture();
        if (snapshot.Lens == null) repaired = repaired with { Lens = null };
        return (repaired, true);
    }

    internal static (PhotoEditState State, bool Changed) RepairLegacyNormalX3f(PhotoEditState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        if (state.Edit is not { } edit) return (state.Copy(), false);
        var settings = edit.Settings.Restore();
        if (!settings.RepairLegacyNormalX3f(state.Identity.Path))
            return (state.Copy(), false);
        var repaired = settings.Capture();
        if (edit.Settings.Lens == null) repaired = repaired with { Lens = null };
        return (new PhotoEditState(state.Identity, edit with { Settings = repaired }), true);
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

    internal static bool IsX3fInput(string? path) =>
        PhotoInput.IsX3f(path) || HasX3fSignature(path);

    internal static bool IsNormalX3f(string? path, Adjustments settings) =>
        settings.X3fMode == X3fMode.Normal && IsX3fInput(path);

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
