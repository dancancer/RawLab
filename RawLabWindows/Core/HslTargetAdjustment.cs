namespace RawLab.Windows;

internal readonly record struct HslTargetRevision(ulong Source,ulong Request);
internal enum HslTargetAvailability { Available,NearGray,Outside,Stale,Nonfinite,Failed }
internal sealed class HslTargetSample
{
    internal HslTargetRevision Revision { get; }
    internal HslTargetAvailability Availability { get; }
    internal IReadOnlyList<double> Rgb { get; }
    internal IReadOnlyList<double> Weights { get; }
    internal bool Preview { get; }
    internal bool Usable=>Availability==HslTargetAvailability.Available && Rgb.Count==3 && Rgb.All(double.IsFinite) &&
        Weights.Count==8 && Weights.All(v=>double.IsFinite(v) && v>=0 && v<=1) && Math.Abs(Weights.Sum()-1)<.00001;
    internal IEnumerable<int> Channels=>Usable ? Enumerable.Range(0,8).Where(i=>Weights[i]>0) : [];
    internal HslTargetSample(HslTargetRevision revision,HslTargetAvailability availability,IEnumerable<double> rgb,IEnumerable<double> weights,bool preview)
    { Revision=revision;Availability=availability;Rgb=Array.AsReadOnly(rgb.ToArray());Weights=Array.AsReadOnly(weights.ToArray());Preview=preview; }
    internal static HslTargetSample Unavailable(HslTargetRevision revision,HslTargetAvailability reason)=>new(revision,reason,[],[],true);
}

// 异步取色保留最后位移；整次拖动始终从同一份逻辑 HSL 和权重计算。
internal sealed class HslTargetInteraction
{
    private sealed class Pending(ulong token,HslSettings before,int axis,HslTargetRevision revision)
    {
        internal readonly ulong Token=token;
        internal readonly HslSettings Before=before;
        internal readonly int Axis=axis;
        internal readonly HslTargetRevision Revision=revision;
        internal double Delta;
        internal bool Released;
        internal HslTargetSample? Sample;
        internal HslSettings Value() {
            var next=Before;
            if(Sample!=null)foreach(var i in Sample.Channels)next=next.WithValue(Axis,i,Before.Value(Axis,i)+Delta*Sample.Weights[i]);
            return next;
        }
    }
    private ulong generation;
    private Pending? pending;
    internal HslTargetSample? Selection { get; private set; }
    internal bool Dragging=>pending?.Released==false;
    internal bool Waiting=>pending!=null && pending.Sample==null;
    internal bool Matches(ulong token)=>pending?.Token==token;
    internal ulong Begin(HslSettings before,int axis,HslTargetRevision revision)
    {
        if(axis is <0 or >2)throw new ArgumentOutOfRangeException(nameof(axis));
        Selection=null;pending=new(++generation,before,axis,revision);return generation;
    }
    internal HslSettings? Move(double delta)
    {
        if(pending==null || pending.Released || !double.IsFinite(delta))return null;
        pending.Delta=delta;return pending.Sample==null ? null : pending.Value();
    }
    internal HslSettings? Accept(HslTargetSample sample,ulong token,HslTargetRevision? current)
    {
        if(pending is not {} active || active.Token!=token)return null;
        if(active.Revision!=current || sample.Revision!=active.Revision){pending=null;Selection=null;return null;}
        Selection=sample;
        if(!sample.Usable){pending=null;return null;}
        active.Sample=sample;if(active.Released)pending=null;return active.Value();
    }
    internal void End() { if(pending?.Sample!=null)pending=null;else if(pending!=null)pending.Released=true; }
    internal void AccumulateReleased(double delta)
    { if(pending is { Released:true,Sample:null } active && double.IsFinite(delta) && double.IsFinite(active.Delta+delta))active.Delta+=delta; }
    internal HslSettings? Cancel()
    { var before=pending?.Sample==null ? null : pending.Before;pending=null;Selection=null;return before; }
}
