using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;

namespace RawLab.Windows;

public partial class MainWindow
{
    private readonly TransformDraft transform=new();
    private long transformGeneration;
    private EditorEditSource? transformSource;
    private bool transformSaveFailed;
    private bool transformPreviewReady,savedTransformCompare;
    private GeometrySettings PreviewGeometry=>transform.Active ? transform.PreviewGeometry : settings.Geometry;
    private LensSettings PreviewLens=>transform.Active ? transform.Lens : settings.Lens;
    private bool CanApplyTransform=>transform.Dirty && transformPreviewReady && !scheduler.Busy && !previewResize.IsEnabled &&
        result!=null && !renderFailed && LookAvailable && !exporting && (transform.Tool!=TransformTool.Geometry || !GeometryEditor.HasInvalidInput);
    private void BeginTransform(TransformTool tool)
    {
        if(file==null || exporting || (transform.Active && transform.Tool==tool))return;
        CancelViewingInput();
        if(!ResolveTransformDraft() || !SaveEdits())return;
        try { transformSource=new(file,openRevision,editRevision,CaptureCurrentEdit(),lut); }
        catch(Exception error) when(error is System.IO.IOException or UnauthorizedAccessException)
        { SetSaveNotice("调整未保存 · 重试",error.Message,true);return; }
        transformSaveFailed=false;
        savedTransformCompare=compare;
        transform.Begin(settings.Geometry,settings.Lens,tool);++transformGeneration;transformPreviewReady=false;
        view.SetEnabled(false);NeutralCanvas.Visibility=Visibility.Collapsed;NeutralColumn.Width=new(0);ResultCanvas.ComparisonEnabled=false;
        choosingRecipes=choosingHsl=choosingGrading=choosingFilm=choosingDenoise=choosingPhotoEffects=choosingWhiteBalance=false;
        choosingGeometry=tool==TransformTool.Geometry;choosingLens=tool==TransformTool.Lens;
        if(choosingGeometry){GeometryEditor.Begin(transform.Geometry);ResultCanvas.GeometryEditing=true;}
        viewport.Fit();interacting=false;RefreshControls();Schedule();ResultCanvas.Focus();
    }
    private void UpdateGeometryDraft(GeometrySettings value,bool dragging)
    {
        if(!ready || syncing || exporting || !transform.Active || transform.Tool!=TransformTool.Geometry)return;
        var previous=transform.PreviewGeometry;transform.Update(value);
        RefreshCropDraft();
        if(previous!=transform.PreviewGeometry){++transformGeneration;transformPreviewReady=false;RefreshCropDraft();interacting=dragging;Schedule();}
        else if(interacting && !dragging){interacting=false;Schedule();}
        if(transformPreviewReady && result!=null)GeometryEditor.SetCanvasSize(result.NativeWidth,result.NativeHeight);
        RefreshControls();
    }
    private void UpdateLensDraft(LensSettings value)
    {
        if(!ready || syncing || exporting || !transform.Active || transform.Tool!=TransformTool.Lens)return;
        transform.Update(value);++transformGeneration;transformPreviewReady=false;interacting=false;RefreshControls();Schedule();
    }
    private void RefreshCropDraft()=>ResultCanvas.SetCropDraft(transform.Active && transform.Tool==TransformTool.Geometry && transformPreviewReady ? transform.Geometry : null,
        GeometryEditor.AspectRatio,GeometryEditor.ShowCorrectionGrid);
    private bool ApplyTransformDraft()
    {
        if(!transform.Active)return true;
        if(transform.Tool==TransformTool.Geometry && !GeometryEditor.CommitInputs())return false;
        if(!CanApplyTransform)return false;
        try
        {
            if(file==null || transformSource==null || !transformSource.Matches(file,openRevision,editRevision,CaptureCurrentEdit(),lut))
                throw new InvalidOperationException(Loc.Text("原始文件已被替换，请重新选择照片。"));
            var candidate=settings.Capture();
            candidate = settings.IsHDREditing
                ? candidate with { HDR = candidate.HDR! with { Geometry = transform.Geometry }, Lens = transform.Lens }
                : candidate with { Geometry = transform.Geometry, Lens = transform.Lens };
            editSaveTimer.Stop();
            CommitCurrentEdit(candidate);
        }
        catch(Exception error)
        {
            if(error is EditPersistenceConflict){adjustmentReloadRequired=true;RefreshControls();}
            transformSaveFailed=true;SetSaveNotice(adjustmentReloadRequired ? "照片或调整已变化，请重新打开后重试。" : "调整未保存 · 重试",error.Message,true);return false;
        }
        // 只有候选已落盘，才能提升草稿；不再排队保存旧 committed。
        (settings.Geometry,settings.Lens)=transform.Apply();++editRevision;editDirty=false;
        EndTransform();SetSaveNotice("调整已保存","",false);RefreshControls();Schedule();return true;
    }
    private void CancelTransformDraft()
    {
        if(!transform.Active)return;
        if(transformSaveFailed)SetSaveNotice("已放弃未保存的修改","",false);
        transform.Cancel();EndTransform();RefreshControls();Schedule();
    }
    private void EndTransform()
    {
        ++transformGeneration;transformPreviewReady=false;exactReady=false;interacting=false;
        transformSource=null;transformSaveFailed=false;
        choosingLens=choosingGeometry=choosingGrading=false;selectedParameter=Parameter.Exposure;selectedToneParameter=null;selectedAtmosphereParameter=null;expandedGroup=quickPresetsVisible ? EditorAdjustmentGroup.Looks : EditorAdjustmentGroup.Light;ResultCanvas.GeometryEditing=false;ResultCanvas.SetCropDraft(null,null,false);
        GeometryEditor.Begin(settings.Geometry);
        view.SetEnabled(savedTransformCompare);
        RefreshComparisonLayout();RefreshComparisonToolTip();viewport.Fit();
    }
    private bool ResolveTransformDraft()
    {
        if(!transform.Active)return true;
        if(transform.Tool==TransformTool.Geometry)GeometryEditor.CommitInputs();
        var invalid=transform.Tool==TransformTool.Geometry && GeometryEditor.HasInvalidInput;
        if(!transform.Dirty && !invalid){CancelTransformDraft();return true;}
        var focus=Keyboard.FocusedElement;
        var dialog=new Window{Title=Loc.Text("保留这次几何或镜头修改？"),Owner=this,Width=520,SizeToContent=SizeToContent.Height,
            ResizeMode=ResizeMode.NoResize,ShowInTaskbar=false,WindowStartupLocation=WindowStartupLocation.CenterOwner};
        KeyboardNavigation.SetTabNavigation(dialog,KeyboardNavigationMode.Cycle);
        var panel=new StackPanel{Margin=new Thickness(24)};
        var message=new TextBlock{Text=Loc.Text("这些修改尚未应用。应用并离开，放弃修改，或继续编辑。"),TextWrapping=TextWrapping.Wrap};
        panel.Children.Add(message);
        var actions=new WrapPanel{HorizontalAlignment=HorizontalAlignment.Right,Margin=new Thickness(0,16,0,0)};
        var choice=0;
        var stay=new Button{Content=Loc.Text("继续编辑"),IsCancel=true};stay.Click+=(_,_)=>dialog.Close();
        var discard=new Button{Content=Loc.Text("放弃修改")};discard.Click+=(_,_)=>{choice=1;dialog.Close();};
        var apply=new Button{Content=Loc.Text("应用并离开")};
        apply.SetBinding(IsEnabledProperty,new Binding(nameof(Button.IsEnabled)){Source=ApplyDraftButton,Mode=BindingMode.OneWay});
        apply.Click+=(_,_)=>{
            if(!ApplyTransformDraft())
            {
                message.Text=Loc.Text("调整未保存 · 重试");message.ToolTip=SaveState.ToolTip;
                message.SetResourceReference(TextBlock.ForegroundProperty,"ErrorForeground");return;
            }
            choice=2;dialog.Close();
        };
        actions.Children.Add(stay);actions.Children.Add(discard);actions.Children.Add(apply);panel.Children.Add(actions);dialog.Content=panel;
        dialog.ShowDialog();if(focus is UIElement control && control.IsVisible)control.Focus();
        if(choice==1){CancelTransformDraft();return true;}return choice==2;
    }
    private void ApplyDraftClicked(object sender,RoutedEventArgs e)=>ApplyTransformDraft();
    private void CancelDraftClicked(object sender,RoutedEventArgs e)=>CancelTransformDraft();
}
