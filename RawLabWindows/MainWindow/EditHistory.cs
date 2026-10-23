using System.IO;
using System.Windows;
using System.Windows.Controls.Primitives;

namespace RawLab.Windows;

public partial class MainWindow
{
    private AdjustmentTransferSession? adjustmentSession;
    private EditStore? sessionStore;
    private VersionedPhotoEdit? currentEditRecord;
    private sealed record EditGesture(string Path,long OpenRevision,SavedEdit Before,bool WasDirty);
    private EditGesture? editGesture;
    private AdjustmentTransferSession TransferSession
    {
        get {
            editStore ??=new(EditStore.DefaultDirectory);
            if(adjustmentSession==null || !ReferenceEquals(sessionStore,editStore)) {sessionStore=editStore;adjustmentSession=new(editStore);}
            return adjustmentSession;
        }
    }
    private void InitializeAdjustmentHistory()
    {
        AdjustmentPanel.AddHandler(ParameterRow.GestureStartedEvent,new RoutedEventHandler((_,_)=>BeginEditGesture()));
        AdjustmentPanel.AddHandler(ParameterRow.GestureCancelledEvent,new RoutedEventHandler((_,_)=>CancelEditGesture()));
        AdjustmentPanel.AddHandler(ParameterRow.GestureCompletedEvent,new RoutedEventHandler((_,_)=>{editGesture=null;if(!transform.Active)interacting=false;}));
    }
    private void BeginEditGesture()
    {
        if(!ready || syncing || file==null || transform.Active || closing || exporting)return;
        if(editGesture!=null)CancelEditGesture();
        try {editGesture=new(file,openRevision,CaptureCurrentEdit(),editDirty);}
        catch(Exception error) {SetSaveNotice("调整未保存 · 重试",error.Message,true);}
    }
    private void CancelEditGesture()
    {
        if(editGesture is not {} gesture)return;
        editGesture=null;interacting=false;editSaveTimer.Stop();
        if(file!=gesture.Path || openRevision!=gesture.OpenRevision)return;
        settings=gesture.Before.Settings.Restore();lut=ResolveLook(gesture.Before);
        editDirty=gesture.WasDirty;++editRevision;RefreshControls();Schedule();
    }
    private AdjustmentOutcome CommitCurrentEdit(AdjustmentSnapshot snapshot)
    {
        if(file==null || currentEditRecord==null)throw new EditPersistenceConflict();
        var candidate=new SavedEdit(OriginalIdentity.Read(file),snapshot,CurrentLookIdentity());
        var defaults=RenderEngine.PrepareInputSettings(file,new Adjustments());defaults.ResolveWhiteBalance(settings.AsShot);
        var result=TransferSession.CommitEdit(currentEditRecord,candidate,new(candidate.Identity,defaults.Capture(),null));
        if(result.Status is not (AdjustmentStatus.Applied or AdjustmentStatus.Unchanged))throw result.Error ?? new EditPersistenceConflict();
        currentEditRecord=result.Saved;return result;
    }
    private string? ResolveLook(SavedEdit saved)
    {
        if(saved.Settings.MasterRecipeID is {} recipe)return MasterRecipe.Find(recipe)?.LutPath;
        if(saved.Look?.StartsWith("recipe-lut:",StringComparison.Ordinal)==true)
            return MasterRecipe.Find(saved.Look[11..])?.LutPath ?? saved.Look;
        if(saved.Look?.StartsWith("builtin:",StringComparison.Ordinal)==true)
            return Path.Combine(AppContext.BaseDirectory,"LUTs",Path.GetFileName(saved.Look[8..]));
        return lookLibrary?.ResolveIdentity(saved.Look) ?? saved.Look;
    }
    private void AdoptSavedEdit(VersionedPhotoEdit saved)
    {
        if(file==null || !StringComparer.OrdinalIgnoreCase.Equals(file,saved.Identity.Path))return;
        if(editDirty || transform.Active || editGesture!=null)throw new AdjustmentTransferException(AdjustmentFailure.Draft);
        if(!editStore!.VersionedState(file).SameAs(saved))throw new EditPersistenceConflict();
        var calibration=settings.AsShot;
        currentEditRecord=saved;settings=saved.Edit?.Settings.Restore() ?? RenderEngine.PrepareInputSettings(file,new Adjustments());
        if(calibration!=null)settings.ResolveWhiteBalance(calibration);
        lut=saved.Edit is {} edit ? ResolveLook(edit) : null;
        if(lut!=null && !films.Any(f=>StringComparer.OrdinalIgnoreCase.Equals(f.Path,lut))) {films.Add(new(Path.GetFileNameWithoutExtension(lut),lut,null));BuildFilms();}
        ++editRevision;ResetAITask();RefreshControls();Schedule();
    }
    private bool PrepareAdjustmentCommand()
    {
        if(file==null || exporting || closing || aiJob.State.IsRunning || adjustmentReloadRequired)return false;
        CancelParameterInputs();CancelEditGesture();
        return ResolveTransformDraft() && SaveEdits();
    }
    private bool HistoryTargetIsCurrent(string path)=>!StringComparer.OrdinalIgnoreCase.Equals(path,file) ||
        !editDirty && !transform.Active && editGesture==null && !exporting && !closing && !aiJob.State.IsRunning && !adjustmentReloadRequired;

    private void ReloadEditsClicked(object sender,RoutedEventArgs e)
    {
        if(file==null || exporting || closing)return;
        if((editDirty || transform.Dirty || GeometryEditor.HasInvalidInput) && MessageBox.Show(this,
            Loc.Text("丢弃当前未保存修改并重新载入调整？"),Loc.Text("重新载入调整"),MessageBoxButton.YesNo,MessageBoxImage.Question)!=MessageBoxResult.Yes)return;
        ReloadCurrentAdjustments();
    }
    internal void ReloadCurrentAdjustments()
    {
        if(file==null)return;
        try {
            _=editStore!.VersionedState(file);
            editGesture=null;editDirty=false;interacting=false;adjustmentReloadRequired=false;
            if(transform.Active){transform.Cancel();EndTransform();}
            editNoticeTimer.Stop();SaveState.Text="";saveNoticeKey=null;RetrySave.Visibility=Visibility.Collapsed;OpenFile(file);
        }catch(Exception error){ShowAdjustmentError(error);}
    }
}
