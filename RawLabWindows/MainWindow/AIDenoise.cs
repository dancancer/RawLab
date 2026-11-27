using System.IO;
using System.Windows;

namespace RawLab.Windows;
public partial class MainWindow
{
    private readonly AIDenoiseJob aiJob;
    private AIModelPackageManager aiModelManager;
    private AIGpuPreferenceStore aiPreferenceStore;
    private AIDiagnosticStore aiDiagnostics;
    private AIGpuPreference aiPreference=new();
    private bool aiManuallyRequested;
    private AIDenoiseIdentity? aiNotReadyIdentity;
    private int aiNotReadyAttempts;
    private const int MaxAIReprepareAttempts=3;
    private int RequestedAIBackend=>GpuMode.SelectedIndex==2 ? 3 : 2;
    private Adjustments AIWorkSettings { get { var snapshot=settings.Clone();snapshot.Lens=PreviewLens;return snapshot; } }
    private bool HDRCameraAICandidate=>file!=null && PhotoInput.IsHDRCameraAICandidate(hdrSource);
    private string? ResolveAIModelDirectory()=>RenderEngine.ResolveAIModelDirectory(appPaths,aiModelManager?.Store);
    private bool HasAIModel=>aiModelManager.State.IsInstalled || ResolveAIModelDirectory()!=null;
    private bool CanRemoveDownloadedAIModel=>aiModelManager.State.IsDownloadedInstalled && !aiModelManager.State.IsBusy &&
        !aiJob.State.IsRunning && !scheduler.Busy && !exporting && !autoExposing && !transferPreparing &&
        !(photoPreviews?.IsPreparingAI==true) && !closing;
    private bool CanStartAI=>file!=null && (settings.IsHDREditing
        ? HDRCameraAICandidate && settings.HDR!.CameraSettings.AllowsAI && RequestedGpuMode!=2
        : !PhotoInput.IsNormalX3f(file,settings) && PhotoInput.IsRaw(file)) && RenderEngine.AIAvailable && RenderEngine.AIHardwareAvailable &&
        HasAIModel && !aiModelManager.State.IsBusy && RenderEngine.GetAIDevices().IsAvailable(aiPreference.DeviceID) && !exporting && !transform.Active && !closing;
    private AIModelPackageManager CreateAIModelManager(AppPaths paths)
    {
        var manager=new AIModelPackageManager(
            AIModelPackageStore.CreateForAppPaths(paths),
            isRuntimeSupported:()=>RenderEngine.AIModelDownloadSupported,
            overrideProvider:()=>AIModelPackageStore.ResolvedOverrideDirectory,
            bundledProvider:()=>RenderEngine.BundledAIModel,
            dispatch:action=>{
                if(Dispatcher.HasShutdownStarted)return;
                if(Dispatcher.CheckAccess())action();
                else Dispatcher.BeginInvoke(action);
            });
        AttachAIModelManager(manager);
        return manager;
    }
    private void AttachAIModelManager(AIModelPackageManager manager)
    {
        manager.StateChanged+=OnAIModelStateChanged;
        manager.InstallStateChanged+=OnAIModelInstallStateChanged;
    }
    private void DetachAIModelManager(AIModelPackageManager? manager)
    {
        if(manager==null)return;
        manager.StateChanged-=OnAIModelStateChanged;
        manager.InstallStateChanged-=OnAIModelInstallStateChanged;
    }
    private void RebindAIModelManagerForTests(AppPaths isolatedPaths)
    {
        DetachAIModelManager(aiModelManager);
        aiModelManager.CancelDownload();
        aiModelManager=CreateAIModelManager(isolatedPaths);
        RefreshAIControls();
    }
    private void OnAIModelStateChanged(AIModelPackageState _)
    {
        if(!closing)RefreshControls();
    }
    private void OnAIModelInstallStateChanged()
    {
        if(closing)return;
        var installed=HasAIModel;
        if(!scheduler.Busy && !exporting && engine!=null &&
            !string.Equals(engine.CurrentAIModelDirectory,ResolveAIModelDirectory(),StringComparison.OrdinalIgnoreCase)) {
            engine.Dispose();engine=null;
        }
        photoPreviews?.RefreshAll();
        if(installed) {
            if(settings.ActiveAIDenoise && file!=null && aiJob.State.Status!=AIDenoiseStatus.Ready && !aiJob.State.IsRunning) {
                aiJob.Reset();
                Schedule();
            }
        } else {
            if(!aiJob.State.IsRunning)aiJob.Reset();
        }
        RefreshControls();
    }
    private bool AIResultReady
    {
        get {
            if(!settings.ActiveAIDenoise)return true;
            try {
                return file!=null && CurrentViewSource is { } source && aiJob.State.Status==AIDenoiseStatus.Ready &&
                    aiJob.Identity==AIDenoiseIdentity.Read(file,AIWorkSettings,RequestedAIBackend,aiPreference.DeviceID,source);
            }
            catch(Exception error) when(PreviewFallback.IsFileIdentityFailure(error)) { return false; }
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
        DenoiseEditor.AIStrengthChanged+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.AIDenoiseStrength=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        DenoiseEditor.AICancelRequested+=()=>{aiManuallyRequested=false;aiJob.Cancel();RefreshControls();Schedule();};
        DenoiseEditor.AIRetryRequested+=()=>RequestAI(true);
        DenoiseEditor.AIDiagnosticsRequested+=async()=>await ExportAIDiagnostics(this,aiJob.State.DiagnosticPath);
        DenoiseEditor.AIModelDownloadRequested+=()=>aiModelManager.StartDownload();
        DenoiseEditor.AIModelCancelRequested+=()=>aiModelManager.CancelDownload();
        DenoiseEditor.AIModelLicenseRequested+=ShowAIModelLicenses;
        DenoiseEditor.AIModelRemoveRequested+=ConfirmAndRemoveDownloadedAIModel;
    }
    private void ShowAIModelLicenses()
    {
        var dialog=new AIModelLicenseWindow(aiModelManager.Store.InstalledPackageDirectory()){Owner=this};
        dialog.ShowDialog();
    }
    private void ConfirmAndRemoveDownloadedAIModel()
    {
        if(!CanRemoveDownloadedAIModel)return;
        var state=aiModelManager.State;
        var message=Loc.Format("删除后将释放约 {0} MB 磁盘空间，需要时可重新下载。",AIModelPackageException.FormatMegabytes(state.UnpackedBytes));
        if(MessageBox.Show(this,message,Loc.Text("确定删除已下载的 AI 降噪模型？"),MessageBoxButton.YesNo,MessageBoxImage.Warning,MessageBoxResult.No)!=MessageBoxResult.Yes)
            return;
        if(!CanRemoveDownloadedAIModel)return;
        if(!scheduler.Busy && !exporting && engine!=null) { engine.Dispose(); engine=null; }
        aiModelManager.RemoveDownloadedModel();
    }
    private void RefreshAIControls()
    {
        var visible = settings.ActiveAIDenoise || RenderEngine.AIAvailable && (!settings.IsHDREditing || HDRCameraAICandidate);
        DenoiseEditor.RefreshAI(visible,settings.ActiveAIDenoise,CanStartAI,aiJob.State,
            PhotoInput.HDRCameraAIUnavailableHint(settings.HDR,RequestedGpuMode) ??
                (!RenderEngine.AIHardwareAvailable ? Loc.Text("AI 降噪需要支持 DirectML 的 D3D12 硬件显卡。") :
                !RenderEngine.GetAIDevices().IsAvailable(aiPreference.DeviceID) ? Loc.Text("所选 AI 显卡不可用，请在设置中重新选择。") : null),
            GpuMode.SelectedIndex==1,settings.AIDenoiseStrength,
            aiModelManager.State,!exporting,CanRemoveDownloadedAIModel);
    }
    private void ResetAITask() { aiManuallyRequested=false;aiNotReadyIdentity=null;aiNotReadyAttempts=0;aiJob.Reset(); }
    private bool HasPendingAIReset(EditorResetScope scope)=>EditorAdjustmentRules.ResetsAI(scope) && aiManuallyRequested;
    private void SetAIEnabled(bool enabled)
    {
        if(enabled) { RequestAI(true);return; }
        ResetAITask();settings.ActiveAIDenoise=false;MarkEdited();RefreshControls();Schedule();
    }
    private void ReconcileAI()
    {
        if(settings.IsHDREditing && !settings.HDR!.CameraSettings.AllowsAI && aiManuallyRequested)ResetAITask();
        if(!settings.ActiveAIDenoise && !aiManuallyRequested) {
            if(aiJob.State.Status is AIDenoiseStatus.Running or AIDenoiseStatus.Ready)aiJob.Reset();
            return;
        }
        if(file==null || closing)return;
        try {
            if(CurrentViewSource is not { } source) return;
            var identity=AIDenoiseIdentity.Read(file,AIWorkSettings,RequestedAIBackend,aiPreference.DeviceID,source);
            if(identity!=aiJob.Identity)RequestAI(false);
        } catch(Exception error) when(PreviewFallback.IsFileIdentityFailure(error)) { Report(error); }
    }
    private async void RequestAI(bool explicitRequest)
    {
        if(file==null || closing || exporting)return;
        if(explicitRequest && !CanStartAI)return;
        try {
            var path=file;var revision=openRevision;
            var source=CurrentViewSource;
            if(source==null) {
                if(!explicitRequest)return;
                source=await Task.Run(()=>OriginalIdentity.Read(path));
                if(closing || file!=path || openRevision!=revision)return;
                viewSourceState.ApplyProbeResult(path,revision,source);
            }
            var snapshot=AIWorkSettings;
            var identity=AIDenoiseIdentity.Read(path,snapshot,RequestedAIBackend,aiPreference.DeviceID,source);
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
                if(!settings.ActiveAIDenoise)Schedule();
                return;
            }
            var latestSource=CurrentViewSource;
            if(!completed || revision!=openRevision || file!=identity.Source.Path ||
                aiJob.Identity!=identity || aiJob.State.Status!=AIDenoiseStatus.Ready ||
                latestSource==null ||
                AIDenoiseIdentity.Read(path,AIWorkSettings,RequestedAIBackend,aiPreference.DeviceID,latestSource)!=identity)return;
            aiManuallyRequested=false;
            if(!settings.ActiveAIDenoise) {
                settings.ActiveAIDenoise=true;MarkEdited();
                // 首次开启只更新已提交的 AI 标志，草稿镜头仍等待 Apply。
                if(transform.Active)transformSource=new(file,openRevision,editRevision,CaptureCurrentEdit(),lut);
            }
            RefreshControls();Schedule();
        } catch(Exception error) { if(!closing)Report(error); }
        finally { if(closing)FinishClose();else RefreshControls(); }
    }
    private void AIResultUnavailable()
    {
        if(!settings.ActiveAIDenoise || aiJob.State.Status!=AIDenoiseStatus.Ready || aiJob.Identity is not {} identity)return;
        if(aiNotReadyIdentity!=identity) { aiNotReadyIdentity=identity;aiNotReadyAttempts=0; }
        if(++aiNotReadyAttempts>MaxAIReprepareAttempts) {
            aiJob.Fail(Loc.Text("AI 降噪结果连续未就绪，请重试。"));aiManuallyRequested=false;
            ClearPendingAllReset();RefreshControls();return;
        }
        aiJob.Reset();previewDeferred=true;if(!exporting)ReconcileAI();
    }
    private bool HandleAIFailure(Exception error)
    {
        if(!settings.ActiveAIDenoise)return false;
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
