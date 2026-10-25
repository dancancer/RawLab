using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace RawLab.Windows;

public partial class MainWindow
{
    internal readonly DesktopUpdateController desktopUpdates;
    private SoftwareUpdateWindow? softwareUpdateWindow;
    private readonly DispatcherTimer updateGateTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool preservingUpdateNavigation, updateQuitPending, updateQuitApproved;
    internal bool UpdateDataHealthy {
        get {try {_=presetStore.List();return editStore!=null && lookLibrary!=null && !updateJournalLoadFailed;}catch{return false;}}
    }
    private bool UpdateInstallationActive => desktopUpdates.BlocksEditing;

    private void InitializeSoftwareUpdates()
    {
        var reference = new WeakReference<MainWindow>(this);
        desktopUpdates.Gate.Register(this, () => reference.TryGetTarget(out var window) ? window.UpdateStatus() : new(),
            () => !reference.TryGetTarget(out var window) || window.PrepareUpdateData());
        desktopUpdates.PropertyChanged += UpdateChanged;
        desktopUpdates.RestartRequested += RestartForUpdate;
        updateGateTimer.Tick += async (_, _) => await desktopUpdates.RefreshGateAsync();
        Loaded += (_, _) => updateGateTimer.Start();
        Activated += (_, _) => preservingUpdateNavigation = false;
        MainMenu.PreviewGotKeyboardFocus += (_, e) => { if(IsUpdateMenuNavigation(e.NewFocus as DependencyObject))PreserveUpdateNavigation(); };
        MainMenu.AddHandler(MenuItem.SubmenuClosedEvent, new RoutedEventHandler((_, _) => Dispatcher.BeginInvoke(() => {
            if(IsActive && !OwnedWindows.OfType<SettingsWindow>().Any(w=>w.IsVisible) && softwareUpdateWindow?.IsVisible!=true)
                preservingUpdateNavigation=false;
        }, DispatcherPriority.Background)));
        Closed += (_, _) => {
            updateGateTimer.Stop(); desktopUpdates.Gate.Unregister(this);
            desktopUpdates.PropertyChanged -= UpdateChanged; desktopUpdates.RestartRequested -= RestartForUpdate;
        };
        UpdateChanged(null, new(null));
    }
    private UpdateSessionStatus UpdateStatus() => new(
        Draft: transform.Active || ParameterRows(AdjustmentPanel).Any(row=>row.HasPendingInput) || interacting || editGesture != null,
        Unsaved: editDirty, SaveFailed: editStore==null || RetrySave.Visibility==Visibility.Visible || adjustmentReloadRequired,
        TasksRunning: foregroundBusy || autoExposing || transferPreparing || scheduler.Busy || embeddedScheduler.Busy || aiJob.State.IsRunning || batchWindow?.UpdateTasksRunning==true,
        JournalFailed: updateJournalLoadFailed || batchWindow?.UpdateJournalFailed==true);
    private bool PrepareUpdateData()
    {
        if(!SaveEdits() || updateJournalLoadFailed)return false;
        if(batchWindow!=null)return batchWindow.PrepareForUpdate();
        if(previousBatch==null)return true;
        try { batchJournal.Save(previousBatch);return true; }
        catch { updateJournalLoadFailed=true;return false; }
    }
    private void UpdateChanged(object? sender, PropertyChangedEventArgs args)
    {
        var version=desktopUpdates.State.Phase==UpdatePhase.Available ? desktopUpdates.State.Release?.Version :
            desktopUpdates.UnavailableReason!=null ? updates.Available?.Version : null;
        UpdateNotice.Content=version==null ? "" : Loc.Format("RawLab {0} 已发布",version);
        UpdateNotice.Visibility=version==null ? Visibility.Collapsed : Visibility.Visible;
        if(!closing)IsEnabled=!UpdateInstallationActive;
        if(batchWindow!=null)batchWindow.IsEnabled=!UpdateInstallationActive;
    }
    private void RestartForUpdate() => Close();
    private void PreserveUpdateNavigation()
    {
        preservingUpdateNavigation=true;
        foreach(var row in ParameterRows(AdjustmentPanel))row.PreserveInputForUpdateNavigation();
    }
    private bool IsUpdateMenuNavigation(DependencyObject? source)
    {
        while(source!=null)
        {
            if(ReferenceEquals(source,ToolsMenu))return true;
            source=source is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(source) : LogicalTreeHelper.GetParent(source);
        }
        return false;
    }
    private void SoftwareUpdatesClicked(object sender, RoutedEventArgs e) => ShowSoftwareUpdates(false);
    private void UpdateNavigationPressed(object sender,MouseButtonEventArgs e) => PreserveUpdateNavigation();
    private void ShowSoftwareUpdates(bool settings)
    {
        PreserveUpdateNavigation();
        if(softwareUpdateWindow==null)
        {
            softwareUpdateWindow=new(desktopUpdates,updates,settings){Owner=this};
            softwareUpdateWindow.Closed+=(_,_)=>softwareUpdateWindow=null;
            softwareUpdateWindow.Show();
        }
        else softwareUpdateWindow.Activate();
    }
    private async Task PrepareUpdateQuitAsync()
    {
        if(updateQuitPending)return;
        updateQuitPending=true;
        try { if(await desktopUpdates.PrepareForQuitAsync()){updateQuitApproved=true;Close();} }
        finally { updateQuitPending=false; }
    }
}
