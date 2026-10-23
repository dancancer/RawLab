using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Automation;

namespace RawLab.Windows;

public partial class GeometryPanel : UserControl
{
    private GeometrySettings value=new();
    private bool syncing=true,swapped;
    private double canvasWidth,canvasHeight,originalAspect;
    private double? lockedRatio;
    private readonly ParameterRow angle=new(){KeepInvalidInput=true},horizontal=new(){KeepInvalidInput=true},vertical=new(){KeepInvalidInput=true};
    private readonly ParameterRow[] crops=Enumerable.Range(0,4).Select(_=>new ParameterRow{KeepInvalidInput=true,Compact=true}).ToArray();
    private CropAspectPreset preset;
    public double? AspectRatio=>lockedRatio is {} ratio ? (swapped ? 1/ratio : ratio) : CropInteraction.Ratio(preset,originalAspect,1,swapped);
    public bool ShowPerspective {
        get=>PerspectiveRows.Visibility==Visibility.Visible;
        set {CropControls.Visibility=value ? Visibility.Collapsed : Visibility.Visible;PerspectiveRows.Visibility=value ? Visibility.Visible : Visibility.Collapsed;}
    }
    public bool ShowCorrectionGrid=>GridBox.IsChecked==true;
    public bool HasInvalidInput=>new[]{angle,horizontal,vertical}.Concat(crops).Any(row=>row.HasInvalidInput);
    public event Action? ResetRequested;
    public event Action<GeometrySettings,bool>? Changed;
    public event Action? OverlayChanged;
    public GeometryPanel()
    {
        InitializeComponent();
        TransformRows.Children.Add(angle);PerspectiveRows.Children.Add(horizontal);PerspectiveRows.Children.Add(vertical);
        for(var i=0;i<crops.Length;++i){
            var component=(CropComponent)i;var row=crops[i];Grid.SetRow(row,i/2);Grid.SetColumn(row,i%2);
            row.Margin=new Thickness(i%2==0 ? 0 : 8,2,i%2==0 ? 8 : 0,2);CropRows.Children.Add(row);
            row.Changed+=(number,dragging)=>SetCrop(component,number,dragging);
        }
        RegisterName("CropX",crops[0].Number);RegisterName("CropY",crops[1].Number);
        RegisterName("CropWidth",crops[2].Number);RegisterName("CropHeight",crops[3].Number);
        RegisterName("StraightenSlider",angle.Slider);
        angle.Changed+=(number,dragging)=>Publish(value with{StraightenDegrees=number},dragging);
        horizontal.Changed+=(number,dragging)=>Publish(value with{PerspectiveHorizontal=number},dragging);
        vertical.Changed+=(number,dragging)=>Publish(value with{PerspectiveVertical=number},dragging);
        RefreshLanguage();Refresh(value);
    }
    public void Begin(GeometrySettings settings)
    {
        originalAspect=canvasWidth=canvasHeight=0;preset=CropAspectPreset.Free;swapped=false;lockedRatio=null;ShowPerspective=false;
        foreach(var row in new[]{angle,horizontal,vertical}.Concat(crops))row.RestoreText();
        RefreshAspectChoices();Refresh(settings);
    }
    public bool CommitInputs()
    {
        var valid=true;foreach(var row in new[]{angle,horizontal,vertical}.Concat(crops))valid=row.Commit() && valid;
        return valid;
    }
    public void ResetDraft()
    {
        if(!IsEnabled)return;Begin(new());Changed?.Invoke(value,false);OverlayChanged?.Invoke();
    }
    public void SetCanvasSize(double width,double height)
    {
        if(width<=0 || height<=0){canvasWidth=canvasHeight=0;return;}
        var changed=canvasWidth!=width || canvasHeight!=height;canvasWidth=width;canvasHeight=height;
        if(originalAspect==0)originalAspect=width/height;
        if(changed && AspectRatio.HasValue)Publish(CropInteraction.Applying(CropInteraction.Fitting(AspectRatio,width,height,CropInteraction.FromGeometry(value),true),value));
    }
    public void RefreshLanguage()
    {
        RefreshAspectChoices();Refresh(value);
    }
    public void Refresh(GeometrySettings settings)
    {
        syncing=true;value=settings;
        HorizontalFlip.IsChecked=value.FlipHorizontal;VerticalFlip.IsChecked=value.FlipVertical;
        angle.Refresh(Loc.Text("拉直"),new(-45,45,.01,.1,.01,false,2),value.StraightenDegrees,0,"°");
        horizontal.Refresh(Loc.Text("水平透视"),new(-1,1,.001,.01,.001),value.PerspectiveHorizontal,0);
        vertical.Refresh(Loc.Text("垂直透视"),new(-1,1,.001,.01,.001),value.PerspectiveVertical,0);
        var numbers=new[]{value.CropX,value.CropY,value.CropWidth,value.CropHeight};
        var names=new[]{"裁切左边","裁切上边","裁切宽度","裁切高度"};
        var normalized=AspectRatio is {} ratio && canvasWidth>0 ? ratio*canvasHeight/canvasWidth : (double?)null;
        var maxWidth=normalized is {} n ? Math.Min(1-value.CropX,(1-value.CropY)*n) : 1-value.CropX;
        var maxHeight=normalized is {} h ? Math.Min(1-value.CropY,(1-value.CropX)/h) : 1-value.CropY;
        var maxima=new[]{1-value.CropWidth,1-value.CropHeight,maxWidth,maxHeight};
        for(var i=0;i<crops.Length;++i)crops[i].Refresh(Loc.Text(names[i]),
            new(i<2 ? 0 : .01,maxima[i]*100,.01,.1,.01,CompactPercent:true),numbers[i]*100,i<2 ? 0 : 100,"%");
        LockIcon.Kind=AspectRatio==null ? "Unlock" : "Lock";
        AutomationProperties.SetItemStatus(AspectLock,Loc.Text(AspectRatio==null ? "已停用" : "已启用"));
        SwapAspect.IsEnabled=AspectRatio!=null && AspectRatio!=1;
        syncing=false;
    }
    private void Publish(GeometrySettings next,bool dragging=false)
    {
        if(syncing || !IsEnabled)return;_=next.NativeConfig();Refresh(next);Changed?.Invoke(next,dragging);
    }
    private void SetCrop(CropComponent component,double number,bool dragging)
    {
        var fraction=number/100;
        var next=component switch {
            CropComponent.X=>value with{CropX=fraction},CropComponent.Y=>value with{CropY=fraction},
            CropComponent.Width=>value with{CropWidth=fraction},_=>value with{CropHeight=fraction}
        };
        if(AspectRatio is {} ratio && canvasWidth>0) {
            var normalized=ratio*canvasHeight/canvasWidth;
            if(component==CropComponent.Width)next=next with{CropHeight=fraction/normalized};
            else if(component==CropComponent.Height)next=next with{CropWidth=fraction*normalized};
        }
        Publish(next,dragging);
    }

    private void Rotate(int turns)
    {
        if(!CommitInputs())return;
        if(originalAspect>0)originalAspect=1/originalAspect;
        Publish(value.Rotate(turns));
    }
    private void RotateLeftClicked(object sender,RoutedEventArgs e)=>Rotate(-1);
    private void RotateRightClicked(object sender,RoutedEventArgs e)=>Rotate(1);
    private void FlipChanged(object sender,RoutedEventArgs e)
    {
        if(syncing)return;
        var x=HorizontalFlip.IsChecked==true;var y=VerticalFlip.IsChecked==true;
        if(!CommitInputs()){Refresh(value);return;}
        Publish(value with{FlipHorizontal=x,FlipVertical=y,CropX=x!=value.FlipHorizontal ? Math.Max(0,1-value.CropX-value.CropWidth) : value.CropX,
            CropY=y!=value.FlipVertical ? Math.Max(0,1-value.CropY-value.CropHeight) : value.CropY});
    }
    private void ResetClicked(object sender,RoutedEventArgs e){if(!syncing && IsEnabled)ResetRequested?.Invoke();}
    private void RefreshAspectChoices() {
        syncing=true;
        var choices=new List<string>{Loc.Text("自由"),Loc.Text("原始比例"),"1:1","3:2","4:3","16:9"};
        if(lockedRatio!=null)choices.Add(Loc.Text("锁定当前比例"));
        AspectBox.ItemsSource=choices;AspectBox.SelectedIndex=lockedRatio!=null ? 6 : (int)preset;
        syncing=false;
    }
    private void AspectChanged(object sender,SelectionChangedEventArgs e)
    {
        if(syncing || AspectBox.SelectedIndex<0 || AspectBox.SelectedIndex==6)return;
        var selected=(CropAspectPreset)AspectBox.SelectedIndex;
        if(!CommitInputs()){RefreshAspectChoices();return;}
        lockedRatio=null;preset=selected;RefreshAspectChoices();FitAspect();
    }
    private void LockClicked(object sender,RoutedEventArgs e) {
        if(!CommitInputs() || canvasWidth<=0 || canvasHeight<=0)return;
        if(AspectRatio!=null){lockedRatio=null;preset=CropAspectPreset.Free;swapped=false;}
        else {lockedRatio=value.CropWidth*canvasWidth/(value.CropHeight*canvasHeight);swapped=false;}
        RefreshAspectChoices();Refresh(value);OverlayChanged?.Invoke();
    }
    private void SwapClicked(object sender,RoutedEventArgs e){if(!CommitInputs() || AspectRatio==null)return;swapped=!swapped;FitAspect();}
    private void FitAspect(){if(canvasWidth>0)Publish(CropInteraction.Applying(CropInteraction.Fitting(AspectRatio,canvasWidth,canvasHeight,CropInteraction.FromGeometry(value)),value));Refresh(value);OverlayChanged?.Invoke();}
    private void PreciseCropPressed(object sender,MouseButtonEventArgs e) {
        if(PreciseCrop.IsExpanded && e.OriginalSource is DependencyObject source && !IsInsideCropRows(source) && !CommitInputs())e.Handled=true;
    }
    private bool IsInsideCropRows(DependencyObject element) {
        while(element!=null){if(ReferenceEquals(element,CropRows))return true;element=element is System.Windows.Media.Visual ? System.Windows.Media.VisualTreeHelper.GetParent(element) : LogicalTreeHelper.GetParent(element);}
        return false;
    }
    private void PreciseCropKeyDown(object sender,KeyEventArgs e) {
        if(PreciseCrop.IsExpanded && e.Key is Key.Space or Key.Enter or Key.Left && e.OriginalSource is not TextBox && !CommitInputs())e.Handled=true;
    }
    private void GridChanged(object sender,RoutedEventArgs e){if(!syncing)OverlayChanged?.Invoke();}
}
