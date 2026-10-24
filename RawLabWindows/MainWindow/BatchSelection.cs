using System.IO;
using System.Windows;

namespace RawLab.Windows;

public partial class MainWindow
{
    internal BatchSelectionSession Collection {get;}=new();
    private BatchSelectionWindow? collectionWindow;
    internal string? CollectionSourcePath=>file;
    internal bool CollectionBusy=>closing || exporting || transferPreparing;
    internal bool CollectionHasExport=>CurrentBatch!=null;
    internal string? CollectionSourceID {
        get {try{return file==null ? null : OriginalIdentity.Read(file).StableKey;}catch{return null;}}
    }
    private bool CommitCollectionInputs()
    {
        foreach(var row in ParameterRows(AdjustmentPanel).Where(row=>row.IsVisible && row.IsEnabled))
            if(!row.Commit()){row.Number.Focus();return false;}
        return editGesture==null;
    }
    private void OpenCollectionClicked(object sender,RoutedEventArgs e)
    {
        if(CollectionBusy)return;
        CancelHslTarget();
        if(!CommitCollectionInputs())return;
        if(Collection.CurrentID!=null && (!ResolveTransformDraft() || !SaveEdits()))return;
        if(file!=null)Collection.Add([file],file);
        Collection.ReturnToCollection();ShowCollection();
    }
    private void ShowCollection()
    {
        Collection.RefreshFailures();
        if(collectionWindow==null) {
            collectionWindow=new(this);
            collectionWindow.Closed+=(_,_)=>{collectionWindow=null;};
        }
        collectionWindow.Refresh(restorePosition:true);collectionWindow.Show();collectionWindow.Activate();RefreshControls();
    }
    internal void AddCollectionPhotos(IEnumerable<string> paths) {Collection.Add(paths,file);Collection.RefreshFailures();}
    internal bool EditCollectionPhoto(string id)
    {
        if(CollectionBusy || !CommitCollectionInputs())return false;
        var photo=Collection.Photos.FirstOrDefault(photo=>photo.ID==id);if(photo==null)return false;
        try {
            photo.Validate();
            if(!ResolveTransformDraft() || !SaveEdits())return false;
            if(!StringComparer.OrdinalIgnoreCase.Equals(file,photo.Path))OpenFile(photo.Path);
            if(!StringComparer.OrdinalIgnoreCase.Equals(file,photo.Path) || currentEditRecord==null ||
                !currentEditRecord.Identity.SameFile(photo.Identity))return false;
            Collection.BeginEditing(id);collectionWindow?.Hide();Activate();RefreshControls();return true;
        }catch(Exception error){Report(error);return false;}
    }
    internal string? CollectionDraftFailure(string id)
    {
        var photo=Collection.Photos.FirstOrDefault(photo=>photo.ID==id);
        if(photo==null || !StringComparer.OrdinalIgnoreCase.Equals(file,photo.Path))return null;
        if(!HistoryTargetIsCurrent(photo.Path))return SaveState.ToolTip as string ?? Loc.Text("请应用、放弃或跳过这张照片的草稿。");
        try {
            if(currentEditRecord==null || !editStore!.VersionedState(photo.Path).SameAs(currentEditRecord))throw new EditPersistenceConflict();
            return null;
        }catch(Exception error){return error.Message;}
    }
    internal bool ResolveCollectionDraft(string id,bool apply)
    {
        var photo=Collection.Photos.FirstOrDefault(photo=>photo.ID==id);
        if(photo==null || !StringComparer.OrdinalIgnoreCase.Equals(file,photo.Path))return true;
        if(closing || exporting || aiJob.State.IsRunning)return false;
        if(apply) {
            if(!CommitCollectionInputs())return false;
            if(transform.Active) {
                if(!transform.Dirty && !GeometryEditor.HasInvalidInput)CancelTransformDraft();
                else if(!ApplyTransformDraft())return false;
            }
            return SaveEdits() && !editDirty;
        }
        CancelParameterInputs();CancelEditGesture();
        if(transform.Active)CancelTransformDraft();
        editDirty=false;ReloadCurrentAdjustments();
        return !adjustmentReloadRequired && CollectionDraftFailure(id)==null;
    }
    internal void CancelCollectionOperation(){++transferGeneration;transferPreparing=false;}
    internal async Task SynchronizeCollection(Window owner)
    {
        if(CollectionBusy || !PrepareAdjustmentCommand() || file==null)return;
        var source=OriginalIdentity.Read(file);
        var targets=Collection.SynchronizationTargets(source.StableKey);
        if(targets.Count==0){MessageBox.Show(owner,Loc.Text("排除来源照片后没有可同步的目标。"));return;}
        AdjustmentPayload? payload=null;
        var scope=new AdjustmentScopeDialog(owner,Path.GetFileName(file)+" · "+Loc.Format("目标：{0} 张照片",targets.Count),selected=>{
            try{payload=CapturePresetAdjustments(selected);return null;}catch(Exception error){return error.Message;}
        },"同步调整","检查同步目标");
        if(scope.ShowDialog()!=true || payload==null)return;
        try {
            var expected=targets.ToDictionary(photo=>photo.Path,StringComparer.OrdinalIgnoreCase);
            var operation=await PrepareAdjustmentTargets(payload,targets.Select(photo=>photo.Path),AdjustmentHistoryAction.Synchronize,source,expected);
            if(!owner.IsVisible)return;
            if(operation==null)throw new InvalidOperationException(Loc.Text("照片或调整已变化，请重新检查。"));
            var initial=operation.Targets.Select(target=>new AdjustmentOutcome(target.ID,
                target.Unchanged ? AdjustmentStatus.Unchanged : AdjustmentStatus.Blocked,
                Error:target.Error,RequiresHistoryDecision:target.Error!=null)).ToArray();
            if(initial.Length==0)return;
            var adopted=new Dictionary<string,Exception?>();var session=TransferSession;AdjustmentResultDialog? dialog=null;
            dialog=new(owner,"同步调整",initial,true,skipping=>{
                var results=AdoptAdjustmentOutcomes(session.Apply(operation,skipping),adopted);
                Collection.RecordSynchronization(operation.ID,results.Any(result=>result.Status==AdjustmentStatus.Applied));
                return results;
            },sourceSummary:Loc.Format("来源：{0} · {1} 项调整",Path.GetFileName(source.Path),payload.Fields.Count),
                historyParts:()=>session.Transactions.FirstOrDefault(transaction=>transaction.ID==operation.ID)?.Parts ?? [],
                changeHistory:undo=>RunAdjustmentHistory(operation.ID,null,undo,dialog!));
            dialog.ShowDialog();
        }catch(Exception error){if(owner.IsVisible)MessageBox.Show(owner,error.Message,Loc.Text("调整未应用"),MessageBoxButton.OK,MessageBoxImage.Information);}
        finally{collectionWindow?.Refresh();}
    }
    internal void ShowCollectionHistory(Window owner)
    {
        if(Collection.LastSynchronization is not {} id)return;
        AdjustmentHistoryDialog? dialog=null;
        dialog=new(owner,()=>TransferSession.Transactions.Where(transaction=>transaction.ID==id).ToArray(),
            (transaction,undo)=>RunAdjustmentHistory(transaction,null,undo,dialog!));dialog.ShowDialog();
    }
    internal CollectionExportReview PrepareCollectionExport(IReadOnlyCollection<string> skipping,ExportFormat format,int? longEdge,string directory)
    {
        editStore ??=new(EditStore.DefaultDirectory);
        return new BatchSelectionExport(editStore,batchJournal,ResolveLook).Prepare(Collection,skipping,format,longEdge,directory,CollectionDraftFailure);
    }
    internal BatchJob FreezeCollectionExport(CollectionExportReview review)
    {
        if(CollectionBusy)throw new InvalidOperationException(Loc.Text("请等待当前操作完成。"));
        if(CurrentBatch is {} previous && previous.SelectedCount>previous.SucceededCount)
            throw new InvalidOperationException(Loc.Text("请先结束或完成当前导出任务。"));
        if(batchWindow!=null){batchWindow.Close();if(batchWindow!=null)throw new InvalidOperationException(Loc.Text("请先关闭当前任务窗口。"));}
        editStore ??=new(EditStore.DefaultDirectory);
        var job=new BatchSelectionExport(editStore,batchJournal,ResolveLook).Freeze(Collection,review,CollectionDraftFailure);
        previousBatch=job;ShowBatch(job);return job;
    }
    internal void ViewCollectionExport()=>ShowBatchClicked(this,new());
}
