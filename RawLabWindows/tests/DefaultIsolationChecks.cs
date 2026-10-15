using System.IO;
using System.Security.Cryptography;
using System.Windows;
using RawLab.Windows;

internal static class DefaultIsolationChecks
{
    private sealed record Stamp(string Path,string Hash,DateTime Written);

    internal static void Run(string output,Action<bool,string> check)
    {
        var root=Path.Combine(Path.GetFullPath(output),Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(root);
        var caseIndex=0;
        foreach(var status in new[]{BatchStatus.Running,BatchStatus.Publishing})
        {
            // Prove these fixtures exercise the actual recovery cleanup, not inert JSON.
            var control=Create("control-"+(int)status,status);
            var recovered=control.Journal.Load()!;
            check(!File.Exists(control.Staging) && recovered.Interrupted,
                "Recovery control really cleans the private staging file: "+status);
            check(File.Exists(control.Record) && File.Exists(control.Published),
                "Recovery control retains the private journal and published output: "+status);
            foreach(var mode in new[]{"--default-isolation","--profile-isolation","--status-layout","--appearance","--editor-review","--editor-shell",
                "--transform-ui","--about","--geometry","--lens","--rendered-dng","--master-recipes","--photo-features","--denoise",
                "--interactions","--benchmark","--benchmark-ui","--entry-selection","--resources","--agent-recipe"})Reject(status,false,mode:mode);
            foreach(var uiOnly in new[]{false,true})Reject(status,uiOnly);
        }
        Reject(BatchStatus.Running,true,locked:true);
        Reject(BatchStatus.Publishing,false,malformed:true);
        Console.WriteLine("Default isolation fixtures: "+root);

        void Reject(BatchStatus status,bool uiOnly,bool locked=false,bool malformed=false,string? mode=null)
        {
            var name=$"{mode ?? "default"}-{status}-{uiOnly}-{locked}-{malformed}";
            var fixture=Create("case-"+caseIndex++,status);
            if(malformed)File.WriteAllText(fixture.Record,"not a batch journal");
            var before=Snapshot(fixture.Directory);
            var repo=Path.Combine(fixture.Directory,"suite");
            string[] args=[repo,Path.Combine(fixture.Directory,"missing.arw")];
            if(uiOnly)args=[..args,"--ui-only"];
            if(mode!=null)args=mode switch{
                "--about"=>[mode],
                "--agent-recipe"=>[mode,..args,Path.Combine(fixture.Directory,"missing-cli.exe")],
                "--default-isolation" or "--profile-isolation" or "--status-layout" or "--appearance" or "--editor-shell"=>[mode,repo],
                _=>[mode,..args]};
            var rejected=false;
            using(var held=locked ? new FileStream(fixture.Record,FileMode.Open,FileAccess.ReadWrite,FileShare.None) : null)
            {
                using var errors=new StringWriter();var previous=Console.Error;
                try
                {
                    Console.SetError(errors);
                    rejected=Program.Run(args,fixture.Journal.DirectoryPath)==1 &&
                        errors.ToString().Contains("Preserve existing batch job: "+fixture.Record,StringComparison.Ordinal);
                }
                finally{Console.SetError(previous);}
            }
            var after=Snapshot(fixture.Directory);
            check(rejected,"Default suite refuses an existing journal before initializing fixtures: "+name);
            check(before.SequenceEqual(after),"Default refusal preserves journal, staging and output bytes/timestamps: "+name);
            check(!Directory.Exists(repo) && Application.Current==null,
                "Default refusal creates no suite output or WPF application: "+name);
        }

        (string Directory,BatchJournal Journal,string Record,string Staging,string Published) Create(string name,BatchStatus status)
        {
            var directory=Path.Combine(root,name);Directory.CreateDirectory(directory);
            var input=Path.Combine(directory,"source.arw");File.WriteAllBytes(input,[11,23,47]);
            var published=Path.Combine(directory,"published.png");File.WriteAllBytes(published,[89,101,127]);
            var job=BatchJob.Create(input,new Adjustments().Capture(),null,"Neutral");
            job.Format=ExportFormat.Png;job.Started=true;job.OutputDirectory=directory;
            var item=BatchItem.Create(input) with{Selected=true,Status=status,Output=published,CompletedIdentity=OriginalIdentity.Read(published)};
            job.Items=[item];
            var journal=new BatchJournal(Path.Combine(directory,"Batch"));journal.Save(job);
            var staging=job.TemporaryPath(item);File.WriteAllBytes(staging,[131,149,167,181]);
            return(directory,journal,Path.Combine(journal.DirectoryPath,"job.json"),staging,published);
        }
    }

    private static Stamp[] Snapshot(string directory)=>Directory.GetFiles(directory,"*",SearchOption.AllDirectories)
        .Order(StringComparer.Ordinal).Select(path=>new Stamp(path,Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))),File.GetLastWriteTimeUtc(path))).ToArray();
}
