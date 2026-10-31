using System.IO;
using System.Text.Json;
using System.Windows.Automation;
using System.Drawing;
using System.Drawing.Imaging;

internal static partial class Program
{
    private sealed partial class DriverContext
    {
        private void LookBrowserFlow()
        {
            OpenPhoto(raw);WaitReady();
            // 新宿主默认打开光线组；直接切组，避免在隐藏子树上做全窗口查询。
            Invoke(FindById(main,"editor.group.looks")!);Trace("looks-group");
            var browser=main;
            Trace("looks-browser");
            var search=Wait(()=>FindById(browser,"looks.search"))!;
            var category=FindById(browser,"looks.category")!;
            if(phase=="first") {
                SetForegroundWindow(new IntPtr(main.Current.NativeWindowHandle));search.SetFocus();
                Keys(0x11,0x41);foreach(var key in new byte[]{0x41,0x43,0x52,0x4f,0x53})Keys(key);
                // 中文 IME 的组合文本先提交，随后焦点才可离开搜索框。
                Keys(0x0d);
                Wait(()=>((ValuePattern)search.GetCurrentPattern(ValuePattern.Pattern)).Current.Value.Equals("acros",StringComparison.OrdinalIgnoreCase));
                Check(true,"Keyboard search reaches the fixed look field");
                // 每次输入都会重建卡片；完整输入落定后再获取可操作的元素。
                var acros=Wait(()=>browser.FindFirst(TreeScope.Descendants,new AndCondition(
                    new PropertyCondition(AutomationElement.NameProperty,"ACROS"),
                    new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Button))))!;
                Trace("looks-search-result");
                SetForegroundWindow(new IntPtr(main.Current.NativeWindowHandle));acros.SetFocus();
                Wait(()=>acros.Current.HasKeyboardFocus ? acros : null,TimeSpan.FromSeconds(5));
                Trace("looks-keyboard-focus="+acros.Current.HasKeyboardFocus+" type="+acros.Current.ControlType.ProgrammaticName);
                Keys(0x0d);WaitReady();
                Trace("looks-activation-sent");
                Wait(()=>File.Exists(Path.Combine(profile,"recent-looks.json")) ? acros : null,TimeSpan.FromSeconds(20));
                Check(File.ReadAllText(Path.Combine(profile,"recent-looks.json")).Contains("builtin:FLog2_to_ACROS"),"Keyboard activation saves the stable look identity");
                var saved=File.ReadAllBytes(Path.Combine(profile,"edits","edits.json"));
                SetValue(search,"no matching look");
                Check(FindByNames(browser,"No matching looks") is {} empty && !empty.Current.IsOffscreen && FindById(browser,"looks.import")!.Current.IsEnabled,
                    "Empty search keeps the fixed import action");
                Check(saved.SequenceEqual(File.ReadAllBytes(Path.Combine(profile,"edits","edits.json"))),"Search does not change the saved photo");
                Invoke(FindById(browser,"looks.search.clear")!);
            }
            ((ExpandCollapsePattern)category.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand();
            Trace("looks-category");
            var recent=Wait(()=>FindByNames(category,"Recent"))!;
            ((SelectionItemPattern)recent.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
            var selected=Wait(()=>FindByNames(browser,"ACROS"))!;
            Check(selected.Current.ItemStatus=="Applied","Recent retains the applied look with native accessibility status: "+phase);
            var bounds=main.Current.BoundingRectangle;var import=FindById(browser,"looks.import")!.Current.BoundingRectangle;
            Check(bounds.Contains(import),"Import remains inside the narrow native window");
            using var bitmap=new Bitmap((int)Math.Ceiling(bounds.Width),(int)Math.Ceiling(bounds.Height));
            using(var graphics=Graphics.FromImage(bitmap))graphics.CopyFromScreen((int)bounds.X,(int)bounds.Y,0,0,bitmap.Size);
            bitmap.Save(Path.Combine(profile,"looks-"+phase+".png"),ImageFormat.Png);
            File.WriteAllText(Path.Combine(profile,"looks-"+phase+".json"),JsonSerializer.Serialize(new{phase,width=bounds.Width,height=bounds.Height,selected=selected.Current.Name,status=selected.Current.ItemStatus}));
        }
    }
}
