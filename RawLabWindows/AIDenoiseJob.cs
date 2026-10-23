namespace RawLab.Windows;

internal sealed record AIDenoiseIdentity(OriginalIdentity Source,ProcessingIdentity Processing,int WhiteBalance,float Temperature,float Tint,int Backend,LensSettings Lens)
{
    internal static AIDenoiseIdentity Read(string path,Adjustments settings,int backend)
    {
        var request=settings.Request(path,null,0,null);
        // 相机 WB 由原片确定；配方身份只记录用户偏移，不随首帧解析出的 AsShot 改变。
        var temperature=settings.CameraWhiteBalance ? 0 : request.Temperature;
        var tint=settings.MasterRecipeID==null ? request.Tint : (float)(settings[Parameter.Tint]*settings[Parameter.Strength]/100);
        return new(OriginalIdentity.Read(path),settings.Processing,request.WbMode,temperature,tint,backend,settings.Lens);
    }
}
internal enum AIDenoiseStatus { Idle,Running,Ready,Failed,Cancelled }
internal sealed record AIDenoiseState(AIDenoiseStatus Status,int Phase=0,ulong Done=0,ulong Total=0,string? Error=null)
{
    internal bool IsRunning=>Status==AIDenoiseStatus.Running;
}
internal sealed class AIPreparation : IDisposable
{
    private readonly CancellationTokenSource cancellation=new();
    private readonly Action<int,ulong,ulong> progress;
    internal AIPreparation(Action<int,ulong,ulong> progress)=>this.progress=progress;
    internal CancellationToken Token=>cancellation.Token;
    internal bool IsCancelled=>cancellation.IsCancellationRequested;
    internal void Cancel()=>cancellation.Cancel();
    internal bool Report(int phase,ulong done,ulong total)
    {
        if(IsCancelled)return false;
        progress(phase,done,total);return !IsCancelled;
    }
    public void Dispose()=>cancellation.Dispose();
}

// 同一进程只准备一张完整照片；新任务可以取消旧任务，但必须等旧 native 调用退出。
internal sealed class AIDenoiseJob
{
    private static readonly SemaphoreSlim queue=new(1,1);
    private readonly object gate=new();
    private readonly Action<AIDenoiseIdentity,Adjustments,AIPreparation> prepare;
    private AIPreparation? preparation;
    private long generation;
    private AIDenoiseState state=new(AIDenoiseStatus.Idle);
    private AIDenoiseIdentity? identity;
    internal AIDenoiseState State { get { lock(gate)return state; } }
    internal AIDenoiseIdentity? Identity { get { lock(gate)return identity; } }
    internal Task Completion { get; private set; }=Task.CompletedTask;
    internal event Action? Changed;
    internal AIDenoiseJob(Action<AIDenoiseIdentity,Adjustments,AIPreparation> prepare)=>this.prepare=prepare;
    internal Task<bool> StartAsync(AIDenoiseIdentity next,Adjustments settings)
    {
        long revision;AIPreparation progress;
        lock(gate) {
            preparation?.Cancel();revision=++generation;identity=next;state=new(AIDenoiseStatus.Running,1,0,1);
            preparation=progress=new((phase,done,total)=>{
                lock(gate) {
                    if(revision!=generation || !state.IsRunning)return;
                    state=new(AIDenoiseStatus.Running,phase,done,total);
                }
                Changed?.Invoke();
            });
        }
        Changed?.Invoke();
        var work=RunAsync(revision,next,settings.Clone(),progress);
        Completion=Completion.IsCompleted ? work : Task.WhenAll(Completion,work);
        return work;
    }
    private async Task<bool> RunAsync(long revision,AIDenoiseIdentity current,Adjustments settings,AIPreparation progress)
    {
        var entered=false;Exception? failure=null;
        try {
            await queue.WaitAsync(progress.Token);entered=true;
            await Task.Run(()=>prepare(current,settings,progress),progress.Token);
        } catch(Exception error) { failure=error; }
        finally { if(entered)queue.Release(); }
        bool success;
        lock(gate) {
            if(revision!=generation) { progress.Dispose();return false; }
            success=failure==null && !progress.IsCancelled;
            state=success ? new(AIDenoiseStatus.Ready) :
                progress.IsCancelled || failure is OperationCanceledException ? new(AIDenoiseStatus.Cancelled) :
                new(AIDenoiseStatus.Failed,Error:failure!.Message);
            preparation=null;progress.Dispose();
        }
        Changed?.Invoke();return success;
    }
    internal void Cancel()
    {
        lock(gate) {
            if(!state.IsRunning)return;
            ++generation;preparation?.Cancel();preparation=null;state=new(AIDenoiseStatus.Cancelled);
        }
        Changed?.Invoke();
    }
    internal void Reset()
    {
        lock(gate) {
            ++generation;preparation?.Cancel();preparation=null;identity=null;state=new(AIDenoiseStatus.Idle);
        }
        Changed?.Invoke();
    }
    internal void Fail(string message)
    {
        lock(gate) {
            ++generation;preparation?.Cancel();preparation=null;state=new(AIDenoiseStatus.Failed,Error:message);
        }
        Changed?.Invoke();
    }
}
