using RawLab.Windows;

internal static class ViewChecks
{
    internal static void Run(Action<bool,string> check)
    {
        var view=new EditorViewState();
        view.Toggle();check(view.Enabled && view.PreferredMode==ComparisonMode.SideBySide,"First comparison toggle opens side-by-side");
        view.Select(ComparisonMode.Wipe);view.Toggle();view.Toggle();
        check(view.Enabled && view.PreferredMode==ComparisonMode.Wipe,"Closing comparison and reopening restores the selected mode");
        view.SourceChanged();check(!view.Enabled && view.PreferredMode==ComparisonMode.Wipe,"A photo switch disables comparison while retaining the session preference");
        check(view.BeginHold(false) && view.NeedsReference,"Holding before requests a real reference without turning comparison on");
        view.EndHold();check(!view.HoldingBefore && !view.Enabled,"Release returns after without enabling persistent comparison");
        check(!view.BeginHold(true),"Geometry and lens drafts cannot enter before viewing");
        view.Toggle();check(!view.BeginHold(false),"Persistent comparison has priority over temporary before");
        var wide=PhotoViewProjection.Project(200,100,400,200,2,.75,.25);
        var tall=PhotoViewProjection.Project(100,200,400,200,2,.75,.25);
        check(wide==new ViewRectangle(-200,0,400,200) && tall==new ViewRectangle(-100,75,200,100),
            "Different pane sizes project the same normalized photo focus instead of a shared pixel offset");
        check(PhotoViewProjection.Project(200,100,400,200,1,.5,.5,16)==new ViewRectangle(32,16,136,68),
            "Photo margins fit the complete photograph with equal visible inset");
        check(PhotoViewProjection.Project(200,100,400,200,1,.5,.5)==new ViewRectangle(0,0,200,100),
            "Removing photo margins reduces viewing space without fill cropping");
        var key=new NeutralReferenceKey(new("fixture.ARW",12,34,56),false,ProcessingIdentity.Legacy,new(),new(),640);
        check(key!=key with{Source=key.Source with{Created=57}} && key!=key with{Raster=true} && key!=key with{Edge=1280} &&
            key!=key with{Lens=new(true)},"Neutral reference identity includes replacement identity, input kind, committed lens and demanded size");
        check(!NeutralReference.Matches(key,key.Source with{Created=57},key.Processing,key.Geometry,key.Lens),
            "Replacing the same path invalidates before readiness even when geometry and values are unchanged");
        check(!NeutralReference.Matches(key,key.Source,key.Processing,key.Geometry,key.Lens,1280),"A small neutral frame cannot satisfy a newer larger or native viewing demand");
        var edited=new Adjustments { Processing=ProcessingIdentity.Legacy,Geometry=new(.1,.2,.7,.6,1,true,false,2),Lens=new(true,true,true,true,"lens-id") };
        edited.Set(Parameter.Exposure,.7);edited.Set(Parameter.Temperature,8000);edited.Hsl=edited.Hsl.WithValue(0,2,30);
        var original=edited.Capture();
        var before=NeutralReference.Settings("fixture.ARW",edited);
        check(before.Lens==edited.Lens,"Neutral reference preserves committed lens correction instead of comparing different compositions");
        check(before.Geometry==edited.Geometry && before.Processing==ProcessingIdentity.Legacy,"Neutral reference retains committed geometry and processing identity");
        check(before[Parameter.Exposure]==0 && before.CameraWhiteBalance && before.Hsl.Equals(new HslSettings()),"Neutral reference resets user grading instead of copying the edited frame");
        check(original.SameAs(edited.Capture()),"Preparing a neutral reference does not edit the source settings");
        var raster=NeutralReference.Settings("fixture.jpg",edited);
        check(raster.ExposureMode==2 && raster.Lens==new LensSettings(false,false,false),"Raster reference follows sensor/none input rules without inventing camera correction");
        Console.WriteLine("PASS: view preference, hold/source cancellation, normalized projection, margins and neutral composition");
    }
}
