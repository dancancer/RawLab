using System.Runtime.InteropServices;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

internal sealed record LUTPreviewFrame(byte[] Pixels, int Width, int Height, int Stride, BitmapSource Image)
{
    internal static LUTPreviewFrame From(Native.Buffer buffer)
    {
        if (buffer.Data == IntPtr.Zero || buffer.PixelFormat != 1 || buffer.Width == 0 || buffer.Height == 0 ||
            buffer.Width > 1024 || buffer.Height > 1024 || buffer.Stride != buffer.Width * 4 || buffer.Size != (nuint)buffer.Stride * buffer.Height)
            throw new InvalidOperationException(Loc.Text("无法生成预览，请检查照片、LUT 和颜色配置。"));
        var pixels = new byte[checked((int)buffer.Size)]; Marshal.Copy(buffer.Data, pixels, 0, pixels.Length);
        var bgra = (byte[])pixels.Clone();
        for (var i = 0; i + 3 < bgra.Length; i += 4) (bgra[i], bgra[i + 2]) = (bgra[i + 2], bgra[i]);
        var image = BitmapSource.Create((int)buffer.Width, (int)buffer.Height, 96, 96, PixelFormats.Bgra32, null, bgra, (int)buffer.Stride);
        image.Freeze(); return new(pixels, (int)buffer.Width, (int)buffer.Height, (int)buffer.Stride, image);
    }
    internal (double Mean, double Maximum, double CandidateBoundary, double ReferenceBoundary) Compare(LUTPreviewFrame reference, LUTReferenceConditions conditions)
    {
        if (!conditions.CanCompare) throw new InvalidOperationException(Loc.Text("请先确认同源图片、处理条件和参考来源。"));
        if (Width != reference.Width || Height != reference.Height)
            throw new InvalidOperationException(Loc.Text("参考图与预览的比例或尺寸不一致，仅可目视比较。"));
        var a = GCHandle.Alloc(Pixels, GCHandleType.Pinned); var b = GCHandle.Alloc(reference.Pixels, GCHandleType.Pinned);
        var blob = new PInvokeNative.DcpBlob();
        try {
            var left = Buffer(a.AddrOfPinnedObject()); var right = reference.Buffer(b.AddrOfPinnedObject());
            Native.Check(Native.sony2fuji_compare_lut_previews(ref left, ref right, conditions.Json(), ref blob));
            var bytes = new byte[checked((int)blob.SizeBytes)]; Marshal.Copy(blob.Data, bytes, 0, bytes.Length);
            var result = JsonNode.Parse(Encoding.UTF8.GetString(bytes))!;
            return (result["mean_absolute_rgb"]!.GetValue<double>(), result["max_absolute_rgb"]!.GetValue<double>(),
                result["candidate_boundary_fraction"]!.GetValue<double>(), result["reference_boundary_fraction"]!.GetValue<double>());
        } finally { PInvokeNative.ReleaseBlob(ref blob); a.Free(); b.Free(); }
    }
    private Native.Buffer Buffer(IntPtr pointer) => new() { Data = pointer, Size = (nuint)Pixels.Length,
        Width = (uint)Width, Height = (uint)Height, Stride = (uint)Stride, PixelFormat = 1 };
}

internal sealed class LUTPreviewWorker : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "RawLab-LUT-preview-" + Guid.NewGuid().ToString("N"));
    private readonly Native.Session session;
    private Native.Buffer display;
    private HDRSdrInput? hdrDisplay;
    private readonly string source, lut;
    internal bool DisplayInput { get; }
    internal LUTPreviewWorker(string look, string photo)
    {
        session = NewSession(); source = Path.Combine(directory, "source" + Path.GetExtension(photo));
        lut = Path.Combine(directory, "look" + Path.GetExtension(look)); DisplayInput = PhotoInput.IsRaster(photo);
        try {
            Directory.CreateDirectory(directory); File.Copy(look, lut); File.Copy(photo, source);
            if (DisplayInput)
            {
                if (PhotoInput.ProbeHDR(photo, out _) == HDRProbeState.Supported)
                {
                    using var decoded = HDRNative.Decode(photo, HDRIntent.Preview, 512);
                    hdrDisplay = new HDRSdrInput(HDRDisplay.CopyPair(decoded.Pair).SDR);
                    display = hdrDisplay.Buffer;
                }
                else Native.Check(Native.sony2fuji_load_display_image(source, ref display));
            }
        } catch { Dispose(); throw; }
    }
    private static Native.Session NewSession()
    {
        var session = new Native.Session();
        try {
            var gpu = new Native.GpuConfig { Version = 1, StructSize = 12, Mode = 0 };
            Native.Check(Native.sony2fuji_session_set_gpu_config(session, ref gpu));
            Native.Check(Native.sony2fuji_session_set_processing_version(session, 2));
            Native.Check(Native.sony2fuji_session_set_raw_exposure_mode(session, 0));
            return session;
        } catch { session.Dispose(); throw; }
    }
    private static Native.Request Request() => new() {
        Version = 2, StructSize = (uint)Marshal.SizeOf<Native.Request>(), Wb0 = 1, Wb1 = 1, Wb2 = 1, Wb3 = 1,
        Brightness = 1, Contrast = 1, Saturation = 1, Temperature = 6500, OutputTarget = 1, OutputFormat = 3,
        Intent = 0, PreviewLongEdge = 512, SizeMode = 3 };
    private static void SetDisplay(ref Native.Request request, Native.Buffer display)
    {
        request.InputType = 2; request.InputPixels = display.Data; request.InputWidth = display.Width;
        request.InputHeight = display.Height; request.InputPixelFormat = display.PixelFormat;
    }
    internal LUTPreviewFrame Render(LUTCompatibility? configuration)
    {
        if (configuration != null && !configuration.SupportsPreview(DisplayInput))
            throw new InvalidOperationException(Loc.Text("此配置与预览照片类型不匹配，请更换照片或配置。"));
        var request = Request(); request.InputPath = source; request.LutPath = configuration == null ? null : lut;
        request.LutStrength = configuration == null ? 0 : 1; if (DisplayInput) SetDisplay(ref request, display);
        var output = new Native.Buffer();
        try {
            Native.Check(configuration == null ? Native.sony2fuji_process(session, ref request, out output) :
                Native.sony2fuji_preview_lut_compatibility(session, ref request, configuration.PreviewRequest(), ref output));
            return LUTPreviewFrame.From(output);
        } finally { Native.sony2fuji_release_buffer(ref output); }
    }
    internal static LUTPreviewFrame Reference(string file)
    {
        using var session = NewSession(); var input = new Native.Buffer(); var output = new Native.Buffer();
        HDRSdrInput? hdrInput = null;
        try {
            if (PhotoInput.ProbeHDR(file, out _) == HDRProbeState.Supported)
            {
                using var decoded = HDRNative.Decode(file, HDRIntent.Preview, 512);
                hdrInput = new HDRSdrInput(HDRDisplay.CopyPair(decoded.Pair).SDR); input = hdrInput.Buffer;
            }
            else Native.Check(Native.sony2fuji_load_display_image(file, ref input));
            var request = Request(); SetDisplay(ref request, input);
            Native.Check(Native.sony2fuji_process(session, ref request, out output)); return LUTPreviewFrame.From(output);
        } finally { if (hdrInput == null) Native.sony2fuji_release_buffer(ref input); hdrInput?.Dispose(); Native.sony2fuji_release_buffer(ref output); }
    }
    public void Dispose()
    {
        if (hdrDisplay == null) Native.sony2fuji_release_buffer(ref display);
        hdrDisplay?.Dispose(); hdrDisplay = null; session.Dispose();
        try { if (Directory.Exists(directory)) Directory.Delete(directory, true); } catch (IOException) { }
    }
}

// 关闭后排队释放资源；正在运行的 native 调用不会因窗口关闭而失去文件或会话。
internal sealed class LUTPreviewService : IDisposable
{
    private readonly ConcurrentExclusiveSchedulerPair scheduler = new(TaskScheduler.Default, 1);
    private readonly TaskFactory queue;
    private LUTPreviewWorker? worker;
    private bool closed;
    internal LUTPreviewService() => queue = new(CancellationToken.None, TaskCreationOptions.None, TaskContinuationOptions.None, scheduler.ExclusiveScheduler);
    internal Task<(LUTPreviewFrame Baseline, bool DisplayInput)> Load(string look, string photo, CancellationToken token) => queue.StartNew(() => {
        token.ThrowIfCancellationRequested(); worker?.Dispose(); worker = null;
        worker = new LUTPreviewWorker(look, photo); return (worker.Render(null), worker.DisplayInput);
    }, token);
    internal Task<LUTPreviewFrame> Render(LUTCompatibility draft, CancellationToken token) => queue.StartNew(() => {
        token.ThrowIfCancellationRequested(); return (worker ?? throw new InvalidOperationException()).Render(draft);
    }, token);
    internal Task<LUTPreviewFrame> Reference(string file, CancellationToken token) => queue.StartNew(() => {
        token.ThrowIfCancellationRequested(); return LUTPreviewWorker.Reference(file);
    }, token);
    internal Task<(double Mean, double Maximum, double CandidateBoundary, double ReferenceBoundary)> Compare(LUTPreviewFrame a, LUTPreviewFrame b, LUTReferenceConditions conditions, CancellationToken token) =>
        queue.StartNew(() => { token.ThrowIfCancellationRequested(); return a.Compare(b, conditions); }, token);
    public void Dispose()
    {
        if (closed) return; closed = true;
        _ = queue.StartNew(() => { worker?.Dispose(); worker = null; }).ContinueWith(_ => scheduler.Complete(), TaskScheduler.Default);
    }
}
