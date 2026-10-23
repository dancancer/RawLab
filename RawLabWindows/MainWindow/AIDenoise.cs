using System.IO;

namespace RawLab.Windows;
public partial class MainWindow
{
    private readonly AIDenoiseJob aiJob;
    private bool aiManuallyRequested;
    private int RequestedAIBackend=>GpuMode.SelectedIndex switch { 1=>0,2=>3,_=>2 };
    private bool CanStartAI=>file!=null && PhotoInput.IsRaw(file) && RenderEngine.AIAvailable &&
        RenderEngine.HasBundledAIModel && !exporting && !transform.Active && !closing;
    private bool AIResultReady
    {
        get {
            if(!settings.AIDenoiseEnabled)return true;
            try { return file!=null && aiJob.State.Status==AIDenoiseStatus.Ready &&
                aiJob.Identity==AIDenoiseIdentity.Read(file,settings,RequestedAIBackend); }
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
    }
    private void RefreshAIControls()=>DenoiseEditor.RefreshAI(RenderEngine.AIAvailable || settings.AIDenoiseEnabled,
        settings.AIDenoiseEnabled,CanStartAI,aiJob.State);
    private void ResetAITask() { aiManuallyRequested=false;aiJob.Reset(); }
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
        if(file==null || closing || aiJob.State.Status is AIDenoiseStatus.Failed or AIDenoiseStatus.Cancelled)return;
        try {
            var identity=AIDenoiseIdentity.Read(file,settings,RequestedAIBackend);
            if(identity!=aiJob.Identity)RequestAI(false);
        } catch(Exception error) when(error is IOException or UnauthorizedAccessException) { Report(error); }
    }
    private async void RequestAI(bool explicitRequest)
    {
        if(file==null || closing || exporting || transform.Active)return;
        if(explicitRequest && !CanStartAI)return;
        try {
            var identity=AIDenoiseIdentity.Read(file,settings,RequestedAIBackend);
            var revision=openRevision;
            if(!explicitRequest && identity==aiJob.Identity)return;
            if(explicitRequest)aiManuallyRequested=true;
            exactReady=false;
            var work=aiJob.StartAsync(identity,settings);RefreshControls();
            var completed=await work;
            if(closing)return;
            if(!completed && revision==openRevision && aiJob.Identity==identity &&
                aiJob.State.Status is AIDenoiseStatus.Failed or AIDenoiseStatus.Cancelled && !settings.AIDenoiseEnabled) {
                aiManuallyRequested=false;Schedule();return;
            }
            if(!completed || revision!=openRevision || file!=identity.Source.Path ||
                aiJob.Identity!=identity || aiJob.State.Status!=AIDenoiseStatus.Ready ||
                AIDenoiseIdentity.Read(file,settings,RequestedAIBackend)!=identity)return;
            aiManuallyRequested=false;settings.AIDenoiseEnabled=true;MarkEdited();RefreshControls();Schedule();
        } catch(Exception error) { if(!closing)Report(error); }
        finally { if(closing)FinishClose();else RefreshControls(); }
    }
    private void AIResultUnavailable()
    {
        if(!settings.AIDenoiseEnabled || aiJob.State.Status!=AIDenoiseStatus.Ready)return;
        aiJob.Reset();previewDeferred=true;if(!exporting)ReconcileAI();
    }
    private bool HandleAIFailure(Exception error)
    {
        if(!settings.AIDenoiseEnabled)return false;
        if(error is AINotReadyException) {AIResultUnavailable();return true;}
        if(error is AIDenoiseException) {aiJob.Fail(error.Message);RefreshControls();return true;}
        return false;
    }
}
