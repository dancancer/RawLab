package app.rawlab.cameraconnect;

import com.rawlab.android.camera.protocol.SonyMobileSession;
import com.rawlab.android.camera.protocol.SonyWifiCredentials;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.location.LocationManager;
import android.net.*;
import android.net.wifi.WifiNetworkSpecifier;
import android.net.wifi.WifiManager;
import android.os.*;
import android.provider.MediaStore;
import android.util.Log;
import android.widget.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.*;

public final class CameraConnectActivity extends Activity {
    private static final UUID CONTROL = UUID.fromString("8000cc00-cc00-ffff-ffff-ffffffffffff");
    private static final UUID PAIRING = UUID.fromString("8000ee00-ee00-ffff-ffff-ffffffffffff");
    private static UUID id(String suffix) { return UUID.fromString("0000" + suffix + "-0000-1000-8000-00805f9b34fb"); }
    private static final UUID SSID = id("cc06"), PASSWORD = id("cc07"), WIFI_ON = id("cc08");
    private final Handler main = new Handler(Looper.getMainLooper());
    private BluetoothAdapter adapter;
    private BluetoothGatt gatt;
    private BluetoothDevice selected;
    private ConnectivityManager connectivity;
    private ConnectivityManager.NetworkCallback networkCallback;
    private TextView state, logView;
    private LinearLayout devices;
    private final Set<String> found = new HashSet<>();
    private boolean busy;
    private boolean wifiStarted;
    private boolean reconnectKnown;
    private String reconnectName;
    private volatile int generation;
    private int readAttempts;
    private String ssid;
    private OutputStream logFile;
    private volatile Socket socket;
    private volatile SonyMobileSession ptp;
    private Network cameraNetwork;
    private InetAddress cameraAddress;
    private boolean awaitingConnection;
    private String requestedFile;
    private String pendingSSID, pendingPassword;
    private long scanStartedMicros;
    private WifiManager wifi;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(32, 48, 32, 24);
        TextView title = new TextView(this); title.setText("Sony 相机连接验证"); title.setTextSize(24); root.addView(title);
        TextView intro = new TextView(this);
        intro.setText("蓝牙配对 → 自动加入相机 Wi-Fi → 浏览照片 → 下载原文件。\n仅验证 α7C II / 固件 2.00。");
        root.addView(intro);
        state = new TextView(this); state.setTextSize(18); state.setPadding(0, 24, 0, 24); root.addView(state);
        devices = new LinearLayout(this); devices.setOrientation(LinearLayout.VERTICAL); root.addView(devices);
        Button scan = new Button(this); scan.setText("查找相机"); scan.setOnClickListener(v -> startScan()); root.addView(scan);
        Button list = new Button(this); list.setText("读取照片列表"); list.setOnClickListener(v -> runMobileOperation("list")); root.addView(list);
        Button download = new Button(this); download.setText("下载一张 RAW 原文件"); download.setOnClickListener(v -> runMobileOperation("download")); root.addView(download);
        Button stop = new Button(this); stop.setText("结束并释放连接"); stop.setOnClickListener(v -> { release(); state.setText("连接已释放。"); record("experiment_stopped"); }); root.addView(stop);
        ScrollView scroll = new ScrollView(this); logView = new TextView(this); logView.setTextSize(12); logView.setTextIsSelectable(true); scroll.addView(logView);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        TextView note = new TextView(this); note.setText("原文件保存到手机 Download/RawLab Camera Imports；不会拍摄或删除相机照片。"); root.addView(note);
        setContentView(root);
        try { logFile = openFileOutput("connection-events.txt", MODE_PRIVATE); } catch (IOException e) { throw new RuntimeException(e); }
        adapter = getSystemService(BluetoothManager.class).getAdapter();
        connectivity = getSystemService(ConnectivityManager.class);
        wifi = getApplicationContext().getSystemService(WifiManager.class);
        IntentFilter filter = new IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(bondReceiver, filter, Context.RECEIVER_EXPORTED);
        else registerReceiver(bondReceiver, filter);
        IntentFilter wifiFilter = new IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(wifiScanReceiver, wifiFilter, Context.RECEIVER_EXPORTED);
        else registerReceiver(wifiScanReceiver, wifiFilter);
        record("experiment_started android=" + Build.VERSION.SDK_INT);
        reconnectName = getIntent().getStringExtra("reconnect-name");
        requestedFile = getIntent().getStringExtra("file-name");
        reconnectKnown = reconnectName != null;
        askPermissions();
    }

    private void askPermissions() {
        ArrayList<String> wanted = new ArrayList<>();
        wanted.add(Manifest.permission.ACCESS_FINE_LOCATION);
        if (Build.VERSION.SDK_INT >= 31) { wanted.add(Manifest.permission.BLUETOOTH_SCAN); wanted.add(Manifest.permission.BLUETOOTH_CONNECT); }
        if (Build.VERSION.SDK_INT >= 33) wanted.add(Manifest.permission.NEARBY_WIFI_DEVICES);
        wanted.removeIf(p -> checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED);
        if (wanted.isEmpty()) startScan(); else requestPermissions(wanted.toArray(new String[0]), 10);
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(request, permissions, grants);
        for (int grant : grants) if (grant != PackageManager.PERMISSION_GRANTED) { fail("需要位置/附近设备权限才能查找相机。"); return; }
        startScan();
    }
    private void startScan() {
        if (busy) return;
        if (gatt != null || networkCallback != null) release();
        if (adapter == null || !adapter.isEnabled()) { state.setText("请打开手机蓝牙。"); return; }
        if (!getSystemService(LocationManager.class).isLocationEnabled()) { state.setText("Android 10 要求打开系统位置服务才能扫描蓝牙和请求 Wi-Fi。"); return; }
        try {
            adapter.getBluetoothLeScanner().stopScan(scanCallback);
            found.clear(); devices.removeAllViews();
            state.setText("正在查找相机，请让相机处于“智能手机连接”的等待画面。");
            adapter.getBluetoothLeScanner().startScan(scanCallback);
            int current = generation;
            main.postDelayed(() -> { if (generation == current && !busy) { adapter.getBluetoothLeScanner().stopScan(scanCallback); if (found.isEmpty()) state.setText("没有找到相机，请检查相机是否在等待连接，再点查找。"); } }, 25000);
        } catch (SecurityException e) { state.setText("请允许蓝牙与位置权限。"); }
    }
    private final ScanCallback scanCallback = new ScanCallback() {
        @Override public void onScanResult(int callbackType, ScanResult result) {
            ScanRecord ad = result.getScanRecord();
            if (ad == null || ad.getManufacturerSpecificData(0x012d) == null) return;
            String name = ad.getDeviceName();
            if (name == null || !name.contains("ILCE-7CM2")) return;
            main.post(() -> {
                if (busy) return;
                if (!found.add(result.getDevice().getAddress())) return;
                record("sony_camera_discovered rssi=" + result.getRssi());
                Button button = new Button(CameraConnectActivity.this); button.setText("连接 " + name);
                button.setOnClickListener(v -> connectCamera(result.getDevice())); devices.addView(button);
                state.setText("请选择你的相机。");
                if (reconnectKnown && reconnectName.equalsIgnoreCase(name)
                    && result.getDevice().getBondState() == BluetoothDevice.BOND_BONDED) {
                    reconnectKnown = false; record("reconnecting_bonded_camera"); connectCamera(result.getDevice());
                }
            });
        }
        @Override public void onScanFailed(int code) { main.post(() -> fail("蓝牙扫描失败：" + code)); }
    };
    private void connectCamera(BluetoothDevice device) {
        if (busy) return;
        if (gatt != null || networkCallback != null) release();
        generation++; busy = true; awaitingConnection = true; wifiStarted = false; readAttempts = 0; selected = device;
        adapter.getBluetoothLeScanner().stopScan(scanCallback);
        state.setText("首次连接请核对手机与相机的配对数字，并在两边确认。");
        record("ble_connect_requested");
        int current = generation;
        main.postDelayed(() -> { if (current == generation && busy && awaitingConnection) fail("蓝牙连接超时，请检查相机和手机提示。"); }, 180000);
        if (device.getBondState() == BluetoothDevice.BOND_BONDED) openGatt();
        else if (!device.createBond()) fail("系统未能发起蓝牙配对。");
    }
    private final BroadcastReceiver bondReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
            if (!busy || selected == null || !selected.equals(device)) return;
            int state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE);
            if (state == BluetoothDevice.BOND_BONDED) { record("ble_bond_confirmed"); openGatt(); }
            else if (state == BluetoothDevice.BOND_NONE) fail("蓝牙配对未完成。");
        }
    };
    private void openGatt() {
        if (gatt != null) return;
        gatt = selected.connectGatt(this, false, gattCallback, BluetoothDevice.TRANSPORT_LE);
    }
    private BluetoothGattCharacteristic characteristic(UUID uuid) {
        BluetoothGattService service = gatt == null ? null : gatt.getService(CONTROL);
        return service == null ? null : service.getCharacteristic(uuid);
    }
    private void activateWiFi() {
        BluetoothGattCharacteristic command = characteristic(WIFI_ON);
        command.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT); command.setValue(new byte[]{1});
        state.setText("正在请求相机开启 Wi-Fi…"); record("wifi_activation_requested CC08=01");
        if (!gatt.writeCharacteristic(command)) fail("无法发送 Wi-Fi 请求。");
    }
    private final BluetoothGattCallback gattCallback = new BluetoothGattCallback() {
        @Override public void onConnectionStateChange(BluetoothGatt source, int status, int newState) { main.post(() -> {
            if (source != gatt || !busy) return;
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                record("ble_connected");
                // SSID 特征超过默认 MTU 的单包长度；Sony Android 参考实现使用 158。
                if (!source.requestMtu(158)) fail("无法发起蓝牙包长协商。");
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) fail("蓝牙连接中断：" + status);
        }); }
        @Override public void onMtuChanged(BluetoothGatt source, int mtu, int status) { main.post(() -> {
            if (source != gatt || !busy) return;
            record("ble_mtu=" + mtu + " status=" + status);
            if (status != 0 || mtu < 67) { fail("蓝牙包长不足，不能完整读取相机连接参数。"); return; }
            source.discoverServices();
        }); }
        @Override public void onServicesDiscovered(BluetoothGatt source, int status) { main.post(() -> {
            if (source != gatt || !busy) return;
            BluetoothGattCharacteristic command = characteristic(WIFI_ON);
            if (status != 0 || command == null || characteristic(SSID) == null || characteristic(PASSWORD) == null) { fail("相机没有提供所需的 Wi-Fi 服务。"); return; }
            BluetoothGattService pairing = source.getService(PAIRING);
            BluetoothGattCharacteristic init = pairing == null ? null : pairing.getCharacteristic(id("ee01"));
            if (init == null) { fail("相机没有提供 Sony 配对初始化服务。"); return; }
            // Sony 应用级配对，与 Android 的系统 bond 是两个阶段。
            init.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
            init.setValue(new byte[]{6, 8, 1, 0, 0, 0, 0});
            record("sony_pairing_initialization_requested");
            if (!source.writeCharacteristic(init)) fail("无法发送 Sony 配对初始化。");
        }); }
        @Override public void onCharacteristicWrite(BluetoothGatt source, BluetoothGattCharacteristic item, int status) { main.post(() -> {
            if (source != gatt || !busy) return;
            if (item.getUuid().equals(id("ee01"))) {
                if (status != 0) { fail("Sony 配对初始化失败：" + status); return; }
                record("sony_pairing_initialization_acknowledged");
                activateWiFi(); return;
            }
            if (!item.getUuid().equals(WIFI_ON)) return;
            if (status != 0) { fail("相机拒绝 Wi-Fi 请求：" + status); return; }
            record("wifi_activation_acknowledged"); scheduleSSIDRead();
        }); }
        @Override public void onCharacteristicRead(BluetoothGatt source, BluetoothGattCharacteristic item, int status) {
            byte[] value = item.getValue() == null ? null : item.getValue().clone(); UUID key = item.getUuid();
            main.post(() -> handleRead(source, key, value, status));
        }
    };
    private void scheduleSSIDRead() {
        int current = generation;
        main.postDelayed(() -> { if (current == generation && busy && gatt != null) { readAttempts++; if (!gatt.readCharacteristic(characteristic(SSID))) fail("无法读取 Wi-Fi 名称。"); } }, 3000);
    }
    private void handleRead(BluetoothGatt source, UUID key, byte[] value, int status) {
        if (source != gatt || !busy) return;
        if (status != 0) {
            if (key.equals(SSID) && status == 157 && readAttempts < 8) { record("wifi_parameters_pending ATT=157 attempt=" + readAttempts); scheduleSSIDRead(); }
            else fail("读取 Wi-Fi 参数失败：ATT " + status);
            return;
        }
        try {
            if (key.equals(SSID)) { ssid = SonyWifiCredentials.decode(value, false); if (!gatt.readCharacteristic(characteristic(PASSWORD))) fail("无法读取 Wi-Fi 参数。"); }
            else if (key.equals(PASSWORD)) { String password = SonyWifiCredentials.decode(value, true); record("wifi_parameters_received"); waitForAccessPoint(ssid, password); ssid = null; }
        } catch (IllegalArgumentException e) { fail(e.getMessage()); }
    }
    private void waitForAccessPoint(String name, String password) {
        pendingSSID = name; pendingPassword = password; scanStartedMicros = SystemClock.elapsedRealtime() * 1000;
        state.setText("正在确认相机热点是否已开始广播…");
        boolean requested = wifi.startScan();
        record("fresh_camera_wifi_scan requested=" + requested);
        findFreshAccessPoint();
        int current = generation;
        main.postDelayed(() -> { if (generation == current && pendingSSID != null) fail("未发现正在广播的相机热点；请保持相机唤醒后重新连接。"); }, 35000);
    }
    private final BroadcastReceiver wifiScanReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) { findFreshAccessPoint(); }
    };
    private void findFreshAccessPoint() {
        if (pendingSSID == null || !busy) return;
        for (android.net.wifi.ScanResult result : wifi.getScanResults()) {
            if (result.SSID.equals(pendingSSID) && result.timestamp >= scanStartedMicros - 2000000) {
                record("fresh_camera_ap_found frequency=" + result.frequency + " rssi=" + result.level);
                String name = pendingSSID, password = pendingPassword;
                pendingSSID = null; pendingPassword = null;
                requestWiFi(name, password, result.BSSID); return;
            }
        }
    }
    private void requestWiFi(String name, String password, String bssid) {
        awaitingConnection = false;
        state.setText("请在系统窗口中允许连接相机 Wi-Fi。");
        WifiNetworkSpecifier specifier = new WifiNetworkSpecifier.Builder().setSsid(name).setBssid(MacAddress.fromString(bssid)).setWpa2Passphrase(password).build();
        NetworkRequest request = new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).setNetworkSpecifier(specifier).build();
        int current = generation;
        networkCallback = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network network) { main.post(() -> {
                if (generation != current || !busy) return;
                record("android_camera_wifi_available"); state.setText("相机 Wi-Fi 已自动连接，正在检查传输服务…");
            }); }
            @Override public void onLinkPropertiesChanged(Network network, LinkProperties properties) { main.post(() -> {
                if (generation == current && busy) inspectNetwork(network, properties, current);
            }); }
            @Override public void onUnavailable() { main.post(() -> { if (generation == current) fail("系统未建立相机 Wi-Fi 连接。"); }); }
            @Override public void onLost(Network network) { main.post(() -> { if (generation == current) { release(); record("camera_wifi_lost"); state.setText("相机 Wi-Fi 已断开，可重新连接。"); } }); }
        };
        // 用户确认属于交互等待，不把系统弹窗等待计入网络超时。
        connectivity.requestNetwork(request, networkCallback);
        record("android_wifi_join_requested");
    }
    private void inspectNetwork(Network network, LinkProperties properties, int current) {
        InetAddress gateway = null;
        if (properties != null) for (RouteInfo route : properties.getRoutes())
            if (route.isDefaultRoute() && route.getGateway() instanceof Inet4Address) { gateway = route.getGateway(); break; }
        // onAvailable 先于 DHCP/路由更新；等待 LinkProperties，不能立即判为失败。
        if (gateway == null) { state.setText("已自动加入相机 Wi-Fi，正在等待网络地址…"); return; }
        if (wifiStarted) return;
        wifiStarted = true;
        cameraNetwork = network; cameraAddress = gateway; busy = false;
        record("camera_network_gateway " + gateway.getHostAddress());
        runMobileOperation("probe");
    }
    private void runMobileOperation(String operation) {
        if (cameraNetwork == null || cameraAddress == null || busy) return;
        busy = true;
        int current = generation;
        Network network = cameraNetwork; InetAddress cameraIP = cameraAddress;
        String requestedName = requestedFile;
        state.setText(operation.equals("download") ? "正在读取列表并下载 RAW 原文件…" : "正在读取相机信息和照片…");
        new Thread(() -> {
            try {
                String stored = getPreferences(MODE_PRIVATE).getString("ptpip-guid", null);
                UUID guid = stored == null ? UUID.randomUUID() : UUID.fromString(stored);
                getPreferences(MODE_PRIVATE).edit().putString("ptpip-guid", guid.toString()).apply();
                try (SonyMobileSession client = new SonyMobileSession(network.getSocketFactory(), cameraIP, guid,
                    message -> main.post(() -> { if (generation == current) record(message); }))) {
                    ptp = client;
                    if (generation != current) throw new IOException("传输已取消。");
                    SonyMobileSession.Device info = client.deviceInfo();
                    String identity = info.manufacturer + " " + info.model + " " + info.firmware;
                    main.post(() -> { if (generation == current) { record("mobile_camera_verified " + identity); record("mobile_operations " + info.operations); } });
                    String result = "手机 PTP/IP 已连接，型号与固件匹配：" + identity;
                    if (!operation.equals("probe")) {
                        client.openSession();
                        List<SonyMobileSession.Asset> photos = client.listPhotos(info);
                        main.post(() -> { if (generation == current) {
                            record("mobile_photo_count=" + photos.size());
                            for (int i = 0; i < Math.min(photos.size(), 20); i++) { SonyMobileSession.Asset photo = photos.get(i); record("photo " + photo.name + " bytes=" + photo.size); }
                        } });
                        result = "已读取 " + photos.size() + " 个 RAW/JPEG 文件。";
                        if (operation.equals("download")) {
                            SonyMobileSession.Asset selected = null;
                            for (SonyMobileSession.Asset photo : photos) {
                                if (requestedName != null ? photo.name.equals(requestedName) : photo.name.toLowerCase(Locale.ROOT).endsWith(".arw")) {
                                    if (selected != null && requestedName != null) throw new IOException("相机中有多个同名文件，请重新选择。");
                                    if (selected == null) selected = photo;
                                }
                            }
                            if (selected == null) throw new IOException("未找到待验证的 RAW 文件。");
                            result = saveOriginal(client, info, selected, current);
                        }
                    }
                    String finalResult = result;
                    main.post(() -> { if (generation == current) { busy = false; state.setText(finalResult); } });
                }
            } catch (Exception e) {
                main.post(() -> { if (generation == current) { busy = false; record("mobile_ptpip_failed " + e.toString()); state.setText("Wi-Fi 已连接，PTP/IP 验证失败：" + e.getMessage()); } });
            } finally { ptp = null; }
        }, "camera-mobile-ptpip").start();
    }

    private String saveOriginal(SonyMobileSession client, SonyMobileSession.Device info, SonyMobileSession.Asset photo, int current) throws IOException {
        ContentValues values = new ContentValues();
        String folder = Environment.DIRECTORY_DOWNLOADS + "/RawLab Camera Imports/" + UUID.randomUUID();
        values.put(MediaStore.Downloads.DISPLAY_NAME, photo.name);
        values.put(MediaStore.Downloads.MIME_TYPE, photo.name.toLowerCase(Locale.ROOT).endsWith(".arw") ? "image/x-sony-arw" : "image/jpeg");
        values.put(MediaStore.Downloads.RELATIVE_PATH, folder);
        values.put(MediaStore.Downloads.IS_PENDING, 1);
        Uri uri = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
        if (uri == null) throw new IOException("无法建立手机原文件存储。");
        boolean published = false;
        try {
            String hash;
            try (OutputStream output = getContentResolver().openOutputStream(uri, "w")) {
                if (output == null) throw new IOException("无法打开手机原文件存储。");
                hash = client.download(info, photo, output);
            }
            if (generation != current) throw new IOException("传输已取消。");
            ContentValues done = new ContentValues(); done.put(MediaStore.Downloads.IS_PENDING, 0);
            if (getContentResolver().update(uri, done, null, null) != 1) throw new IOException("无法完成原文件发布。");
            published = true;
            main.post(() -> { if (generation == current) { record("photo_saved " + photo.name + " bytes=" + photo.size + " sha256=" + hash); record("photo_uri " + uri); record("photo_path " + folder + "/" + photo.name); } });
            return "已保存原文件：" + photo.name + "\n" + photo.size + " 字节\nSHA-256：" + hash + "\n位置：" + folder;
        } finally { if (!published) getContentResolver().delete(uri, null, null); }
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent.hasExtra("file-name")) requestedFile = intent.getStringExtra("file-name");
        String operation = intent.getStringExtra("operation");
        if ("probe".equals(operation) || "list".equals(operation) || "download".equals(operation)) runMobileOperation(operation);
    }

    private void record(String message) {
        String line = new SimpleDateFormat("HH:mm:ss", Locale.ROOT).format(new Date()) + " " + message;
        logView.append(line + "\n"); Log.i("RawLabCamera", line);
        try { if (logFile != null) { logFile.write((line + "\n").getBytes(StandardCharsets.UTF_8)); logFile.flush(); } } catch (IOException ignored) {}
    }
    private void fail(String message) { release(); state.setText(message); record("failed " + message); }
    private void release() {
        generation++; busy = false; ssid = null; pendingSSID = null; pendingPassword = null; cameraNetwork = null; cameraAddress = null; awaitingConnection = false;
        if (adapter != null && adapter.isEnabled()) try { adapter.getBluetoothLeScanner().stopScan(scanCallback); } catch (SecurityException ignored) {}
        if (gatt != null) { BluetoothGatt old = gatt; gatt = null; old.disconnect(); old.close(); }
        if (networkCallback != null) { connectivity.unregisterNetworkCallback(networkCallback); networkCallback = null; }
        SonyMobileSession activePTP = ptp; if (activePTP != null) activePTP.close();
        Socket active = socket; if (active != null) try { active.close(); } catch (IOException ignored) {}
    }
    @Override public void onDestroy() { release(); unregisterReceiver(bondReceiver); unregisterReceiver(wifiScanReceiver); try { if (logFile != null) logFile.close(); } catch (IOException ignored) {} super.onDestroy(); }
}
