using System.IO;
using System.Runtime.InteropServices;

namespace RawLab.Windows;
internal sealed class AINotReadyException(string message) : InvalidOperationException(message);
internal sealed class AIDenoiseException(string message) : InvalidOperationException(message);
internal sealed partial class RenderEngine
{
    private readonly string aiModelDirectory,aiCacheDirectory;
    private readonly int? aiBackendOverride;
    private string aiDeviceID,aiOperation="unknown";
    private string? aiInputPath,aiNativeDetails;
    private int? aiNativeStatus;
    private bool aiNativeOperationStarted;
    private readonly AIDiagnosticStore aiDiagnosticStore;
    private static readonly object aiDevicesGate=new();
    private static AIDeviceInventory? aiDevices;
    internal static bool AIAvailable=>Native.sony2fuji_ai_available()!=0;
    internal static bool AIHardwareAvailable=>GetAIDevices().IsAvailable("");
    internal static AIDeviceInventory GetAIDevices(bool refresh=false)
    {
        lock(aiDevicesGate) {
            if(!refresh && aiDevices!=null)return aiDevices;
            try{return aiDevices=AIDeviceInventory.Parse(Marshal.PtrToStringUTF8(Native.sony2fuji_ai_get_devices()) ?? "{}");}
            catch(Exception error) when(error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
            {return aiDevices=AIDeviceInventory.Unavailable(error.Message);}
        }
    }
    internal void SetAIDevice(string deviceID)=>aiDeviceID=deviceID;
    private void BeginAIOperation(string operation,string path)
    {aiOperation=operation;aiInputPath=path;aiNativeDetails=null;aiNativeStatus=null;aiNativeOperationStarted=false;}
    private void CaptureAIFailure(Exception error)
    {
        string? diagnostics=null;
        try{if(aiNativeOperationStarted)diagnostics=Marshal.PtrToStringUTF8(Native.sony2fuji_session_get_ai_diagnostics(session));}catch(Exception){ }
        aiDiagnosticStore.Capture(error,new(aiOperation,aiDeviceID,aiBackendOverride ?? AIBackendForGpuMode(gpuMode),
            aiInputPath,aiNativeStatus,aiNativeDetails,diagnostics,GetAIDevices(true).JSON,aiModelDirectory,aiCacheDirectory));
    }
    internal static string BundledAIModel=>Path.Combine(AppContext.BaseDirectory,"AI","DualDn");
    internal static bool HasBundledAIModel=>File.Exists(Path.Combine(BundledAIModel,"manifest.json"));
    internal static int AIBackendForGpuMode(int mode)=>mode==2 ? 3 : 2;
    internal string LastAIBackend=>Marshal.PtrToStringUTF8(Native.sony2fuji_session_get_ai_backend(session)) ?? "";
    internal static void ValidateAIInput(string path)=>ValidateAIInput(path,"");
    internal static void ValidateAIInput(string path,string deviceID,X3fMode x3fMode=X3fMode.Legacy)
    {
        if(PhotoInput.IsX3f(path) && x3fMode==X3fMode.Normal)
            throw new AIDenoiseException(Loc.Text("此 X3F 显影模式不支持 AI 降噪。"));
        if(!PhotoInput.IsRaw(path))throw new AIDenoiseException(Loc.Text("AI 降噪仅支持 RAW 照片。"));
        if(!AIAvailable || !HasBundledAIModel)throw new AIDenoiseException(Loc.Text("此构建未安装 AI 降噪模型。"));
        if(!AIHardwareAvailable)throw new AIDenoiseException(Loc.Text("AI 降噪需要支持 DirectML 的 D3D12 硬件显卡。"));
        if(!GetAIDevices().IsAvailable(deviceID))throw new AIDenoiseException(Loc.Text("所选 AI 显卡不可用，请在设置中重新选择。"));
    }
    private void ConfigureAI(bool enabled)
    {
        if(enabled && (!AIAvailable || !File.Exists(Path.Combine(aiModelDirectory,"manifest.json"))))
            throw new AIDenoiseException(Loc.Text("此构建未安装 AI 降噪模型。"));
        if(enabled && !AIHardwareAvailable)
            throw new AIDenoiseException(Loc.Text("AI 降噪需要支持 DirectML 的 D3D12 硬件显卡。"));
        var config=new Native.AIConfig {Version=1,StructSize=(uint)Marshal.SizeOf<Native.AIConfig>(),
            Enabled=enabled ? 1 : 0,Backend=aiBackendOverride ?? AIBackendForGpuMode(gpuMode),
            ModelDirectory=aiModelDirectory,CacheDirectory=aiCacheDirectory};
        CheckAI(Native.sony2fuji_session_set_ai_denoise(session,ref config));
        if(enabled)CheckAI(Native.sony2fuji_session_set_ai_device(session,aiDeviceID));
    }
    private void CheckAI(int status)
    {
        if(status==0)return;
        if(status==7)throw new OperationCanceledException(Loc.Text("AI 降噪已取消。"));
        var detail=Marshal.PtrToStringUTF8(Native.sony2fuji_session_get_ai_error(session)) ?? "";
        aiNativeStatus=status;aiNativeDetails=detail;
        if(detail.StartsWith("DirectML requires a hardware D3D12 adapter",StringComparison.Ordinal) ||
            detail.StartsWith("This build has no DirectML backend",StringComparison.Ordinal))
            throw new AIDenoiseException(Loc.Text("AI 降噪需要支持 DirectML 的 D3D12 硬件显卡。"));
        if(status==8)throw new AINotReadyException(Loc.Text("请先完成此照片的 AI 降噪，再预览或导出。")+"\n"+detail);
        if(detail.StartsWith("The selected AI GPU",StringComparison.Ordinal))
            throw new AIDenoiseException(Loc.Text("所选 AI 显卡不可用，请在设置中重新选择。"));
        if(detail.Contains("887A0001",StringComparison.OrdinalIgnoreCase))
            throw new AIDenoiseException(Loc.Text("AI 显卡执行失败，请更换 AI 显卡或导出诊断包。")+" (0x887A0001)");
        if(detail.Length==0)Native.Check(status);
        throw new AIDenoiseException(Loc.Format("AI 降噪失败：{0}",detail));
    }
    internal void PrepareAI(string path,Adjustments settings,AIPreparation progress)
    {
        BeginAIOperation("prepare",path);
        try{PrepareAICore(path,settings,progress);}
        catch(Exception error) when(error is not OperationCanceledException && error is not AINotReadyException)
        {CaptureAIFailure(error);throw;}
    }
    private void PrepareAICore(string path,Adjustments settings,AIPreparation progress)
    {
        progress.Token.ThrowIfCancellationRequested();
        if(PhotoInput.IsNormalX3f(path,settings))throw new AIDenoiseException(Loc.Text("此 X3F 显影模式不支持 AI 降噪。"));
        if(!PhotoInput.IsRaw(path))throw new InvalidOperationException(Loc.Text("AI 降噪仅支持 RAW 照片。"));
        settings=PrepareRecipe(path,settings);SetProcessing(settings.Processing);SetX3f(path,settings);
        SetTone(settings.RenderToneControls);SetAtmosphere(settings.RenderAtmosphere);
        SetCurve(settings.RenderCurve);SetGrading(settings.RenderGrading);SetLens(settings.Lens);ConfigureAI(true);
        var request=settings.Request(path,null,0,null);
        Exception? callbackError=null;
        Native.AIProgress callback=(_,phase,done,total)=>{
            try { return progress.Report(phase,done,total) ? 1 : 0; }
            catch(Exception error) { callbackError=error;return 0; }
        };
        int status;
        try { aiNativeOperationStarted=true;status=Native.sony2fuji_session_prepare_ai(session,ref request,callback,IntPtr.Zero); }
        finally { GC.KeepAlive(callback); }
        if(callbackError!=null)throw callbackError;
        CheckAI(status);progress.Token.ThrowIfCancellationRequested();
    }
}
