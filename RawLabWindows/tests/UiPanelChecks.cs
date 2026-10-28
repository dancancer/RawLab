using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Ellipse = System.Windows.Shapes.Ellipse;
using RawLab.Windows;

// ┌─ 发布前界面细节回归：调整面板、对话框与图标形状 ──────────────────────────────────┐
// │ 全部是独立控件，不需要 RAW 或 native DLL；每类细节问题一个检查方法。             │
// └──────────────────────────────────────────────────────────────────────────────────┘
internal static class UiPanelChecks
{
    internal static void Run(string output,string language,Action<bool,string> check)
    {
        GeometryIcons(check);
        LensSeparator(check);
        DuplicateValues(output,language,check);
        WhiteBalance(language,check);
        Alignment(language,check);
        LensCrop(check);
    }

    // 几何面板的旋转、交换宽高与重置并排出现：图标不同，形状也不能相近
    private static void GeometryIcons(Action<bool,string> check)
    {
        var panel=new GeometryPanel();
        Host(panel,()=>{
            var kinds=UiDetailChecks.Descendants(panel).OfType<Button>()
                .Where(button=>!UiDetailChecks.Descendants(panel).OfType<ParameterRow>().Any(row=>row.ResetButton==button))
                .Select(button=>UiDetailChecks.Descendants(button).OfType<EditorIcon>().FirstOrDefault()?.Kind).OfType<string>().ToList();
            check(kinds.SequenceEqual(new[]{"Unlock","Swap","RotateLeft","RotateRight","Reset"}),"Geometry actions use different icons: "+string.Join(", ",kinds));
            foreach(var (a,b) in kinds.SelectMany((a,i)=>kinds.Skip(i+1).Select(b=>(a,b))))
            {
                var similarity=Similarity(a,b);
                Console.WriteLine($"Icon shape similarity {a}/{b}: {similarity:0.00}");
                check(similarity<.6,$"Geometry icons {a} and {b} are not look-alikes: {similarity:0.00}");
            }
        });
    }
    private static void LensSeparator(Action<bool,string> check)
    {
        var message=new LensInfo(1,"","",true,true,1,[]).Message;
        check(UiDetailChecks.Cjk.IsMatch(Loc.Text("畸变")) || !message.Contains('、'),$"Lens status list uses the interface language separator: {message}");
    }
    // 同一名称或数值不在相邻位置显示两次：降噪摘要、效果标题、批量导出尺寸
    private static void DuplicateValues(string output,string language,Action<bool,string> check)
    {
        var denoise=new DenoisePanel();
        Host(denoise,()=>{
            denoise.Refresh(new DenoiseSettings());
            int Mentions()=>VisibleTexts(denoise).Count(text=>text.Contains(Loc.Text("色彩降噪"),StringComparison.Ordinal));
            check(Mentions()==1,$"Expanded denoise rows are not repeated by a summary line: {Mentions()} ({language})");
            UiDetailChecks.Descendants(denoise).OfType<Expander>().Single().IsExpanded=false;denoise.UpdateLayout();
            check(Mentions()==1,$"Collapsed denoise panel still summarizes its values: {Mentions()} ({language})");
        });
        var effects=new PhotoEffectsPanel();
        Host(effects,()=>{
            foreach(var (tool,title) in new[]{(PhotoEffectTool.Vignette,"暗角"),(PhotoEffectTool.Grain,"颗粒")})
            {
                effects.Refresh(new PhotoEffectsSettings(),tool);effects.UpdateLayout();
                check(!VisibleTexts(effects).Contains(Loc.Text(title)),$"Effect panel does not repeat the selected tool name {title}: {language}");
            }
        });
        var job=BatchJob.Create("missing.arw",new Adjustments().Capture(),null,"中性");
        var batch=new BatchExportWindow(job,new BatchJournal(Path.Combine(output,"batch-"+Guid.NewGuid().ToString("N")[..8])));
        batch.Show();batch.UpdateLayout();
        try
        {
            var texts=VisibleTexts((FrameworkElement)((FrameworkElement)batch.SizeSelection.Parent).Parent);
            check(!texts.Contains(Loc.Text("原尺寸")) && !texts.Contains("px"),
                $"Batch size row does not repeat the selected size or show px for original size: {string.Join(" | ",texts)}");
        }
        finally { batch.Close(); }
    }
    // 白平衡：每行一个重置图标；分组重置写明文字（与“重置分组”“重置 HSL”一致），不再是第三个无字图标
    private static void WhiteBalance(string language,Action<bool,string> check)
    {
        var panel=new WhiteBalancePanel();
        Host(panel,()=>{
            panel.Refresh(new Adjustments(),true);panel.UpdateLayout();
            var buttons=UiDetailChecks.Descendants(panel).OfType<Button>().Where(button=>button.IsVisible).ToList();
            var bare=buttons.Count(button=>button.Content is EditorIcon);
            var labeled=buttons.Count(button=>Equals(button.Content,Loc.Text("重置白平衡")));
            check(bare==0 && labeled==1,$"White balance keeps row reset actions in menus and one labeled tool reset: {bare} icons, {labeled} labeled ({language})");
        });
    }
    // 对齐与裁切：效果分组重置与行重置同列，HSL 色块完整，导出尺寸对话框按钮等高
    private static void Alignment(string language,Action<bool,string> check)
    {
        var effects=new PhotoEffectsPanel();
        Host(effects,()=>{
            effects.Refresh(new PhotoEffectsSettings(),PhotoEffectTool.Grain);effects.UpdateLayout();
            var rows=UiDetailChecks.Descendants(effects).OfType<ParameterRow>().Where(item=>item.IsVisible).ToArray();
            check(rows.Length==3 && rows.All(row=>row.ResetButton.Visibility==Visibility.Collapsed && row.ContextMenu!=null),
                "All grain values expose semantic reset menus without persistent row reset buttons");
        });
        var hsl=new HslPanel();
        Host(hsl,()=>{
            var swatches=UiDetailChecks.Descendants(hsl).OfType<Ellipse>().Where(swatch=>swatch.Width==20 && swatch.Height==20).ToArray();
            var clipped=swatches.Count(swatch=>VisualTreeHelper.GetParent(swatch) is FrameworkElement slot && slot.ActualWidth+.5<swatch.Width);
            check(swatches.Length==8 && clipped==0,$"Eight HSL color swatches are not clipped: {clipped} of {swatches.Length} ({language})");
        });
        var owner=new Window{Width=400,Height=300,ShowInTaskbar=false};owner.Show();
        var dialog=(Window)Activator.CreateInstance(typeof(LongEdgeDialog),BindingFlags.Instance|BindingFlags.NonPublic,null,new object?[]{null,owner},null)!;
        dialog.Show();dialog.UpdateLayout();
        try
        {
            var buttons=UiDetailChecks.Descendants(dialog).OfType<Button>().ToList();
            var tops=buttons.Select(button=>button.TranslatePoint(new Point(),dialog).Y).ToList();
            check(buttons.Count==2 && Math.Abs(buttons[0].ActualHeight-buttons[1].ActualHeight)<.5 && Math.Abs(tops[0]-tops[1])<.5,
                $"Export size dialog buttons share one height and top: {string.Join(", ",buttons.Select(b=>b.ActualHeight))} ({language})");
        }
        finally { dialog.Close();owner.Close(); }
    }
    private static void LensCrop(Action<bool,string> check)
    {
        var panel=new LensPanel();
        Host(panel,()=>{
            panel.Refresh(new LensSettings(Distortion:true),new LensInfo(1,"","",true,false,1.0003f,[]));
            check(panel.CropText.Text.Length==0,$"Negligible lens crop is not reported as 0.0%: {panel.CropText.Text}");
        });
    }

    // ------------------------------------------------------------------
    //  图标形状相似度：各自按墨迹外框缩放到同一尺寸后，比较重叠面积占比
    // ------------------------------------------------------------------
    private static double Similarity(string a,string b)
    {
        var x=Ink(a);var y=Ink(b);
        var both=x.Zip(y,(p,q)=>p && q).Count(v=>v);var either=x.Zip(y,(p,q)=>p || q).Count(v=>v);
        return either==0 ? 1 : (double)both/either;
    }
    private static bool[] Ink(string kind)
    {
        const int size=96,grid=32;
        var icon=new EditorIcon{Kind=kind,Width=size,Height=size};TextElement.SetForeground(icon,Brushes.Black);
        icon.Measure(new Size(size,size));icon.Arrange(new Rect(0,0,size,size));
        var bitmap=new RenderTargetBitmap(size,size,96,96,PixelFormats.Pbgra32);bitmap.Render(icon);
        var pixels=new byte[size*size*4];bitmap.CopyPixels(pixels,size*4,0);
        bool On(int px,int py)=>pixels[(py*size+px)*4+3]>64;
        var points=Enumerable.Range(0,size*size).Where(i=>On(i%size,i/size)).ToList();
        int l=points.Min(i=>i%size),r=points.Max(i=>i%size),t=points.Min(i=>i/size),b=points.Max(i=>i/size);
        return Enumerable.Range(0,grid*grid).Select(i=>On(l+(i%grid)*(r-l)/(grid-1),t+(i/grid)*(b-t)/(grid-1))).ToArray();
    }

    private static void Host(FrameworkElement content,Action body)
    {
        var host=new Window{Content=content,Width=760,SizeToContent=SizeToContent.Height,ShowInTaskbar=false};
        host.Show();host.UpdateLayout();
        try { body(); }
        finally { host.Close(); }
    }
    private static List<string> VisibleTexts(FrameworkElement root)=>
        UiDetailChecks.Descendants(root).OfType<TextBlock>().Where(text=>text.IsVisible && text.Text.Length>0).Select(text=>text.Text).ToList();
}
