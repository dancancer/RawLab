using RawLab.Windows;

internal static class HslTargetChecks
{
    private static void Check(bool value,string message) { if(!value)throw new Exception(message); }
    internal static void Run()
    {
        var revision=new HslTargetRevision(7,11);
        var weights=new double[]{.25,.75,0,0,0,0,0,0};
        var sample=new HslTargetSample(revision,HslTargetAvailability.Available,[.8,.3,.1],weights,true);
        weights[0]=1;
        var before=new HslSettings().WithValue(1,0,98.125).WithValue(2,7,-8.25);
        var input=new HslTargetInteraction();
        var token=input.Begin(before,1,revision);
        Check(input.Move(10)==null && input.Waiting,"Pending drag retains total delta");
        var result=input.Accept(sample,token,revision)!;
        Check(result.Value(1,0)==100 && result.Value(1,1)==7.5 && result.Value(2,7)==-8.25,"Frozen weights update only the chosen axis and clamp");
        Check(input.Move(4)!.Value(1,1)==3,"Every move derives from before rather than accumulating");
        Check(input.Cancel()!.Equals(before) && input.Accept(sample,token,revision)==null,"Cancel rolls back and rejects late samples");
        token=input.Begin(new(),2,revision);input.Move(10);input.End();input.AccumulateReleased(2);
        Check(input.Accept(sample,token,revision)!.Value(2,1)==9 && !input.Dragging && !input.Waiting,"Release before sample preserves the final delta and ends once");
        token=input.Begin(before,0,revision);
        Check(input.Accept(sample,token,new(7,12))==null && !input.Waiting,"Changed displayed frame rejects sample");
        token=input.Begin(before,0,revision);
        Check(input.Accept(new(revision,HslTargetAvailability.NearGray,[.5,.5,.5],new double[8],true),token,revision)==null && !input.Waiting,"Gray samples do not start edits");
        Check(!new HslTargetSample(revision,HslTargetAvailability.Available,[.8,.3,.1],[double.NaN,0,0,0,0,0,0,0],true).Usable,"Malformed weights rejected");
        var recipe=new Adjustments();recipe.ApplyMasterRecipe(MasterRecipe.All[0]);recipe.Set(Parameter.Strength,0);
        token=input.Begin(recipe.Hsl,0,revision);input.Move(10);recipe.Hsl=input.Accept(sample,token,revision)!;
        Check(recipe.Hsl.Value(0,1)==7.5 && recipe.RenderHsl.IsIdentity,"Logical HSL changes remain independent of zero recipe strength");
        Console.WriteLine("PASS: HSL target frozen weights, axes, rollback, release, stale frame and recipe strength");
    }
}
