using System.Diagnostics;
using System.Reflection;
using RawLab.Windows;

// ExifTool stay_open 会话的行为测试：用 EditWorkflow.Tests 自身重启为
// --exif-stub 替身进程实现协议，不依赖打包的 ExifTool.exe（真机 ExifTool
// 由 RawLabWindows.Tests 的 ExportMetadataChecks 覆盖）。
internal static class ExifToolSessionChecks
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    // 替身主循环：stdin 一行一参数；-execute<seq> 收尾一条命令，回显
    // -echo3 文本（替换 ${status}）后打印 {ready<seq>}；EOF 且仍有挂起参数 = 单次模式。
    internal static void StubMain(string[] args)
    {
        var marker = args.Length > 1 ? args[1] : "exif-stub-calls.log";
        var pid = Environment.ProcessId.ToString();
        var pending = new List<string>();
        string? line;
        while ((line = Console.In.ReadLine()) != null)
        {
            if (!line.StartsWith("-execute", StringComparison.Ordinal)) { pending.Add(line); continue; }
            var seq = line["-execute".Length..];
            var code = pending.Contains("-fake-fail") ? 3 : 0;
            var sleep = pending.FirstOrDefault(p => p.StartsWith("-fake-sleep=", StringComparison.Ordinal)) is { } delay
                ? int.Parse(delay["-fake-sleep=".Length..], System.Globalization.CultureInfo.InvariantCulture) : 0;
            var die = pending.Contains("-fake-die");
            File.AppendAllText(marker, $"CMD {pid}{Environment.NewLine}");
            if (pending.Contains("-fake-out")) Console.Out.WriteLine("OUTLINE");
            if (sleep > 0) Thread.Sleep(sleep);
            if (code != 0) Console.Error.WriteLine("stub warning");
            var echoIndex = pending.IndexOf("-echo3");
            if (echoIndex >= 0 && echoIndex + 1 < pending.Count)
                Console.Out.WriteLine(pending[echoIndex + 1].Replace("${status}",
                    code.ToString(System.Globalization.CultureInfo.InvariantCulture)));
            Console.Out.WriteLine($"{{ready{seq}}}");
            Console.Out.Flush();
            pending.Clear();
            if (die) Environment.Exit(9);
        }
        if (pending.Count > 0)
        {
            var code = pending.Contains("-fake-fail") ? 3 : 0;
            File.AppendAllText(marker, $"ONESHOT {pid}{Environment.NewLine}");
            if (pending.Contains("-fake-out")) Console.Out.WriteLine("OUTLINE");
            if (code != 0) Console.Error.WriteLine("stub warning");
            Console.Out.Flush();
            Environment.Exit(code);
        }
        Environment.Exit(0);
    }

    private static List<string> SessionPids(string marker) =>
        File.ReadAllLines(marker).Where(l => l.StartsWith("CMD ", StringComparison.Ordinal))
            .Select(l => l[4..]).ToList();

    internal static void Run()
    {
        var directory = Path.Combine(Path.GetTempPath(), "rawlab-exif-session-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var marker = Path.Combine(directory, "calls.log");
        try
        {
            List<string>? captured = null;
            var failNextStartup = false;
            Process Launch(ProcessStartInfo start)
            {
                captured = start.ArgumentList.ToList();
                var sessionMode = start.ArgumentList.Contains("-stay_open");
                if (sessionMode && failNextStartup) throw new IOException("stub refuses session start");
                var path = Environment.ProcessPath ?? throw new IOException("no re-exec process path");
                start.FileName = path;
                start.ArgumentList.Clear();
                // dotnet X.dll 形态下需把入口程序集放在参数首位；apphost 形态直接自重启。
                if (string.Equals(Path.GetFileNameWithoutExtension(path), "dotnet", StringComparison.OrdinalIgnoreCase))
                    start.ArgumentList.Add(Assembly.GetEntryAssembly()!.Location);
                start.ArgumentList.Add("--exif-stub");
                start.ArgumentList.Add(marker);
                if (sessionMode) start.ArgumentList.Add("-stay_open");
                var spawned = new Process { StartInfo = start };
                if (!spawned.Start()) throw new IOException("stub did not start");
                return spawned;
            }
            ExifToolSession.LauncherForTests = Launch;
            try
            {
                // 1) 会话启动失败 → 本张回退单次调用，不拖垮导出。
                failNextStartup = true;
                Check(ExifToolSession.Run(["-fake-out"]).Trim() == "OUTLINE",
                    "Session startup failure falls back to a single ExifTool call");
                Check(File.ReadAllText(marker).Contains("ONESHOT"),
                    "Fallback actually executed one ExifTool process");
                failNextStartup = false;

                // 2) 会话按 -config/-stay_open/-@ 契约启动，命令输出干净（RC 标记不混入结果）。
                Check(ExifToolSession.Run(["-fake-out"]) == "OUTLINE", "Session command returns its stdout before the ready marker");
                var startArgs = captured;
                Check(ExifToolSession.Run(["-plain"]) == string.Empty, "Silent command returns empty result");
                Check(startArgs != null && startArgs.Contains("-config") && startArgs.Contains("") &&
                    startArgs.Contains("-stay_open") && startArgs.Contains("True") &&
                    startArgs.Contains("-@") && startArgs.Contains("-"),
                    "Session starts one stay_open piped ExifTool process");

                // 3) 两张照片共用一个进程；退出码非零抛错但会话存活可继续。
                var failed = false;
                try { ExifToolSession.Run(["-fake-fail", "-fake-out"]); }
                catch (IOException ex)
                {
                    failed = true;
                    Check(ex.Message.StartsWith("写入 EXIF 失败", StringComparison.Ordinal) &&
                        ex.Message.Contains("stub warning"), "Failure message carries ExifTool stderr");
                }
                Check(failed, "Non-zero command status surfaces as a write failure");
                Check(ExifToolSession.Run(["-fake-out"]) == "OUTLINE", "Session survives a failed command");
                var reused = SessionPids(marker);
                Check(reused.Count == 4 && reused.All(pid => pid == reused[0]),
                    "Four commands share one stay_open process without restart");

                // 4) 超时：本张在预算内失败并清理管道，下一张照片换新进程，不挂整批。
                ExifToolSession.CommandTimeoutMilliseconds = 200;
                var clock = Stopwatch.StartNew();
                var timedOut = false;
                try { ExifToolSession.Run(["-fake-sleep=10000"]); }
                catch (IOException ex)
                {
                    timedOut = ex.Message.Contains("超时");
                }
                clock.Stop();
                Check(timedOut && clock.ElapsedMilliseconds < 4000, "Stalled command fails inside the timeout budget instead of hanging");
                Check(ExifToolSession.Run(["-fake-out"]) == "OUTLINE", "Next photo proceeds after the stalled command was killed");
                var afterTimeout = SessionPids(marker);
                Check(afterTimeout.Count == 6 && afterTimeout[^1] != afterTimeout[^2],
                    "Timeout retires the stalled process so the next photo gets a fresh ExifTool");
                ExifToolSession.CommandTimeoutMilliseconds = 60_000;

                // 5) 进程中途退出 → 本张自愈（透明重启或 EOF 重发一次），下一张照片正常。
                Check(ExifToolSession.Run(["-fake-die", "-fake-out"]) == "OUTLINE", "Dying command still returns its acknowledged output");
                Check(ExifToolSession.Run(["-fake-out"]) == "OUTLINE", "Dead session transparently restarts on the next photo");
                var afterDie = SessionPids(marker);
                Check(afterDie.Count == 8 && afterDie[^1] != afterDie[^2],
                    "Mid-life exit is healed by a fresh ExifTool process, not a stuck pipe");

                // 6) 会话协议护栏：参数里禁止再塞 -execute。
                try
                {
                    ExifToolSession.Run(["-execute"]);
                    Check(false, "-execute inside command arguments was accepted");
                }
                catch (ArgumentException) { Check(true, "-execute inside command arguments is rejected before touching the pipe"); }
            }
            finally
            {
                ExifToolSession.LauncherForTests = null;
                ExifToolSession.CommandTimeoutMilliseconds = 60_000;
                ExifToolSession.RetireForTests();
            }
        }
        finally
        {
            try { Directory.Delete(directory, true); } catch { }
        }
        Console.WriteLine("PASS: ExifTool stay_open session (startup fallback, process reuse, status, timeout recovery)");
    }
}
