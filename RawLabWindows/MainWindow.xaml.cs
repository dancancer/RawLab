using System.ComponentModel;
using System.Windows.Automation;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace RawLab.Windows;
public partial class MainWindow : Window
{
    private record Film(string Name,string? Path,string? Artwork);
    private record Work(string File,Adjustments Settings,string? Lut,int Edge,bool Interactive,int GpuMode,bool Compare,bool Clipping,bool Refine);
    private readonly Library library=new();
    private readonly Viewport viewport=new();
    private readonly List<Film> films=[];
    private readonly LatestWork<Work> scheduler=new();
    private record EmbeddedWork(string Path,long Revision);
    private readonly LatestWork<EmbeddedWork> embeddedScheduler=new();
    private long openRevision;
    private readonly Dictionary<Parameter,(Button Button,AdjustmentRing Ring)> toolButtons=[];
    private readonly Dictionary<string,Button> filmButtons=new(StringComparer.OrdinalIgnoreCase);
    private Adjustments settings=new();
    private Parameter selectedParameter=Parameter.Exposure;
    private string? file,lut;
    private RenderEngine? engine;
    private bool ready,syncing,interacting,exporting,closing,exactReady;
    private bool compare=true,clipping,choosingFilm,choosingDenoise,swipe;
    private bool renderFailed;
    private double dockHeight=264;
    private double libraryWidth=260;
    private RenderedImage? result;
    private readonly HashSet<LibraryEntry> visibleThumbnails=[];
    private readonly DispatcherTimer thumbnailRefresh=new(){Interval=TimeSpan.FromMilliseconds(80)};
    private LibraryEntry? selectedThumbnail;
    private readonly UpdateChecker updates = new(typeof(App).Assembly.GetName().Version?.ToString(3) ?? "unknown");
    private AboutWindow? aboutWindow;
    private readonly CancellationTokenSource updateCancellation = new();
    public MainWindow()
    {
        InitializeComponent();
        UpdateNotice.DataContext = updates;
        void RefreshUpdateNotice() => UpdateNotice.Visibility = updates.HasUpdate ? Visibility.Visible : Visibility.Collapsed;
        updates.PropertyChanged += (_, _) => RefreshUpdateNotice();
        RefreshUpdateNotice();
        Closed += (_, _) => updateCancellation.Cancel();
        Files.ItemsSource=library.Roots;
        thumbnailRefresh.Tick+=(_,_)=>{thumbnailRefresh.Stop();RefreshVisibleThumbnails();};
        Files.AddHandler(ScrollViewer.ScrollChangedEvent,new ScrollChangedEventHandler((_,_)=>QueueThumbnailRefresh()));
        Files.SizeChanged+=(_,_)=>QueueThumbnailRefresh();
        Files.Loaded+=(_,_)=>QueueThumbnailRefresh();
        DockHeader.SizeChanged+=(_,_)=>UpdateDockMinimum();
        ToolsScroller.SizeChanged+=(_,_)=>UpdateDockMinimum();
        NeutralCanvas.Viewport=ResultCanvas.Viewport=viewport;
        viewport.ResolutionChanged+=()=>{if(!syncing)Schedule();};
        films.Add(new("中性",null,null));
        var artwork=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase) {
            ["PROVIA"]="provia",["Velvia"]="velvia",["ASTIA"]="astia",["ACROS"]="acros",
            ["PRO Neg.Std"]="pro-neg-std",["CLASSIC Neg."]="classic-neg",["CLASSIC CHROME"]="classic-chrome",
            ["ETERNA"]="eterna",["ETERNA BB"]="eterna-bb",["REALA ACE"]="reala-ace" };
        var root=Path.Combine(AppContext.BaseDirectory,"LUTs");
        if(Directory.Exists(root))foreach(var path in Directory.GetFiles(root,"*.cube").Order())
        {
            var name=Path.GetFileNameWithoutExtension(path).Replace("FLog2_to_","").Replace("_65grid_V.1.00","").Replace('-', ' ');
            films.Add(new(name,path,artwork.TryGetValue(name,out var icon) ? Path.Combine(AppContext.BaseDirectory,"FilmIcons",icon+".png") : null));
        }
        lut=films.FirstOrDefault(f=>f.Name=="PROVIA")?.Path;
        BuildTools(); BuildFilms();
        DenoiseEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting)return;
            settings.Denoise=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        ValueSlider.AddHandler(Thumb.DragStartedEvent,new DragStartedEventHandler((_,_)=>{interacting=true;}));
        ValueSlider.AddHandler(Thumb.DragCompletedEvent,new DragCompletedEventHandler((_,_)=>{interacting=false; Schedule();}));
        ready=true; RefreshControls();
        InitializeEditWorkflow();
        Closing+=WindowClosing;
        Loaded+=async (_,_)=> {
            var input=Environment.GetCommandLineArgs().Skip(1).FirstOrDefault(LibraryEntry.IsRaw);
            if(input!=null)OpenFile(input);
            await updates.CheckAsync(false, updateCancellation.Token);
        };
    }
    private void AboutClicked(object sender, RoutedEventArgs e)
    {
        if (aboutWindow == null)
        {
            aboutWindow = new AboutWindow(updates) { Owner = this };
            aboutWindow.Closed += (_, _) => aboutWindow = null;
            aboutWindow.Show();
        }
        else aboutWindow.Activate();
    }
    private void BuildTools()
    {
        foreach(var spec in ParameterSpec.All)
        {
            var ring=new AdjustmentRing{Width=40,Height=40};
            var grid=new Grid(); grid.Children.Add(ring); grid.Children.Add(new EditorIcon{Kind=spec.Id.ToString(),Width=20,Height=20});
            var stack=new StackPanel(); stack.Children.Add(grid); stack.Children.Add(new TextBlock{Text=spec.Title,FontSize=11,HorizontalAlignment=HorizontalAlignment.Center,Margin=new Thickness(0,4,0,0)});
            var button=new Button{Content=stack,Style=(Style)FindResource("ToolButton"),ToolTip=spec.Title};
            AutomationProperties.SetName(button,spec.Title);
            button.Click+=(_,_)=>{choosingFilm=false;choosingDenoise=false;selectedParameter=spec.Id;RefreshControls();};
            Tools.Children.Add(button); toolButtons[spec.Id]=(button,ring);
        }
    }
    private void FilmCategoryClicked(object sender,RoutedEventArgs e) { choosingFilm=true;choosingDenoise=false;RefreshControls(); }
    private void DenoiseCategoryClicked(object sender,RoutedEventArgs e) { choosingDenoise=true;choosingFilm=false;RefreshControls(); }
    private void BuildFilms()
    {
        FilmStrip.Children.Clear(); filmButtons.Clear();
        foreach(var film in films)
        {
            var stack=new StackPanel();
            if(film.Artwork!=null && File.Exists(film.Artwork))stack.Children.Add(new Image{Source=new BitmapImage(new Uri(film.Artwork)),Width=64,Height=64});
            else stack.Children.Add(new EditorIcon{Kind=film.Path==null ? "Neutral" : "Film",Width=32,Height=64});
            stack.Children.Add(new TextBlock{Text=film.Name,FontSize=11,Width=80,Height=30,TextWrapping=TextWrapping.Wrap,TextAlignment=TextAlignment.Center,Margin=new Thickness(0,5,0,0)});
            var button=new Button{Content=stack,Style=(Style)FindResource("FilmButton"),ToolTip=film.Path ?? "中性显影"};
            AutomationProperties.SetName(button,film.Name);
            button.Click+=(_,_)=>{if(exporting)return;lut=film.Path;MarkEdited();RefreshControls();Schedule();};
            FilmStrip.Children.Add(button); filmButtons[film.Path ?? ""]=button;
        }
        var importContent=new StackPanel();
        importContent.Children.Add(new EditorIcon{Kind="Add",Width=26,Height=64});
        importContent.Children.Add(new TextBlock{Text="导入外观",FontSize=11,Height=30,TextAlignment=TextAlignment.Center,Margin=new Thickness(0,5,0,0)});
        var importButton=new Button{Content=importContent,Style=(Style)FindResource("FilmButton"),ToolTip="导入兼容 CUBE 或 RLOOK，可选择多个文件"};
        AutomationProperties.SetName(importButton,"导入外观");importButton.Click+=ImportClicked;FilmStrip.Children.Add(importButton);
    }
    private void RefreshControls()
    {
        if(!ready)return;
        syncing=true;
        try
        {
            var spec=ParameterSpec.All[(int)selectedParameter];
            ParameterTitle.Text=spec.Title; ParameterUnit.Text=spec.Unit;
            ValueText.Text=settings[selectedParameter].ToString("F"+spec.Decimals);
            ValueSlider.Value=spec.Position(settings[selectedParameter]);
            AutomationProperties.SetName(ValueSlider,spec.Title);
            AutomationProperties.SetName(ValueText,spec.Title+"数值（"+spec.Unit+"）");
            var canAdjust=file!=null && !exporting && !choosingFilm && (selectedParameter!=Parameter.Strength || lut!=null) && (selectedParameter is not(Parameter.Temperature or Parameter.Tint) || settings.AsShot!=null);
            ValueSlider.IsEnabled=ValueText.IsEnabled=canAdjust;
            FilmPanel.Visibility=choosingFilm ? Visibility.Visible : Visibility.Collapsed;
            ParameterPanel.Visibility=choosingFilm || choosingDenoise ? Visibility.Collapsed : Visibility.Visible;
            DenoiseEditor.Visibility=choosingDenoise ? Visibility.Visible : Visibility.Collapsed;
            DenoiseEditor.IsEnabled=file!=null && !exporting;DenoiseEditor.Refresh(settings.Denoise);
            DenoiseCategory.Tag=choosingDenoise ? "selected" : null;
            DenoiseCategoryRing.Selected=choosingDenoise;
            DenoiseCategoryRing.Progress=settings.Denoise.Enabled ? 1 : 0;DenoiseCategoryRing.InvalidateVisual();
            FilmCategory.Tag=choosingFilm ? "selected" : null;
            FilmCategoryRing.Selected=choosingFilm;FilmCategoryRing.InvalidateVisual();
            ExposureMode.SelectedIndex=settings.ExposureMode;
            ExposureMode.IsEnabled=ResetAllButton.IsEnabled=file!=null && !exporting;
            ResetParameterButton.IsEnabled=ResetGroupButton.IsEnabled=canAdjust;
            AsShotButton.IsEnabled=file!=null && !exporting && settings.AsShot!=null;
            foreach(var (id,controls) in toolButtons)
            {
                var selected=!choosingFilm && !choosingDenoise && id==selectedParameter;
                controls.Button.Tag=selected ? "selected" : null;
                controls.Ring.Selected=selected;
                var p=ParameterSpec.All[(int)id]; var origin=p.Position(settings.Default(id)); var offset=p.Position(settings[id])-origin;
                controls.Ring.Progress=offset==0 ? 0 : offset/(offset<0 ? origin : 1-origin); controls.Ring.InvalidateVisual();
            }
            foreach(var pair in filmButtons)pair.Value.Tag=pair.Key==(lut ?? "") ? "selected" : null;
            var filmName=films.FirstOrDefault(f=>f.Path==lut)?.Name ?? "中性";
            ActiveFilm.Text=filmName;FilmLabelText.Text=lut==null ? "调整后" : filmName;ActiveFilm.ToolTip=filmName;
            NeutralLabel.Visibility=FilmLabel.Visibility=compare && result!=null ? Visibility.Visible : Visibility.Collapsed;
            CompareButton.Tag=compare ? "selected" : null;
            ClippingButton.Tag=clipping ? "selected" : null;
            LibraryToggleButton.Tag=LibraryPanel.Visibility==Visibility.Visible ? "selected" : null;
            AdjustToggleButton.Tag=AdjustmentPanel.Visibility==Visibility.Visible ? "selected" : null;
            UpdateBusy();
        }
        finally { syncing=false; }
    }
    private static SolidColorBrush Brush(string color)=>(SolidColorBrush)new BrushConverter().ConvertFromString(color)!;
    private void UpdateBusy()
    {
        ExportJpeg.IsEnabled=ExportPng.IsEnabled=BatchExportMenu.IsEnabled=exactReady && !scheduler.Busy && !exporting && result!=null && LookAvailable;
        ViewBatchMenu.IsEnabled=CurrentBatch!=null;
        ExportButton.IsEnabled=ExportJpeg.IsEnabled || ViewBatchMenu.IsEnabled;
        AdjustmentPanel.IsEnabled=!exporting;GpuMode.IsEnabled=!exporting;
        BusyIndicator.Visibility=scheduler.Busy || exporting ? Visibility.Visible : Visibility.Collapsed;
        RetryButton.Visibility=renderFailed && !scheduler.Busy && !exporting ? Visibility.Visible : Visibility.Collapsed;
        ExportButton.ToolTip=file==null ? "打开 RAW 照片后导出" : scheduler.Busy ? "精确预览完成后可导出" : "导出原始分辨率照片";
        ToolTipService.SetShowOnDisabled(ExportButton,true);
        ToolTipService.SetShowOnDisabled(ExportJpeg,true);ToolTipService.SetShowOnDisabled(ExportPng,true);
    }
    private void SetStatus(string text,bool error=false) { Status.Text=text; Status.ToolTip=text; Status.Foreground=Brush(error ? "#FFAB92" : "#B5B8C0"); }
    private void RetryClicked(object sender,RoutedEventArgs e)=>Schedule();
    private void Report(Exception error)=>SetStatus(error is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException
        ? "无法加载显影组件。请通过 build.ps1 构建，并保留程序目录内的 DLL。" : error.Message,true);
    internal void OpenFile(string path,BitmapSource? placeholder=null)
    {
        if(exporting || closing)return;
        try
        {
            path=Path.GetFullPath(path);
            if(!LibraryEntry.IsRaw(path))throw new InvalidOperationException("请选择支持的 RAW 文件。");
            if(!SaveEdits())return;
            RestoreEdits(path);
            file=path; interacting=false; exactReady=false; result=null;syncing=true;viewport.Fit();syncing=false;
            viewport.SetSourceSize(0,0);
            NeutralCanvas.SetImage(placeholder,null); ResultCanvas.SetImage(placeholder,null);ResultCanvas.SetComparison(placeholder,null); Histogram.Bins=null; Histogram.InvalidateVisual(); ClipStats.Text="";
            BackendLabel.Text="相机预览 · 正在显影";BaselineLabel.Text="";
            Title="RawLab · "+Path.GetFileName(path); Welcome.Visibility=Visibility.Collapsed;
            embeddedScheduler.Submit(new(path,++openRevision));PumpEmbedded();
            RefreshControls(); Schedule(initialPreview:true);QueueThumbnailRefresh();
        }
        catch(Exception ex) { Report(ex); }
    }
    private async void PumpEmbedded()
    {
        var ticket=embeddedScheduler.Start();if(ticket==null)return;
        EmbeddedPreview? preview=null;
        try{preview=await Task.Run(()=>RenderEngine.ReadEmbeddedPreview(ticket.Value.Path));}
        catch(Exception ex) when(ex is IOException or InvalidOperationException or DllNotFoundException or BadImageFormatException or EntryPointNotFoundException) { }
        var current=embeddedScheduler.Finish(ticket);
        if(closing)return;
        if(current && ticket.Value.Revision==openRevision && ticket.Value.Path==file && preview!=null)
        {
            if(viewport.SourceSize.Width==0)viewport.SetSourceSize(preview.Width,preview.Height);
            if(result==null && !renderFailed && preview.Image!=null)
            {
                NeutralCanvas.SetImage(preview.Image,null);ResultCanvas.SetImage(preview.Image,null);ResultCanvas.SetComparison(preview.Image,null);
                SetStatus("相机内嵌预览 · 正在显影…");
            }
        }
        PumpEmbedded();
    }
    private void Schedule(bool initialPreview=false)
    {
        if(!ready || file==null || exporting || closing)return;
        if(!LookAvailable){exactReady=false;result=null;renderFailed=true;SetStatus("上次使用的外观不可用，请重新导入或选择外观。",true);UpdateBusy();return;}
        renderFailed=false;
        var proxy=interacting || initialPreview;
        scheduler.Submit(new(file,settings.Clone(),lut,proxy ? 1000 : viewport.ActualPixels ? 0 : 2000,proxy,GpuMode.SelectedIndex==0 ? 1 : GpuMode.SelectedIndex==1 ? 0 : 2,compare,clipping,initialPreview));
        exactReady=false; SetStatus(interacting ? "正在生成交互预览…" : "正在显影…"); UpdateBusy();
        Pump();
    }
    private async void Pump()
    {
        var ticket=scheduler.Start(); if(ticket==null)return;
        RenderedImage? neutral=null,rendered=null; Exception? failure=null;
        try
        {
            (neutral,rendered)=await Task.Run(()=> {
                engine ??= new(); var w=ticket.Value;engine.SetGpuMode(w.GpuMode);
                var frame=engine.RenderPreview(w.File,w.Settings,w.Lut,w.Edge,w.Interactive,w.Compare,w.Clipping);
                return(frame.Neutral,frame.Result);
            });
        }
        catch(Exception ex) { failure=ex; }
        var current=scheduler.Finish(ticket);
        if(closing) { FinishClose(); return; }
        var work=ticket.Value;
        // A current-file proxy may publish while dragging; stale exact work never publishes.
        if(work.File==file && work.Lut==lut && work.Compare==compare && work.Clipping==clipping && (current || (work.Interactive && interacting)))
        {
            if(failure!=null) { if(current){result=null;exactReady=false;renderFailed=true;Report(failure);} }
            else if(rendered!=null && neutral!=null)
            {
                result=rendered; settings.ResolveWhiteBalance(rendered.WhiteBalance);
                if(work.Edge==0)viewport.SetSourceSize(rendered.Image.PixelWidth,rendered.Image.PixelHeight);
                BackendLabel.Text=$"{(rendered.Backend==3 ? "Direct3D 11 · GPU" : work.GpuMode==0 ? "CPU" : "CPU · GPU 已回退")} · sRGB";
                NeutralCanvas.SetImage(neutral.Image,neutral.Clipping); ResultCanvas.SetImage(rendered.Image,rendered.Clipping);
                ResultCanvas.SetComparison(neutral.Image,neutral.Clipping);
                Histogram.Bins=rendered.Histogram; Histogram.InvalidateVisual();
                ClipStats.Text=$"暗部 {rendered.Shadows:P1}   高光 {rendered.Highlights:P1} · 显示图统计";
                BaselineLabel.Text=$"基础偏移 {rendered.Baseline:+0.00;-0.00;0.00} EV";
                AsShotButton.ToolTip=rendered.WhiteBalance==null ? "此 RAW 缺少有效校准，使用相机原始白平衡" : $"拍摄时：{rendered.WhiteBalance.Value.Temperature} K / {rendered.WhiteBalance.Value.Tint}";
                exactReady=current && !work.Interactive;
                SetStatus($"{(work.Interactive ? "交互预览" : work.Edge==0 ? "原尺寸" : "预览")} {rendered.Image.PixelWidth} × {rendered.Image.PixelHeight} · {Path.GetFileName(file)}");
                RefreshControls();
            }
        }
        // A quick RAW proxy shortens the blank wait. Only its exact successor enables export.
        if(current && work.Refine && failure==null && work.File==file && !interacting)Schedule();
        UpdateBusy(); Pump();
    }
    private void SliderChanged(object sender,RoutedPropertyChangedEventArgs<double> e)
    {
        if(!ready || syncing || exporting)return;
        var value=ParameterSpec.All[(int)selectedParameter].Value(e.NewValue);
        if(settings[selectedParameter]==value)return;
        settings.Set(selectedParameter,value);
        MarkEdited();
        RefreshControls(); Schedule();
    }
    private void CommitValue()
    {
        if(!ready || syncing || exporting || !ValueText.IsEnabled)return;
        var spec=ParameterSpec.All[(int)selectedParameter];
        if(spec.Parse(ValueText.Text) is {} value) { if(settings[selectedParameter]!=value){settings.Set(selectedParameter,value);MarkEdited();interacting=false;Schedule();} }
        else SetStatus("请输入有限数值。",true);
        RefreshControls();
    }
    private void ValueCommitted(object sender,KeyboardFocusChangedEventArgs e)=>CommitValue();
    private void ValueKeyDown(object sender,KeyEventArgs e) { if(e.Key==Key.Enter){CommitValue();e.Handled=true;} if(e.Key==Key.Escape){RefreshControls();e.Handled=true;} }
    private void ExposureModeChanged(object sender,SelectionChangedEventArgs e) { if(!ready || syncing || exporting)return;settings.ExposureMode=ExposureMode.SelectedIndex;MarkEdited();Schedule(); }
    private void GpuModeChanged(object sender,SelectionChangedEventArgs e) { if(ready && !exporting)Schedule(); }
    private void ResetParameterClicked(object sender,RoutedEventArgs e) { settings.Reset(selectedParameter);MarkEdited();RefreshControls();Schedule(); }
    private void ResetGroupClicked(object sender,RoutedEventArgs e) { settings.ResetGroup(ParameterSpec.All[(int)selectedParameter].Group);MarkEdited();RefreshControls();Schedule(); }
    private void ResetAllClicked(object sender,RoutedEventArgs e) { settings.ResetAll();MarkEdited();RefreshControls();Schedule(); }
    private void AsShotClicked(object sender,RoutedEventArgs e) { settings.ResetWhiteBalance();MarkEdited();RefreshControls();Schedule(); }
    private void OpenClicked(object sender,RoutedEventArgs e)
    {
        if(exporting)return;
        var dialog=new OpenFileDialog{Title="打开 RAW 照片",Filter="RAW 照片|"+string.Join(';',LibraryEntry.RawExtensions.Select(x=>"*."+x))+"|所有文件|*.*"};
        if(dialog.ShowDialog(this)==true)OpenFile(dialog.FileName);
    }
    private void ImportClicked(object sender,RoutedEventArgs e)
    {
        if(exporting)return;
        var dialog=new OpenFileDialog{Title="导入胶片外观",Multiselect=true,Filter="胶片外观|*.cube;*.rlook|CUBE LUT|*.cube|RawLab DCP 外观|*.rlook"};
        if(dialog.ShowDialog(this)!=true)return;
        foreach(var path in dialog.FileNames)
        {
            if(!films.Any(f=>f.Path==path))films.Add(new(Path.GetFileNameWithoutExtension(path),path,null));
            lut=path;
        }
        MarkEdited();BuildFilms();RefreshControls();Schedule();
    }
    private void AddFolderClicked(object sender,RoutedEventArgs e)
    {
        var dialog=new OpenFolderDialog{Title="添加照片目录",Multiselect=true};
        if(dialog.ShowDialog(this)==true)try { foreach(var path in dialog.FolderNames)library.Add(path); } catch(Exception ex){Report(ex);}
    }
    private async void FolderExpanded(object sender,RoutedEventArgs e) { if(e.OriginalSource is TreeViewItem {DataContext:LibraryEntry entry})try{await entry.Load();}catch(Exception ex){Report(ex);} }
    private void QueueThumbnailRefresh() { if(!closing){thumbnailRefresh.Stop();thumbnailRefresh.Start();} }
    private void ThumbnailLoaded(object sender,RoutedEventArgs e)=>QueueThumbnailRefresh();
    private void ThumbnailUnloaded(object sender,RoutedEventArgs e) { if(sender is Image {DataContext:LibraryEntry entry}){entry.ReleaseThumbnail();visibleThumbnails.Remove(entry);} }
    internal void RefreshVisibleThumbnails()
    {
        var visible=new HashSet<LibraryEntry>();
        var viewportRect=new Rect(0,0,Files.ActualWidth,Files.ActualHeight);
        void Visit(DependencyObject element)
        {
            if(element is Image {DataContext:LibraryEntry entry} image && VisualTreeHelper.GetParent(image) is FrameworkElement tile && tile.ActualWidth>0 && tile.ActualHeight>0)
            {
                // An unloaded Image has zero size; use its reserved tile to start loading.
                var bounds=new Rect(tile.TranslatePoint(new Point(),Files),tile.RenderSize);
                if(Files.Visibility==Visibility.Visible && viewportRect.IntersectsWith(bounds)){visible.Add(entry);entry.IsSelected=entry.Path.Equals(file,StringComparison.OrdinalIgnoreCase);}
            }
            for(var i=0;i<VisualTreeHelper.GetChildrenCount(element);i++)Visit(VisualTreeHelper.GetChild(element,i));
        }
        Visit(Files);
        foreach(var entry in visibleThumbnails.Except(visible))entry.ReleaseThumbnail();
        foreach(var entry in visible.Except(visibleThumbnails))_ = entry.LoadThumbnail();
        visibleThumbnails.Clear();visibleThumbnails.UnionWith(visible);
    }
    private void PhotoSelected(object sender,RoutedEventArgs e)
    {
        if(sender is not Button {DataContext:LibraryEntry entry} || exporting)return;
        if(selectedThumbnail!=null)selectedThumbnail.IsSelected=false;
        selectedThumbnail=entry;entry.IsSelected=true;OpenFile(entry.Path,entry.Thumbnail);QueueThumbnailRefresh();
    }
    private void FileSelected(object sender,RoutedPropertyChangedEventArgs<object> e) { if(e.NewValue is LibraryEntry{IsFolder:false} entry && entry.Path!="")OpenFile(entry.Path,entry.Thumbnail); }
    private void RemoveFolderClicked(object sender,RoutedEventArgs e) { if(Files.SelectedItem is LibraryEntry entry && library.Roots.Contains(entry))try{library.Remove(entry);}catch(Exception ex){Report(ex);} }
    private void RefreshFolderClicked(object sender,RoutedEventArgs e)
    {
        if(Files.SelectedItem is LibraryEntry entry && library.Roots.Contains(entry)) { var index=library.Roots.IndexOf(entry);library.Roots[index]=new(entry.Path,true); }
    }
    private void FilesDropped(object sender,DragEventArgs e)
    {
        if(exporting || e.Data.GetData(DataFormats.FileDrop) is not string[] paths)return;
        try{foreach(var path in paths.Where(Directory.Exists))library.Add(path);}catch(Exception ex){Report(ex);}
        if(paths.FirstOrDefault(LibraryEntry.IsRaw) is {} raw)OpenFile(raw);
    }
    private void LibraryToggle(object sender,RoutedEventArgs e)
    {
        var visible=LibraryPanel.Visibility==Visibility.Visible;
        if(visible)libraryWidth=LibraryColumn.ActualWidth;
        LibraryPanel.Visibility=LibrarySplitter.Visibility=visible ? Visibility.Collapsed : Visibility.Visible;
        LibraryColumn.MinWidth=visible ? 0 : 180;
        LibraryColumn.Width=new(visible ? 0 : libraryWidth);
        LibrarySplitterColumn.Width=new(visible ? 0 : 5);
        RefreshControls();
        QueueThumbnailRefresh();
    }
    private void CompareClicked(object sender,RoutedEventArgs e)=>ZoomClicked(sender,e);
    private void ExportMenuClicked(object sender,RoutedEventArgs e)=>ZoomClicked(sender,e);
    private void CompareOffClicked(object sender,RoutedEventArgs e)=>SetComparisonMode(false,false);
    private void CompareSideClicked(object sender,RoutedEventArgs e)=>SetComparisonMode(true,false);
    private void CompareSwipeClicked(object sender,RoutedEventArgs e)=>SetComparisonMode(true,true);
    internal void SetComparisonMode(bool enabled,bool sliding)
    {
        var changed=compare!=enabled;
        compare=enabled;swipe=enabled && sliding;
        NeutralCanvas.Visibility=compare && !swipe ? Visibility.Visible : Visibility.Collapsed;
        NeutralColumn.Width=compare && !swipe ? new(1,GridUnitType.Star) : new(0);
        ResultCanvas.ComparisonEnabled=swipe;
        ResultCanvas.ToolTip=swipe ? "拖动分隔线对比；方向键微调，Home 居中。拖动照片平移，滚轮缩放。" : "拖动平移，滚轮缩放，双击适合窗口。";
        Grid.SetColumnSpan(NeutralLabel,swipe ? 2 : 1);
        FilmLabel.HorizontalAlignment=swipe ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        CompareOff.IsChecked=!enabled;CompareSide.IsChecked=enabled && !sliding;CompareSwipe.IsChecked=swipe;
        RefreshControls();
        if(changed)Schedule();
    }
    private void DockToggle(object sender,RoutedEventArgs e)
    {
        var visible=AdjustmentPanel.Visibility==Visibility.Visible;
        if(visible)dockHeight=DockRow.ActualHeight;
        AdjustmentPanel.Visibility=visible ? Visibility.Collapsed : Visibility.Visible;
        DockRow.MinHeight=visible ? 0 : 216; DockRow.Height=new(visible ? 0 : dockHeight);SplitterRow.Height=new(visible ? 0 : 6);
        RefreshControls();
        UpdateDockMinimum();
    }
    private void UpdateDockMinimum()
    {
        if(AdjustmentPanel.Visibility==Visibility.Visible)
            DockRow.MinHeight=Math.Max(216,DockHeader.ActualHeight+ToolsScroller.ActualHeight+130);
    }
    private void HistogramClicked(object sender,RoutedEventArgs e)=>HistogramPanel.Visibility=HistogramPanel.Visibility==Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
    private void ClippingClicked(object sender,RoutedEventArgs e) { clipping=!clipping;NeutralCanvas.ShowClipping=ResultCanvas.ShowClipping=clipping;NeutralCanvas.InvalidateVisual();ResultCanvas.InvalidateVisual();RefreshControls();Schedule(); }
    private void ZoomClicked(object sender,RoutedEventArgs e) { if(sender is Button button && button.ContextMenu is {} menu){menu.PlacementTarget=button;menu.IsOpen=true;} }
    private void FitClicked(object sender,RoutedEventArgs e)=>viewport.Fit();
    private void ActualClicked(object sender,RoutedEventArgs e)=>viewport.Actual();
    private void ZoomInClicked(object sender,RoutedEventArgs e)=>viewport.Magnify(1.25);
    private void ZoomOutClicked(object sender,RoutedEventArgs e)=>viewport.Magnify(.8);
    private void KeyPressed(object sender,KeyEventArgs e)
    {
        if(e.OriginalSource is TextBox or ComboBox || Keyboard.FocusedElement is ComboBox)return;
        if(e.Key==Key.O && Keyboard.Modifiers==ModifierKeys.Control)OpenClicked(sender,e);
        else if(e.Key==Key.F)FitClicked(sender,e); else if(e.Key==Key.D1)ActualClicked(sender,e);
        else if(e.Key is Key.Add or Key.OemPlus)ZoomInClicked(sender,e); else if(e.Key is Key.Subtract or Key.OemMinus)ZoomOutClicked(sender,e);
    }
    private void ExportJpegClicked(object sender,RoutedEventArgs e)=>Export(false);
    private void ExportPngClicked(object sender,RoutedEventArgs e)=>Export(true);
    private async void Export(bool png)
    {
        if(!exactReady || scheduler.Busy || exporting || file==null || engine==null)return;
        var dialog=new SaveFileDialog{Title="全分辨率导出",Filter=png ? "16-bit PNG|*.png" : "JPEG|*.jpg",DefaultExt=png ? ".png" : ".jpg",AddExtension=true,OverwritePrompt=true,
            FileName=Path.GetFileNameWithoutExtension(file)+"-"+(films.FirstOrDefault(f=>f.Path==lut)?.Name ?? "neutral")};
        if(dialog.ShowDialog(this)!=true)return;
        if(Path.GetFullPath(dialog.FileName).Equals(Path.GetFullPath(file),StringComparison.OrdinalIgnoreCase)){SetStatus("不能覆盖原始 RAW。",true);return;}
        exporting=true;RefreshControls();SetStatus("正在全分辨率导出…");
        var input=file;var adjustment=settings.Clone();var film=lut;
        // Render to a sibling temporary file, then replace only after encoding succeeds.
        var temp=Path.Combine(Path.GetDirectoryName(dialog.FileName)!,".rawlab-"+Guid.NewGuid().ToString("N")+(png ? ".png" : ".jpg"));
        try { await Task.Run(()=>engine.Render(input,adjustment,film,0,false,temp));File.Move(temp,dialog.FileName,true);SetStatus($"已导出（{(engine.LastBackend==3 ? "Direct3D 11" : "CPU")}）：{dialog.FileName}"); }
        catch(Exception ex){Report(ex);}
        finally {try{if(File.Exists(temp))File.Delete(temp);}catch(IOException){} exporting=false;RefreshControls();if(closing)FinishClose();}
    }
    private void WindowClosing(object? sender,CancelEventArgs e)
    {
        if(!SaveEdits()){e.Cancel=true;return;}
        closing=true;
        if(batchWindow?.Running==true)batchWindow.CancelExecution();
        thumbnailRefresh.Stop();foreach(var entry in visibleThumbnails)entry.ReleaseThumbnail();visibleThumbnails.Clear();
        if(scheduler.Busy || exporting){e.Cancel=true;closing=true;IsEnabled=false;SetStatus("正在完成当前任务后关闭…");return;}
        engine?.Dispose();engine=null;
    }
    private void FinishClose() { engine?.Dispose();engine=null;Closing-=WindowClosing;Close(); }
}
