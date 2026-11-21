using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace RawLab.Windows;

// 常驻 ExifTool 管道：整批导出共享一个 `-stay_open True -@ -` 进程，避免每张照片
// 重新支付一次 ExifTool（Perl 运行时）冷启动。每张照片写入本命令参数、
// `-echo3 RC${status}E<seq>` 与 `-execute<seq>`，然后等待 stdout 上的 `{ready<seq>}`
// 结束标记。-echo3 在“本条命令处理完成之后”输出到 stdout，${status} 即该命令的
// 退出码（exiftool_pod：-echo[3|4] after processing is complete … the numerical
// exit status of the command），因此命令输出、状态标记、ready 标记同流有序，
// 不依赖跨流时序。若某版本把 ${status} 解释为进程累计状态，最坏只会虚报失败
// （导出可见地报错、不静默写坏），不会假绿。
// 失败语义：会话启动失败 → 本张回退旧单次调用（语义不降级）；超时/管道中断 →
// 杀进程并清理，下一张照片重新拉起，避免一张坏图拖垮整批；退出码非零 → 本张
// 抛错但进程仍可用。
internal static class ExifToolSession
{
    // 测试接缝：注入替身可执行（本仓库为 --exif-stub 重启自身）。生产为 null。
    internal static Func<ProcessStartInfo, Process?>? LauncherForTests;
    // 单条命令的等待预算；与历史单次调用 WaitForExit(60000) 口径一致。
    internal static int CommandTimeoutMilliseconds = 60_000;

    private static readonly object Gate = new();
    private static readonly Regex ReturnCode = new(@"^RC(-?\d+)E(\d+)$", RegexOptions.Compiled);
    private static Process? process;
    private static StreamWriter? input;
    private static StreamReader? output;
    private static readonly StringBuilder StderrTail = new();
    private static readonly object StderrGate = new();
    private static long sequence;

    static ExifToolSession() => AppDomain.CurrentDomain.ProcessExit += (_, _) =>
    {
        // 收尾有界进行：正常在途命令毫秒级即锁到手；抢不到说明命令已卡住，直接强杀，
        // 宁可少一次优雅退出也不拖住应用关闭（stay_open 进程遇 EOF 会空转，不能留孤儿）。
        if (System.Threading.Monitor.TryEnter(Gate, 100))
        {
            try { Retire(); }
            finally { System.Threading.Monitor.Exit(Gate); }
        }
        else
        {
            try { process?.Kill(entireProcessTree: true); } catch { }
        }
    };

    internal static string ExecutablePath()
    {
        var executable = Path.Combine(AppContext.BaseDirectory, "ExifTool", "ExifTool.exe");
        if (LauncherForTests is null && !File.Exists(executable))
            throw new OutputWriteException(Loc.Text("缺少 EXIF 导出组件，请重新解压完整的 RawLab 安装包。"));
        return executable;
    }

    internal static string Run(IEnumerable<string> arguments)
    {
        var lines = arguments.ToArray();
        if (lines.Any(line => line.Contains('\n') || line.Contains('\r')))
            throw new ArgumentException(Loc.Text("EXIF 参数不能包含换行。"));
        // 会话协议依赖 -execute<seq> 的独占配对；提前拒绝，避免标记计数错位。
        if (lines.Any(line => line.StartsWith("-execute", StringComparison.Ordinal)))
            throw new ArgumentException(Loc.Text("EXIF 参数不能包含 -execute。"));
        lock (Gate)
        {
            try
            {
                return Send(lines);
            }
            catch (StartupFailedException failure)
            {
                return RunSingleShot(lines, failure);
            }
        }
    }

    private sealed class StartupFailedException(Exception cause) : Exception(null, cause);

    private static string Send(string[] lines)
    {
        // 子进程死亡与“本张命令写入”之间存在无法消除的竞态窗口（HasExited 检查后一拍才死）。
        // EOF/写故障意味着 ExifTool 已终止且没有留下未读回执——命令要么没执行，要么幂等重放
        // 无害（-overwrite_original 重写同一组标签）。因此首次遇到直接换新进程重发一次；
        // 超时不放行重试（命令可能执行到一半，等满预算直接失败给用户）。
        for (var attempt = 0; ; attempt++)
        {
            if (process is null) Start();
            else if (process.HasExited) { Retire(); Start(); }
            var writer = input ?? throw new IOException(Loc.Text("EXIF 导出进程意外中断，未确认写入结果。"));
            var reader = output ?? throw new IOException(Loc.Text("EXIF 导出进程意外中断，未确认写入结果。"));
            var seq = ++sequence;
            var seqText = seq.ToString(CultureInfo.InvariantCulture);
            lock (StderrGate) StderrTail.Clear();
            try
            {
                writer.WriteLine("-charset"); writer.WriteLine("filename=utf8");
                foreach (var line in lines) writer.WriteLine(line);
                writer.WriteLine("-echo3"); writer.WriteLine($"RC${{status}}E{seqText}");
                writer.WriteLine($"-execute{seqText}");
                writer.Flush();
            }
            catch (Exception ex)
            {
                Retire();
                if (attempt == 0) continue;
                throw new IOException(Loc.Text("EXIF 导出进程意外中断，未确认写入结果。") + StderrDetail(), ex);
            }
            var result = new List<string>();
            int? exitCode = null;
            var eof = false;
            try
            {
                while (true)
                {
                    var line = ReadLine(reader);
                    if (line is null) { eof = true; break; }
                    if (line == $"{{ready{seqText}}}") break;
                    var match = ReturnCode.Match(line);
                    if (match.Success && match.Groups[2].Value == seqText)
                        exitCode = int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
                    else result.Add(line);
                }
            }
            catch (Exception ex)
            {
                Retire();
                if (ex is IOException) throw; // 保留超时/中断的原始用户文案
                throw new IOException(Loc.Text("EXIF 导出进程意外中断，未确认写入结果。") + StderrDetail(), ex);
            }
            if (eof)
            {
                Retire();
                if (attempt == 0) continue;
                throw new IOException(Loc.Text("EXIF 导出进程意外中断，未确认写入结果。") + StderrDetail());
            }
            if (exitCode is { } code && code != 0)
            {
                // 等 stderr 抽干线程补齐，避免截断给用户的错误文本。
                throw new IOException(Loc.Text("写入 EXIF 失败：") + FailureDetail(code));
            }
            return string.Join('\n', result);
        }
    }

    // 已死子进程的 stderr 尾部（多为崩溃/报错原因），等抽干线程 50ms 追平。
    private static string StderrDetail()
    {
        Thread.Sleep(50);
        string stderr;
        lock (StderrGate) stderr = StderrTail.ToString().Trim();
        return stderr.Length == 0 ? string.Empty : " " + stderr;
    }

    private static string FailureDetail(int code)
    {
        Thread.Sleep(100);
        string stderr;
        lock (StderrGate) stderr = StderrTail.ToString().Trim();
        return stderr.Length > 0 ? stderr : string.Format(Loc.Text("退出码 {0}。"), code);
    }

    // 在命令超时预算内读一行；超时即杀进程解锁管道（reader 线程随管道关闭自然退出）。
    private static string? ReadLine(StreamReader reader)
    {
        var line = Task.Run(reader.ReadLine);
        if (!line.Wait(CommandTimeoutMilliseconds))
        {
            Retire();
            throw new IOException(Loc.Text("写入 EXIF 超时，未保存导出结果。"));
        }
        if (line.IsFaulted) throw line.Exception!.GetBaseException();
        return line.Result;
    }

    private static void Start()
    {
        var launcher = LauncherForTests;
        var start = new ProcessStartInfo(ExecutablePath())
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        // 禁用用户配置并让 ExifTool 常驻等待 stdin 参数流（-config 在 -execute 之间保持生效）。
        foreach (var arg in new[] { "-config", "", "-stay_open", "True", "-@", "-" }) start.ArgumentList.Add(arg);
        start.Environment["LC_ALL"] = "C";
        try
        {
            process = launcher?.Invoke(start) ?? Process.Start(start) ?? throw new IOException(Loc.Text("无法启动 EXIF 导出组件。"));
        }
        catch (Exception ex)
        {
            process = null; input = null; output = null;
            throw new StartupFailedException(ex);
        }
        var error = process.StandardError;
        lock (StderrGate) StderrTail.Clear();
        // stderr 持续抽干，防止大量告警填满管道把 ExifTool 卡死；仅保留有界尾部供失败信息。
        _ = Task.Run(() =>
        {
            try { while (error.ReadLine() is { } reported) lock (StderrGate) { if (StderrTail.Length < 65_536) StderrTail.AppendLine(reported); } }
            catch { /* 进程结束 */ }
        });
        input = process.StandardInput;
        output = process.StandardOutput;
        sequence = 0;
    }

    // 优雅收尾（-stay_open False），短等后强杀兜底，并释放管道与会话状态。
    private static void Retire()
    {
        var current = process;
        process = null;
        try { input?.WriteLine("-stay_open"); input?.WriteLine("False"); input?.WriteLine("-execute"); } catch { }
        try { input?.Close(); } catch { }
        input = null; output = null;
        if (current is null) return;
        try
        {
            if (!current.WaitForExit(250)) current.Kill(entireProcessTree: true);
            current.WaitForExit(1000);
        }
        catch { /* 已退出 */ }
        try { current.Dispose(); } catch { }
    }

    internal static void RetireForTests() { lock (Gate) Retire(); }

    // 单次调用回退：与改造前的 Run 逐段同语义（同参数、同超时消息、退出码非零即抛）。
    private static string RunSingleShot(string[] lines, Exception startupFailure)
    {
        var launcher = LauncherForTests;
        var start = new ProcessStartInfo(ExecutablePath())
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        // Disable user configuration and use a UTF-8 argument stream for Unicode paths.
        foreach (var arg in new[] { "-config", "", "-charset", "filename=utf8", "-@", "-" }) start.ArgumentList.Add(arg);
        start.Environment["LC_ALL"] = "C";
        Process started;
        try
        {
            started = launcher?.Invoke(start) ?? Process.Start(start) ?? throw new IOException(Loc.Text("无法启动 EXIF 导出组件。"));
        }
        catch (Exception ex)
        {
            throw new IOException(Loc.Text("无法启动 EXIF 导出组件。"), new AggregateException(startupFailure, ex));
        }
        using var oneShot = started;
        var stdout = oneShot.StandardOutput.ReadToEndAsync();
        var stderr = oneShot.StandardError.ReadToEndAsync();
        foreach (var line in lines) oneShot.StandardInput.WriteLine(line);
        oneShot.StandardInput.Close();
        if (!oneShot.WaitForExit(CommandTimeoutMilliseconds))
        {
            oneShot.Kill(entireProcessTree: true);
            oneShot.WaitForExit();
            throw new IOException(Loc.Text("写入 EXIF 超时，未保存导出结果。"));
        }
        var error = stderr.GetAwaiter().GetResult();
        var result = stdout.GetAwaiter().GetResult();
        if (oneShot.ExitCode != 0) throw new IOException(Loc.Text("写入 EXIF 失败：") + error.Trim());
        return result;
    }
}
