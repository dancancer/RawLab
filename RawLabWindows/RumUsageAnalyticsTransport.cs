#if RAWLAB_RUM_SDK || RAWLAB_RUM_TRANSPORT_TEST
using System.IO;
using System.Runtime.InteropServices;

namespace RawLab.Windows;

internal interface IRumNative
{
    IntPtr OptionsNew();
    void OptionsFree(IntPtr options);
    void SetConfigAddress(IntPtr options, string configAddress);
    void SetAppId(IntPtr options, string appId);
    void SetAppName(IntPtr options, string appName);
    void SetAppVersion(IntPtr options, string appVersion);
    void SetEnv(IntPtr options, int env);
    void SetUtdid(IntPtr options, string utdid);
    void SetDebugLevel(IntPtr options, int level);
    void SetCachePath(IntPtr options, string path);
    void SetAutoCrashTracking(IntPtr options, int enabled);
    void SetAutoCurlTracking(IntPtr options, int enabled);
    void SetAutoCefTracking(IntPtr options, int enabled);
    int Init(IntPtr options);
    int Close();
    IntPtr CustomEventNew(string type, string name);
    void CustomEventSetValue(IntPtr nativeEvent, double value);
    void CustomEventSetGroup(IntPtr nativeEvent, string group);
    void CustomEventAddExtra(IntPtr nativeEvent, string key, string value);
    void CustomEventFree(IntPtr nativeEvent);
    void CustomEventReport(IntPtr nativeEvent);
}

// ┌──────────────────────────────────────────────────────────────────────┐
// │ 阿里云 RUM PC SDK 0.4.4 适配：只开自定义事件，关闭崩溃/网络/CEF 自动采集。 │
// │ 设备标识由 UsageAnalytics 传入（本机随机安装标识），不读取任何硬件编号。   │
// │ 缓存复用固定目录，启动清扫仅移除过期的发送失败残留，保留未过期待发缓存。   │
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
    private readonly IRumNative native;
    private string? configuredCacheDirectory;
    private bool started;
    private volatile bool lifecycleFailed;
    private Exception? lifecycleFailure;
    private IntPtr options;
    private string? cachePath;

    public RumUsageAnalyticsTransport(RumConfiguration configuration)
        : this(configuration, null, null)
    {
    }

    internal RumUsageAnalyticsTransport(RumConfiguration configuration, string? cacheDirectory, IRumNative? native = null)
    {
        this.configuration = configuration;
        configuredCacheDirectory = cacheDirectory;
        this.native = native ?? PInvokeRumNative.Instance;
    }

    public bool IsAvailable => !lifecycleFailed;

    public string CacheDirectory
    {
        get
        {
            lock (NativeGate)
                return Path.GetFullPath(configuredCacheDirectory ?? UsageAnalytics.DefaultCacheDirectory);
        }
    }

    internal void BindDefaultCacheDirectory(string directory)
    {
        lock (NativeGate)
        {
            if (!started && configuredCacheDirectory == null)
                configuredCacheDirectory = directory;
        }
    }

    internal static bool IsCacheInUse(string directory)
    {
        if (string.IsNullOrWhiteSpace(directory)) return false;
        string full;
        try { full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(directory)); }
        catch (ArgumentException) { return false; }
        lock (NativeGate)
        {
            return active?.cachePath is { } activePath &&
                StringComparer.OrdinalIgnoreCase.Equals(
                    Path.TrimEndingDirectorySeparator(Path.GetFullPath(activePath)),
                    full);
        }
    }

    // ─── 正式构建用写死的正式配置，本地验证构建用环境变量配置；SDK 不在程序旁边就当作不可用 ───
    public static IUsageAnalyticsTransport CreateDefault() => CreateDefault(null);

    internal static IUsageAnalyticsTransport CreateDefault(string? cacheDirectory)
    {
        var environment = RumConfiguration.ProcessEnvironment();
        var version = typeof(RumUsageAnalyticsTransport).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
#if RAWLAB_RUM_LOCAL
        var configured = RumConfiguration.TryLocal(environment, version, out var configuration);
#else
        var configured = RumConfiguration.TryProduction(environment, version, out var configuration);
#endif
        return configured && configuration != null && File.Exists(Path.Combine(AppContext.BaseDirectory, LibraryName))
            ? new RumUsageAnalyticsTransport(configuration, cacheDirectory)
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

            var cache = Path.GetFullPath(configuredCacheDirectory ?? UsageAnalytics.DefaultCacheDirectory);
            if (Directory.Exists(cache) && TempCleanup.IsReparsePoint(new DirectoryInfo(cache)))
                throw new IOException("The Windows RUM SDK cache directory cannot be a reparse point.");
            TempCleanup.SweepExpiredAnalyticsCache(cache, DateTime.UtcNow, TempCleanup.DefaultRetention);
            Directory.CreateDirectory(cache);
            var nativeOptions = native.OptionsNew();
            if (nativeOptions == IntPtr.Zero)
                throw new InvalidOperationException("The Windows RUM SDK could not allocate options.");

            options = nativeOptions;
            cachePath = cache;
            active = this;
            TempCleanup.WriteOwnerMarker(cache);
            try
            {
                native.SetConfigAddress(options, configuration.ConfigAddress);
                native.SetAppId(options, configuration.AppId);
                native.SetAppName(options, AppName);
                native.SetAppVersion(options, configuration.AppVersion);
                native.SetEnv(options, (int)configuration.Env);
                native.SetUtdid(options, installId);
                native.SetDebugLevel(options, RumLevelFatal);
                native.SetCachePath(options, cache);
                native.SetAutoCrashTracking(options, 0);
                native.SetAutoCurlTracking(options, 0);
                native.SetAutoCefTracking(options, 0);
                if (native.Init(options) != 0)
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
            if (native.Close() != 0)
                throw new InvalidOperationException("The Windows RUM SDK could not confirm failed-start cleanup.");

            native.OptionsFree(options);
            options = IntPtr.Zero;
            active = null;
            var cache = cachePath;
            cachePath = null;
            if (cache != null) TempCleanup.RemoveOwnerMarker(cache);
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
            var nativeEvent = native.CustomEventNew("usage", usageEvent.Name);
            if (nativeEvent == IntPtr.Zero) return;

            try
            {
                native.CustomEventSetGroup(nativeEvent, usageEvent.Group);
                native.CustomEventSetValue(nativeEvent, usageEvent.Value);
                foreach (var property in usageEvent.Properties)
                    native.CustomEventAddExtra(nativeEvent, property.Key, property.Value);
                if (configuration.ValidationRun != null)
                    native.CustomEventAddExtra(
                        nativeEvent, "validation_run", configuration.ValidationRun);
                native.CustomEventReport(nativeEvent);
                nativeEvent = IntPtr.Zero;
            }
            finally
            {
                if (nativeEvent != IntPtr.Zero)
                    native.CustomEventFree(nativeEvent);
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
            try { result = native.Close(); }
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
            native.OptionsFree(nativeOptions);
            if (cache != null) TempCleanup.RemoveOwnerMarker(cache);
        }
    }

    private Exception MarkLifecycleFailure(Exception error)
    {
        lifecycleFailure = error;
        lifecycleFailed = true;
        return error;
    }

    private sealed class PInvokeRumNative : IRumNative
    {
        internal static readonly PInvokeRumNative Instance = new();
        public IntPtr OptionsNew() => Native.alibabacloud_rum_options_new();
        public void OptionsFree(IntPtr options) => Native.alibabacloud_rum_options_free(options);
        public void SetConfigAddress(IntPtr options, string configAddress) =>
            Native.alibabacloud_rum_options_set_config_address(options, configAddress);
        public void SetAppId(IntPtr options, string appId) => Native.alibabacloud_rum_options_set_app_id(options, appId);
        public void SetAppName(IntPtr options, string appName) => Native.alibabacloud_rum_options_set_app_name(options, appName);
        public void SetAppVersion(IntPtr options, string appVersion) =>
            Native.alibabacloud_rum_options_set_app_version(options, appVersion);
        public void SetEnv(IntPtr options, int env) => Native.alibabacloud_rum_options_set_env(options, env);
        public void SetUtdid(IntPtr options, string utdid) => Native.alibabacloud_rum_options_set_utdid(options, utdid);
        public void SetDebugLevel(IntPtr options, int level) => Native.alibabacloud_rum_options_set_debug_level(options, level);
        public void SetCachePath(IntPtr options, string path) => Native.alibabacloud_rum_options_set_cache_path(options, path);
        public void SetAutoCrashTracking(IntPtr options, int enabled) =>
            Native.alibabacloud_rum_options_set_auto_crash_tracking(options, enabled);
        public void SetAutoCurlTracking(IntPtr options, int enabled) =>
            Native.alibabacloud_rum_options_set_auto_curl_tracking(options, enabled);
        public void SetAutoCefTracking(IntPtr options, int enabled) =>
            Native.alibabacloud_rum_options_set_auto_cef_tracking(options, enabled);
        public int Init(IntPtr options) => Native.alibabacloud_rum_init(options);
        public int Close() => Native.alibabacloud_rum_close();
        public IntPtr CustomEventNew(string type, string name) => Native.alibabacloud_rum_custom_event_new(type, name);
        public void CustomEventSetValue(IntPtr nativeEvent, double value) =>
            Native.alibabacloud_rum_custom_event_set_value(nativeEvent, value);
        public void CustomEventSetGroup(IntPtr nativeEvent, string group) =>
            Native.alibabacloud_rum_custom_event_set_group(nativeEvent, group);
        public void CustomEventAddExtra(IntPtr nativeEvent, string key, string value) =>
            Native.alibabacloud_rum_custom_event_add_extra(nativeEvent, key, value);
        public void CustomEventFree(IntPtr nativeEvent) => Native.alibabacloud_rum_custom_event_free(nativeEvent);
        public void CustomEventReport(IntPtr nativeEvent) => Native.alibabacloud_rum_custom_event_report(nativeEvent);
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
