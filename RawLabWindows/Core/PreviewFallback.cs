using System.ComponentModel;
using System.IO;

namespace RawLab.Windows;

internal enum MainPreviewDisposition
{
    Ignore,
    DegradeWithError,
    DegradeSourceUnavailable,
    PublishFrame
}

internal readonly record struct PreviewRenderOutcome(
    bool RenderFailed,
    bool ExactReady,
    bool TransformPreviewReady,
    bool KeepExistingFrame,
    string? StatusError);

internal static class PreviewFallback
{
    internal static bool IsFatal(Exception error) =>
        error is OutOfMemoryException or StackOverflowException;

    internal static bool ShouldDegrade(Exception error) => !IsFatal(error);

    internal static bool IsFileIdentityFailure(Exception error) =>
        error is IOException or UnauthorizedAccessException or Win32Exception;

    internal static T ExecuteEmbedded<T>(Func<T> decode, T fallback, Action<Exception>? onFallback = null)
    {
        try
        {
            return decode();
        }
        catch (Exception ex) when (ShouldDegrade(ex))
        {
            onFallback?.Invoke(ex);
            return fallback;
        }
    }

    internal static bool ShouldClearOpeningPreview(bool hasResult, bool hasFile, bool closing) =>
        hasResult || !hasFile || closing;

    internal static bool ShouldShowOpeningPlaceholderOnNeutral(bool renderFailed) => !renderFailed;

    internal static PreviewRenderOutcome DegradeMainPreview(Exception error, bool hasPreviousResult, bool hasOpeningPreview)
    {
        return new(
            RenderFailed: true,
            ExactReady: false,
            TransformPreviewReady: false,
            KeepExistingFrame: hasPreviousResult || hasOpeningPreview,
            StatusError: string.IsNullOrWhiteSpace(error.Message)
                ? error.GetType().Name
                : error.Message);
    }

    internal static PreviewRenderOutcome DegradeUnavailableSource(bool hasPreviousResult, bool hasOpeningPreview) =>
        new(
            RenderFailed: true,
            ExactReady: false,
            TransformPreviewReady: false,
            KeepExistingFrame: hasPreviousResult || hasOpeningPreview,
            StatusError: null);

    internal static MainPreviewDisposition ResolveMainPreviewDisposition(
        bool current,
        bool sameOpenFile,
        bool sameRenderInputs,
        bool sameSource,
        bool previewDeferred,
        bool aiRunning,
        bool alreadyFailed,
        bool hasFailure)
    {
        if (hasFailure)
        {
            return current && sameOpenFile && !previewDeferred && !aiRunning && !alreadyFailed
                ? MainPreviewDisposition.DegradeWithError
                : MainPreviewDisposition.Ignore;
        }

        if (sameOpenFile && sameSource && sameRenderInputs)
        {
            return MainPreviewDisposition.PublishFrame;
        }

        if (current && sameOpenFile && !sameSource && !previewDeferred && !aiRunning && !alreadyFailed)
        {
            return MainPreviewDisposition.DegradeSourceUnavailable;
        }

        return MainPreviewDisposition.Ignore;
    }
}
