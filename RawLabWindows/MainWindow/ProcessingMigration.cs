using System.IO;
using System.Windows;

namespace RawLab.Windows;

public partial class MainWindow
{
    private CancellationTokenSource? processingMigrationCancellation;
    private ProcessingMigrationReceipt? processingMigrationReceipt;
    private bool processingMigrationBusy;
    private sealed record PendingProcessingMigration(string Path,OriginalIdentity Source,SavedEdit Before,
        AdjustmentSnapshot ExpectedSettings,string? ExpectedLook,OriginalIdentity? LookIdentity,long Opened,long Revision,
        Native.ProcessingMigrationResult Result,CancellationTokenSource Cancellation);
    private PendingProcessingMigration? processingMigrationPending;

    private void CancelProcessingMigration()
    {
        processingMigrationCancellation?.Cancel();
        processingMigrationCancellation=null;
        processingMigrationPending=null;
        processingMigrationBusy=false;
        RefreshProcessingMigrationControls();
    }

    private void BeginProcessingMigration(string path)
    {
        if (processingMigrationBusy || closing || exporting || editDirty || file != path || currentEditRecord?.Edit is not { } before ||
            !ProcessingMigration.ShouldAttempt(before,processingMigrationReceipt) || !LookAvailable)
            return;
        var source=before.Identity;
        try { if (!source.SameFile(OriginalIdentity.Read(path))) return; }
        catch (IOException) { return; }
        var snapshot=settings.Clone();
        var expectedSettings=snapshot.Capture();
        var opened=openRevision;var revision=editRevision;var expectedLook=lut;var gpu=RequestedGpuMode;
        OriginalIdentity? lookIdentity;
        try { lookIdentity=expectedLook == null ? null : OriginalIdentity.Read(expectedLook); }
        catch (IOException) { return; }
        var cancellation=new CancellationTokenSource();processingMigrationCancellation=cancellation;processingMigrationBusy=true;
        RefreshProcessingMigrationControls();
        _=Task.Run(() =>
        {
            try
            {
                using var worker=new RenderEngine(gpuMode:gpu);
                var result=worker.MigrateProcessing(path,snapshot,expectedLook,cancellation.Token);
                Dispatcher.BeginInvoke(new Action(() => FinishProcessingMigration(path,source,before,expectedSettings,expectedLook,lookIdentity,opened,revision,result,cancellation)));
            }
            catch (OperationCanceledException)
            {
                Dispatcher.BeginInvoke(new Action(() => {
                    if (processingMigrationCancellation == cancellation) CancelProcessingMigration();
                }));
            }
            catch (Exception error)
            {
                Dispatcher.BeginInvoke(new Action(() => FailProcessingMigration(path,opened,revision,cancellation,error)));
            }
        },cancellation.Token);
    }

    private bool MigrationIsCurrent(string path,OriginalIdentity source,SavedEdit before,AdjustmentSnapshot expectedSettings,string? expectedLook,OriginalIdentity? lookIdentity,long opened,long revision)
    {
        if (closing || file != path || openRevision != opened || editRevision != revision || editDirty ||
            editGesture != null || transform.Active || exporting || aiJob.State.IsRunning || lut != expectedLook ||
            currentEditRecord?.Edit is not { } current || !current.SameAs(before)) return false;
        try
        {
            var currentSettings=settings.Capture();
            // Native WB metadata may hydrate AsShot after the old frame is displayed;
            // it is not a user edit and is intentionally excluded from this guard.
            currentSettings=currentSettings with { AsShotTemperature=expectedSettings.AsShotTemperature, AsShotTint=expectedSettings.AsShotTint };
            if (!currentSettings.SameAs(expectedSettings)) return false;
        }
        catch (InvalidDataException) { return false; }
        try { return source.SameFile(OriginalIdentity.Read(path)) &&
            (lookIdentity == null || lookIdentity.SameFile(OriginalIdentity.Read(lookIdentity.Path))); }
        catch (IOException) { return false; }
    }

    private void FinishProcessingMigration(string path,OriginalIdentity source,SavedEdit before,AdjustmentSnapshot expectedSettings,string? expectedLook,OriginalIdentity? lookIdentity,
        long opened,long revision,Native.ProcessingMigrationResult nativeResult,CancellationTokenSource cancellation)
    {
        if (processingMigrationCancellation != cancellation) return;
        if (!MigrationIsCurrent(path,source,before,expectedSettings,expectedLook,lookIdentity,opened,revision))
        {
            processingMigrationCancellation=null;processingMigrationBusy=false;RefreshProcessingMigrationControls();return;
        }
        if (result == null || !exactReady)
        {
            processingMigrationPending=new(path,source,before,expectedSettings,expectedLook,lookIdentity,opened,revision,nativeResult,cancellation);
            RefreshProcessingMigrationControls();return;
        }
        processingMigrationCancellation=null;processingMigrationBusy=false;
        try
        {
            PhotoEditState saved;
            if (ProcessingMigration.IsRejectedResult(before,nativeResult))
            {
                saved=editStore!.CommitProcessingMigration(source,before,before,ProcessingMigrationReceipt.Kept);
                TransferSession.RememberExternalSave(saved);
            }
            else if (ProcessingMigration.TryBuildCandidate(before,nativeResult,out var candidate) && candidate != null)
            {
                saved=editStore!.CommitProcessingMigration(source,before,candidate,ProcessingMigrationReceipt.Migrated);
                TransferSession.AdoptExternalProcessingMigration(saved);
                currentEditRecord=saved;settings=candidate.Settings.Restore();editDirty=false;++editRevision;
                ResetAITask();RefreshControls();Schedule();
            }
            else { RefreshProcessingMigrationControls(); return; }
            currentEditRecord=saved;processingMigrationReceipt=editStore.ReadProcessingMigration(path);
            RefreshControls();
        }
        catch (AdjustmentOperationExpiredException) { RefreshProcessingMigrationControls(); }
        catch (Exception error) { Report(error);RefreshProcessingMigrationControls(); }
    }

    private void FailProcessingMigration(string path,long opened,long revision,CancellationTokenSource cancellation,Exception error)
    {
        if (processingMigrationCancellation != cancellation) return;
        processingMigrationCancellation=null;processingMigrationBusy=false;
        processingMigrationPending=null;
        if (!closing && file == path && openRevision == opened && editRevision == revision) Report(error);
        RefreshProcessingMigrationControls();
    }

    private void TryFinishPendingProcessingMigration()
    {
        if (processingMigrationPending is not { } pending || result == null || !exactReady) return;
        processingMigrationPending=null;
        FinishProcessingMigration(pending.Path,pending.Source,pending.Before,pending.ExpectedSettings,pending.ExpectedLook,pending.LookIdentity,
            pending.Opened,pending.Revision,pending.Result,pending.Cancellation);
    }

    private void RefreshProcessingMigrationControls()
    {
        if (ProcessingMigrationState == null || RollbackProcessingMigrationButton == null) return;
        var currentOld=settings.Processing.Version is 1 or 2;
        var receiptVisible=processingMigrationReceipt?.Status == ProcessingMigrationReceipt.Migrated ||
            currentOld && processingMigrationReceipt?.Status is ProcessingMigrationReceipt.Kept or ProcessingMigrationReceipt.RolledBack;
        var visible=processingMigrationBusy || receiptVisible;
        ProcessingMigrationState.Visibility=visible ? Visibility.Visible : Visibility.Collapsed;
        ProcessingMigrationState.Text=processingMigrationBusy ? Loc.Text("正在匹配原画面…") : processingMigrationReceipt?.Status switch {
            ProcessingMigrationReceipt.Migrated => Loc.Text("已自动升级，原设置已保留。"),
            ProcessingMigrationReceipt.Kept => Loc.Text("画面差异较大，已保留旧版本。"),
            ProcessingMigrationReceipt.RolledBack => Loc.Text("已回退，保留旧版本。"),
            _ => ""
        };
        RollbackProcessingMigrationButton.Visibility=!processingMigrationBusy && processingMigrationReceipt?.Status == ProcessingMigrationReceipt.Migrated
            ? Visibility.Visible : Visibility.Collapsed;
        RollbackProcessingMigrationButton.IsEnabled=file != null && !processingMigrationBusy && !exporting && !transform.Active &&
            !interacting && editGesture == null;
    }

    private void RollbackProcessingMigrationClicked(object sender,RoutedEventArgs e)
    {
        if (file == null || processingMigrationBusy || processingMigrationReceipt?.Status != ProcessingMigrationReceipt.Migrated ||
            exporting || transform.Active || interacting || editGesture != null || currentEditRecord == null) return;
        if (MessageBox.Show(this,Loc.Text("将恢复迁移前的全部调整，之后的修改会被替换。"),Loc.Text("回到迁移前"),
            MessageBoxButton.YesNo,MessageBoxImage.Warning,MessageBoxResult.No) != MessageBoxResult.Yes) return;
        try
        {
            if (!SaveEdits()) return;
            var before=currentEditRecord;var identity=before.Identity;
            var saved=editStore!.RollbackProcessingMigration(identity,before);
            TransferSession.AdoptExternalProcessingMigration(saved);
            currentEditRecord=saved;processingMigrationReceipt=editStore.ReadProcessingMigration(file);AdoptSavedEdit(saved);
        }
        catch (Exception error) { Report(error); }
    }
}
