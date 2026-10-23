using RawLab.Windows;

internal static class AIDenoiseJobChecks
{
    internal static async Task Run()
    {
        static void Check(bool value,string text) { if(!value)throw new Exception(text); }
        var root=Path.Combine(Path.GetTempPath(),"rawlab-ai-state-"+Guid.NewGuid());Directory.CreateDirectory(root);
        try {
            var first=Path.Combine(root,"first.arw");var second=Path.Combine(root,"second.arw");
            File.WriteAllText(first,"one");File.WriteAllText(second,"two");
            var settings=new Adjustments();var identity=AIDenoiseIdentity.Read(first,settings,2);
            settings.Set(Parameter.Exposure,1);
            Check(AIDenoiseIdentity.Read(first,settings,2)==identity,"Exposure changed AI identity");
            settings.Set(Parameter.Temperature,4500);
            Check(AIDenoiseIdentity.Read(first,settings,2)!=identity,"WB did not change AI identity");
            var recipeSettings=new Adjustments();recipeSettings.ApplyMasterRecipe(MasterRecipe.All.First(r=>r.TintDelta!=0));
            var unresolved=AIDenoiseIdentity.Read(first,recipeSettings,2);
            recipeSettings.ResolveWhiteBalance((4800,17));
            Check(AIDenoiseIdentity.Read(first,recipeSettings,2)==unresolved,"Resolving source WB changed an unchanged recipe AI identity");
            recipeSettings.Set(Parameter.Tint,recipeSettings[Parameter.Tint]+1);
            Check(AIDenoiseIdentity.Read(first,recipeSettings,2)!=unresolved,"Recipe tint edit failed to invalidate AI identity");
            settings=new();
            using var started=new ManualResetEventSlim();using var release=new ManualResetEventSlim();
            var calls=0;var active=0;var maximum=0;
            var job=new AIDenoiseJob((_,_,progress)=>{
                var concurrent=Interlocked.Increment(ref active);maximum=Math.Max(maximum,concurrent);
                try { Interlocked.Increment(ref calls);started.Set();release.Wait(TimeSpan.FromSeconds(5));progress.Report(3,1,1); }
                finally { Interlocked.Decrement(ref active); }
            });
            var work=job.StartAsync(identity,settings);
            Check(started.Wait(TimeSpan.FromSeconds(5)) && job.State.IsRunning && !settings.AIDenoiseEnabled,
                "First AI job did not stay pending without enabling saved edits");
            job.Cancel();release.Set();await work;
            Check(job.State.Status==AIDenoiseStatus.Cancelled,"Cancelled completion published Ready");
            release.Reset();started.Reset();
            var old=job.StartAsync(identity,settings);Check(started.Wait(TimeSpan.FromSeconds(5)),"Second job did not start");
            var nextIdentity=AIDenoiseIdentity.Read(second,settings,2);
            var next=job.StartAsync(nextIdentity,settings);release.Set();await Task.WhenAll(old,next);
            Check(job.State.Status==AIDenoiseStatus.Ready && job.Identity==nextIdentity && maximum==1 && calls==3,
                "Stale completion crossed photos or jobs ran concurrently");
            job.Reset();Check(job.State.Status==AIDenoiseStatus.Idle && job.Identity==null,"Disable did not clear AI state");
            release.Reset();started.Reset();
            var activeBeforeClose=job.StartAsync(identity,settings);Check(started.Wait(TimeSpan.FromSeconds(5)),"Close fixture did not start");
            var queuedBeforeClose=job.StartAsync(nextIdentity,settings);job.Cancel();
            await queuedBeforeClose;
            Check(!job.Completion.IsCompleted,"Close forgot the still-running superseded native worker");
            release.Set();await activeBeforeClose;await job.Completion;
            var broken=new AIDenoiseJob((_,_,_)=>throw new InvalidOperationException("fixture failure"));
            Check(!await broken.StartAsync(identity,settings) && broken.State.Status==AIDenoiseStatus.Failed &&
                  broken.State.Error=="fixture failure","AI failure was silently published");
            Check(!settings.AIDenoiseEnabled,"Worker mutated persisted AI flag");
            Console.WriteLine("PASS: AI identity, cancellation, serialized retry, stale completion and failures");
        } finally { Directory.Delete(root,true); }
    }
}
