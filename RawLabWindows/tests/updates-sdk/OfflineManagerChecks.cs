using System.Security.Cryptography;
using System.Text.Json;
using System.IO.Compression;
using System.Reflection.PortableExecutable;
using System.Xml.Linq;
using RawLab.Windows;
using Velopack;
using Velopack.Locators;
using Velopack.Sources;

internal static class OfflineManagerChecks
{
    internal static async Task Run(string feedDirectory,Action<bool,string> check)
    {
        var root=Path.Combine(Path.GetTempPath(),"rawlab-velopack-offline-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        try {
            UpdateManager Manager(IUpdateSource source,string name)=>new(source,
                new UpdateOptions{ExplicitChannel="stable",MaximumDeltasBeforeFallback=-1},
                new TestVelopackLocator(appId:"RawLab.Desktop",version:"0.8.2",packagesDir:Path.Combine(root,name)));
            var manager=Manager(new SimpleFileSource(new DirectoryInfo(feedDirectory)),"file");
            var update=await manager.CheckForUpdatesAsync();
            check(update?.TargetFullRelease.Version.ToString()=="0.9.1","Actual Velopack manager reads a vpk-generated offline feed");
            await manager.DownloadUpdatesAsync(update!);
            var package=Path.Combine(root,"file",update!.TargetFullRelease.FileName);
            check(File.Exists(package) && manager.UpdatePendingRestart?.Version.ToString()=="0.9.1",
                "Actual SDK downloads a valid nupkg into its isolated packages directory");
            using (var archive = ZipFile.OpenRead(package))
            {
                var specification = archive.Entries.Single(entry => entry.FullName.EndsWith(".nuspec", StringComparison.OrdinalIgnoreCase));
                using var specificationStream = specification.Open(); var xml = XDocument.Load(specificationStream);
                check(xml.Descendants().Any(value => value.Name.LocalName == "rid" && value.Value == "win-x64") &&
                    xml.Descendants().Any(value => value.Name.LocalName == "machineArchitecture" && value.Value == "x64"),
                    "The actual vpk package declares the supported win-x64 runtime");
                foreach (var fileName in new[] { "RawLab.exe", "RawLab.dll" })
                {
                    var entry = archive.Entries.Single(value => value.FullName.EndsWith("/" + fileName, StringComparison.OrdinalIgnoreCase));
                    using var stream = entry.Open(); using var copy = new MemoryStream(); stream.CopyTo(copy); copy.Position = 0;
                    using var pe = new PEReader(copy);
                    check(pe.PEHeaders.CoffHeader.Machine == Machine.Amd64, "Fixture package contains an AMD64 " + fileName);
                }
            }
            var bytes=File.ReadAllBytes(package);var name=Path.GetFileName(package);var now=DateTimeOffset.UtcNow;
            using var key=ECDsa.Create(ECCurve.NamedCurves.nistP256);
            var trust=new UpdateTrustConfiguration("https://updates.example.invalid/stable.json",Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()),new string('a',64));
            var payload=new SignedUpdatePayload(1,"RawLab.Desktop","windows","x64","stable","0.9.1","19","0.8.2",now.AddMinutes(-1),now.AddDays(1),
                "https://updates.example.invalid/"+name,name,bytes.Length,Convert.ToHexString(SHA256.HashData(bytes)),Convert.ToHexString(SHA1.HashData(bytes)),"Offline fixture");
            var data=JsonSerializer.SerializeToUtf8Bytes(payload);
            var envelope=JsonSerializer.SerializeToUtf8Bytes(new{Format=1,Payload=Convert.ToBase64String(data),Signature=Convert.ToBase64String(key.SignData(data,HashAlgorithmName.SHA256,DSASignatureFormat.Rfc3279DerSequence))});
            using var client=new HttpClient(new FixtureHandler(()=>envelope,()=>bytes));
            var signed=new SignedUpdateSource(trust,"0.8.2",client,()=>now);
            manager=Manager(signed,"signed");update=await manager.CheckForUpdatesAsync();
            await manager.DownloadUpdatesAsync(update!);
            var downloaded=Path.Combine(root,"signed",name);
            check(File.ReadAllBytes(downloaded).SequenceEqual(bytes) && manager.UpdatePendingRestart!=null,
                "Production signed source works through actual Velopack Check and Download APIs");
            UpdatePackageVerifier.Verify(downloaded,payload,"");
            check(true,"Signed-manifest mode accepts the real unsigned vpk package");
            var rejected=false;
            try{UpdatePackageVerifier.Verify(downloaded,payload,trust.PublisherKeySha256);}catch(CryptographicException){rejected=true;}
            check(rejected,"A real unsigned vpk package is rejected by production package Authenticode verification");
            using(var file=new FileStream(downloaded,FileMode.Open,FileAccess.Write)){file.Position=10;file.WriteByte((byte)(bytes[10]^1));}
            rejected=false;
            try{UpdatePackageVerifier.Verify(downloaded,payload,trust.PublisherKeySha256);}catch(CryptographicException){rejected=true;}
            check(rejected,"Tampering with the SDK cache invalidates package trust before dispatch");
            manager=Manager(new SignedUpdateSource(trust,"0.8.2",client,()=>now),"cancelled");update=await manager.CheckForUpdatesAsync();
            using var cancellation=new CancellationTokenSource();cancellation.Cancel();
            rejected=false;
            try{await manager.DownloadUpdatesAsync(update!,cancelToken:cancellation.Token);}catch(OperationCanceledException){rejected=true;}
            check(rejected && manager.UpdatePendingRestart==null,"Cancellation cannot leave an installable SDK cache entry");
        } finally {Directory.Delete(root,true);}
    }
}
