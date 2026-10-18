using System.Windows;
using System.Windows.Controls;

namespace RawLab.Windows;

public partial class GeometryPanel : UserControl
{
    private GeometrySettings value=new();
    private bool syncing=true,swapped;
    private double canvasWidth,canvasHeight,originalAspect;
    private readonly ParameterRow angle=new(){KeepInvalidInput=true},horizontal=new(){KeepInvalidInput=true},vertical=new(){KeepInvalidInput=true};
    private readonly ParameterRow[] crops=[new(){KeepInvalidInput=true},new(){KeepInvalidInput=true},new(){KeepInvalidInput=true},new(){KeepInvalidInput=true}];
    private CropAspectPreset preset;
    public double? AspectRatio=>CropInteraction.Ratio(preset,originalAspect,1,swapped);
    public bool ShowCorrectionGrid=>GridBox.IsChecked==true;
    public bool HasInvalidInput=>new[]{angle,horizontal,vertical}.Concat(crops).Any(row=>row.HasInvalidInput);
    public event Action<GeometrySettings,bool>? Changed;
    public event Action? OverlayChanged;
    public GeometryPanel()
    {
        InitializeComponent();
        foreach(var row in new[]{angle,horizontal,vertical})TransformRows.Children.Add(row);
        for(var i=0;i<crops.Length;++i){var component=(CropComponent)i;CropRows.Children.Add(crops[i]);crops[i].Changed+=(number,dragging)=>SetCrop(component,number,dragging);}
        RegisterName("CropX",crops[0].Number);RegisterName("CropY",crops[1].Number);
        RegisterName("CropWidth",crops[2].Number);RegisterName("CropHeight",crops[3].Number);
        RegisterName("StraightenSlider",angle.Slider);
        angle.Changed+=(number,dragging)=>Publish(value with{StraightenDegrees=number},dragging);
        horizontal.Changed+=(number,dragging)=>Publish(value with{PerspectiveHorizontal=number},dragging);
        vertical.Changed+=(number,dragging)=>Publish(value with{PerspectiveVertical=number},dragging);
        Ruler.Changed+=(number,dragging)=>Publish(value with{StraightenDegrees=number},dragging);
        RefreshLanguage();Refresh(value);
    }
    public void Begin(GeometrySettings settings)
    {
        originalAspect=canvasWidth=canvasHeight=0;preset=CropAspectPreset.Free;swapped=false;
        foreach(var row in new[]{angle,horizontal,vertical}.Concat(crops))row.RestoreText();
        syncing=true;AspectBox.SelectedIndex=0;syncing=false;Refresh(settings);
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
        syncing=true;AspectBox.ItemsSource=new[]{Loc.Text("自由"),Loc.Text("原始比例"),"1:1","3:2","4:3","16:9"};AspectBox.SelectedIndex=(int)preset;syncing=false;
        Refresh(value);
    }
    public void Refresh(GeometrySettings settings)
    {
        syncing=true;value=settings;
        HorizontalFlip.IsChecked=value.FlipHorizontal;VerticalFlip.IsChecked=value.FlipVertical;
        angle.Refresh(Loc.Text("拉直"),new(-45,45,.01,.1,.01,false,2),value.StraightenDegrees,0,"°");
        horizontal.Refresh(Loc.Text("水平透视"),new(-1,1,.001,.01,.001),value.PerspectiveHorizontal,0);
        vertical.Refresh(Loc.Text("垂直透视"),new(-1,1,.001,.01,.001),value.PerspectiveVertical,0);
        var numbers=new[]{value.CropX,value.CropY,value.CropWidth,value.CropHeight};
        var names=new[]{"左边 (%)","顶边 (%)","宽度 (%)","高度 (%)"};
        for(var i=0;i<crops.Length;++i)crops[i].Refresh(Loc.Text(names[i]),new(i<2 ? 0 : .01,100,.01,.1,.01),numbers[i]*100,i<2 ? 0 : 100,"%");
        Ruler.Value=value.StraightenDegrees;Ruler.InvalidateVisual();syncing=false;
    }
    private void Publish(GeometrySettings next,bool dragging=false)
    {
        if(syncing || !IsEnabled)return;_=next.NativeConfig();Refresh(next);Changed?.Invoke(next,dragging);
    }
    private void SetCrop(CropComponent component,double number,bool dragging)
    {
        if(AspectRatio==null || canvasWidth<=0){Publish(value.WithCropPercent(component,number),dragging);return;}
        var rect=CropInteraction.FromGeometry(value);
        var handle=component switch{CropComponent.Width=>CropHandle.Right,CropComponent.Height=>CropHandle.Bottom,_=>CropHandle.Move};
        var dx=component==CropComponent.X ? number/100-rect.X : component==CropComponent.Width ? number/100-rect.Width : 0;
        var dy=component==CropComponent.Y ? number/100-rect.Y : component==CropComponent.Height ? number/100-rect.Height : 0;
        Publish(CropInteraction.Applying(CropInteraction.Dragging(rect,handle,dx,dy,canvasWidth,canvasHeight,AspectRatio),value),dragging);
    }
    private void Rotate(int turns)
    {
        if(originalAspect>0)originalAspect=1/originalAspect;
        Publish(value.Rotate(turns));
    }
    private void RotateLeftClicked(object sender,RoutedEventArgs e)=>Rotate(-1);
    private void RotateRightClicked(object sender,RoutedEventArgs e)=>Rotate(1);
    private void FlipChanged(object sender,RoutedEventArgs e)
    {
        if(syncing)return;
        var x=HorizontalFlip.IsChecked==true;var y=VerticalFlip.IsChecked==true;
        Publish(value with{FlipHorizontal=x,FlipVertical=y,CropX=x!=value.FlipHorizontal ? Math.Max(0,1-value.CropX-value.CropWidth) : value.CropX,
            CropY=y!=value.FlipVertical ? Math.Max(0,1-value.CropY-value.CropHeight) : value.CropY});
    }
    private void ResetClicked(object sender,RoutedEventArgs e)=>ResetDraft();
    private void AspectChanged(object sender,SelectionChangedEventArgs e)
    {
        if(syncing || AspectBox.SelectedIndex<0)return;preset=(CropAspectPreset)AspectBox.SelectedIndex;
        FitAspect();
    }
    private void SwapClicked(object sender,RoutedEventArgs e){swapped=!swapped;FitAspect();}
    private void FitAspect(){if(canvasWidth>0)Publish(CropInteraction.Applying(CropInteraction.Fitting(AspectRatio,canvasWidth,canvasHeight,CropInteraction.FromGeometry(value)),value));OverlayChanged?.Invoke();}
    private void GridChanged(object sender,RoutedEventArgs e){if(!syncing)OverlayChanged?.Invoke();}
}
