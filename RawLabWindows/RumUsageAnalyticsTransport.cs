#if RAWLAB_RUM_SDK
using System.IO;
using System.Runtime.InteropServices;

namespace RawLab.Windows;

// ┌──────────────────────────────────────────────────────────────────────┐
// │ 阿里云 RUM PC SDK 0.4.4 适配：只开自定义事件，关闭崩溃/网络/CEF 自动采集。 │
// │ 设备标识由 UsageAnalytics 传入（本机随机安装标识），不读取任何硬件编号。   │
// │ 原生 options 只在 alibabacloud_rum_close() 确认成功后才释放；关闭失败或   │
// │ 退出时放弃等待，都不会提前释放 SDK 仍可能在用的指针。                     │
// └──────────────────────────────────────────────────────────────────────┘
public sealed class RumUsageAnalyticsTransport : IUsageAnalyticsTransport
{
    private const string LibraryName = "alibabacloud_rum.dll";
    private const string AppName = "RawLab";
    // 取值来自 alibabacloud_rum.h；构建不编译 C 头文件
    private const int RumLevelFatal = 1;
    private static readonly object NativeGate = new();
    private static RumUsageAnalyticsTransport? active;

    private readonly RumConfiguration configuration;
    private bool started;
    private volatile bool lifecycleFailed;
    private Exception? lifecycleFailure;
    private IntPtr options;
    private string? cachePath;

    public RumUsageAnalyticsTransport(RumConfiguration configuration)
    {
        this.configuration = configuration;
    }

    public bool IsAvailable => !lifecycleFailed;

    // ─── 正式构建用写死的正式配置，本地验证构建用环境变量配置；SDK 不在程序旁边就当作不可用 ───
    public static IUsageAnalyticsTransport CreateDefault()
    {
        var environment = RumConfiguration.ProcessEnvironment();
        var version = typeof(RumUsageAnalyticsTransport).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
#if RAWLAB_RUM_LOCAL
        var configured = RumConfiguration.TryLocal(environment, version, out var configuration);
#else
        var configured = RumConfiguration.TryProduction(environment, version, out var configuration);
#endif
        return configured && configuration != null && File.Exists(Path.Combine(AppContext.BaseDirectory, LibraryName))
            ? new RumUsageAnalyticsTransport(configuration)
            : new UnavailableUsageAnalyticsTransport();
    }

    public Task StartAsync(string installId, CancellationToken cancellationToken) => Task.Run(() => StartCore(installId));

    public Task SendAsync(UsageEvent usageEvent, CancellationToken cancellationToken) =>
        Task.Run(() => SendCore(usageEvent));

    public Task StopAsync(CancellationToken cancellationToken) => Task.Run(StopCore);

    private void StartCore(string installId)
    {
        lock (NativeGate)
        {
            if (lifecycleFailure != null) throw lifecycleFailure;
            if (started) return;
            if (active != null && !ReferenceEquals(active, this))
                throw new InvalidOperationException("The Windows RUM SDK already has an active instance.");

            var cache = Path.Combine(Path.GetTempPath(), "rawlab-rum-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(cache);
            IntPtr nativeOptions;
            try { nativeOptions = Native.alibabacloud_rum_options_new(); }
            catch
            {
                DeleteCache(cache);
                throw;
            }
            if (nativeOptions == IntPtr.Zero)
            {
                DeleteCache(cache);
                throw new InvalidOperationException("The Windows RUM SDK could not allocate options.");
            }

            options = nativeOptions;
            cachePath = cache;
            active = this;
            try
            {
                Native.alibabacloud_rum_options_set_config_address(options, configuration.ConfigAddress);
                Native.alibabacloud_rum_options_set_app_id(options, configuration.AppId);
                Native.alibabacloud_rum_options_set_app_name(options, AppName);
                Native.alibabacloud_rum_options_set_app_version(options, configuration.AppVersion);
                Native.alibabacloud_rum_options_set_env(options, (int)configuration.Env);
                Native.alibabacloud_rum_options_set_utdid(options, installId);
                Native.alibabacloud_rum_options_set_debug_level(options, RumLevelFatal);
                Native.alibabacloud_rum_options_set_cache_path(options, cache);
                Native.alibabacloud_rum_options_set_auto_crash_tracking(options, 0);
                Native.alibabacloud_rum_options_set_auto_curl_tracking(options, 0);
                Native.alibabacloud_rum_options_set_auto_cef_tracking(options, 0);
                if (Native.alibabacloud_rum_init(options) != 0)
                    throw new InvalidOperationException("The Windows RUM SDK could not initialize.");

                started = true;
            }
            catch (Exception initializationFailure)
            {
                throw FinishFailedStart(initializationFailure);
            }
        }
    }

    private Exception FinishFailedStart(Exception initializationFailure)
    {
        try
        {
            if (Native.alibabacloud_rum_close() != 0)
                throw new InvalidOperationException("The Windows RUM SDK could not confirm failed-start cleanup.");

            Native.alibabacloud_rum_options_free(options);
            options = IntPtr.Zero;
            active = null;
            var cache = cachePath;
            cachePath = null;
            if (cache != null) DeleteCache(cache);
            return initializationFailure;
        }
        catch (Exception cleanupFailure)
        {
            return MarkLifecycleFailure(
                new InvalidOperationException(
                    "The Windows RUM SDK failed to initialize and cleanup was not confirmed; no retry will be attempted.",
                    new AggregateException(initializationFailure, cleanupFailure)));
        }
    }

    private void SendCore(UsageEvent usageEvent)
    {
        lock (NativeGate)
        {
            if (lifecycleFailure != null || !started || !ReferenceEquals(active, this)) return;
            var nativeEvent = Native.alibabacloud_rum_custom_event_new("usage", usageEvent.Name);
            if (nativeEvent == IntPtr.Zero) return;

            try
            {
                Native.alibabacloud_rum_custom_event_set_group(nativeEvent, usageEvent.Group);
                Native.alibabacloud_rum_custom_event_set_value(nativeEvent, usageEvent.Value);
                foreach (var property in usageEvent.Properties)
                    Native.alibabacloud_rum_custom_event_add_extra(nativeEvent, property.Key, property.Value);
                if (configuration.ValidationRun != null)
                    Native.alibabacloud_rum_custom_event_add_extra(
                        nativeEvent, "validation_run", configuration.ValidationRun);
                Native.alibabacloud_rum_custom_event_report(nativeEvent);
                nativeEvent = IntPtr.Zero;
            }
            finally
            {
                if (nativeEvent != IntPtr.Zero)
                    Native.alibabacloud_rum_custom_event_free(nativeEvent);
            }
        }
    }

    private void StopCore()
    {
        lock (NativeGate)
        {
            if (lifecycleFailure != null) throw lifecycleFailure;
            if (!started || !ReferenceEquals(active, this)) return;
            int result;
            try { result = Native.alibabacloud_rum_close(); }
            catch (Exception error)
            {
                throw MarkLifecycleFailure(new InvalidOperationException(
                    "The Windows RUM SDK close call failed; options and cache were retained and no retry will be attempted.",
                    error));
            }
            if (result != 0)
                throw MarkLifecycleFailure(new InvalidOperationException(
                    "The Windows RUM SDK close returned a failure; options and cache were retained and no retry will be attempted."));

            var nativeOptions = options;
            options = IntPtr.Zero;
            started = false;
            active = null;
            var cache = cachePath;
            cachePath = null;
            Native.alibabacloud_rum_options_free(nativeOptions);
            if (cache != null) DeleteCache(cache);
        }
    }

    private Exception MarkLifecycleFailure(Exception error)
    {
        lifecycleFailure = error;
        lifecycleFailed = true;
        return error;
    }

    private static void DeleteCache(string path)
    {
        if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
    }

    private static class Native
    {
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern IntPtr alibabacloud_rum_options_new();

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_options_free(IntPtr options);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_options_set_config_address(
            IntPtr options, [MarshalAs(UnmanagedType.LPUTF8Str)] string configAddress);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_options_set_app_id(
            IntPtr options, [MarshalAs(UnmanagedType.LPUTF8Str)] string appId);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_options_set_app_name(
            IntPtr options, [MarshalAs(UnmanagedType.LPUTF8Str)] string appName);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_options_set_app_version(
            IntPtr options, [MarshalAs(UnmanagedType.LPUTF8Str)] string appVersion);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_options_set_env(IntPtr options, int env);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_options_set_utdid(
            IntPtr options, [MarshalAs(UnmanagedType.LPUTF8Str)] string utdid);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_options_set_debug_level(IntPtr options, int level);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_options_set_cache_path(
            IntPtr options, [MarshalAs(UnmanagedType.LPUTF8Str)] string path);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_options_set_auto_crash_tracking(IntPtr options, int enabled);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_options_set_auto_curl_tracking(IntPtr options, int enabled);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_options_set_auto_cef_tracking(IntPtr options, int enabled);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern int alibabacloud_rum_init(IntPtr options);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern int alibabacloud_rum_close();

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern IntPtr alibabacloud_rum_custom_event_new(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string type,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string name);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_custom_event_set_value(IntPtr nativeEvent, double value);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_custom_event_set_group(
            IntPtr nativeEvent, [MarshalAs(UnmanagedType.LPUTF8Str)] string group);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_custom_event_add_extra(
            IntPtr nativeEvent,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string key,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string value);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_custom_event_free(IntPtr nativeEvent);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        internal static extern void alibabacloud_rum_custom_event_report(IntPtr nativeEvent);
    }
}
#endif
