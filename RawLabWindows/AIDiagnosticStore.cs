using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace RawLab.Windows;

internal sealed record AIDiagnosticContext(string Operation,string DeviceID,int Backend,string? InputPath=null,
    int? NativeStatus=null,string? NativeDetails=null,string? NativeDiagnostics=null,string? Devices=null,
    string? ModelDirectory=null,string? CacheDirectory=null);

internal sealed class AIDiagnosticStore
{
    private const string ReportKey="RawLab.AIDiagnostic",SaveFailureKey="RawLab.AIDiagnosticSaveFailure";
    private const int MaxReportBytes=512*1024;
    private readonly object gate=new();
    private readonly int maxReports;
    internal static AIDiagnosticStore Default {get;}=new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RawLab","Diagnostics","AI"));
    internal string DirectoryPath {get;}
    internal AIDiagnosticStore(string directory,int maxReports=20)
    {
        DirectoryPath=directory;this.maxReports=Math.Clamp(maxReports,1,100);
    }
    internal static string? ReportPath(Exception error)=>error.Data[ReportKey] as string;
    internal static bool SaveFailed(Exception error)=>error.Data[SaveFailureKey] is true;
    internal string? Capture(Exception error,AIDiagnosticContext context)
    {
        if(error is OperationCanceledException)return null;
        lock(gate) {
            if(ReportPath(error) is {} existing)return existing;
            try {
                var input=new JsonObject();
                if(context.InputPath is {} path) {
                    input["extension"]=Path.GetExtension(path);
                    try{if(File.Exists(path))input["bytes"]=new FileInfo(path).Length;}catch(IOException){}
                }
                using var process=Process.GetCurrentProcess();
                var report=new JsonObject {
                    ["version"]=1,["created_utc"]=DateTimeOffset.UtcNow.ToString("O"),["operation"]=context.Operation,
                    ["app_version"]=typeof(AIDiagnosticStore).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion,
                    ["os"]=RuntimeInformation.OSDescription,["os_version"]=Environment.OSVersion.Version.ToString(),
                    ["os_architecture"]=RuntimeInformation.OSArchitecture.ToString(),["process_architecture"]=RuntimeInformation.ProcessArchitecture.ToString(),
                    ["processor"]=Environment.GetEnvironmentVariable("PROCESSOR_IDENTIFIER"),["logical_processors"]=Environment.ProcessorCount,
                    ["process_memory_bytes"]=process.WorkingSet64,["available_memory_bytes"]=GC.GetGCMemoryInfo().TotalAvailableMemoryBytes,
                    ["requested_device_id"]=context.DeviceID,["requested_backend"]=context.Backend,["input"]=input,
                    ["native_status"]=context.NativeStatus,["error_type"]=error.GetType().FullName,
                    ["error_codes"]=new JsonArray(Regex.Matches(error+"\n"+context.NativeDetails+"\n"+context.NativeDiagnostics,@"(?i)\b(?:0x)?[89A-F][0-9A-F]{7}\b")
                        .Select(match=>"0x"+match.Value[^8..].ToUpperInvariant()).Distinct().Take(32).Select(value=>(JsonNode?)JsonValue.Create(value)).ToArray()),
                    ["error"]=Limit(error.ToString(),32768),["native_error"]=Limit(context.NativeDetails,32768),
                    ["native"]=Parse(context.NativeDiagnostics),["devices"]=Parse(context.Devices)
                };
                Redact(report,context);
                var name="ai-error-"+DateTime.UtcNow.ToString("yyyyMMdd-HHmmss-fff")+"-"+Guid.NewGuid().ToString("N")+".json";
                var destination=Path.Combine(DirectoryPath,name);
                var json=report.ToJsonString();
                if(Encoding.UTF8.GetByteCount(json)>MaxReportBytes)throw new IOException("AI diagnostic exceeded its size limit.");
                AtomicJson.Write(destination,report);
                error.Data[ReportKey]=destination;
                try{foreach(var stale in Reports().Skip(maxReports))try{File.Delete(stale);}catch(IOException){}catch(UnauthorizedAccessException){}}
                catch(IOException){}catch(UnauthorizedAccessException){}
                return destination;
            } catch(Exception) {
                error.Data[SaveFailureKey]=true;return null;
            }
        }
    }
    private static string? Limit(string? text,int limit)=>text?.Length>limit ? text[..limit]+" [truncated]" : text;
    private static JsonNode Parse(string? text)
    {
        if(string.IsNullOrEmpty(text))return new JsonObject();
        if(text.Length>300000)return new JsonObject{["error"]="Native diagnostic exceeded its size limit"};
        try{return JsonNode.Parse(text) as JsonObject ?? new JsonObject{["unparsed"]=Limit(text,16384)};}
        catch(System.Text.Json.JsonException){return new JsonObject{["unparsed"]=Limit(text,16384)};}
    }
    private static void Redact(JsonNode node,AIDiagnosticContext context)
    {
        var paths=new[]{(context.InputPath,"<input>"),(context.ModelDirectory,"<models>"),(context.CacheDirectory,"<cache>"),
            (Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"<user>"),(AppContext.BaseDirectory,"<app>"),(Path.GetTempPath(),"<temp>")};
        string Clean(string text) {
            foreach(var (path,replacement) in paths.Where(value=>!string.IsNullOrEmpty(value.Item1)).OrderByDescending(value=>value.Item1!.Length)) {
                text=text.Replace(path!,replacement,StringComparison.OrdinalIgnoreCase)
                    .Replace(path!.Replace('\\','/'),replacement,StringComparison.OrdinalIgnoreCase);
            }
            if(context.InputPath is {} source) {
                var name=source.Replace('\\','/').Split('/').Last();
                if(name.Length>0)text=text.Replace(name,"<input>",StringComparison.OrdinalIgnoreCase);
            }
            text=Regex.Replace(text,@"(?i)(?:[a-z]:[\\/]|\\\\)[^\r\n""'<>]*?(?=\(\d+\)|[""'\r\n<>]|$)","<path>");
            return Regex.Replace(text,@"/(?:Users|home|private|var|tmp)/[^\r\n""'<>]*","<path>");
        }
        void Walk(JsonNode value) {
            if(value is JsonObject obj)foreach(var key in obj.Select(pair=>pair.Key).ToArray()) {
                if(obj[key] is JsonValue item && item.TryGetValue<string>(out var text))obj[key]=Clean(text);
                else if(obj[key] is {} child)Walk(child);
            }
            else if(value is JsonArray array)for(var i=0;i<array.Count;i++) {
                if(array[i] is JsonValue item && item.TryGetValue<string>(out var text))array[i]=Clean(text);
                else if(array[i] is {} child)Walk(child);
            }
        }
        Walk(node);
    }
    private IEnumerable<string> Reports()=>Directory.Exists(DirectoryPath)
        ? Directory.EnumerateFiles(DirectoryPath,"ai-error-*.json").OrderByDescending(Path.GetFileName,StringComparer.Ordinal)
        : [];
    internal string? Latest()
    {
        lock(gate)try{return Reports().FirstOrDefault();}catch(IOException){return null;}catch(UnauthorizedAccessException){return null;}
    }
    internal void Export(string reportPath,string destination)
    {
        var file=new FileInfo(reportPath);
        if(!file.Exists || file.Length>MaxReportBytes)throw new InvalidDataException("AI diagnostic is missing or oversized.");
        var report=JsonNode.Parse(File.ReadAllText(reportPath)) as JsonObject ?? throw new InvalidDataException("Invalid AI diagnostic.");
        var log=new StringBuilder();
        if(report["native"]?["logs"] is JsonArray entries)foreach(var entry in entries)
            log.AppendLine($"[{entry?["severity"]}] {entry?["category"]}: {entry?["message"]}");
        var temporary=destination+"."+Guid.NewGuid().ToString("N")+".tmp";
        try {
            using(var output=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None))
            using(var zip=new ZipArchive(output,ZipArchiveMode.Create)) {
                void Add(string name,string text){using var writer=new StreamWriter(zip.CreateEntry(name).Open(),new UTF8Encoding(false));writer.Write(text);}
                Add("diagnostic.json",report.ToJsonString(new(){WriteIndented=true}));
                Add("runtime.log",log.ToString());
                Add("README.txt","RawLab AI diagnostic report\nContains application/system/GPU information and bounded runtime errors.\nPhoto data and known personal file paths are excluded. Upload this ZIP manually with the issue description.\n");
            }
            File.Move(temporary,destination,true);
        } finally {if(File.Exists(temporary))File.Delete(temporary);}
    }
}
