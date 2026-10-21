using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Threading;
using RawLab.Windows;

internal static partial class EditorReviewChecks
{
    private sealed partial class ReviewRun
    {
        void WorkspaceReset()
        {
            foreach(var choice in new[]{"apply","discard","stay"})foreach(var confirm in new[]{false,true}) {
                if(choice=="stay" && confirm)continue;
                var window=Open("workspace-all-"+choice+"-"+confirm);DispatcherTimer? timer=null;
                try {
                    var state=Get<Adjustments>(window,"settings");state.Processing=ProcessingIdentity.Legacy;state.Set(Parameter.Exposure,.7);
                    Invoke(window,"MarkEdited");Invoke(window,"SaveEdits");Invoke(window,"Schedule",false);
                    InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                    Click(window.GeometryCategory);
                    InteractionChecks.PumpUntil(()=>Get<bool>(window,"transformPreviewReady") && !Get<DispatcherTimer>(window,"previewResize").IsEnabled);
                    Invoke(window,"UpdateGeometryDraft",new GeometrySettings(CropWidth:.8),false);
                    InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
                    var before=Get<Adjustments>(window,"settings").Capture();var draft=Get<TransformDraft>(window,"transform");
                    var leaveSeen=false;var confirmationSeen=false;var watch=Stopwatch.StartNew();
                    timer=new DispatcherTimer(DispatcherPriority.Background){Interval=TimeSpan.FromMilliseconds(20)};
                    timer.Tick+=(_,_)=>{
                        var dialog=app.Windows.OfType<Window>().FirstOrDefault(candidate=>candidate!=window);
                        if(dialog==null)return;
                        if(watch.Elapsed>TimeSpan.FromMinutes(3)){dialog.Close();timer.Stop();throw new TimeoutException("All-reset dialog flow timed out");}
                        if(dialog.Title==Loc.Text("保留这次几何或镜头修改？")) {
                            leaveSeen=true;
                            var title=Loc.Text(choice=="apply" ? "应用并离开" : choice=="discard" ? "放弃修改" : "继续编辑");
                            var button=PhotoFeatureChecks.Descendants<Button>(dialog).Single(button=>Equals(button.Content,title));
                            if(button.IsEnabled)Click(button);
                        } else if(AutomationProperties.GetAutomationId(dialog)=="editor.reset.confirmation") {
                            confirmationSeen=true;
                            check(!draft.Active,"All reset independently confirms only after resolving the original draft");
                            Click(PhotoFeatureChecks.Descendants<Button>(dialog).Single(button=>Equals(button.Content,Loc.Text(confirm ? "重置" : "取消"))));
                        }
                    };
                    timer.Start();Invoke(window,"RequestReset",new EditorResetScope(EditorResetKind.All));
                    if(choice=="stay") {
                        check(leaveSeen && !confirmationSeen && draft.Active && draft.Dirty && draft.Geometry.CropWidth==.8 &&
                            Get<Adjustments>(window,"settings").Capture().SameAs(before),"Stay cancels All intent without changing the dirty draft or committed legacy state");
                    } else {
                        InteractionChecks.PumpUntil(()=>confirmationSeen && draft.Active && Get<bool>(window,"transformPreviewReady"));
                        var actual=Get<Adjustments>(window,"settings");
                        check(leaveSeen && !draft.Dirty && draft.Tool==TransformTool.Geometry && draft.Geometry==actual.Geometry && draft.Lens==actual.Lens,
                            "All completion/cancellation restores the original tool with a fresh unchanged draft: "+choice+"/"+confirm);
                        check(actual.Processing==ProcessingIdentity.Legacy && draft.Geometry.CropWidth==(confirm || choice=="discard" ? 1 : .8) &&
                            actual[Parameter.Exposure]==(confirm ? 0 : .7),
                            "Second-stage cancellation retains explicit Apply/Discard; full reset retains legacy identity: "+choice+"/"+confirm);
                        if(!confirm && choice=="discard")check(draft.Geometry!=new GeometrySettings(CropWidth:.8),"Discarded draft is never resurrected by cancelling All");
                    }
                    check(Get<object?>(window,"pendingAllReset")==null,"All reset consumes or cancels its single pending intent exactly once");
                    if(draft.Active)Invoke(window,"CancelTransformDraft");
                    InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                } finally {
                    timer?.Stop();if(Get<TransformDraft>(window,"transform").Active)Invoke(window,"CancelTransformDraft");
                    window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
                }
            }
            var neutral=Open("workspace-nochange");
            try {
                foreach(var processing in new[]{ProcessingIdentity.Legacy,ProcessingIdentity.Current}) {
                    Get<Adjustments>(neutral,"settings").Processing=processing;
                    var revision=Get<long>(neutral,"editRevision");
                    var scheduler=Get<object>(neutral,"scheduler");var previews=scheduler.GetType().GetProperty("Revision")!.GetValue(scheduler);
                    Invoke(neutral,"RequestReset",new EditorResetScope(EditorResetKind.All));
                    check(Get<long>(neutral,"editRevision")==revision && Equals(previews,scheduler.GetType().GetProperty("Revision")!.GetValue(scheduler)) &&
                        Get<Adjustments>(neutral,"settings").Processing==processing,
                        "Neutral All reset schedules no save or preview and retains processing identity: "+processing.Version);
                }
            } finally {neutral.Close();InteractionChecks.PumpUntil(()=>!neutral.IsVisible);}
        }
    }
}
