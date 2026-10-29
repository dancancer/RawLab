using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

internal sealed record AIGpuPreference(string DeviceID="",string DeviceName="");

internal sealed class AIGpuPreferenceStore(string path)
{
    internal static string DefaultPath=>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RawLab","ai-gpu.json");
    internal string PathName {get;}=path;
    internal AIGpuPreference Read()
    {
        try {
            if(!File.Exists(PathName) || new FileInfo(PathName).Length>16384)return new();
            var value=AtomicJson.Read<AIGpuPreference>(PathName);
            return value.DeviceID is {Length:<=256} && value.DeviceName is {Length:<=512} ? value : new();
        } catch(Exception error) when(error is IOException or InvalidDataException or UnauthorizedAccessException or JsonException){return new();}
    }
    internal void Save(AIGpuPreference value)
    {
        if(value.DeviceID is not {Length:<=256} || value.DeviceName is not {Length:<=512})
            throw new ArgumentException("Invalid AI GPU preference.");
        AtomicJson.Write(PathName,value);
    }
}

internal sealed record AIDeviceInfo
{
    [JsonPropertyName("id")] public string ID {get;init;}="";
    [JsonPropertyName("name")] public string Name {get;init;}="";
    [JsonPropertyName("driver_version")] public string DriverVersion {get;init;}="";
    [JsonPropertyName("available")] public bool Available {get;init;}
    [JsonPropertyName("integrated")] public bool Integrated {get;init;}
    [JsonPropertyName("dedicated_memory_bytes")] public ulong DedicatedMemory {get;init;}
}

internal sealed class AIDeviceInventory
{
    internal IReadOnlyList<AIDeviceInfo> Devices {get;private init;}=[];
    internal string RecommendedID {get;private init;}="";
    internal string Error {get;private init;}="";
    internal string JSON {get;private init;}="{}";
    internal bool IsAvailable(string id)=>string.IsNullOrEmpty(id)
        ? Devices.Any(device=>device.Available && device.ID==RecommendedID)
        : Devices.Count(device=>device.Available && device.ID==id)==1;
    internal string EffectiveID(string id)=>string.IsNullOrEmpty(id) ? RecommendedID : id;
    internal AIDeviceInfo? Selected(string id)=>Devices.FirstOrDefault(device=>device.ID==EffectiveID(id));
    internal static AIDeviceInventory Unavailable(string error)=>new(){Error=error};
    internal static AIDeviceInventory Parse(string json)
    {
        try {
            using var value=JsonDocument.Parse(json);
            var root=value.RootElement;
            if(root.GetProperty("version").GetInt32()!=1)throw new JsonException("Unsupported device inventory version.");
            return new() {
                Devices=root.GetProperty("devices").Deserialize<AIDeviceInfo[]>() ?? [],
                RecommendedID=root.TryGetProperty("recommended_id",out var recommended) ? recommended.GetString() ?? "" : "",
                Error=root.TryGetProperty("error",out var error) ? error.GetString() ?? "" : "",
                JSON=json
            };
        } catch(Exception error) when(error is JsonException or InvalidOperationException or KeyNotFoundException) {
            return new(){Error=error.Message};
        }
    }
}
