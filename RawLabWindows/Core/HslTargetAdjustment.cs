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

internal sealed class CurveTargetDrag
{
    internal ToneCurveSettings Before { get; }
    internal ToneCurveChannel Channel { get; }
    internal ToneCurveSettings Initial { get; }
    internal int PointIndex { get; }
    internal HslTargetSample Sample { get; }

    internal static double? TargetValue(HslTargetSample sample, ToneCurveChannel channel, bool isHdr)
    {
        if (sample.Availability is not (HslTargetAvailability.Available or HslTargetAvailability.NearGray) ||
            sample.Rgb.Count != 3 || !sample.Rgb.All(double.IsFinite))
            return null;
        var raw = channel switch {
            ToneCurveChannel.Rgb => 0.2126 * sample.Rgb[0] + 0.7152 * sample.Rgb[1] + 0.0722 * sample.Rgb[2],
            ToneCurveChannel.Red => sample.Rgb[0],
            ToneCurveChannel.Green => sample.Rgb[1],
            ToneCurveChannel.Blue => sample.Rgb[2],
            _ => sample.Rgb[0]
        };
        if (isHdr) {
            if (raw <= 0) return 0.0;
            return Math.Clamp((Math.Log2(raw) + 8.0) / 16.0, 0.0, 1.0);
        }
        return Math.Clamp(raw, 0.0, 1.0);
    }

    internal static double InvertSampledCurve(double yOut, IReadOnlyList<ToneCurvePoint> samples)
    {
        if (samples.Count < 2) return Math.Clamp(yOut, 0.0, 1.0);
        if (yOut <= samples[0].Y) return samples[0].X;
        if (yOut >= samples[^1].Y) return samples[^1].X;
        for (var i = 0; i < samples.Count - 1; i++) {
            var a = samples[i]; var b = samples[i + 1];
            if (yOut >= a.Y && yOut <= b.Y) {
                var spanY = b.Y - a.Y;
                return spanY <= 1e-12 ? (a.X + b.X) * 0.5 : a.X + (b.X - a.X) * ((yOut - a.Y) / spanY);
            }
        }
        return Math.Clamp(yOut, 0.0, 1.0);
    }

    internal static CurveTargetDrag? Create(
        ToneCurveSettings before,
        ToneCurveChannel channel,
        HslTargetSample sample,
        IReadOnlyList<ToneCurvePoint> sampledCurve,
        bool isHdr = false,
        Func<double, double>? parametricEvaluator = null,
        double toleranceX = 0.04)
    {
        if (TargetValue(sample, channel, isHdr) is not {} yOut) return null;
        var existingShape = before.Shape(channel);
        var workingShape = existingShape.Mode == ToneCurveMode.Legacy ? ToneCurveShape.Identity : existingShape;
        var xIn = InvertSampledCurve(yOut, sampledCurve);
        var targetX = channel == ToneCurveChannel.Rgb && !before.Parametric.IsIdentity && parametricEvaluator != null
            ? Math.Clamp(parametricEvaluator(xIn), 0.0, 1.0)
            : xIn;
        var nearestIdx = Enumerable.Range(0, workingShape.Points.Count).MinBy(i => Math.Abs(workingShape.Points[i].X - targetX));
        if (Math.Abs(workingShape.Points[nearestIdx].X - targetX) <= toleranceX) {
            return new(before, channel, before.Replacing(channel, workingShape), nearestIdx, sample);
        }
        if (targetX > 0.0 && targetX < 1.0 && workingShape.Points.Count < 33) {
            var yAtX = existingShape.Mode == ToneCurveMode.Legacy ? targetX : yOut;
            var inserted = workingShape.Inserting(targetX, yAtX);
            var idx = -1;
            for (var i = 0; i < inserted.Points.Count; i++) {
                if (inserted.Points[i].X == targetX) { idx = i; break; }
            }
            if (idx >= 0) {
                return new(before, channel, before.Replacing(channel, inserted), idx, sample);
            }
        }
        return new(before, channel, before.Replacing(channel, workingShape), nearestIdx, sample);
    }

    private CurveTargetDrag(ToneCurveSettings before, ToneCurveChannel channel, ToneCurveSettings initial, int pointIndex, HslTargetSample sample)
    {
        Before = before; Channel = channel; Initial = initial; PointIndex = pointIndex; Sample = sample;
    }

    internal ToneCurveSettings Value(double delta)
    {
        if (!double.IsFinite(delta)) return Before;
        var shape = Initial.Shape(Channel);
        if (PointIndex < 0 || PointIndex >= shape.Points.Count) return Before;
        var p = shape.Points[PointIndex];
        return Initial.Replacing(Channel, shape.Moving(PointIndex, p.X, p.Y + delta / 200.0));
    }
}

internal sealed class CurveTargetInteraction
{
    private sealed class Pending(ulong token, ToneCurveSettings before, ToneCurveChannel channel, HslTargetRevision revision,
        IReadOnlyList<ToneCurvePoint> sampledCurve, bool isHdr, Func<double, double>? parametricEvaluator)
    {
        internal readonly ulong Token = token;
        internal readonly ToneCurveSettings Before = before;
        internal readonly ToneCurveChannel Channel = channel;
        internal readonly HslTargetRevision Revision = revision;
        internal readonly IReadOnlyList<ToneCurvePoint> SampledCurve = sampledCurve;
        internal readonly bool IsHdr = isHdr;
        internal readonly Func<double, double>? ParametricEvaluator = parametricEvaluator;
        internal double Delta;
        internal bool Released;
        internal CurveTargetDrag? Drag;
    }
    private ulong generation;
    private Pending? pending;
    internal HslTargetSample? Selection { get; private set; }
    internal bool Dragging => pending?.Released == false;
    internal bool Waiting => pending != null && pending.Drag == null;
    internal bool Matches(ulong token) => pending?.Token == token;

    internal ulong Begin(ToneCurveSettings before, ToneCurveChannel channel, HslTargetRevision revision,
        IReadOnlyList<ToneCurvePoint> sampledCurve, bool isHdr = false, Func<double, double>? parametricEvaluator = null)
    {
        Selection = null;
        pending = new(++generation, before, channel, revision, sampledCurve, isHdr, parametricEvaluator);
        return generation;
    }

    internal ToneCurveSettings? Move(double delta)
    {
        if (pending == null || pending.Released || !double.IsFinite(delta)) return null;
        pending.Delta = delta;
        return pending.Drag?.Value(delta);
    }

    internal ToneCurveSettings? Accept(HslTargetSample sample, ulong token, HslTargetRevision? current)
    {
        if (pending is not {} active || active.Token != token) return null;
        if (active.Revision != current || sample.Revision != active.Revision) { pending = null; Selection = null; return null; }
        Selection = sample;
        if (CurveTargetDrag.Create(active.Before, active.Channel, sample, active.SampledCurve, active.IsHdr, active.ParametricEvaluator) is not {} drag) {
            pending = null; return null;
        }
        active.Drag = drag;
        if (active.Released) pending = null;
        return drag.Value(active.Delta);
    }

    internal void End() { if (pending?.Drag != null) pending = null; else if (pending != null) pending.Released = true; }
    internal void AccumulateReleased(double delta)
    { if (pending is { Released: true, Drag: null } active && double.IsFinite(delta) && double.IsFinite(active.Delta + delta)) active.Delta += delta; }
    internal ToneCurveSettings? Cancel()
    { var before = pending?.Drag == null ? null : pending.Before; pending = null; Selection = null; return before; }
}
