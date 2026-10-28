using F = RawLab.Windows.AdjustmentField;
using static RawLab.Windows.AdjustmentPayload;

namespace RawLab.Windows;

internal static class AdjustmentTransferWB
{
    private sealed record Resolved(bool Camera,double Temperature=6500,double Tint=0)
    {
        public bool Equals(Resolved? other)=>other!=null && Camera==other.Camera && (float)Temperature==(float)other.Temperature && (float)Tint==(float)other.Tint;
        public override int GetHashCode()=>HashCode.Combine(Camera,(float)Temperature,(float)Tint);
    }
    private static Resolved Camera(AdjustmentSnapshot s)
    {
        if(s.AsShotTemperature is not {} temperature || s.AsShotTint is not {} tint ||
            !double.IsFinite(temperature) || !double.IsFinite(tint) || temperature is <2000 or >50000 || tint is <-150 or >150)
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"target camera white balance unavailable");
        return new(false,temperature,tint);
    }
    private static Resolved Render(AdjustmentSnapshot s)
    {
        var r=s.Restore().Request("",null,0,null);return new(r.WbMode==0,r.Temperature,r.Tint);
    }
    private static void Require(bool valid,string field="color.white_balance")
    {if(!valid)throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable,field);}
    private static void RequireCalibration(AdjustmentSnapshot s)
    {
        if(s.MasterRecipeID!=null && (s.Values[(int)Parameter.Tint]*AdjustmentTransfer.Scale(s)!=0 || !s.CameraWhiteBalance)) _=Camera(s);
    }
    private static AdjustmentSnapshot Set(AdjustmentSnapshot s,bool camera,double temperature,double tint)
    {
        var values=(double[])s.Values.Clone();values[(int)Parameter.Temperature]=temperature;values[(int)Parameter.Tint]=tint;
        var result=s with {CameraWhiteBalance=camera,Values=values};_=result.Restore();return result;
    }
    private static Resolved Resolve(bool camera,double? temperature,double tint,bool relative,AdjustmentRecipeContext? recipe,
        bool sourceIsRaw,bool targetIsRaw,AdjustmentSnapshot target)
    {
        if(!targetIsRaw || !sourceIsRaw && recipe==null)return new(true);
        var offset=tint*(relative ? recipe?.Strength ?? 1 : 1);
        if(camera && offset==0)return new(true);
        if(camera || relative)_=Camera(target);
        var finalTint=relative ? target.AsShotTint!.Value+offset : offset;
        Require(finalTint is >=-150 and <=150,F.Tint.ID());
        return new(false,camera ? target.AsShotTemperature!.Value : temperature!.Value,finalTint);
    }
    private static AdjustmentSnapshot ApplyResolved(Resolved desired,AdjustmentSnapshot s)
    {
        if(desired.Camera)return Set(s,true,s.AsShotTemperature ?? 6500,s.MasterRecipeID!=null ? 0 : s.AsShotTint ?? 0);
        var tint=(double)desired.Tint;
        if(s.MasterRecipeID!=null) {
            _=Camera(s);var delta=tint-s.AsShotTint!.Value;var scale=AdjustmentTransfer.Scale(s);
            Require(scale!=0 || delta==0);tint=scale==0 ? 0 : delta/scale;
        }
        var result=Set(s,false,desired.Temperature,tint);
        if(Render(result)!=desired) {
            foreach(var neighbor in new[]{Math.BitDecrement(tint),Math.BitIncrement(tint)}) {
                try {var candidate=Set(s,false,desired.Temperature,neighbor);if(Render(candidate)==desired)return candidate;}
                catch(ArgumentException) { }
            }
        }
        Require(Render(result)==desired);return result;
    }
    internal static AdjustmentSnapshot Apply(AdjustmentPayload p,AdjustmentSnapshot target,AdjustmentSnapshot s,
        AdjustmentTransferContext context,bool fullRecipe,bool changed)
    {
        var selected=p.Fields.Intersect(AdjustmentFields.WhiteBalance).ToHashSet();
        if(selected.Count==0) {
            if(context.IsRaw && changed && Render(s)!=Render(target)) {
                RequireCalibration(target);var desired=Render(target);s=ApplyResolved(desired,s);
                if(target.CameraWhiteBalance && s.MasterRecipeID!=null) {
                    var camera=s with {CameraWhiteBalance=true};if(Render(camera)==desired)s=camera;
                }
            }
            return s;
        }
        if(!context.IsRaw && p.Source.IsRaw)throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"color.white_balance");
        var previousValues=AdjustmentTransferValues.Values(new(new("",0,0,0),target,null),context);
        if(!changed && context.IsRaw==p.Source.IsRaw && AdjustmentTransfer.Recipe(target)==p.Source.Recipe && selected.All(f=>Same(p[f],previousValues[f])))return s;
        var mode=Text(p[F.WhiteBalanceMode]);var temperature=p[F.Temperature];var tint=p[F.Tint];
        if(selected.SetEquals(AdjustmentFields.WhiteBalance)) {
            var camera=mode=="camera" || mode=="none" && p.Source.Recipe!=null;
            var desired=Resolve(camera,Number(temperature),Number(tint) ?? 0,p.Source.Recipe!=null || mode=="camera",p.Source.Recipe,p.Source.IsRaw,context.IsRaw,target);
            if(fullRecipe) {
                s=Set(s,mode!="temperature",Number(temperature) ?? s.AsShotTemperature ?? 6500,Number(tint) ?? 0);
                if(context.IsRaw && Render(s)!=desired) {
                    s=ApplyResolved(desired,s);if(camera)s=s with {CameraWhiteBalance=true};
                    Require(Render(s)==desired);
                }
            } else if(context.IsRaw)s=ApplyResolved(desired,s);
            return s;
        }
        if(!context.IsRaw)return s;
        var cameraMode=mode!=null ? mode!="temperature" : target.CameraWhiteBalance;
        if(temperature!=null && (cameraMode ? !Null(temperature) : Number(temperature)==null))
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"select white balance mode with temperature");
        if(tint!=null && (cameraMode ? Number(tint)!=null && p.Source.Recipe==null : Null(tint)))
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"select white balance mode with tint");
        RequireCalibration(target);var previous=Render(target);Resolved request;
        if(cameraMode) {
            double offset;
            if(tint!=null)offset=(Number(tint) ?? 0)*(p.Source.Recipe?.Strength ?? 1);
            else if(target.MasterRecipeID!=null)offset=target.Values[(int)Parameter.Tint]*AdjustmentTransfer.Scale(target);
            else if(target.CameraWhiteBalance)offset=0;
            else {_=Camera(target);offset=previous.Tint-target.AsShotTint!.Value;}
            if(temperature==null && !target.CameraWhiteBalance)Require((float)previous.Temperature==(float)Camera(target).Temperature,"unselected white balance temperature");
            if(offset==0)request=new(true);
            else {_=Camera(target);var finalTint=target.AsShotTint!.Value+offset;Require(finalTint is >=-150 and <=150,F.Tint.ID());request=new(false,target.AsShotTemperature!.Value,finalTint);}
            if(s.MasterRecipeID==null && offset!=0 && mode==null && !changed)
                throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"select white balance mode with relative tint");
            if(s.MasterRecipeID==null && offset!=0 && mode!=null && tint==null)
                throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable,"unselected white balance tint");
        } else {
            var fixedTemperature=Number(temperature) ?? (previous.Camera ? Camera(target).Temperature : previous.Temperature);
            var fixedTint=Number(tint) is {} value ? p.Source.Recipe is {} recipe ? Camera(target).Tint+value*recipe.Strength : value
                : previous.Camera ? Camera(target).Tint : previous.Tint;
            Require(fixedTint is >=-150 and <=150,F.Tint.ID());request=new(false,fixedTemperature,fixedTint);
        }
        s=ApplyResolved(request,s);
        if(cameraMode && s.MasterRecipeID!=null)s=s with {CameraWhiteBalance=true};
        if(!changed)s=Set(s,mode==null ? target.CameraWhiteBalance : s.CameraWhiteBalance,
            temperature==null ? target.Values[(int)Parameter.Temperature] : s.Values[(int)Parameter.Temperature],
            tint==null ? target.Values[(int)Parameter.Tint] : s.Values[(int)Parameter.Tint]);
        Require(Render(s)==request);return s;
    }
}
