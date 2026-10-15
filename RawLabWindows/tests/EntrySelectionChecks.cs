using System.IO;
using System.Windows;

internal static class EntrySelectionChecks
{
    internal static void Run(string repo,string raw,Action<bool,string> check)
    {
        var output=Path.Combine(repo,"build","entry-selection",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(output);
        foreach(var part in new[]{"close-journal-snyc",""," ","all,close-running"})
            Reject(["--editor-review",Path.Combine(output,Guid.NewGuid().ToString("N")),raw,part]);
        foreach(var args in new string[][]{
            [],["--unknown"],["--about","extra"],["--appearance"],["--editor-review","repo","raw","all","extra"],
            [Path.Combine(output,"missing-raw")],[Path.Combine(output,"bad-flag"),raw,"--ui-ony"],
            [Path.Combine(output,"extra-positional"),raw,"unexpected"],[Path.Combine(output,"too-many"),raw,"--ui-only","extra"]})Reject(args);
        check(EditorReviewChecks.Parts.Values.Distinct().Count()==Enum.GetValues<EditorReviewChecks.Part>().Length,"Editor part map covers every distinct scenario");
        foreach(var pair in EditorReviewChecks.Parts)
            check(EditorReviewChecks.ParsePart(" "+pair.Key.ToUpperInvariant()+" ")==pair.Value,"Editor selection normalizes case and whitespace: "+pair.Key);
        void Reject(string[] args)
        {
            var before=Directory.GetFileSystemEntries(output,"*",SearchOption.AllDirectories).Order().ToArray();
            using var errors=new StringWriter();using var text=new StringWriter();var previousError=Console.Error;var previousOut=Console.Out;
            int code;
            try{Console.SetError(errors);Console.SetOut(text);code=Program.Run(args,Path.Combine(output,"private-journal"));}
            finally{Console.SetError(previousError);Console.SetOut(previousOut);}
            check(code==1 && errors.ToString().Contains("ArgumentException",StringComparison.Ordinal),"Malformed test command fails explicitly: "+string.Join(' ',args));
            check(before.SequenceEqual(Directory.GetFileSystemEntries(output,"*",SearchOption.AllDirectories).Order()) && Application.Current==null,
                "Malformed command creates no fixtures or WPF application");
            check(!text.ToString().Contains("PASS",StringComparison.Ordinal),"Malformed command executes no unrelated test body");
        }
    }
}
