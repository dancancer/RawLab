using System.IO;

namespace RawLab.Windows;
public partial class MainWindow
{
    private readonly AIDenoiseJob aiJob;
    private AIGpuPreferenceStore aiPreferenceStore=new(AIGpuPreferenceStore.DefaultPath);
    private AIDiagnosticStore aiDiagnostics=AIDiagnosticStore.Default;
    private AIGpuPreference aiPreference=new();
    private bool aiManuallyRequested;
    private AIDenoiseIdentity? aiNotReadyIdentity;
    private int aiNotReadyAttempts;
    private const int MaxAIReprepareAttempts=3;
    private int RequestedAIBackend=>GpuMode.SelectedIndex==2 ? 3 : 2;
    private Adjustments AIWorkSettings { get { var snapshot=settings.Clone();snapshot.Lens=PreviewLens;return snapshot; } }
    private bool CanStartAI=>file!=null && !PhotoInput.IsNormalX3f(file,settings) && PhotoInput.IsRaw(file) && RenderEngine.AIAvailable && RenderEngine.AIHardwareAvailable &&
        RenderEngine.HasBundledAIModel && RenderEngine.GetAIDevices().IsAvailable(aiPreference.DeviceID) && !exporting && !transform.Active && !closing;
    private bool AIResultReady
    {
        get {
            if(!settings.AIDenoiseEnabled)return true;
            try { return file!=null && aiJob.State.Status==AIDenoiseStatus.Ready &&
                aiJob.Identity==AIDenoiseIdentity.Read(file,AIWorkSettings,RequestedAIBackend,aiPreference.DeviceID); }
            catch(Exception error) when(error is IOException or UnauthorizedAccessException) { return false; }
        }
    }
    private bool AIBlocksOutput=>aiJob.State.IsRunning || !AIResultReady;
    private void InitializeAI()
    {
        aiJob.Changed+=()=>{
            if(Dispatcher.HasShutdownStarted)return;
            Dispatcher.BeginInvoke(new Action(()=>{if(!closing)RefreshControls();}));
        };
        DenoiseEditor.AIChanged+=SetAIEnabled;
        DenoiseEditor.AICancelRequested+=()=>{aiManuallyRequested=false;aiJob.Cancel();RefreshControls();Schedule();};
        DenoiseEditor.AIRetryRequested+=()=>RequestAI(true);
        DenoiseEditor.AIDiagnosticsRequested+=async()=>await ExportAIDiagnostics(this,aiJob.State.DiagnosticPath);
    }
    private void RefreshAIControls()=>DenoiseEditor.RefreshAI(RenderEngine.AIAvailable || settings.AIDenoiseEnabled,
        settings.AIDenoiseEnabled,CanStartAI,aiJob.State,
        !RenderEngine.AIHardwareAvailable ? Loc.Text("AI 降噪需要支持 DirectML 的 D3D12 硬件显卡。") :
            !RenderEngine.GetAIDevices().IsAvailable(aiPreference.DeviceID) ? Loc.Text("所选 AI 显卡不可用，请在设置中重新选择。") : null,GpuMode.SelectedIndex==1);
    private void ResetAITask() { aiManuallyRequested=false;aiNotReadyIdentity=null;aiNotReadyAttempts=0;aiJob.Reset(); }
    private static bool ResetsAI(EditorResetScope scope)=>scope.Kind==EditorResetKind.All ||
        scope.Kind==EditorResetKind.Group && scope.Group==EditorAdjustmentGroup.Detail ||
        scope.Kind==EditorResetKind.Tool && scope.Tool==EditorAdjustmentTool.Denoise;
    private bool HasPendingAIReset(EditorResetScope scope)=>ResetsAI(scope) && aiManuallyRequested;
    private void SetAIEnabled(bool enabled)
    {
        if(enabled) { RequestAI(true);return; }
        ResetAITask();settings.AIDenoiseEnabled=false;MarkEdited();RefreshControls();Schedule();
    }
    private void ReconcileAI()
    {
        if(!settings.AIDenoiseEnabled && !aiManuallyRequested) {
            if(aiJob.State.Status is AIDenoiseStatus.Running or AIDenoiseStatus.Ready)aiJob.Reset();
            return;
        }
        if(file==null || closing)return;
        try {
            var identity=AIDenoiseIdentity.Read(file,AIWorkSettings,RequestedAIBackend,aiPreference.DeviceID);
            if(identity!=aiJob.Identity)RequestAI(false);
        } catch(Exception error) when(error is IOException or UnauthorizedAccessException) { Report(error); }
    }
    private async void RequestAI(bool explicitRequest)
    {
        if(file==null || closing || exporting)return;
        if(explicitRequest && !CanStartAI)return;
        try {
            var snapshot=AIWorkSettings;
            var identity=AIDenoiseIdentity.Read(file,snapshot,RequestedAIBackend,aiPreference.DeviceID);
            var revision=openRevision;
            if(!explicitRequest && identity==aiJob.Identity)return;
            if(explicitRequest)aiManuallyRequested=true;
            if(explicitRequest || aiNotReadyIdentity!=identity) { aiNotReadyIdentity=identity;aiNotReadyAttempts=0; }
            exactReady=false;
            var work=aiJob.StartAsync(identity,snapshot);RefreshControls();
            var completed=await work;
            if(closing)return;
            if(!completed && revision==openRevision && file==identity.Source.Path && aiJob.Identity==identity &&
                aiJob.State.Status is AIDenoiseStatus.Failed or AIDenoiseStatus.Cancelled) {
                ClearPendingAllReset();aiManuallyRequested=false;
                if(!settings.AIDenoiseEnabled)Schedule();
                return;
            }
            if(!completed || revision!=openRevision || file!=identity.Source.Path ||
                aiJob.Identity!=identity || aiJob.State.Status!=AIDenoiseStatus.Ready ||
                AIDenoiseIdentity.Read(file,AIWorkSettings,RequestedAIBackend,aiPreference.DeviceID)!=identity)return;
            aiManuallyRequested=false;
            if(!settings.AIDenoiseEnabled) {
                settings.AIDenoiseEnabled=true;MarkEdited();
                // 首次开启只更新已提交的 AI 标志，草稿镜头仍等待 Apply。
                if(transform.Active)transformSource=new(file,openRevision,editRevision,CaptureCurrentEdit(),lut);
            }
            RefreshControls();Schedule();
        } catch(Exception error) { if(!closing)Report(error); }
        finally { if(closing)FinishClose();else RefreshControls(); }
    }
    private void AIResultUnavailable()
    {
        if(!settings.AIDenoiseEnabled || aiJob.State.Status!=AIDenoiseStatus.Ready || aiJob.Identity is not {} identity)return;
        if(aiNotReadyIdentity!=identity) { aiNotReadyIdentity=identity;aiNotReadyAttempts=0; }
        if(++aiNotReadyAttempts>MaxAIReprepareAttempts) {
            aiJob.Fail(Loc.Text("AI 降噪结果连续未就绪，请重试。"));aiManuallyRequested=false;
            ClearPendingAllReset();RefreshControls();return;
        }
        aiJob.Reset();previewDeferred=true;if(!exporting)ReconcileAI();
    }
    private bool HandleAIFailure(Exception error)
    {
        if(!settings.AIDenoiseEnabled)return false;
        if(error is AINotReadyException) {AIResultUnavailable();return true;}
        if(error is AIDenoiseException) {
            ClearPendingAllReset();aiJob.Fail(error.Message,AIDiagnosticStore.ReportPath(error),AIDiagnosticStore.SaveFailed(error));RefreshControls();return true;
        }
        return false;
    }
    private async Task<bool> ExportAIDiagnostics(System.Windows.Window owner,string? report)
    {
        try {
            report ??= aiDiagnostics.Latest();
            if(report==null)throw new IOException(Loc.Text("暂无可导出的 AI 诊断。"));
            var dialog=new Microsoft.Win32.SaveFileDialog{Title=Loc.Text("导出 AI 诊断包…"),Filter="ZIP (*.zip)|*.zip",DefaultExt=".zip",
                AddExtension=true,FileName="RawLab-AI-diagnostic-"+DateTime.Now.ToString("yyyyMMdd-HHmmss")+".zip"};
            if(dialog.ShowDialog(owner)!=true)return false;
            var destination=dialog.FileName;
            await Task.Run(()=>aiDiagnostics.Export(report,destination));
            SetStatus(()=>Loc.Text("AI 诊断包已导出，可手动发送给开发者。"));return true;
        } catch(Exception error) {
            System.Windows.MessageBox.Show(owner,Loc.Text("无法导出 AI 诊断包。")+"\n"+error.Message,Loc.Text("导出 AI 诊断包…"));return false;
        }
    }
}
