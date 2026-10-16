using System.IO;
using System.Security.Cryptography;
using System.Windows;
using RawLab.Windows;

internal static class AdmissionChecks
{
    private sealed record Stamp(string Path,string Hash,DateTime Written);
    internal static void Run(string output)
    {
        var root=Path.Combine(Path.GetFullPath(output),Guid.NewGuid().ToString("N")[..8]);Directory.CreateDirectory(root);
        var checks=0;var index=0;
        void Check(bool success,string name){Console.WriteLine((success ? "PASS " : "FAIL ")+name);checks++;if(!success)throw new Exception(name);}
        foreach(var status in new[]{BatchStatus.Running,BatchStatus.Publishing})
        {
            var control=Create("control-"+(int)status,status);var loaded=control.Journal.Load()!;
            Check(loaded.Interrupted && !File.Exists(control.Staging),"Real recovery control removes private staging: "+status);
            Check(File.Exists(control.Record) && File.Exists(control.Published),"Real recovery control retains journal and output: "+status);
            Reject(status);
        }
        Reject(BatchStatus.Running,locked:true);Reject(BatchStatus.Publishing,malformed:true);
        var started=false;
        Check(Program.Admit(Path.Combine(root,"empty"),()=>{started=true;return 73;})==73 && started,
            "Empty journal admission executes and preserves the startup result");
        Check(!Directory.Exists(Path.Combine(root,"empty")) && Application.Current==null,"Empty admission creates no persistence or WPF by itself");
        Console.WriteLine($"PASS {checks} localization admission checks; fixtures: {root}");

        void Reject(BatchStatus status,bool locked=false,bool malformed=false)
        {
            var fixture=Create("case-"+index++,status);if(malformed)File.WriteAllText(fixture.Record,"not JSON");
            var before=Snapshot(fixture.Directory);var reached=false;var result=0;var catalog=Loc.Strings;
            using var errors=new StringWriter();var previous=Console.Error;
            using(var held=locked ? new FileStream(fixture.Record,FileMode.Open,FileAccess.ReadWrite,FileShare.None) : null)
            {
                try{Console.SetError(errors);result=Program.Admit(fixture.Journal.DirectoryPath,()=>{reached=true;return 0;});}
                finally{Console.SetError(previous);}
            }
            var name=$"{status}-{locked}-{malformed}";
            Check(result==1 && errors.ToString().Contains("Preserve existing batch job: "+fixture.Record,StringComparison.Ordinal),"Reject existing journal with its exact path: "+name);
            Check(before.SequenceEqual(Snapshot(fixture.Directory)),"Preserve journal, staging, source and published bytes/timestamps: "+name);
            Check(!reached && Application.Current==null,"Reject before the actual startup continuation or WPF: "+name);
            Check(ReferenceEquals(catalog,Loc.Strings) && Loc.Strings.Count==0,"Reject before language initialization or preference handling: "+name);
        }
        (string Directory,BatchJournal Journal,string Record,string Staging,string Published) Create(string name,BatchStatus status)
        {
            var directory=Path.Combine(root,name);Directory.CreateDirectory(directory);
            var input=Path.Combine(directory,"source.arw");File.WriteAllBytes(input,[11,23,47]);
            var published=Path.Combine(directory,"published.png");File.WriteAllBytes(published,[89,101,127]);
            var job=BatchJob.Create(input,new Adjustments().Capture(),null,"Neutral");job.Format=ExportFormat.Png;job.Started=true;job.OutputDirectory=directory;
            var item=BatchItem.Create(input) with{Selected=true,Status=status,Output=published,CompletedIdentity=OriginalIdentity.Read(published)};job.Items=[item];
            var journal=new BatchJournal(Path.Combine(directory,"Batch"));journal.Save(job);
            var staging=job.TemporaryPath(item);File.WriteAllBytes(staging,[131,149,167,181]);
            return(directory,journal,Path.Combine(journal.DirectoryPath,"job.json"),staging,published);
        }
    }
    private static Stamp[] Snapshot(string directory)=>Directory.GetFiles(directory,"*",SearchOption.AllDirectories).Order(StringComparer.Ordinal)
        .Select(path=>new Stamp(path,Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))),File.GetLastWriteTimeUtc(path))).ToArray();
}
