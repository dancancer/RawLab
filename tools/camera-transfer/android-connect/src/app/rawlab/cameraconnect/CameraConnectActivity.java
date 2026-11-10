package app.rawlab.cameraconnect;

import com.rawlab.android.camera.protocol.SonyMobileSession;
import com.rawlab.android.camera.protocol.SonyWifiCredentials;
import com.rawlab.android.camera.protocol.SonyTetherSession;

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
    private TetherExperiment tether;
    private boolean tetherMode;
    private boolean releasePending;
    private String probeModel;
    private volatile SonyTetherSession inspection;
    private boolean useCurrentWifi;
    private String probeStage="device";
    private boolean manualWifi;
    private ImageView probeLive;
    private volatile HttpURLConnection probeStream;
    private boolean probeCardSavingConfirmed;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        tetherMode = getIntent().getBooleanExtra("tether", false);
        probeModel=getIntent().getStringExtra("probe-model");
        if(probeModel!=null && !probeModel.equals("ZV-E10") && !probeModel.equals("ILCE-7CM2")) throw new IllegalArgumentException("Unknown probe model");
        if(probeModel!=null) tetherMode=false;
        useCurrentWifi=probeModel!=null && getIntent().getBooleanExtra("use-current-wifi",false);
        manualWifi=probeModel!=null && getIntent().getBooleanExtra("manual-wifi",false);
        if(getIntent().hasExtra("probe-stage")) probeStage=getIntent().getStringExtra("probe-stage");
        if("legacy-capture".equals(probeStage) || "legacy-watch".equals(probeStage)) probeStage="device";
        getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(32, 48, 32, 24);
        TextView title = new TextView(this); title.setText("Sony 相机连接验证"); title.setTextSize(24); root.addView(title);
        TextView intro = new TextView(this);
        intro.setText(tetherMode ? "联机拍摄协议实验：实时取景、显式单拍、监视机身新照片。\n仅 α7C II / 固件 2.00；原件保留在卡上。" : "蓝牙配对 → 自动加入相机 Wi-Fi → 浏览照片 → 下载原文件。\n仅验证 α7C II / 固件 2.00。");
        if(probeModel!=null) intro.setText(probeModel+" 协议实验：检查设备能力、读取卡内原件与实时取景。拍摄需要单独操作。");
        root.addView(intro);
        state = new TextView(this); state.setTextSize(18); state.setPadding(0, 24, 0, 24); root.addView(state);
        devices = new LinearLayout(this); devices.setOrientation(LinearLayout.VERTICAL); root.addView(devices);
        Button scan = new Button(this); scan.setText("查找相机"); scan.setOnClickListener(v -> startScan()); root.addView(scan);
        Button list = new Button(this); list.setText("读取照片列表"); list.setOnClickListener(v -> runMobileOperation("list")); root.addView(list);
        Button download = new Button(this); download.setText("下载一张 RAW 原文件"); download.setOnClickListener(v -> runMobileOperation("download")); root.addView(download);
        if (tetherMode) { list.setVisibility(android.view.View.GONE);download.setVisibility(android.view.View.GONE);tether=new TetherExperiment(this,root,this::record); }
        if(probeModel!=null) { list.setVisibility(android.view.View.GONE);download.setVisibility(android.view.View.GONE);
            probeLive=new ImageView(this);probeLive.setAdjustViewBounds(true);root.addView(probeLive,new LinearLayout.LayoutParams(-1,420)); }
        Button stop = new Button(this); stop.setText("结束并释放连接"); stop.setOnClickListener(v -> { release(); state.setText(releasePending ? "正在释放快门，请检查相机。" : "连接已释放。"); record("experiment_stopped"); }); root.addView(stop);
        ScrollView scroll = new ScrollView(this); logView = new TextView(this); logView.setTextSize(12); logView.setTextIsSelectable(true); scroll.addView(logView);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        TextView note = new TextView(this); note.setText(tetherMode ? "点击单拍会实际拍摄。仅接收 ARW/JPEG；HEIF 未接入。实验副本在私有 tether-originals，不改设置、不删卡内照片。" : "原文件保存到手机 Download/RawLab Camera Imports；不会拍摄或删除相机照片。"); root.addView(note);
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
        if(releasePending) { state.setText("正在结束上一遥控会话，请稍后重试。");return; }
        if (busy) return;
        if(manualWifi) { showManualWifi();return; }
        if(useCurrentWifi) { inspectCurrentWifi();return; }
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

    private void showManualWifi() {
        LinearLayout fields=new LinearLayout(this);fields.setOrientation(LinearLayout.VERTICAL);fields.setPadding(48,24,48,0);
        EditText name=new EditText(this);name.setSingleLine(true);name.setHint("相机 Wi-Fi 名称");
        name.setText(getIntent().getStringExtra("wifi-ssid"));fields.addView(name);
        EditText password=new EditText(this);password.setSingleLine(true);password.setHint("相机屏幕显示的 Wi-Fi 密码");
        password.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD);
        password.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
        password.setImportantForAutofill(android.view.View.IMPORTANT_FOR_AUTOFILL_NO);fields.addView(password);
        TextView explanation=new TextView(this);explanation.setText("请保持相机连接画面。密码仅用于本次连接，不保存到文件或日志。");fields.addView(explanation);
        android.app.AlertDialog dialog=new android.app.AlertDialog.Builder(this).setTitle("连接 "+probeModel)
            .setView(fields).setNegativeButton("取消",(d,w)->password.setText(""))
            .setPositiveButton("连接",null).create();
        dialog.setOnShowListener(d -> dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String networkName=name.getText().toString().trim(),secret=password.getText().toString();
            if(!networkName.startsWith("DIRECT-") || !networkName.endsWith(":"+probeModel) || networkName.getBytes(StandardCharsets.UTF_8).length>32) {
                name.setError("请输入当前相机屏幕显示的完整 Wi-Fi 名称");return;
            }
            if(secret.length()<8 || secret.length()>63 || !secret.chars().allMatch(c -> c>=32 && c<=126)) { password.setError("请输入 8–63 位相机 Wi-Fi 密码");return; }
            release();busy=true;password.setText("");dialog.dismiss();waitForAccessPoint(networkName,secret);
        }));
        dialog.show();
    }

    private void inspectCurrentWifi() {
        String currentSSID=wifi.getConnectionInfo().getSSID();
        if(currentSSID!=null && currentSSID.startsWith("\"") && currentSSID.endsWith("\"")) currentSSID=currentSSID.substring(1,currentSSID.length()-1);
        if(currentSSID==null || !currentSSID.startsWith("DIRECT-") || !currentSSID.endsWith(":"+probeModel)) {
            state.setText("当前 Wi-Fi 已不是选定相机热点，请重新选择相机网络。");record("probe_camera_wifi_not_selected");return;
        }
        Network selectedNetwork=null;LinkProperties properties=null;
        for(Network candidate:connectivity.getAllNetworks()) {
            NetworkCapabilities capabilities=connectivity.getNetworkCapabilities(candidate);
            if(capabilities!=null && capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                if(selectedNetwork!=null) { state.setText("有多个 Wi-Fi 网络，请仅保留选定的相机连接。");return; }
                selectedNetwork=candidate;properties=connectivity.getLinkProperties(candidate);
            }
        }
        InetAddress gateway=null;
        if(properties!=null) for(RouteInfo route:properties.getRoutes())
            if(route.isDefaultRoute() && route.getGateway() instanceof Inet4Address) { gateway=route.getGateway();break; }
        if(selectedNetwork==null || gateway==null || !gateway.isSiteLocalAddress()) { state.setText("请先在系统 Wi-Fi 中连接相机热点，再点查找相机重试。");return; }
        cameraNetwork=selectedNetwork;cameraAddress=gateway;
        Network expected=selectedNetwork;int current=generation;
        if(networkCallback!=null) connectivity.unregisterNetworkCallback(networkCallback);
        networkCallback=new ConnectivityManager.NetworkCallback() {
            @Override public void onLost(Network network) { main.post(() -> { if(current==generation && network.equals(expected)) { release();state.setText("相机 Wi-Fi 已离开，请重新选择相机网络。");record("probe_selected_wifi_lost"); } }); }
        };
        connectivity.registerNetworkCallback(new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(),networkCallback);
        record("probe_user_selected_wifi_gateway "+gateway.getHostAddress());runInspection();
    }
    private final ScanCallback scanCallback = new ScanCallback() {
        @Override public void onScanResult(int callbackType, ScanResult result) {
            ScanRecord ad = result.getScanRecord();
            if (ad == null || ad.getManufacturerSpecificData(0x012d) == null) return;
            String name = ad.getDeviceName();
            String target=probeModel==null?"ILCE-7CM2":probeModel;
            if (name == null || !(name.equals(target) || name.startsWith(target+".") || name.startsWith(target+" "))) return;
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
        if(releasePending) return;
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
        if(command==null && "ZV-E10".equals(probeModel)) {
            state.setText("请保持相机二维码/SSID 画面，正在读取网络信息…");record("probe_wifi_started_on_camera_no_cc08");scheduleSSIDRead();return;
        }
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
            if(probeModel!=null) for(BluetoothGattService service:source.getServices()) {
                if(!service.getUuid().toString().startsWith("8000")) continue;
                List<String> characteristics=new ArrayList<>();for(BluetoothGattCharacteristic item:service.getCharacteristics()) characteristics.add(item.getUuid().toString());
                record("probe_ble_service "+service.getUuid()+" characteristics="+characteristics);
            }
            BluetoothGattCharacteristic command = characteristic(WIFI_ON);
            if (status != 0 || command == null && !"ZV-E10".equals(probeModel) || characteristic(SSID) == null || characteristic(PASSWORD) == null) { fail("相机没有提供所需的 Wi-Fi 服务。"); return; }
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
        if(probeModel!=null && status==0) {
            int end=value==null?0:value.length;while(end>0 && value[end-1]==0) end--;
            boolean plain=end>0;for(int i=0;i<end;i++) if(value[i]<32 || value[i]>126) plain=false;
            record("probe_wifi_layout field="+(key.equals(SSID)?"ssid":"password")+" bytes="+(value==null?0:value.length)+
                " length_prefix="+(value!=null && value.length>0 && (value[0]&255)==value.length-1)+" plain_ascii="+plain+" text_length="+end);
        }
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
        if(probeModel!=null) runInspection();
        else if (tether != null) { devices.removeAllViews();tether.connect(network,gateway);state.setText("相机 Wi-Fi 已连接，正在验证联机拍摄。"); }
        else runMobileOperation("probe");
    }
    private void runMobileOperation(String operation) {
        if(probeModel!=null) { runInspection();return; }
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

    private void runInspection() {
        if(cameraNetwork==null || cameraAddress==null || busy) return;
        busy=true;int current=generation;Network selectedNetwork=cameraNetwork;InetAddress address=cameraAddress;String stage=probeStage;
        boolean cardConfirmed=probeCardSavingConfirmed;probeCardSavingConfirmed=false;
        state.setText("正在只读检查 "+probeModel+" 的型号、固件和操作列表…");
        new Thread(() -> {
            SonyTetherSession opened=inspection;
            try {
                if(opened==null || !opened.isOpen()) opened=new SonyTetherSession(selectedNetwork.getSocketFactory(),address,UUID.randomUUID(),
                    message -> main.post(() -> { if(current==generation) record(message); }));
                inspection=opened;if(current!=generation) throw new IOException("Device probe cancelled");
                SonyMobileSession.Device device=opened.inspectDevice();
                if(!device.model.equals(probeModel)) throw new IOException("Unexpected probe model "+device.model);
                List<String> ops=new ArrayList<>();for(int op:new TreeSet<>(device.operations)) ops.add(String.format(Locale.ROOT,"0x%04x",op));
                String detail="尚未启用拍摄或照片传输。";
                if("storage".equals(stage)) {
                    List<Long> storages=opened.probeLegacyStorage();detail="标准 PTP 存储列表："+storages;
                    String log="probe_legacy_storages "+storages;main.post(() -> { if(current==generation) record(log); });
                } else if("contents".equals(stage)) {
                    if(!opened.isRemoteReady()) opened.connectRemote(SonyTetherSession.Profile.ZVE10_2_02);
                    List<Long> storages=opened.probeLegacyContentsStorage();detail="内容模式存储列表："+storages+"；已退出内容模式。";
                    String log="probe_contents_storages "+storages;main.post(() -> { if(current==generation) record(log); });
                } else if("legacy-list".equals(stage) || "legacy-download".equals(stage)) {
                    if(!opened.isRemoteReady()) opened.connectRemote(SonyTetherSession.Profile.ZVE10_2_02);
                    try {
                    opened.enterLegacyContents();
                    List<SonyTetherSession.LegacyObject> photos=opened.listLegacyPhotos();
                    List<String> samples=new ArrayList<>();for(int i=0;i<Math.min(10,photos.size());i++) {
                        SonyTetherSession.LegacyObject photo=photos.get(i);samples.add(photo.name+" bytes="+photo.size+" handle="+photo.handle);
                    }
                    String log="probe_legacy_photos count="+photos.size()+" samples="+samples;
                    main.post(() -> { if(current==generation) record(log); });
                    detail="已枚举卡内 RAW/JPEG 原件："+photos.size()+" 张。";
                    if("legacy-download".equals(stage)) {
                        File folder=new File(getFilesDir(),"legacy-originals");if(!folder.exists() && !folder.mkdirs()) throw new IOException("Cannot create experiment originals folder");
                        Set<String> formats=new HashSet<>();
                        for(SonyTetherSession.LegacyObject photo:photos) {
                            String format=photo.name.toLowerCase(Locale.ROOT).endsWith(".arw")?"arw":"jpeg";
                            if(!formats.add(format)) continue;
                            File partial=new File(folder,"current.part");String hash;
                            try(FileOutputStream output=new FileOutputStream(partial)) { hash=opened.downloadLegacyWhole(photo,output);output.getFD().sync(); }
                            if(current!=generation) { partial.delete();throw new IOException("Legacy download cancelled"); }
                            File saved=new File(folder,hash+"-"+photo.name);if(!partial.renameTo(saved)) throw new IOException("Cannot publish experiment original");
                            String receipt="probe_legacy_saved name="+photo.name+" bytes="+saved.length()+" sha256="+hash;
                            main.post(() -> { if(current==generation) record(receipt); });
                        }
                        detail+=" 已读取各一种可用格式，保存到独立实验目录。";
                    }
                    } finally { if(opened.isOpen()) opened.leaveLegacyContents(); }
                } else if("legacy-capture".equals(stage) || "legacy-watch".equals(stage)) {
                    if(!cardConfirmed) throw new IOException("Camera-card saving must be confirmed for this experiment action");
                    if(!opened.isRemoteReady()) opened.connectRemote(SonyTetherSession.Profile.ZVE10_2_02);
                    probeLegacyCapture(opened,selectedNetwork,address,current,"legacy-capture".equals(stage));
                    detail="拍后文件检查已结束，遥控会话已关闭；请查看回传与卡内原件记录。";
                } else if("live".equals(stage)) {
                    if(!opened.isRemoteReady()) opened.connectRemote(SonyTetherSession.Profile.ZVE10_2_02);
                    SonyTetherSession.Property live=opened.properties().get(0xd278);
                    if(live==null || live.text().isEmpty()) throw new IOException("Camera live-view URL unavailable");
                    probeLive(selectedNetwork,SonyTetherSession.liveViewURL(live.text(),address),current);
                    detail="已读取并显示实时取景帧；未拍摄。";
                } else if("remote".equals(stage)) {
                    if(!opened.isRemoteReady()) opened.connectRemote(SonyTetherSession.Profile.ZVE10_2_02);
                    Map<Integer,SonyTetherSession.Property> properties=opened.properties();List<String> values=new ArrayList<>();
                    for(int code:new int[]{0xd20c,0xd213,0xd215,0xd222,0xd268,0x5013,0x500a}) {
                        SonyTetherSession.Property property=properties.get(code);
                        if(property!=null) values.add(String.format(Locale.ROOT,"0x%04x=%d",code,property.number()));
                    }
                    detail="遥控握手成功；仅检查属性，未拍摄。";
                    String log="probe_remote_properties "+values+" live_url_available="+properties.containsKey(0xd278);
                    main.post(() -> { if(current==generation) record(log); });
                }
                String finalDetail=detail;
                main.post(() -> { if(current==generation) {
                    busy=false;record("probe_identity model="+device.model+" firmware="+device.firmware);record("probe_operations "+ops);
                    state.setText("已读取："+device.model+" / 固件 "+device.firmware+"。"+finalDetail+(inspection!=null && inspection.isOpen()?"\n正在保持相机会话。":""));
                } });
            } catch(Exception error) {
                if(!(error instanceof SonyTetherSession.RemoteResponseException) && opened!=null) { opened.close();if(inspection==opened) inspection=null; }
                main.post(() -> { if(current==generation) { busy=false;record("probe_failed "+error);state.setText("只读探测失败："+error.getMessage()); } });
            } finally { if(current!=generation && opened!=null) { opened.close();if(inspection==opened) inspection=null; } }
        },"camera-readonly-probe").start();
    }

    private void probeLegacyCapture(SonyTetherSession session,Network network,InetAddress address,int current,boolean remoteShutter) throws Exception {
        Set<Integer> baseline;
        try { session.enterLegacyContents();baseline=session.legacyHandles(); }
        finally { if(session.isOpen()) session.leaveLegacyContents(); }
        session.close();
        session=new SonyTetherSession(network.getSocketFactory(),address,UUID.randomUUID(),message -> main.post(() -> { if(current==generation) record(message); }));
        inspection=session;
        try {
        if(current!=generation) throw new IOException("Capture probe cancelled");
        session.connectRemote(SonyTetherSession.Profile.ZVE10_2_02);
        Thread.sleep(3500);
        if(current!=generation) throw new IOException("Capture probe cancelled");
        if(session.pendingLegacyCapture()!=null) throw new IOException("Camera already has an undelivered host image; capture probe not armed");
        if(remoteShutter) session.captureWithConfirmedCardSaving(true);
        else main.post(() -> { if(current==generation) { state.setText("已准备监视，请在相机上单拍一张。");record("probe_body_watch_armed"); } });
        SonyTetherSession.LegacyObject pending=null;
        for(int wait=0;wait<(remoteShutter?120:800) && current==generation;wait++) { pending=session.pendingLegacyCapture();if(pending!=null) break;Thread.sleep(500); }
        if(current!=generation) throw new IOException("Capture probe cancelled");
        File folder=new File(getFilesDir(),"legacy-originals");if(!folder.exists() && !folder.mkdirs()) throw new IOException("Cannot create experiment folder");
        Map<String,String> hostHashes=new HashMap<>();
        for(int count=0;pending!=null && count<4;count++) {
            String hash=saveLegacyProbe(session,pending,folder,current,true);hostHashes.put(pending.name,hash);
            String log="probe_host_saved name="+pending.name+" bytes="+pending.size+" sha256="+hash;
            main.post(() -> { if(current==generation) record(log); });
            pending=session.pendingLegacyCapture();
        }
        try {
            session.enterLegacyContents();List<SonyTetherSession.LegacyObject> added=session.listLegacyPhotos(baseline);
            String found="probe_capture_card_delta="+added.size()+" shutter="+(remoteShutter?"remote":"body");
            main.post(() -> { if(current==generation) record(found); });
            for(SonyTetherSession.LegacyObject original:added) {
                String hash=saveLegacyProbe(session,original,folder,current,false);
                String log="probe_capture_card_saved name="+original.name+" bytes="+original.size+" sha256="+hash+" host_equal="+hash.equals(hostHashes.get(original.name));
                main.post(() -> { if(current==generation) record(log); });
            }
            if(added.isEmpty()) throw new IOException("No new camera-card original observed");
        } finally { if(session.isOpen()) session.leaveLegacyContents(); }
        } finally { session.requestStop();if(inspection==session) inspection=null; }
    }

    private String saveLegacyProbe(SonyTetherSession session,SonyTetherSession.LegacyObject photo,File folder,int current,boolean host) throws IOException {
        File partial=new File(folder,"capture.part");
        try {
            String hash;
            try(FileOutputStream output=new FileOutputStream(partial)) {
                hash=host?session.downloadLegacyPending(photo,output):session.downloadLegacyWhole(photo,output);output.getFD().sync();
            }
            if(current!=generation) throw new IOException("Capture probe cancelled");
            if(!partial.renameTo(new File(folder,(host?"host-":"card-")+hash+"-"+photo.name))) throw new IOException("Cannot publish experiment original");
            return hash;
        } finally { partial.delete(); }
    }

    private void probeLive(Network network,URL url,int current) throws IOException {
        HttpURLConnection stream=(HttpURLConnection)network.openConnection(url);probeStream=stream;
        stream.setInstanceFollowRedirects(false);stream.setConnectTimeout(5000);stream.setReadTimeout(5000);
        Set<Integer> distinct=new HashSet<>();
        String step="HTTP status";
        try {
            int status=stream.getResponseCode();main.post(() -> { if(current==generation) record("probe_live_http_status="+status); });
            if(status!=200) throw new IOException("Non-success HTTP status");
            step="frame header";
            try(PushbackInputStream input=new PushbackInputStream(stream.getInputStream(),32)) {
                byte[] header=new byte[32];new DataInputStream(input).readFully(header);input.unread(header);
                StringBuilder hex=new StringBuilder();for(byte value:header) hex.append(String.format(Locale.ROOT,"%02x",value&255));
                String metadata="probe_live_header="+hex;main.post(() -> { if(current==generation) record(metadata); });
                for(int frame=0;frame<60 && current==generation;frame++) {
                    byte[] jpeg=SonyTetherSession.readFrame(input);distinct.add(Arrays.hashCode(jpeg));
                    if(frame%6!=0 && frame!=59) continue;
                    android.graphics.BitmapFactory.Options bounds=new android.graphics.BitmapFactory.Options();bounds.inJustDecodeBounds=true;
                    android.graphics.BitmapFactory.decodeByteArray(jpeg,0,jpeg.length,bounds);
                    if(bounds.outWidth<=0 || bounds.outHeight<=0 || (long)bounds.outWidth*bounds.outHeight>16000000) throw new IOException("Invalid live dimensions");
                    android.graphics.Bitmap bitmap=android.graphics.BitmapFactory.decodeByteArray(jpeg,0,jpeg.length);
                    if(bitmap==null) throw new IOException("Invalid live JPEG");
                    if(frame==0 || frame==59) try(FileOutputStream output=new FileOutputStream(new File(getFilesDir(),"probe-live-"+frame+".jpg"))) { output.write(jpeg); }
                    String message="probe_live_frame number="+frame+" width="+bitmap.getWidth()+" height="+bitmap.getHeight();
                    main.post(() -> { if(current==generation) { probeLive.setImageBitmap(bitmap);record(message); } else bitmap.recycle(); });
                }
            }
            int count=distinct.size();main.post(() -> { if(current==generation) record("probe_live_distinct_frames="+count); });
        } catch(IOException error) { throw new IOException("Live-view stream failed at "+step+": "+error.getClass().getSimpleName()); }
        finally { stream.disconnect();if(probeStream==stream) probeStream=null; }
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
        if(intent.hasExtra("probe-stage")) probeStage=intent.getStringExtra("probe-stage");
        probeCardSavingConfirmed=intent.getBooleanExtra("card-saving-confirmed",false);
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
        boolean shutterRelease = tether != null && tether.stop();
        SonyTetherSession activeInspection=inspection;inspection=null;
        if(activeInspection!=null) { activeInspection.requestStop();shutterRelease|=activeInspection.isOpen(); }
        generation++; busy = false; ssid = null; pendingSSID = null; pendingPassword = null; cameraNetwork = null; cameraAddress = null; awaitingConnection = false;
        if (adapter != null && adapter.isEnabled()) try { adapter.getBluetoothLeScanner().stopScan(scanCallback); } catch (SecurityException ignored) {}
        BluetoothGatt oldGatt=gatt;gatt=null;
        ConnectivityManager.NetworkCallback oldNetwork=networkCallback;networkCallback=null;
        Runnable releaseNetwork=() -> {
            if(oldGatt!=null) { oldGatt.disconnect();oldGatt.close(); }
            if(oldNetwork!=null) connectivity.unregisterNetworkCallback(oldNetwork);
        };
        // 给正在释放的快门保留原网络；旧回调已由代次失效，禁止它们继续业务操作。
        if(shutterRelease) { releasePending=true;main.postDelayed(() -> { releaseNetwork.run();releasePending=false; },2100); }
        else releaseNetwork.run();
        SonyMobileSession activePTP = ptp; if (activePTP != null) activePTP.close();
        HttpURLConnection activeStream=probeStream;if(activeStream!=null) activeStream.disconnect();
        Socket active = socket; if (active != null) try { active.close(); } catch (IOException ignored) {}
    }
    @Override protected void onStop() { if(tether!=null || probeModel!=null) { release();record("remote_background_stopped"); } super.onStop(); }
    @Override public void onDestroy() { release();if(tether!=null) tether.destroy(); unregisterReceiver(bondReceiver); unregisterReceiver(wifiScanReceiver); try { if (logFile != null) logFile.close(); } catch (IOException ignored) {} super.onDestroy(); }
}
