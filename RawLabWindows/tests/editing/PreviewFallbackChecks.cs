using System.ComponentModel;
using System.IO;
using RawLab.Windows;

static class PreviewFallbackChecks
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    public static void Run()
    {
        // P2-18 (W-N3): Non-fatal preview decode/render exceptions must degrade cleanly instead of
        // leaking past narrow catch whitelists into the exit modal dialog.
        Check(PreviewFallback.ShouldDegrade(new OverflowException("Integer overflow in buffer size")),
            "OverflowException must be handled via preview degradation fallback");
        Check(PreviewFallback.ShouldDegrade(new ObjectDisposedException("NativeSession")),
            "ObjectDisposedException must be handled via preview degradation fallback");
        Check(PreviewFallback.ShouldDegrade(new FormatException("Corrupt embedded JPEG")),
            "FormatException must be handled via preview degradation fallback");
        Check(PreviewFallback.ShouldDegrade(new InvalidDataException("Nonfinite HDR luminance")),
            "InvalidDataException must be handled via preview degradation fallback");
        Check(PreviewFallback.ShouldDegrade(new InvalidOperationException("Invalid decoded image state")),
            "InvalidOperationException must be handled via preview degradation fallback");
        Check(!PreviewFallback.ShouldDegrade(new OutOfMemoryException("Out of memory")),
            "Fatal OutOfMemoryException must not be silently swallowed by preview fallback");
        Check(!PreviewFallback.ShouldDegrade(new StackOverflowException()),
            "Fatal StackOverflowException must not be silently swallowed by preview fallback");

        Check(PreviewFallback.IsFileIdentityFailure(new Win32Exception(5, "Access denied")),
            "Win32Exception from WindowsFileIdentity.ReadIdentity must be handled gracefully by CurrentViewSource");
        Check(PreviewFallback.IsFileIdentityFailure(new IOException("Locked")),
            "IOException must remain handled by CurrentViewSource");
        Check(PreviewFallback.IsFileIdentityFailure(new UnauthorizedAccessException("Denied")),
            "UnauthorizedAccessException must remain handled by CurrentViewSource");
        Check(!PreviewFallback.IsFileIdentityFailure(new OutOfMemoryException()),
            "Fatal OOM must not be masked as a file-identity read error");

        // Embedded preview fallback must catch OverflowException/ObjectDisposedException/FormatException
        // and invoke logging callback, returning fallback (null, 0, 0).
        Exception? recordedFallback = null;
        var embeddedFallbackCount = 0;
        var sentinel = ("placeholder", 0, 0);
        foreach (Exception fault in new Exception[]
        {
            new OverflowException("buffer size overflow"),
            new ObjectDisposedException("buffer"),
            new FormatException("malformed exif"),
            new InvalidDataException("corrupt header")
        })
        {
            recordedFallback = null;
            var outcome = PreviewFallback.ExecuteEmbedded(
                () => throw fault,
                sentinel,
                ex => { embeddedFallbackCount++; recordedFallback = ex; });
            Check(Equals(outcome, sentinel) && ReferenceEquals(recordedFallback, fault),
                $"ExecuteEmbedded degraded cleanly for {fault.GetType().Name}");
        }
        Check(embeddedFallbackCount == 4, "Each embedded decode exception invoked fallback once");

        // Fatal OOM propagates instead of returning degraded fallback.
        var oomPropagated = false;
        try
        {
            _ = PreviewFallback.ExecuteEmbedded<string?>(() => throw new OutOfMemoryException("fatal"), null);
        }
        catch (OutOfMemoryException)
        {
            oomPropagated = true;
        }
        Check(oomPropagated, "ExecuteEmbedded propagates fatal OutOfMemoryException");

        // Main preview degradation keeps prior image / embedded placeholder, disables exact export,
        // keeps retry recoverable, and exposes visible failure message.
        var afterResultOverflow = PreviewFallback.DegradeMainPreview(
            new OverflowException("Preview overflow at 6000x4000"),
            hasPreviousResult: true,
            hasOpeningPreview: false);
        Check(afterResultOverflow.RenderFailed && !afterResultOverflow.ExactReady && !afterResultOverflow.TransformPreviewReady &&
              afterResultOverflow.KeepExistingFrame &&
              afterResultOverflow.StatusError!.Contains("Preview overflow", StringComparison.Ordinal),
            "Main preview OverflowException with prior result degrades cleanly, preserves pixels, allows retry, and exposes message");

        var initialOpenOverflow = PreviewFallback.DegradeMainPreview(
            new OverflowException("Initial open overflow"),
            hasPreviousResult: false,
            hasOpeningPreview: true);
        Check(initialOpenOverflow.RenderFailed && !initialOpenOverflow.ExactReady && initialOpenOverflow.KeepExistingFrame &&
              initialOpenOverflow.StatusError == "Initial open overflow",
            "Initial open OverflowException keeps embedded preview instead of blanking out");

        Check(!PreviewFallback.ShouldClearOpeningPreview(hasResult: false, hasFile: true, closing: false),
            "Failed main preview on initial open does not wipe the already-decoded embedded placeholder");
        Check(PreviewFallback.ShouldClearOpeningPreview(hasResult: true, hasFile: true, closing: false) &&
              PreviewFallback.ShouldClearOpeningPreview(hasResult: false, hasFile: false, closing: false) &&
              PreviewFallback.ShouldClearOpeningPreview(hasResult: false, hasFile: true, closing: true),
            "Settled result, missing file, or closing still clears the transient opening placeholder");
        Check(!PreviewFallback.ShouldShowOpeningPlaceholderOnNeutral(renderFailed: true) &&
              PreviewFallback.ShouldShowOpeningPlaceholderOnNeutral(renderFailed: false),
            "Failed render does not expose opening placeholder on comparison neutral canvas");

        // P2-18 (Med #2): Current render ticket failure must still degrade cleanly when
        // CurrentViewSource becomes null (deleted / Win32Exception) or replaced (!SameFile) mid-render.
        Check(PreviewFallback.ResolveMainPreviewDisposition(
                current: true, sameOpenFile: true, sameRenderInputs: false, sameSource: false,
                previewDeferred: false, aiRunning: false, alreadyFailed: false, hasFailure: true) ==
              MainPreviewDisposition.DegradeWithError,
            "Current ticket error with missing/replaced source must still degrade instead of stalling in Developing");

        // When render returns without failure but CurrentViewSource disappeared or changed (!SameFile),
        // Pump must not publish stale pixels AND must transition out of Developing into failed/unupdated state.
        Check(PreviewFallback.ResolveMainPreviewDisposition(
                current: true, sameOpenFile: true, sameRenderInputs: false, sameSource: false,
                previewDeferred: false, aiRunning: false, alreadyFailed: false, hasFailure: false) ==
              MainPreviewDisposition.DegradeSourceUnavailable,
            "Current ticket succeeding after source disappeared/changed must degrade to unupdated failure state");

        Check(PreviewFallback.ResolveMainPreviewDisposition(
                current: true, sameOpenFile: true, sameRenderInputs: true, sameSource: true,
                previewDeferred: false, aiRunning: false, alreadyFailed: false, hasFailure: false) ==
              MainPreviewDisposition.PublishFrame,
            "Matching current source and settings publish rendered frame");

        Check(PreviewFallback.ResolveMainPreviewDisposition(
                current: false, sameOpenFile: true, sameRenderInputs: false, sameSource: false,
                previewDeferred: false, aiRunning: false, alreadyFailed: false, hasFailure: true) ==
              MainPreviewDisposition.Ignore,
            "Superseded ticket error does not overwrite active render progress");

        Check(PreviewFallback.ResolveMainPreviewDisposition(
                current: true, sameOpenFile: true, sameRenderInputs: false, sameSource: false,
                previewDeferred: false, aiRunning: true, alreadyFailed: false, hasFailure: true) ==
              MainPreviewDisposition.Ignore,
            "Active AI job wait suppresses unrelated error transition");

        Check(PreviewFallback.ResolveMainPreviewDisposition(
                current: true, sameOpenFile: true, sameRenderInputs: false, sameSource: false,
                previewDeferred: true, aiRunning: false, alreadyFailed: false, hasFailure: false) ==
              MainPreviewDisposition.Ignore,
            "Deferred preview during export does not emit spurious failure");

        Check(PreviewFallback.ResolveMainPreviewDisposition(
                current: true, sameOpenFile: true, sameRenderInputs: false, sameSource: false,
                previewDeferred: false, aiRunning: false, alreadyFailed: true, hasFailure: true) ==
              MainPreviewDisposition.Ignore,
            "Existing error state is preserved without overwriting by an in-flight ticket");

        Console.WriteLine("PASS: P2-18 preview fallback catches OverflowException/non-fatal faults and preserves recoverability");
    }
}
