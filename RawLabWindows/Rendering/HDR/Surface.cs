using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;

namespace RawLab.Windows;

public sealed class HDRSurface : HwndHost
{
    private IntPtr window;
    private bool nativeWindow;
    private int generation = -1;
    private HDRFloatImage? uploaded, uploadedReference;
    internal bool Available { get; private set; }
    internal float Headroom { get; private set; } = 1;
    private readonly float[] capabilities = new float[3];
    private float[]? lastParameters;
    private NativeRect[]? lastHoles;
    public HDRSurface() { IsHitTestVisible = false; Focusable = false; }
    protected override HandleRef BuildWindowCore(HandleRef parent)
    {
        try { window = Create(parent.Handle); nativeWindow = window != IntPtr.Zero; }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }
        catch (BadImageFormatException) { }
        // 缺少显示 DLL 的开发构建仍能使用 WPF 的 SDR 画布。
        if (window == IntPtr.Zero) window = CreateWindowEx(0, "STATIC", "", 0x40000000, 0, 0, 1, 1, parent.Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        return new(this, window);
    }
    protected override void DestroyWindowCore(HandleRef handle)
    {
        if(nativeWindow)Destroy(handle.Handle);else DestroyWindow(handle.Handle);
        window = IntPtr.Zero; uploaded = uploadedReference = null;
    }
    internal void RefreshCapabilities()
    {
        if (window == IntPtr.Zero || !nativeWindow) return;
        try {
            var oldWhite=capabilities[1];
            Available = Capabilities(window, capabilities) != 0;
            Headroom = Available && float.IsFinite(capabilities[0]) ? Math.Clamp(capabilities[0], 1, 65504) : 1;
            var next = (int)capabilities[2];
            if (next != generation || oldWhite!=capabilities[1]) { generation = next; uploaded = uploadedReference = null; }
        } catch (DllNotFoundException) { Available = false; } catch (EntryPointNotFoundException) { Available = false; } catch (BadImageFormatException) { Available = false; }
    }
    internal bool ShowFrame(HDRFloatImage? frame, HDRFloatImage? reference, PhotoCanvas canvas, bool sdr,
        bool falseColor, IEnumerable<FrameworkElement> overlays)
    {
        if (window == IntPtr.Zero || !nativeWindow || frame == null || sdr || canvas.GeometryEditing || canvas.ShowClipping || !canvas.IsVisible || !Available) { HideFrame(); return false; }
        reference ??= frame;
        if (!ReferenceEquals(uploaded, frame)) {
            if (Upload(window, 0, frame.RGB, (uint)frame.Width, (uint)frame.Height) == 0) { HideFrame(); return false; }
            uploaded = frame; lastParameters = null;
        }
        if (!ReferenceEquals(uploadedReference, reference)) {
            if (Upload(window, 1, reference.RGB, (uint)reference.Width, (uint)reference.Height) == 0) { HideFrame(); return false; }
            uploadedReference = reference; lastParameters = null;
        }
        var dpi = VisualTreeHelper.GetDpi(canvas); var rect = canvas.ImageBounds;
        if (rect.IsEmpty || rect.Width <= 0 || rect.Height <= 0) { HideFrame(); return false; }
        var parameters = new float[] { (float)(rect.X*dpi.DpiScaleX), (float)(rect.Y*dpi.DpiScaleY),
            (float)(rect.Width*dpi.DpiScaleX), (float)(rect.Height*dpi.DpiScaleY),
            (float)(canvas.ActualWidth*dpi.DpiScaleX), (float)(canvas.ActualHeight*dpi.DpiScaleY), Headroom, capabilities[1],
            canvas.ShowingBefore ? 2 : canvas.ComparisonEnabled ? 1 : 0, (float)((rect.X+rect.Width*canvas.Divider)*dpi.DpiScaleX),
            falseColor ? 1 : 0, 0, frame.ContentHeadroom, reference.ContentHeadroom, 0, 0 };
        var holes = overlays.Where(element => element.IsVisible && element.ActualWidth > 0 && element.ActualHeight > 0)
            .Select(element => {
                var point = element.TranslatePoint(new Point(), canvas);
                return new NativeRect { Left=(int)Math.Floor(point.X*dpi.DpiScaleX)-1, Top=(int)Math.Floor(point.Y*dpi.DpiScaleY)-1,
                    Right=(int)Math.Ceiling((point.X+element.ActualWidth)*dpi.DpiScaleX)+1, Bottom=(int)Math.Ceiling((point.Y+element.ActualHeight)*dpi.DpiScaleY)+1 };
            }).Take(32).ToArray();
        if (lastParameters?.SequenceEqual(parameters) == true && lastHoles?.SequenceEqual(holes) == true) return true;
        if (Present(window, parameters, holes, holes.Length) == 0) { HideFrame(); Available = false; return false; }
        lastParameters = parameters; lastHoles = holes; return true;
    }
    internal void HideFrame() {
        if (window == IntPtr.Zero || !nativeWindow) return;
        try { Hide(window); } catch (DllNotFoundException) { } catch (EntryPointNotFoundException) { }
        lastParameters = null;
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { internal int Left, Top, Right, Bottom; }
    private const string Library="rawlab-hdr-display.dll";
    [DllImport(Library, EntryPoint="rawlab_hdr_create", CallingConvention=CallingConvention.Cdecl)] private static extern IntPtr Create(IntPtr parent);
    [DllImport(Library, EntryPoint="rawlab_hdr_destroy", CallingConvention=CallingConvention.Cdecl)] private static extern void Destroy(IntPtr window);
    [DllImport(Library, EntryPoint="rawlab_hdr_capabilities", CallingConvention=CallingConvention.Cdecl)] private static extern int Capabilities(IntPtr window, [Out] float[] values);
    [DllImport(Library, EntryPoint="rawlab_hdr_upload", CallingConvention=CallingConvention.Cdecl)] private static extern int Upload(IntPtr window, int index, float[] rgb, uint width, uint height);
    [DllImport(Library, EntryPoint="rawlab_hdr_present", CallingConvention=CallingConvention.Cdecl)] private static extern int Present(IntPtr window, float[] parameters, NativeRect[] holes, int count);
    [DllImport(Library, EntryPoint="rawlab_hdr_hide", CallingConvention=CallingConvention.Cdecl)] private static extern void Hide(IntPtr window);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern IntPtr CreateWindowEx(int ex,string cls,string title,int style,int x,int y,int width,int height,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr window);
}
