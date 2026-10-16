#if RAWLAB_RUM_LOCAL
using System.IO;
using System.Runtime.InteropServices;

namespace RawLab.Windows;

public sealed class RumLocalUsageAnalyticsTransport : IUsageAnalyticsTransport
{
    private const string LibraryName = "alibabacloud_rum.dll";
    // Values from alibabacloud_rum.h; the local build does not compile the C header.
    private const int RumEnvLocal = 5;
    private const int RumLevelFatal = 1;
    private static readonly object NativeGate = new();
    private static RumLocalUsageAnalyticsTransport? active;

    private readonly RumLocalConfiguration configuration;
    private readonly string utdid = Guid.NewGuid().ToString();
    private bool started;
    private volatile bool lifecycleFailed;
    private Exception? lifecycleFailure;
    private IntPtr options;
    private string? cachePath;

    public RumLocalUsageAnalyticsTransport(RumLocalConfiguration configuration)
    {
        this.configuration = configuration;
    }

    public bool IsAvailable => !lifecycleFailed;

    public static bool TryCreate(out RumLocalUsageAnalyticsTransport? transport)
    {
        if (RumLocalConfiguration.TryLoad(out var configuration) && configuration != null)
        {
            transport = new RumLocalUsageAnalyticsTransport(configuration);
            return true;
        }

        transport = null;
        return false;
    }

    public Task StartAsync(CancellationToken cancellationToken) => Task.Run(StartCore);

    public Task SendAsync(UsageEvent usageEvent, CancellationToken cancellationToken) =>
        Task.Run(() => SendCore(usageEvent));

    public Task StopAsync(CancellationToken cancellationToken) => Task.Run(StopCore);

    private void StartCore()
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
                Native.alibabacloud_rum_options_set_app_name(options, "RawLab Local Validation");
                Native.alibabacloud_rum_options_set_app_version(options, "0.0.0-local");
                Native.alibabacloud_rum_options_set_env(options, RumEnvLocal);
                Native.alibabacloud_rum_options_set_utdid(options, utdid);
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
