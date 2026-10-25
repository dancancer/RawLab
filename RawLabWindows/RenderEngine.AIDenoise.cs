using System.IO;
using System.Runtime.InteropServices;

namespace RawLab.Windows;
internal sealed class AINotReadyException(string message) : InvalidOperationException(message);
internal sealed class AIDenoiseException(string message) : InvalidOperationException(message);
internal sealed partial class RenderEngine
{
    private readonly string aiModelDirectory,aiCacheDirectory;
    private readonly int? aiBackendOverride;
    internal static bool AIAvailable=>Native.sony2fuji_ai_available()!=0;
    internal static string BundledAIModel=>Path.Combine(AppContext.BaseDirectory,"AI","DualDn");
    internal static bool HasBundledAIModel=>File.Exists(Path.Combine(BundledAIModel,"manifest.json"));
    internal static int AIBackendForGpuMode(int mode)=>mode==0 ? 0 : mode==2 ? 3 : 2;
    internal string LastAIBackend=>Marshal.PtrToStringUTF8(Native.sony2fuji_session_get_ai_backend(session)) ?? "";
    private void ConfigureAI(bool enabled)
    {
        if(enabled && (!AIAvailable || !File.Exists(Path.Combine(aiModelDirectory,"manifest.json"))))
            throw new AIDenoiseException(Loc.Text("此构建未安装 AI 降噪模型。"));
        var config=new Native.AIConfig {Version=1,StructSize=(uint)Marshal.SizeOf<Native.AIConfig>(),
            Enabled=enabled ? 1 : 0,Backend=aiBackendOverride ?? AIBackendForGpuMode(gpuMode),
            ModelDirectory=aiModelDirectory,CacheDirectory=aiCacheDirectory};
        CheckAI(Native.sony2fuji_session_set_ai_denoise(session,ref config));
    }
    private void CheckAI(int status)
    {
        if(status==0)return;
        if(status==7)throw new OperationCanceledException(Loc.Text("AI 降噪已取消。"));
        var detail=Marshal.PtrToStringUTF8(Native.sony2fuji_session_get_ai_error(session)) ?? "";
        if(status==8)throw new AINotReadyException(Loc.Text("请先完成此照片的 AI 降噪，再预览或导出。")+"\n"+detail);
        if(detail.Length==0)Native.Check(status);
        throw new AIDenoiseException(Loc.Format("AI 降噪失败：{0}",detail));
    }
    internal void PrepareAI(string path,Adjustments settings,AIPreparation progress)
    {
        progress.Token.ThrowIfCancellationRequested();
        if(!PhotoInput.IsRaw(path))throw new InvalidOperationException(Loc.Text("AI 降噪仅支持 RAW 照片。"));
        settings=PrepareRecipe(path,settings);SetProcessing(settings.Processing);SetTone(settings.ToneControls);SetAtmosphere(settings.Atmosphere);SetLens(settings.Lens);ConfigureAI(true);
        var request=settings.Request(path,null,0,null);
        Exception? callbackError=null;
        Native.AIProgress callback=(_,phase,done,total)=>{
            try { return progress.Report(phase,done,total) ? 1 : 0; }
            catch(Exception error) { callbackError=error;return 0; }
        };
        int status;
        try { status=Native.sony2fuji_session_prepare_ai(session,ref request,callback,IntPtr.Zero); }
        finally { GC.KeepAlive(callback); }
        if(callbackError!=null)throw callbackError;
        CheckAI(status);progress.Token.ThrowIfCancellationRequested();
    }
}
