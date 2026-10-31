using System.IO;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace RawLab.Windows;

public partial class MainWindow
{
    private bool transferPreparing;
    private bool adjustmentReloadRequired;
    private int transferGeneration;
    private IReadOnlySet<string> AvailableTransferLooks()=>films.Where(f=>f.Path!=null && File.Exists(f.Path)).Select(f=>
        StringComparer.OrdinalIgnoreCase.Equals(Path.GetDirectoryName(f.Path),Path.Combine(AppContext.BaseDirectory,"LUTs"))
            ? "builtin:"+Path.GetFileName(f.Path) : lookLibrary?.IdentityForPath(f.Path) ?? f.Path!)
        .Concat(MasterRecipe.All.Where(r=>File.Exists(r.LutPath)).Select(r=>"recipe:"+r.Id)).ToHashSet(StringComparer.Ordinal);
    private AdjustmentTransferContext CurrentTransferContext()=>new(file!,PhotoInput.IsRaw(file!),AvailableTransferLooks(),
        HasUncommittedDraft:transform.Active || editGesture!=null,CameraWhiteBalance:settings.AsShot);
    private void CopyAdjustmentsClicked(object sender,RoutedEventArgs e)
    {
        if(!PrepareAdjustmentCommand())return;
        try {
            var dialog=new AdjustmentScopeDialog(this,file!,scope=>{
                try {CopyCurrentAdjustments(scope);return null;}
                catch(Exception error){return AdjustmentTransferPresentation.Error(error);}
            },hdr:settings.IsHDREditing,preview:PreviewAdjustmentPayload,lookName:AdjustmentSummaryLookName);
            if(dialog.ShowDialog()==true)SetStatus(()=>Loc.Text("调整已复制。"),false);
        }catch(Exception error){ShowAdjustmentError(error);}
    }
    internal AdjustmentPayload CopyCurrentAdjustments(AdjustmentScope scope)
        => TransferSession.Copy(scope,CaptureVerifiedAdjustmentSource(),CurrentTransferContext());
    private async void PasteAdjustmentsClicked(object sender,RoutedEventArgs e)
    {
        if(!PrepareAdjustmentCommand())return;
        if(TransferSession.Clipboard is not {} payload){SetStatus(()=>Loc.Text("尚未复制调整。请先从一张照片复制所需范围。"),true);return;}
        await ShowAdjustmentPreflight(payload,[file!]);
    }
    private async void PasteAdjustmentsToPhotosClicked(object sender,RoutedEventArgs e)
    {
        if(!PrepareAdjustmentCommand())return;
        if(TransferSession.Clipboard is not {} payload){SetStatus(()=>Loc.Text("尚未复制调整。请先从一张照片复制所需范围。"),true);return;}
        var picker=new OpenFileDialog{Title=Loc.Text("选择目标照片"),Filter=Loc.Text("照片|")+LibraryEntry.ImageFilter,Multiselect=true};
        if(picker.ShowDialog(this)==true)await ShowAdjustmentPreflight(payload,picker.FileNames);
    }
    internal async Task<PreparedAdjustmentTransfer?> PrepareAdjustmentTargets(AdjustmentPayload payload,IEnumerable<string> paths,
        AdjustmentHistoryAction action=AdjustmentHistoryAction.Paste,OriginalIdentity? frozenSource=null,
        IReadOnlyDictionary<string,CollectionPhoto>? collectionTargets=null)
    {
        var generation=++transferGeneration;var revision=editRevision;var opened=openRevision;var current=file;
        var session=TransferSession;var looks=AvailableTransferLooks();var selected=paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        transferPreparing=true;
        try {
            var result=await Task.Run(()=>{
                var prepared=false;
                bool IsCurrent()=>!closing && transferGeneration==generation && openRevision==opened && file==current &&
                    (prepared ? !editDirty && !transform.Active && editGesture==null : editRevision==revision);
                var targets=new List<AdjustmentTransferTarget>();
                foreach(var path in selected) {
                    if(!IsCurrent())return null;
                    try {
                        collectionTargets?.GetValueOrDefault(path)?.Validate();
                        var identity=OriginalIdentity.Read(path);var raw=PhotoInput.IsRaw(path);
                        var defaults=PhotoInput.PrepareHDRInputSettings(path,new Adjustments());
                        (double Temperature,double Tint)? calibration=null;
                        if(raw) {
                            using var native=new RenderEngine(1);
                            calibration=native.Render(path,defaults,null,32,statistics:false,clipping:false)?.WhiteBalance;
                        }
                        if(!OriginalIdentity.Read(path).SameFile(identity))throw new EditPersistenceConflict();
                        var context=new AdjustmentTransferContext(path,raw,looks,CameraWhiteBalance:calibration,ValidateLens:lens=>{
                            using var native=new RenderEngine(1);var probe=new Adjustments{Lens=lens};
                            var report=native.Render(path,probe,null,32,statistics:false,clipping:false)?.Lens;
                            if(report==null || lens.Distortion && !report.AppliedDistortion || lens.Tca && !report.AppliedTca)
                                throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"target lens calibration unavailable");
                        });
                        if(calibration!=null)defaults.ResolveWhiteBalance(calibration);
                        targets.Add(new(path,new(identity,defaults.Capture(),null),context,IsCurrent));
                    }catch(Exception error) {
                        // 让失败保持为独立目标，预检界面才能明确显示并允许用户跳过。
                        var failure=error;
                        targets.Add(new(path,new(new(Path.GetFullPath(path),0,0,0),new Adjustments().Capture(),null),new(path,PhotoInput.IsRaw(path)),()=>throw failure));
                    }
                }
                if(!IsCurrent())return null;
                var operation=session.Prepare(payload,targets,action,frozenSource);prepared=true;return operation;
            });
            return !closing && generation==transferGeneration && revision==editRevision && opened==openRevision && file==current ? result : null;
        }finally{if(generation==transferGeneration)transferPreparing=false;}
    }
    private async Task ShowAdjustmentPreflight(AdjustmentPayload payload,IEnumerable<string> paths,
        AdjustmentHistoryAction action=AdjustmentHistoryAction.Paste,string? sourceName=null)
    {
        if(transferPreparing)return;
        try {
            var operation=await PrepareAdjustmentTargets(payload,paths,action);if(operation==null)return;
            if(operation.Targets.Count==0){SetStatus(()=>Loc.Text("此目录没有照片。"),true);return;}
            var initial=operation.Targets.Select(t=>new AdjustmentOutcome(t.ID,t.Unchanged ? AdjustmentStatus.Unchanged : AdjustmentStatus.Blocked,
                Error:t.Error,RequiresHistoryDecision:t.Error!=null)).ToArray();
            var adopted=new Dictionary<string,Exception?>();
            var session=TransferSession;AdjustmentResultDialog? dialog=null;
            dialog=new AdjustmentResultDialog(this,action==AdjustmentHistoryAction.Preset ? "应用预设" : "粘贴调整",initial,true,skipping=>AdoptAdjustmentOutcomes(session.Apply(operation,skipping),adopted),
                ()=>ReloadEditsClicked(this,new()),Loc.Format("来源：{0} · {1} 项调整",sourceName ?? Path.GetFileName(payload.Source.Identifier),payload.Fields.Count),
                ()=>session.Transactions.FirstOrDefault(t=>t.ID==operation.ID)?.Parts ?? [],undo=>RunAdjustmentHistory(operation.ID,null,undo,dialog!),payload,AdjustmentSummaryLookName);
            dialog.ShowDialog();
        }catch(Exception error){ShowAdjustmentError(error);}
    }
    private IReadOnlyList<AdjustmentOutcome> AdoptAdjustmentOutcomes(IReadOnlyList<AdjustmentOutcome> outcomes,Dictionary<string,Exception?> adopted)
    {
        return outcomes.Select(outcome=>{
            if(outcome.Status!=AdjustmentStatus.Applied || outcome.Saved is not {} saved ||
                !StringComparer.OrdinalIgnoreCase.Equals(saved.Identity.Path,file))return outcome;
            var key=saved.Identity.Path+"\n"+saved.Revision;
            if(adopted.TryGetValue(key,out var previousError))return previousError==null ? outcome : outcome with {Error=previousError,RequiresHistoryDecision=false};
            try{
                AdoptSavedEdit(saved);
                if(quickPresetsVisible && quickPreset.Phase!=QuickPresetPhase.Preparing)CancelQuickPreset();
                adopted[key]=null;return outcome;
            }
            catch(Exception error){adopted[key]=error;adjustmentReloadRequired=true;RefreshControls();return outcome with {Error=error,RequiresHistoryDecision=false};}
        }).ToArray();
    }
    private void UndoAdjustmentClicked(object sender,RoutedEventArgs e)=>RunPhotoHistory(true);
    private void RedoAdjustmentClicked(object sender,RoutedEventArgs e)=>RunPhotoHistory(false);
    private void RunPhotoHistory(bool undo)
    {
        if(!PrepareAdjustmentCommand() || TransferSession.PhotoHistoryID(file!,undo) is not {} id)return;
        RunAdjustmentHistory(id,file,undo,this);
    }
    private void ShowAdjustmentHistoryClicked(object sender,RoutedEventArgs e)
    {
        if(!PrepareAdjustmentCommand())return;
        AdjustmentHistoryDialog? dialog=null;
        dialog=new(this,()=>TransferSession.Transactions,(id,undo)=>RunAdjustmentHistory(id,null,undo,dialog!));dialog.ShowDialog();
    }
    private void RunAdjustmentHistory(Guid id,string? photo,bool undo,Window owner)
    {
        var adopted=new Dictionary<string,Exception?>();
        IReadOnlyList<AdjustmentOutcome> Run(IReadOnlySet<string> skipped) {
            var results=photo!=null ? skipped.Contains(photo) ? new[]{new AdjustmentOutcome(photo,AdjustmentStatus.Skipped)} :
                undo ? TransferSession.UndoPhoto(photo,id,HistoryTargetIsCurrent) : TransferSession.RedoPhoto(photo,id,HistoryTargetIsCurrent)
                : undo ? TransferSession.UndoTransaction(id,skipped,HistoryTargetIsCurrent) : TransferSession.RedoTransaction(id,skipped,HistoryTargetIsCurrent);
            return AdoptAdjustmentOutcomes(results,adopted);
        }
        var initial=Run(new HashSet<string>(StringComparer.OrdinalIgnoreCase));
        if(initial.Any(o=>o.Error!=null))new AdjustmentResultDialog(owner,undo ? "撤销" : "重做",initial,false,Run,()=>{
            if(owner!=this)owner.Close();
            ReloadEditsClicked(this,new());
        }).ShowDialog();
    }
    private void ShowAdjustmentError(Exception error)=>MessageBox.Show(this,AdjustmentTransferPresentation.Error(error),Loc.Text("调整未应用"),MessageBoxButton.OK,MessageBoxImage.Information);
    private void EditMenuOpened(object sender,RoutedEventArgs e)
    {
        PresetsAdjustmentMenu.IsEnabled=!exporting && !closing && !transferPreparing;
        var enabled=file!=null && !exporting && !closing && !aiJob.State.IsRunning && !adjustmentReloadRequired;
        UndoAdjustmentMenu.IsEnabled=enabled && adjustmentSession?.PhotoHistoryID(file!,true)!=null;
        RedoAdjustmentMenu.IsEnabled=enabled && adjustmentSession?.PhotoHistoryID(file!,false)!=null;
        CopyAdjustmentMenu.IsEnabled=HistoryAdjustmentMenu.IsEnabled=enabled;
        PasteAdjustmentMenu.IsEnabled=PastePhotosAdjustmentMenu.IsEnabled=enabled && adjustmentSession?.Clipboard!=null;
    }
}
