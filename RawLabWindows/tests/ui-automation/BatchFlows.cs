using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Text.Json;
using System.Text;
using System.Runtime.InteropServices;
using System.Windows.Automation;

internal static partial class Program
{
    private sealed partial class DriverContext
    {
        private void BatchFlow()
        {
            OpenPhoto(raw);
            var fileMenu=FindById(main,"MainMenu")!.FindFirst(TreeScope.Children,
                new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.MenuItem));
            ((ExpandCollapsePattern)fileMenu.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand();
            Invoke(Wait(()=>FindById(main,"collection.open"))!);
            var collection=Wait(()=>BatchDialog("collection.window"))!;Trace("batch-collection");
            var export=Wait(()=>FindById(collection,"collection.export"))!;
            Check(export.Current.IsEnabled,"Selected collection enables export");
            var invocation=Task.Run(()=>Invoke(export));
            var configuration=Wait(()=>BatchDialog("collection.export-review"))!;Trace("batch-configuration");
            var output=Path.Combine(profile,"batch-output");Directory.CreateDirectory(output);
            SelectBatchPath(FindById(configuration,"collection.export-folder")!,output);
            var action=FindById(configuration,"collection.export-confirm")!;
            Check(action.Current.IsEnabled && !action.Current.IsOffscreen && action.Current.Name.Contains("1"),
                "Export configuration exposes one final action with the selected photo");
            CaptureBatchWindow(configuration,"configuration");
            SetForegroundWindow(new IntPtr(configuration.Current.NativeWindowHandle));action.SetFocus();Keys(0x0d);
            Wait(()=>BatchDialog("collection.export-review")==null);
            Check(invocation.Wait(TimeSpan.FromSeconds(10)),"Configuration closes after one keyboard activation");
            var batch=Wait(()=>main.FindFirst(TreeScope.Children,
                new PropertyCondition(AutomationElement.NameProperty,"RawLab · Batch export")))!;
            var journal=Path.Combine(profile,"batch","job.json");
            Wait(()=>BatchOutputComplete(journal));
            Check(Directory.GetFiles(output,"*.jpg").Length==1,"One Start action produces the native JPEG output");
            CaptureBatchWindow(batch,"complete");
            Invoke(FindById(batch,"CloseAction")!);
            Invoke(FindById(collection,"collection.close")!);
        }
        private AutomationElement? BatchDialog(string id)
        {
            AutomationElement? FindWindow(AutomationElement parent)
            {
                if(parent.Current.AutomationId==id)return parent;
                foreach(AutomationElement child in parent.FindAll(TreeScope.Children,
                    new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Window)))
                    if(FindWindow(child) is {} match)return match;
                return null;
            }
            return FindWindow(main);
        }
        private bool BatchOutputComplete(string journal)
        {
            try {
                using var json=JsonDocument.Parse(File.ReadAllText(journal));
                var items=json.RootElement.GetProperty("Items").EnumerateArray().ToArray();
                return items.Length==1 && items.All(item=>item.GetProperty("Status").GetInt32()==3);
            }catch(IOException){return false;}catch(JsonException){return false;}
        }
        private void SelectBatchPath(AutomationElement action,string path)
        {
            var invocation=Task.Run(()=>Invoke(action));
            var dialog=Wait(NativeBatchDialog,TimeSpan.FromSeconds(15))!;Trace("batch-folder-dialog");
            Trace("batch-folder-fields "+string.Join(" | ",dialog.FindAll(TreeScope.Descendants,new OrCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit),
                new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.ComboBox)))
                .Cast<AutomationElement>().Select(element=>element.Current.AutomationId+":"+element.Current.Name)));
            CaptureBatchWindow(dialog,"folder");
            var edit=Wait(()=>dialog.FindFirst(TreeScope.Descendants,
                new OrCondition(new PropertyCondition(AutomationElement.AutomationIdProperty,"1152"),
                    new PropertyCondition(AutomationElement.AutomationIdProperty,"1148"))),TimeSpan.FromSeconds(10))!;
            SetValue(edit,path);Trace("batch-folder-path");
            Invoke(dialog.FindFirst(TreeScope.Descendants,new PropertyCondition(AutomationElement.AutomationIdProperty,"1"))!);
            Check(invocation.Wait(TimeSpan.FromSeconds(10)),"Native path picker accepts "+Path.GetFileName(path));
        }
        private AutomationElement? NativeBatchDialog()
        {
            IntPtr found=IntPtr.Zero;
            EnumWindows((window,_)=>{
                GetWindowThreadProcessId(window,out var process);
                if(process!=hostPid || !IsWindowVisible(window))return true;
                var name=new StringBuilder(64);GetClassName(window,name,name.Capacity);
                if(name.ToString()!="#32770")return true;
                found=window;return false;
            },IntPtr.Zero);
            return found==IntPtr.Zero ? null : AutomationElement.FromHandle(found);
        }
        private delegate bool WindowEnumeration(IntPtr window,IntPtr data);
        [DllImport("user32.dll")] private static extern bool EnumWindows(WindowEnumeration callback,IntPtr data);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window,out int process);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window,StringBuilder name,int length);
        private void CaptureBatchWindow(AutomationElement window,string name)
        {
            var bounds=window.Current.BoundingRectangle;
            using var bitmap=new Bitmap((int)Math.Ceiling(bounds.Width),(int)Math.Ceiling(bounds.Height));
            using(var graphics=Graphics.FromImage(bitmap))graphics.CopyFromScreen((int)bounds.X,(int)bounds.Y,0,0,bitmap.Size);
            bitmap.Save(Path.Combine(profile,"batch-"+name+".png"),ImageFormat.Png);
        }
    }
}
