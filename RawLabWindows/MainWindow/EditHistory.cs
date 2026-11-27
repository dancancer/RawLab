using System.IO;
using System.Windows;
using System.Windows.Controls.Primitives;

namespace RawLab.Windows;

public partial class MainWindow
{
    private AdjustmentTransferSession? adjustmentSession => persistence.AdjustmentSession;
    private PhotoEditState? currentEditRecord => persistence.CurrentRecord;
    private sealed record EditGesture(string Path,long OpenRevision,SavedEdit Before,bool WasDirty);
    private EditGesture? editGesture;
    private AdjustmentTransferSession TransferSession => persistence.EnsureTransferSession();
    private void InitializeAdjustmentHistory()
    {
        AdjustmentPanel.AddHandler(ParameterRow.GestureStartedEvent,new RoutedEventHandler((_,_)=>BeginEditGesture()));
        AdjustmentPanel.AddHandler(ParameterRow.GestureCancelledEvent,new RoutedEventHandler((_,_)=>CancelEditGesture()));
        AdjustmentPanel.AddHandler(ParameterRow.GestureCompletedEvent,new RoutedEventHandler((_,_)=>{
            editGesture=null;
            var wasInteracting=interacting;
            if(!transform.Active)interacting=false;
            if(wasInteracting && !interacting)RefreshControls();
        }));
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
        var wasInteracting = interacting;
        interacting = false;
        if (editGesture is not {} gesture)
        {
            if (wasInteracting) RefreshControls();
            return;
        }
        editGesture = null; editSaveTimer.Stop();
        if(file!=gesture.Path || openRevision!=gesture.OpenRevision)return;
        var aiEnabled=settings.ActiveAIDenoise;
        var aiChanged=aiEnabled!=gesture.Before.Settings.ActiveAIDenoise;
        settings=gesture.Before.Settings.Restore();settings.ActiveAIDenoise=aiEnabled;lut=ResolveLook(gesture.Before);
        persistence.RevertGesture(gesture.WasDirty, aiChanged);
        ClearTransferNoticesOnUserEdit();RefreshControls();Schedule();
        if(aiChanged && !closing)EnqueueSaveEdits();
    }
    private AdjustmentOutcome CommitCurrentEdit(AdjustmentSnapshot snapshot)
    {
        if(file==null)throw new InvalidOperationException("No photo is open.");
        var candidate=new SavedEdit(CurrentOrReadViewSource(),snapshot,CurrentLookIdentity());
        var before=currentEditRecord ?? new PhotoEditState(candidate.Identity,null);
        SavedEdit? defaultEdit=null;
        if(before.Edit==null) {
            var defaults=PhotoInput.PrepareDefaultSettings(file);defaults.ResolveWhiteBalance(settings.AsShot);
            defaultEdit=new(candidate.Identity,defaults.Capture(),null);
        }
        return persistence.CommitSynchronously(
            candidate,
            defaultEdit,
            clearMigrationReceipt: false,
            OnEditSaveApplied,
            OnEditSaveFailed,
            FlushDeferredExternalEditsCheckIfNeeded);
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
    private void AdoptSavedEdit(PhotoEditState saved)
    {
        var previous = persistence.AdoptSavedEdit(saved, transform.Active || editGesture != null);
        if (previous == null) return;
        ApplyAdoptedEditToUi(saved, previous);
    }

    private void ApplyAdoptedEditToUi(PhotoEditState saved, PhotoEditState? previous)
    {
        if (file == null) return;
        var calibration=settings.AsShot;
        var previousLook=previous?.Edit?.Look;
        var restored=saved.Edit?.Settings.Restore() ?? PhotoInput.PrepareDefaultSettings(file);
        if(calibration!=null)restored.ResolveWhiteBalance(calibration);
        var restoredLook=saved.Edit is {} edit ? ResolveLook(edit) : null;
        settings=restored;lut=restoredLook;
        ResetAITask();
        if(lut!=null && !films.Any(f=>StringComparer.OrdinalIgnoreCase.Equals(f.Path,lut))) {
            var managed=lookLibrary?.Looks.FirstOrDefault(look=>StringComparer.OrdinalIgnoreCase.Equals(look.Path,lut));
            films.Add(new(managed?.Name ?? lookLibrary?.DisplayName(lut,Path.GetFileNameWithoutExtension(lut)) ?? Path.GetFileNameWithoutExtension(lut),lut,null,
                AppearanceUnverified:managed?.AppearanceUnverified ?? false,CompatibilityMode:managed?.CompatibilityMode ?? 0));BuildFilms();
        }
        RecordRecentLook(previousLook,saved.Edit?.Look);
        RefreshControls();Schedule();
    }
    private bool PrepareAdjustmentCommand()
    {
        CancelCanvasProbeInputs();
        if(file==null || exporting || closing || aiJob.State.IsRunning)return false;
        foreach(var row in ParameterRows(AdjustmentPanel).Where(row=>row.IsVisible && row.IsEnabled)) {
            if(row.Commit())continue;
            row.Number.Focus();return false;
        }
        if(editGesture!=null)return false;
        return ResolveTransformDraft() && SaveEdits();
    }
    private async Task<bool> PrepareAdjustmentCommandAsync()
    {
        CancelCanvasProbeInputs();
        if(file==null || exporting || closing || aiJob.State.IsRunning)return false;
        foreach(var row in ParameterRows(AdjustmentPanel).Where(row=>row.IsVisible && row.IsEnabled)) {
            if(row.Commit())continue;
            row.Number.Focus();return false;
        }
        if(editGesture!=null)return false;
        return ResolveTransformDraft() && await FlushSaveEditsAsync();
    }
    private bool HistoryTargetIsCurrent(string path)=>!StringComparer.OrdinalIgnoreCase.Equals(path,file) ||
        !editDirty && !transform.Active && editGesture==null && !exporting && !closing && !aiJob.State.IsRunning;

    internal bool ReloadCurrentAdjustments()
    {
        if(file==null)return false;
        try {
            _=editStore!.ReadState(file);
            editGesture=null;persistence.DiscardDirtyState();interacting=false;
            if(transform.Active){transform.Cancel();EndTransform();}
            editNoticeTimer.Stop();SaveState.Text="";saveNoticeKey=null;RetrySave.Visibility=Visibility.Collapsed;
            var opened=openRevision;OpenFile(file);return openRevision!=opened;
        }catch(Exception error){ShowAdjustmentError(error);return false;}
    }
}
