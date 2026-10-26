using System.Net;
using RawLab.Windows;

internal static class RedirectChecks
{
    internal static async Task Run(UpdateTrustConfiguration original, SignedUpdatePayload payload, DateTimeOffset now,
        Func<SignedUpdatePayload,byte[]> sign, byte[] package, Action<bool,string> check)
    {
        var trust=original with {FeedUrl="https://github.com/dancancer/RawLab/releases/latest/download/stable.json",PublisherKeySha256=""};
        var manifest=payload with {AssetUrl="https://github.com/dancancer/RawLab/releases/download/test/"+payload.FileName};
        foreach(var kind in new[]{"valid","external","http","loop"}) {
            var calls=0;
            using var client=new HttpClient(new Handler(request=>{
                calls++;
                var uri=request.RequestUri!;
                if(uri.Host=="github.com" || kind=="loop") {
                    var target=kind switch {
                        "external"=>"https://attacker.invalid/asset",
                        "http"=>"http://release-assets.githubusercontent.com/asset",
                        _=>"https://release-assets.githubusercontent.com"+uri.AbsolutePath
                    };
                    return new HttpResponseMessage(HttpStatusCode.Redirect){Headers={Location=new Uri(target)}};
                }
                return new HttpResponseMessage(HttpStatusCode.OK){Content=new ByteArrayContent(uri.AbsolutePath.EndsWith(".json") ? sign(manifest) : package)};
            }));
            var source=new SignedUpdateSource(trust,"0.8.2",client,()=>now);
            var path=Path.Combine(Path.GetTempPath(),"rawlab-redirect-"+Guid.NewGuid()+".nupkg");
            try {
                var feed=await source.GetReleaseFeed(new NullLogger(),"RawLab.Desktop","stable");
                await source.DownloadReleaseEntry(new NullLogger(),feed.Assets.Single(),path,_=>{});
                check(kind=="valid" && File.ReadAllBytes(path).SequenceEqual(package),"Allowlisted HTTPS redirects retain package verification");
            } catch(InvalidDataException) {check(kind!="valid","Unsafe or excessive redirects rejected: "+kind);}
            finally {if(File.Exists(path))File.Delete(path);}
            check(calls<=6,"Redirect request count is bounded: "+kind);
        }
    }
    private sealed class Handler(Func<HttpRequestMessage,HttpResponseMessage> respond):HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
        {token.ThrowIfCancellationRequested();return Task.FromResult(respond(request));}
    }
}
