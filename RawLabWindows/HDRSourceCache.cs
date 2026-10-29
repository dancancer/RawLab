using System.IO;

namespace RawLab.Windows;

internal sealed class HDRSourceLease(HDRPairOwner owner,Action release) : IDisposable
{
    private Action? cleanup=release;
    internal HDRPairOwner Owner => owner;
    public void Dispose()=>Interlocked.Exchange(ref cleanup,null)?.Invoke();
}

// 只缓存不可变的解码源；所有 RenderEngine 共用预算，正在使用的 owner 由 lease 保活。
internal static class HDRSourceCache
{
    private const ulong Budget=128UL*1024*1024;
    private sealed class Entry(string path,string fingerprint,uint edge,HDRPairOwner owner,ulong bytes)
    {
        internal readonly string Path=path,Fingerprint=fingerprint;
        internal readonly uint Edge=edge;
        internal readonly HDRPairOwner Owner=owner;
        internal readonly ulong Bytes=bytes;
        internal int Users;
        internal bool Retained;
    }
    private static readonly object Gate=new();
    private static readonly LinkedList<Entry> Entries=new();
    private static ulong bytes;
    internal static ulong CachedBytes {get {lock(Gate)return bytes;}}
    internal static HDRSourceLease Acquire(string path,HDRSourceInfo info,bool final,uint edge)
    {
        if(final) {
            Clear();var owner=HDRNative.Decode(path,HDRIntent.Final,0,info);
            return new(owner,owner.Dispose);
        }
        var canonical=System.IO.Path.GetFullPath(path);var fingerprint=Convert.ToHexString(info.SourceSha256);
        lock(Gate) {
            for(var node=Entries.First;node!=null;) {
                var next=node.Next;
                var value=node.Value;
                if(!StringComparer.OrdinalIgnoreCase.Equals(value.Path,canonical)){node=next;continue;}
                if(value.Fingerprint!=fingerprint){Remove(node);node=next;continue;}
                if(value.Edge<edge){node=next;continue;}
                Entries.Remove(node);Entries.AddFirst(node);return Lease(value);
            }
            var decoded=HDRNative.Decode(path,HDRIntent.Preview,edge,info);
            var entry=new Entry(canonical,fingerprint,edge,decoded,decoded.Pair.Hdr.SizeBytes+decoded.Pair.Sdr.SizeBytes);
            if(entry.Bytes<=Budget) {
                while(bytes+entry.Bytes>Budget && Entries.Last!=null)Remove(Entries.Last);
                Entries.AddFirst(entry);entry.Retained=true;bytes+=entry.Bytes;
            }
            return Lease(entry);
        }
    }
    private static HDRSourceLease Lease(Entry value)
    {
        value.Users++;
        return new(value.Owner,()=>{lock(Gate){value.Users--;if(!value.Retained && value.Users==0)value.Owner.Dispose();}});
    }
    private static void Remove(LinkedListNode<Entry> node)
    {
        Entries.Remove(node);var value=node.Value;bytes-=value.Bytes;value.Retained=false;
        if(value.Users==0)value.Owner.Dispose();
    }
    internal static void Clear() {lock(Gate)while(Entries.Last!=null)Remove(Entries.Last);}
}
