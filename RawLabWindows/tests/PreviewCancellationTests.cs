using System.Reflection;
using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

public sealed class PreviewCancellationTests
{
    [Fact]
    [Trait("Category", "Model")]
    public void NativeCheckMapsStatusCancelledAndPreservesTwoArgSignature()
    {
        Assert.Equal(7, Native.StatusCancelled);
        Assert.Throws<OperationCanceledException>(() => Native.CheckWithoutSession(Native.StatusCancelled));
        Assert.Throws<InvalidOperationException>(() => Native.CheckWithoutSession(1));

        var checkMethod = typeof(Native)
            .GetMethods(BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public)
            .Single(m => m.Name == nameof(Native.Check));
        var checkParams = checkMethod.GetParameters();
        Assert.Equal(2, checkParams.Length);
        Assert.Equal(typeof(Native.Session), checkParams[1].ParameterType);
        Assert.False(checkParams[1].HasDefaultValue);
        Assert.Throws<ArgumentNullException>(() => Native.Check(Native.StatusCancelled, null!));
    }

    [Fact]
    [Trait("Category", "Model")]
    public void LatestWorkRevisionAndPreviewFallbackIgnoreStaleCancelledWork()
    {
        var queue = new LatestWork<string>();
        queue.Submit("first");
        var first = queue.Start();
        Assert.NotNull(first);
        Assert.Equal(first!.Id, queue.Revision);

        queue.Submit("second");
        Assert.NotEqual(first.Id, queue.Revision);
        Assert.False(queue.Finish(first));

        var second = queue.Start();
        Assert.NotNull(second);
        Assert.Equal("second", second!.Value);
        Assert.True(queue.Finish(second));

        Assert.Equal(MainPreviewDisposition.Ignore, PreviewFallback.ResolveMainPreviewDisposition(
            current: false,
            sameOpenFile: true,
            sameRenderInputs: true,
            sameSource: true,
            previewDeferred: false,
            aiRunning: false,
            renderFailed: false,
            hasFailure: true));

        Assert.Equal(MainPreviewDisposition.Ignore, PreviewFallback.ResolveMainPreviewDisposition(
            current: true,
            sameOpenFile: false,
            sameRenderInputs: true,
            sameSource: true,
            previewDeferred: false,
            aiRunning: false,
            renderFailed: false,
            hasFailure: true));

        Assert.Equal(MainPreviewDisposition.DegradeWithError, PreviewFallback.ResolveMainPreviewDisposition(
            current: true,
            sameOpenFile: true,
            sameRenderInputs: true,
            sameSource: true,
            previewDeferred: false,
            aiRunning: false,
            renderFailed: false,
            hasFailure: true));
    }
}
