package com.rawlab.android.camera.protocol;

import java.io.*;
import java.net.*;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;
import javax.net.SocketFactory;
import com.rawlab.android.camera.SonyCameraNative;
import com.rawlab.android.camera.protocol.SonyMobileSession.Reader;
import static com.rawlab.android.camera.protocol.SonyMobileSession.*;

/** 独立遥控 profile；选片导入必须使用 Purpose.IMPORT，禁止任何快门写入。 */
public final class SonyTetherSession implements Closeable {
    public enum Profile { A7CII_2_00, ZVE10_2_02, GENERIC }
    public enum Purpose { IMPORT, TETHER }
    private static final int LIMIT = 8 << 20;
    private static final int SLOT_DATES_LIMIT = 256 << 10;
    private final Socket command, event;
    private final Reporter reporter;
    private final Purpose purpose;
    private final Set<Integer> controls = new HashSet<>();
    private final Set<String> knownAssets = new HashSet<>();
    private final Set<String> knownLegacyObjects = new HashSet<>();
    private Set<Integer> operations = Collections.emptySet();
    private int transaction;
    private volatile boolean closed;
    private volatile boolean stopRequested, captureInFlight;
    private boolean remoteReady;
    private boolean captureReady;
    private boolean sessionOpened;
    private long remoteReadyNanos;
    private int propertyEnumTables=2;

    public static final class RemoteResponseException extends CameraMediaSession.PhotoTransferException {
        public final int operation, code;
        public RemoteResponseException(int operation,int code) { super(String.format(Locale.ROOT,"PTP op 0x%04x response 0x%04x",operation,code));this.operation=operation;this.code=code; }
        @Override public CameraMediaSession.FailureKind getKind() { return CameraMediaSession.responseFailureKind(operation, code); }
    }

    public SonyTetherSession(SocketFactory factory, InetAddress address, UUID guid, Reporter reporter) throws IOException {
        this(factory,address,guid,reporter,Purpose.TETHER);
    }

    public SonyTetherSession(SocketFactory factory, InetAddress address, UUID guid, Reporter reporter,Purpose purpose) throws IOException {
        this.reporter = reporter;
        this.purpose = purpose;
        command = factory.createSocket(); event = factory.createSocket();
        try {
            command.connect(new InetSocketAddress(address,15740),10000); command.setSoTimeout(10000); command.setTcpNoDelay(true);
            byte[] initCmd = SonyCameraNative.initCmdPacket(guid, "RawLab", 0x10000);
            OutputStream cmdOut = command.getOutputStream();
            cmdOut.write(initCmd); cmdOut.flush();
            Packet ack = readPacket(command,4096);
            if (ack.type != 2) throw new IOException("Remote PTP command init rejected");
            int connection = SonyCameraNative.nativeParseInitCmdAck(ack.bytes);
            event.connect(new InetSocketAddress(address,15740),10000); event.setSoTimeout(10000);
            byte[] initEvt = SonyCameraNative.nativeInitEvtPacket(connection);
            OutputStream evtOut = event.getOutputStream();
            evtOut.write(initEvt); evtOut.flush();
            Packet ready = readPacket(event,4096);
            if (ready.type != 4 || ready.bytes.length != 0) throw new IOException("Remote PTP event init rejected");
            event.setSoTimeout(0); event.setTcpNoDelay(true);
            new Thread(this::readEvents,"camera-tether-events").start();
        } catch (IOException failure) { close(); throw failure; }
    }

    private void readEvents() {
        final byte[] probeResp = SonyCameraNative.nativeProbeRespPacket();
        try {
            OutputStream evtOut = event.getOutputStream();
            while (!closed) {
                Packet packet = readPacket(event,4096);
                if (packet.type == 13 && packet.bytes.length == 0) {
                    evtOut.write(probeResp); evtOut.flush(); continue;
                }
                if (packet.type != 8) throw new IOException("Invalid remote event");
                int[] ev = SonyCameraNative.nativeParseEvent(packet.bytes);
                int code = ev[0];
                long tid = Integer.toUnsignedLong(ev[1]);
                int paramCount = ev[2];
                List<Long> params = new ArrayList<>(paramCount);
                for (int i = 0; i < paramCount; i++) params.add(Integer.toUnsignedLong(ev[3 + i]));
                reporter.report(String.format(Locale.ROOT,"remote_event code=0x%04x tid=%d parameters=%s",code,tid,params));
            }
        } catch (IOException failure) { if (!closed) { reporter.report("remote_event_failed " + failure.getClass().getSimpleName()); close(); } }
    }

    public synchronized Device inspectDevice() throws IOException {
        SonyCameraNative.DecodedDeviceInfo info = SonyCameraNative.parseDeviceInfo(
            call(0x1001,new int[0],null,1 << 20,true));
        if (info.getStatus() != SonyCameraNative.STATUS_OK) throw new IOException("Not a Sony PTP device");
        operations = info.getOperations();
        return new Device(info.getManufacturer(), info.getModel(), info.getFirmware(), info.getSerial(), operations);
    }

    public Device connectRemote() throws IOException { return connectRemote(Profile.GENERIC); }

    public synchronized Device connectRemote(Profile profile) throws IOException {
        if (remoteReady) throw new IOException("Remote session already initialized");
        Device device=inspectDevice();
        reporter.report("remote_identity " + device.model + " firmware=" + device.firmware);
        int[] required={0x1002,0x9201,0x9202,0x9209};
        for (int op : required)
            if (!operations.contains(op)) throw new CameraMediaSession.UnsupportedCameraException(String.format("Remote operation not advertised: 0x%04x",op));
        ensureSession();
        call(0x9201,new int[]{1,0,0},null,65536,false);
        call(0x9201,new int[]{2,0,0},null,65536,false);
        for (int retry=0;retry<20;retry++) {
            byte[] bytes = call(0x9202,new int[]{0x12c,1},null,65536,true);
            if (bytes.length > 0) {
                SonyCameraNative.DecodedRemoteDescriptor desc = SonyCameraNative.parseRemoteDescriptor(bytes);
                if (desc.getStatus() != SonyCameraNative.STATUS_OK)
                    throw new IOException("Unsupported Sony remote protocol descriptor version="+desc.getVersion());
                controls.addAll(desc.getControls());
                propertyEnumTables=desc.getEnumTables();
                reporter.report("remote_extended protocol=" + desc.getVersion() + " properties=" + desc.getProperties().size() + " controls=" + controls);
                if (!desc.getProperties().isEmpty() || !controls.isEmpty()) break;
            }
            pause(100);
        }
        call(0x9201,new int[]{3,0,0},null,65536,false);
        remoteReady = true;
        remoteReadyNanos = System.nanoTime();
        captureReady = true;
        reporter.report("remote_handshake_complete");
        return device;
    }

    public synchronized List<Long> probeLegacyStorage() throws IOException {
        Device device=inspectDevice();
        if(!device.operations.contains(0x1002) || !device.operations.contains(0x1004))
            throw new IOException("Camera storage operations are unavailable");
        ensureSession();
        return readStorageIds();
    }

    public boolean supportsOperation(int operation) { return operations.contains(operation); }

    private boolean hasLegacyContents() {
        return remoteReady && operations.contains(0x9212);
    }

    public synchronized List<Long> probeLegacyContentsStorage() throws IOException {
        if(!hasLegacyContents() || !operations.contains(0x9212)) throw new IOException("Contents probe requires a Sony legacy contents capability");
        IOException failure=null;List<Long> result=null;
        try {
            result=enterLegacyContents();
        } catch(IOException error) { failure=error; }
        finally {
            if(!closed) try { call(0x9212,new int[]{2,0,1},null,0,false); }
            catch(IOException error) { close();if(failure==null) failure=error;else failure.addSuppressed(error); }
        }
        if(failure!=null) throw failure;
        return result;
    }

    public synchronized List<Long> enterLegacyContents() throws IOException {
        if(!hasLegacyContents() || !operations.contains(0x9212)) throw new IOException("Contents mode requires a Sony legacy contents capability");
        // 过早发送 9212 会被确认但不挂载存储；ZV-E10 需先完成遥控初始化。
        pause(Math.max(0,3500-(System.nanoTime()-remoteReadyNanos)/1_000_000));
        // ZV-E10 实测：退出内容模式后旧会话仍确认快门命令却不曝光，必须重建纯遥控会话。
        captureReady=false;
        call(0x9212,new int[]{2,1,0},null,0,false);
        for(int attempt=0;attempt<20;attempt++) { List<Long> storages=readStorageIds();if(!storages.isEmpty()) return storages;pause(250); }
        throw new IOException("Camera card did not become available in contents mode");
    }

    public synchronized void leaveLegacyContents() throws IOException {
        if(!hasLegacyContents()) throw new IOException("Contents mode requires a Sony legacy contents capability");
        call(0x9212,new int[]{2,0,1},null,0,false);
    }

    private List<Long> readStorageIds() throws IOException {
        byte[] bytes=call(0x1004,new int[0],null,4096,true);
        try {
            Reader r=new Reader(bytes);long count=r.u32();
            if(count>32 || r.remaining()!=count*4) throw new IOException("Invalid storage list");
            List<Long> storages=new ArrayList<>();for(int i=0;i<count;i++) storages.add(r.u32());return storages;
        } catch(IOException malformed) { close();throw malformed; }
    }
    public boolean isRemoteReady() { return remoteReady && !closed; }

    public static final class LegacyObject {
        private final SonyTetherSession owner;
        public final int handle,storage,format; public final long size; public final String name,created,modified;
        LegacyObject(int handle,int storage,int format,long size,String name,String created,String modified) {
            this(null,handle,storage,format,size,name,created,modified);
        }
        private LegacyObject(SonyTetherSession owner,int handle,int storage,int format,long size,String name,String created,String modified) {
            this.owner=owner;this.handle=handle;this.storage=storage;this.format=format;this.size=size;this.name=name;this.created=created;this.modified=modified;
        }
        public String key() { return storage+":"+handle+":"+format+":"+size+":"+name+":"+created+":"+modified; }
        public boolean isPhoto() { return size>0 && size<=(1L<<30) && SonyCameraNative.nativeIsPhotoFilename(name); }
    }

    static LegacyObject parseLegacyObject(int handle,byte[] bytes) throws IOException {
        SonyCameraNative.DecodedLegacyObject obj = SonyCameraNative.parseLegacyObject(bytes);
        return new LegacyObject(handle,obj.getStorage(),obj.getFormat(),obj.getSize(),obj.getName(),obj.getCreated(),obj.getModified());
    }

    private LegacyObject legacyObject(int handle) throws IOException {
        byte[] bytes=call(0x1008,new int[]{handle},null,4096,true);
        try { LegacyObject parsed=parseLegacyObject(handle,bytes);
            return new LegacyObject(this,parsed.handle,parsed.storage,parsed.format,parsed.size,parsed.name,parsed.created,parsed.modified);
        } catch(IOException invalid) { close();throw invalid; }
    }

    public synchronized List<LegacyObject> listLegacyPhotos() throws IOException {
        return listLegacyPhotos(Collections.emptySet());
    }

    public synchronized Set<Integer> legacyHandles() throws IOException {
        if(!hasLegacyContents()) throw new IOException("Legacy contents require a Sony legacy contents capability");
        for(int op:new int[]{0x1004,0x1007,0x1008}) if(!operations.contains(op)) throw new IOException("Legacy contents operation not advertised");
        Set<Integer> handles=new LinkedHashSet<>();
        for(long storage:readStorageIds()) {
            byte[] bytes=call(0x1007,new int[]{(int)storage,0,0},null,LIMIT,true);
            try {
                Reader r=new Reader(bytes);long count=r.u32();
                if(r.remaining()!=count*4) throw new IOException("Invalid legacy object handles");
                for(int i=0;i<count;i++) { int handle=r.i32();if(!handles.add(handle)) throw new IOException("Duplicate legacy object handles"); }
            } catch(IOException invalid) { close();throw invalid; }
        }
        if(handles.size()>CameraMediaSession.MAX_LISTED_PHOTOS)
            throw new CameraMediaSession.PhotoLimitExceededException("Legacy object handles exceed limit");
        return handles;
    }

    public static final class LegacyListing {
        public final Set<Integer> handles;
        public final List<LegacyObject> photos;
        LegacyListing(Set<Integer> handles,List<LegacyObject> photos) {
            this.handles=Collections.unmodifiableSet(new LinkedHashSet<>(handles));
            this.photos=Collections.unmodifiableList(new ArrayList<>(photos));
        }
    }

    public synchronized LegacyListing listLegacyPhotosIncremental(Set<Integer> baseline) throws IOException {
        Set<Integer> handles=legacyHandles();
        List<LegacyObject> result=new ArrayList<>();
        for(int handle:handles) {
            if(baseline.contains(handle)) continue;
            LegacyObject object=legacyObject(handle);
            if(object.isPhoto()) { result.add(object);knownLegacyObjects.add(object.key()); }
        }
        return new LegacyListing(handles,result);
    }

    public synchronized List<LegacyObject> listLegacyPhotos(Set<Integer> baseline) throws IOException {
        return listLegacyPhotosIncremental(baseline).photos;
    }

    public synchronized byte[] previewLegacy(LegacyObject object) throws IOException {
        if(object==null || object.owner!=this || !knownLegacyObjects.contains(object.key()) || !operations.contains(0x100a)) throw new IOException("Legacy thumbnail unavailable");
        return call(0x100a,new int[]{object.handle},null,2<<20,true);
    }

    public synchronized String downloadLegacy(LegacyObject object,OutputStream destination) throws IOException {
        if(object==null || object.owner!=this || !object.isPhoto() || !knownLegacyObjects.contains(object.key()) || !operations.contains(0x101b)) throw new IOException("Unknown or unsupported legacy original");
        if(!object.key().equals(legacyObject(object.handle).key())) throw new CameraMediaSession.PhotoTransferException(CameraMediaSession.FailureKind.SOURCE_CHANGED, "Legacy original changed before transfer");
        MessageDigest digest;try { digest=MessageDigest.getInstance("SHA-256"); } catch(NoSuchAlgorithmException error) { throw new IOException(error); }
        for(long offset=0;offset<object.size;) {
            int count=(int)Math.min(3<<20,object.size-offset);
            byte[] bytes=call(0x101b,new int[]{object.handle,(int)offset,count},null,count,true);
            if(bytes.length!=count) throw new CameraMediaSession.PhotoTransferException("Legacy original chunk truncated");
            if(offset==0) {
                if(!SonyCameraNative.nativeValidatePhotoHeader(object.name, bytes)) throw new CameraMediaSession.PhotoTransferException("Legacy original header mismatch");
            }
            destination.write(bytes);digest.update(bytes);offset+=bytes.length;
        }
        destination.flush();
        if(!object.key().equals(legacyObject(object.handle).key())) throw new CameraMediaSession.PhotoTransferException(CameraMediaSession.FailureKind.SOURCE_CHANGED, "Legacy original changed during transfer");
        StringBuilder hash=new StringBuilder();for(byte b:digest.digest()) hash.append(String.format(Locale.ROOT,"%02x",b&255));return hash.toString();
    }

    public synchronized String downloadLegacyWhole(LegacyObject object,OutputStream destination) throws IOException {
        if(closed || object==null || object.owner!=this || !object.isPhoto() || !knownLegacyObjects.contains(object.key()) || !operations.contains(0x1009)) throw new IOException("Unknown or unsupported legacy original");
        if(!object.key().equals(legacyObject(object.handle).key())) throw new CameraMediaSession.PhotoTransferException(CameraMediaSession.FailureKind.SOURCE_CHANGED, "Legacy original changed before transfer");
        String hash=downloadLegacyBytes(object,destination);
        if(!object.key().equals(legacyObject(object.handle).key())) throw new CameraMediaSession.PhotoTransferException(CameraMediaSession.FailureKind.SOURCE_CHANGED, "Legacy original changed during transfer");
        return hash;
    }

    public synchronized LegacyObject pendingLegacyCapture() throws IOException {
        if(!hasLegacyContents()) throw new IOException("Legacy capture requires a Sony legacy capture capability");
        Property ready=properties().get(0xd215);
        if(ready==null || (ready.number()&0x8000)==0) return null;
        return legacyObject(0xffffc001);
    }

    public synchronized String downloadLegacyPending(LegacyObject object,OutputStream destination) throws IOException {
        if(object==null || object.owner!=this) throw new IOException("Pending image outside this session");
        LegacyObject ready=pendingLegacyCapture();
        if(ready==null || !ready.key().equals(object.key()) || !ready.isPhoto()) throw new IOException("Pending host image changed");
        return downloadLegacyBytes(ready,destination);
    }

    private String downloadLegacyBytes(LegacyObject object,OutputStream destination) throws IOException {
        MessageDigest digest;try { digest=MessageDigest.getInstance("SHA-256"); } catch(NoSuchAlgorithmException error) { throw new IOException(error); }
        byte[] prefix=new byte[4];int[] prefixSize={0};
        OutputStream verified=new FilterOutputStream(destination) {
            @Override public void write(byte[] bytes,int offset,int count) throws IOException {
                int head=Math.min(prefix.length-prefixSize[0],count);System.arraycopy(bytes,offset,prefix,prefixSize[0],head);prefixSize[0]+=head;
                out.write(bytes,offset,count);digest.update(bytes,offset,count);
            }
        };
        streamObject(object.handle,object.size,verified);
        if(prefixSize[0]<4 || !SonyCameraNative.nativeValidatePhotoHeader(object.name, prefix)) throw new CameraMediaSession.PhotoTransferException("Legacy original header mismatch");
        destination.flush();StringBuilder hash=new StringBuilder();for(byte b:digest.digest()) hash.append(String.format(Locale.ROOT,"%02x",b&255));return hash.toString();
    }

    /** 标准 GetObject 可能把整个 RAW 放在单个 PTP/IP 数据包中；按块写出，避免随包长分配。 */
    private void streamObject(int handle,long size,OutputStream destination) throws IOException {
        int tid=++transaction;long received=0;boolean started=false,ended=false;
        try {
            byte[] request = SonyCameraNative.nativeOpReqPacket(1, 0x1009, tid, new int[]{handle});
            OutputStream cmdOut = command.getOutputStream();
            cmdOut.write(request); cmdOut.flush();
            DataInputStream input=new DataInputStream(command.getInputStream());byte[] header=new byte[8],buffer=new byte[65536];
            byte[] probeResp = null;
            for(int packets=0;packets<100000;packets++) {
                input.readFully(header);
                long[] hdr = SonyCameraNative.nativeParseHeader(header, size + 12);
                int type = (int)hdr[0];
                int body = (int)hdr[1];
                if(type==9) {
                    if(started || body!=12) throw new IOException("Invalid streamed data start");
                    byte[] bytes=new byte[12];input.readFully(bytes);
                    long[] start = SonyCameraNative.nativeParseStartData(bytes);
                    if((int)start[0]!=tid || start[1]!=size) throw new IOException("Streamed object size/transaction mismatch");
                    started=true;
                } else if(type==10 || type==12) {
                    if(!started || ended || body<4 || body-4>size-received) throw new IOException("Invalid streamed object data");
                    byte[] id=new byte[4];input.readFully(id);if(new Reader(id).i32()!=tid) throw new IOException("Streamed data transaction mismatch");
                    for(int remaining=body-4;remaining>0;) { int count=Math.min(buffer.length,remaining);input.readFully(buffer,0,count);destination.write(buffer,0,count);received+=count;remaining-=count; }
                    if(type==12) { if(received!=size) throw new IOException("Streamed object truncated");ended=true; }
                } else if(type==7) {
                    byte[] bytes=new byte[body];input.readFully(bytes);
                    int[] resp = SonyCameraNative.nativeParseResponse(bytes);
                    int code=resp[0];
                    if(resp[1]!=tid || started && !ended) throw new IOException("Streamed response transaction mismatch");
                    if(code!=0x2001) throw new RemoteResponseException(0x1009,code);
                    if(!ended) throw new IOException("Streamed object missing");
                    reporter.report("remote_operation op=0x1009 bytes="+received);return;
                } else if(type==13 && body==0) {
                    if (probeResp == null) probeResp = SonyCameraNative.nativeProbeRespPacket();
                    cmdOut.write(probeResp); cmdOut.flush();
                }
                else throw new IOException("Unexpected streamed object packet");
            }
            throw new IOException("Streamed object packet budget exceeded");
        } catch(RemoteResponseException rejected) { throw rejected; }
        catch(IOException fatal) { close();throw fatal; }
    }

    private void ensureSession() throws IOException {
        if(!sessionOpened) { call(0x1002,new int[]{1},null,0,false);sessionOpened=true; }
    }

    public synchronized Map<Integer,Property> properties() throws IOException {
        if (!remoteReady) throw new IOException("Remote handshake incomplete");
        boolean legacy=propertyEnumTables==1;
        byte[] bytes=call(0x9209,legacy?new int[0]:new int[]{0},null,LIMIT,true);
        try { return parseProperties(bytes,propertyEnumTables); } catch(IOException invalid) { close();throw invalid; }
    }

    public boolean supportsShutter() {
        return purpose==Purpose.TETHER && remoteReady && captureReady && !closed &&
            operations.contains(0x9207) && controls.contains(0xd2c1) && controls.contains(0xd2c2);
    }

    public boolean supportsParameterWrites() {
        return purpose==Purpose.TETHER && remoteReady && captureReady && !closed && propertyEnumTables==2 && operations.contains(0x9205);
    }

    public static final class ParameterResult {
        public final boolean confirmed;
        public final Map<Integer,Property> properties;
        ParameterResult(boolean confirmed,Map<Integer,Property> properties) {
            this.confirmed=confirmed;this.properties=Collections.unmodifiableMap(new LinkedHashMap<>(properties));
        }
    }

    public static final class ParameterUnavailableException extends IOException {
        ParameterUnavailableException() { super("Camera parameter is not currently adjustable"); }
    }

    /** 只接受当前描述符里的静态拍摄值；只写一次，读回不同不代表成功。 */
    public synchronized ParameterResult setNumericProperty(int code,long requested) throws IOException {
        int type=parameterType(code);
        if(!supportsParameterWrites() || type==0 || stopRequested || code==0xd20d && requested==0)
            throw new ParameterUnavailableException();
        Map<Integer,Property> latest=properties();Property descriptor=latest.get(code);
        if(descriptor==null || descriptor.type!=type || !descriptor.canSet(requested)) throw new ParameterUnavailableException();
        if(descriptor.number()==requested) return new ParameterResult(true,latest);
        byte[] encoded=type==6?u32((int)requested):u16((int)requested);
        call(0x9205,new int[]{code},encoded,0,false);
        for(int attempt=0;attempt<12;attempt++) {
            pause(100);latest=properties();Property value=latest.get(code);
            if(value!=null && value.type==type && value.number()==requested) return new ParameterResult(true,latest);
        }
        return new ParameterResult(false,latest);
    }

    private static int parameterType(int code) {
        switch(code) {
            case 0x5005:case 0x5007:case 0x500a:case 0xd20f:case 0xd22c:return 4;
            case 0x5010:return 3;
            case 0xd20d:case 0xd21e:case 0xd226:return 6;
            default:return 0;
        }
    }

    public enum FocusUnavailableReason { MANUAL_FOCUS, FOCUS_AREA_FIXED, UNSUPPORTED }
    public enum FocusTarget {
        REMOTE_TOUCH(0xd2e4),
        AF_AREA_POSITION(0xd2dc);
        public final int controlCode;
        FocusTarget(int controlCode) { this.controlCode = controlCode; }
    }
    public static final class FocusUnavailableException extends IOException {
        public final FocusUnavailableReason reason;
        public FocusUnavailableException(FocusUnavailableReason reason) {
            super("Remote focus unavailable: " + reason);
            this.reason = reason;
        }
    }
    public static final class FocusRejectedException extends IOException {
        public final int operation, code;
        public FocusRejectedException(int operation, int code) {
            super(String.format(Locale.ROOT, "Camera rejected focus control op=0x%04x code=0x%04x", operation, code));
            this.operation = operation;
            this.code = code;
        }
    }
    public enum LiveViewFrameKind { FOCUS, FACE, TRACKING }
    public static final class LiveViewFocusFrame {
        public final LiveViewFrameKind kind;
        public final float cx, cy, width, height;
        public final boolean focused;
        public LiveViewFocusFrame(LiveViewFrameKind kind, float cx, float cy, float width, float height, boolean focused) {
            this.kind = kind; this.cx = cx; this.cy = cy; this.width = width; this.height = height; this.focused = focused;
        }
    }
    public static final class LiveViewFrame {
        public final byte[] jpeg;
        public final byte[] metadata;
        public LiveViewFrame(byte[] jpeg, byte[] metadata) {
            this.jpeg = jpeg;
            this.metadata = metadata;
        }
    }

    public static final class FocusPointResult {
        public final Map<Integer,Property> properties;
        public final boolean focusLocked;
        public FocusPointResult(Map<Integer,Property> properties, boolean focusLocked) {
            this.properties = properties;
            this.focusLocked = focusLocked;
        }
    }

    private static byte[] encodeNumericProperties(Map<Integer,Property> latest) {
        if (latest == null || latest.isEmpty()) return new byte[0];
        List<long[]> entries = new ArrayList<>();
        for (Property p : latest.values()) {
            if (p.value instanceof Long) {
                entries.add(new long[]{p.code, p.writable ? 1L : 0L, p.enabled, (Long)p.value});
            }
        }
        if (entries.isEmpty()) return new byte[0];
        return SonyCameraNative.encodeNumericPropertyTable(entries);
    }

    private static int[] toIntArray(Set<Integer> values) {
        int[] out = new int[values.size()];
        int i = 0;
        for (Integer v : values) out[i++] = v;
        return out;
    }

    public static boolean isFocusLocked(Map<Integer,Property> latest) {
        byte[] encoded = encodeNumericProperties(latest);
        if (encoded.length == 0) return false;
        return SonyCameraNative.nativeFocusIndication(encoded)[0] != 0;
    }

    public static boolean isFocusFailed(Map<Integer,Property> latest) {
        byte[] encoded = encodeNumericProperties(latest);
        if (encoded.length == 0) return false;
        return SonyCameraNative.nativeFocusIndication(encoded)[1] != 0;
    }

    public boolean canCancelTouchFocus(Map<Integer,Property> latest) {
        if (purpose!=Purpose.TETHER || !remoteReady || !captureReady || closed || latest==null) return false;
        return SonyCameraNative.nativeCanCancelTouchFocus(
            encodeNumericProperties(latest), toIntArray(controls), toIntArray(operations), remoteReady);
    }

    public FocusTarget resolveFocusTarget(Map<Integer,Property> latest) throws FocusUnavailableException {
        if (purpose!=Purpose.TETHER || !remoteReady || !captureReady || closed || latest==null) {
            throw new FocusUnavailableException(FocusUnavailableReason.UNSUPPORTED);
        }
        int[] resolved = SonyCameraNative.nativeResolveFocusTarget(
            encodeNumericProperties(latest), toIntArray(controls), toIntArray(operations), remoteReady);
        if (resolved[0] == 1) return FocusTarget.REMOTE_TOUCH;
        if (resolved[0] == 2) return FocusTarget.AF_AREA_POSITION;
        switch (resolved[1]) {
            case 1: throw new FocusUnavailableException(FocusUnavailableReason.MANUAL_FOCUS);
            case 2: throw new FocusUnavailableException(FocusUnavailableReason.FOCUS_AREA_FIXED);
            default: throw new FocusUnavailableException(FocusUnavailableReason.UNSUPPORTED);
        }
    }

    public synchronized FocusPointResult setFocusPoint(int x, int y) throws IOException {
        if (purpose!=Purpose.TETHER || !remoteReady || !captureReady || closed || !operations.contains(0x9207)) {
            throw new FocusUnavailableException(FocusUnavailableReason.UNSUPPORTED);
        }
        if (x<0 || x>639 || y<0 || y>479) throw new IllegalArgumentException("Focus point outside camera grid");
        Map<Integer,Property> latest = properties();
        boolean remoteTouchReady = false;
        if (controls.contains(0xd2e4)) {
            Property touchUsable = latest.get(0xd284);
            if (touchUsable!=null && touchUsable.enabled==1) {
                try { remoteTouchReady = touchUsable.number()==1L; } catch (IOException ignored) {}
            }
            if (!remoteTouchReady && canCancelTouchFocus(latest)) {
                sendTouchCancel();
                pause(50);
                latest = properties();
            }
        }
        FocusTarget target = resolveFocusTarget(latest);
        try {
            call(0x9207, new int[]{target.controlCode}, u32((x << 16) | y), 0, false);
        } catch (RemoteResponseException rejected) {
            throw new FocusRejectedException(rejected.operation, rejected.code);
        }
        pause(100);
        latest = properties();
        boolean focusLocked = isFocusLocked(latest);
        Long focusModeValue = null;
        Property focusMode = latest.get(0x500a);
        if (focusMode != null) {
            try { focusModeValue = focusMode.number(); } catch (IOException ignored) {}
        }
        if (!focusLocked && controls.contains(0xd2c1) && (focusModeValue == null || focusModeValue != 1L)) {
            return acquireFocusWithHalfPress(latest);
        }
        return new FocusPointResult(latest, focusLocked);
    }

    private FocusPointResult acquireFocusWithHalfPress(Map<Integer,Property> initialProperties) throws IOException {
        boolean half = false;
        boolean pressRejectedByCamera = false;
        boolean achieved = false;
        IOException error = null;
        Map<Integer,Property> current = initialProperties;
        captureInFlight = true;
        try {
            half = true;
            button(0xd2c1, 2);
            for (int attempt = 0; attempt < 15; attempt++) {
                pause(100);
                current = properties();
                Property indication = current.get(0xd213);
                Long value = null;
                if (indication != null) {
                    try { value = indication.number(); } catch (IOException ignored) {}
                }
                if (value == null) {
                    if (attempt >= 2) break;
                    continue;
                }
                if (value == 2L || value == 6L) {
                    achieved = true;
                    break;
                }
                if (value == 3L) {
                    break;
                }
                if (value == 7L && attempt >= 5) {
                    break;
                }
            }
        } catch (RemoteResponseException ignored) {
            pressRejectedByCamera = true;
        } catch (IOException failure) {
            error = failure;
        } finally {
            if (!closed && half) {
                try {
                    button(0xd2c1, 1);
                    half = false;
                } catch (RemoteResponseException ignored) {
                    half = false;
                } catch (IOException releaseFailure) {
                    if (error == null) error = releaseFailure;
                    else error.addSuppressed(releaseFailure);
                }
            }
            captureInFlight = false;
            if (stopRequested) close();
        }
        if (error != null) throw error;
        if (!pressRejectedByCamera && !closed && !stopRequested) {
            try {
                pause(50);
                current = properties();
            } catch (IOException ignored) {}
        }
        return new FocusPointResult(current, achieved || isFocusLocked(current));
    }

    public synchronized Map<Integer,Property> cancelTouchFocus() throws IOException {
        Map<Integer,Property> latest = properties();
        if (!canCancelTouchFocus(latest)) {
            throw new FocusUnavailableException(FocusUnavailableReason.UNSUPPORTED);
        }
        sendTouchCancel();
        pause(100);
        return properties();
    }

    private void sendTouchCancel() throws IOException {
        boolean pressed = false;
        IOException error = null;
        try {
            pressed = true;
            button(0xd2e5, 2);
            pause(50);
            button(0xd2e5, 1);
            pressed = false;
        } catch (IOException failure) {
            error = failure;
        } finally {
            if (pressed && !closed) {
                try { button(0xd2e5, 1); }
                catch (IOException releaseError) {
                    if (error==null) error = releaseError; else error.addSuppressed(releaseError);
                }
            }
        }
        if (error!=null) {
            if (error instanceof RemoteResponseException) {
                RemoteResponseException rejected = (RemoteResponseException) error;
                throw new FocusRejectedException(rejected.operation, rejected.code);
            }
            throw error;
        }
    }

    public synchronized void capture() throws IOException { capture(false); }

    /** ZV-E10 手机模式 D222 不反映机身菜单，由操作者明确确认双端保存。 */
    public synchronized void captureWithConfirmedCardSaving(boolean cardSavingConfirmed) throws IOException {
        if(!hasLegacyContents() || !cardSavingConfirmed) throw new CaptureNotSentException("Confirm camera-card saving before capture");
        capture(true);
    }

    public static final class CaptureNotSentException extends IOException {
        CaptureNotSentException(String reason) { super(reason); }
        CaptureNotSentException(IOException cause) { super("Capture preflight failed before shutter transmission",cause); }
    }

    private void capture(boolean legacyCardConfirmed) throws IOException {
        if(purpose!=Purpose.TETHER) throw new CaptureNotSentException("Shutter outside remote shooting profile");
        if(!captureReady) throw new CaptureNotSentException("Reopen remote session after contents transfer");
        Map<Integer,Property> state;
        try { state=properties(); } catch(IOException failure) { throw new CaptureNotSentException(failure); }
        Property destination = state.get(0xd222), drive = state.get(0x5013);
        if (!legacyCardConfirmed && (destination == null || (destination.number() & 0x10) == 0))
            throw new CaptureNotSentException("Choose camera-card saving before capture");
        if (drive == null || drive.number() != 1) throw new CaptureNotSentException("Choose single-shot drive mode on the camera");
        if (!operations.contains(0x9207) || !controls.contains(0xd2c1) || !controls.contains(0xd2c2))
            throw new CaptureNotSentException("Remote shutter controls not advertised");
        boolean half = false, full = false;
        IOException error = null;
        captureInFlight=true;
        try {
            half = true; button(0xd2c1,2); pause(500);
            full = true; button(0xd2c2,2); pause(35);
            button(0xd2c2,1); full = false; pause(1000);
            button(0xd2c1,1); half = false;
            reporter.report("remote_shutter_sequence_acknowledged");
        } catch (IOException failure) { error = failure; }
        finally {
            // 完整错误响应仍可释放；事务错位后 socket 已关闭，不能在含混的字节流上补发任何命令。
            if (!closed) {
                if (full) try { button(0xd2c2,1); } catch (IOException failure) { if (error == null) error=failure; else error.addSuppressed(failure); }
                if (half && !closed) try { button(0xd2c1,1); } catch (IOException failure) { if (error == null) error=failure; else error.addSuppressed(failure); }
            }
            captureInFlight=false;
            if(stopRequested) close();
        }
        if (error != null) { reporter.report("remote_capture_result_unknown_check_camera"); throw error; }
    }

    private void button(int control,int value) throws IOException {
        call(0x9207,new int[]{control},u16(value),0,false);
    }
    private void pause(long milliseconds) throws IOException {
        try {
            for(long remaining=milliseconds;remaining>0;remaining-=10) {
                if(stopRequested) throw new IOException("Remote operation stopped");
                Thread.sleep(Math.min(remaining,10));
            }
        }
        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new IOException("Remote operation interrupted",interrupted); }
    }

    public static final class IncrementalContents {
        public final List<Asset> assets;
        public final long cursor;
        public final boolean hasEntries;
        public final boolean truncated;
        IncrementalContents(List<Asset> assets,long cursor,boolean hasEntries) {
            this(assets,cursor,hasEntries,false);
        }
        IncrementalContents(List<Asset> assets,long cursor,boolean hasEntries,boolean truncated) {
            this.assets=Collections.unmodifiableList(new ArrayList<>(assets));
            this.cursor=cursor;
            this.hasEntries=hasEntries;
            this.truncated=truncated;
        }
    }

    public synchronized List<Asset> listPhotos() throws IOException {
        return listPhotosFrom(0L).assets;
    }

    private boolean shouldListSlot(int slot, boolean defaultWhenUnknown) throws IOException {
        if (!operations.contains(0x923b)) return slot == 1;
        try {
            byte[] info = call(0x923b, new int[]{slot}, null, SLOT_DATES_LIMIT, true);
            if (info.length < 4) return false;
            return SonyCameraNative.nativeParseSlotPhotoCount(info) > 0;
        } catch (RemoteResponseException error) {
            if (error.code == 0x201d || error.code == 0x2013) return false;
            return defaultWhenUnknown;
        }
    }

    public synchronized IncrementalContents listPhotosFrom(long startCursor) throws IOException {
        if (!remoteReady) throw new IOException("Remote handshake incomplete");
        List<Asset> result = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        long[] latestCursor = {0L};
        boolean[] hasEntries = {false};
        boolean[] exceeded = {false};
        if (shouldListSlot(1, true)) {
            listSlotFrom(1, startCursor, result, seen, latestCursor, hasEntries, exceeded);
        }
        if (shouldListSlot(2, false)) {
            listSlotFrom(2, startCursor, result, seen, latestCursor, hasEntries, exceeded);
        }
        if (exceeded[0]) SonyMobileSession.trimRecentAssets(result);
        rememberAssets(result);
        // 超过枚举上限时返回最近窗口并保持连接，由调用方提示截断，而不是断开会话。
        return new IncrementalContents(result, hasEntries[0] ? latestCursor[0] : 0L, hasEntries[0], exceeded[0]);
    }

    private void listSlotFrom(int slot, long startCursor, List<Asset> result, Set<String> seen,
                              long[] latestCursorOut, boolean[] hasEntriesOut, boolean[] exceededOut) throws IOException {
        long cursor = Math.max(0L, startCursor);
        for (int page = 0; page < 1000; page++) {
            byte[] bytes = call(0x923c, new int[]{(int) cursor, (int) (cursor >>> 32), 100, slot, 0}, null, LIMIT, true);
            SonyMobileSession.Page data;
            try { data = parseContents(bytes, this, slot); } catch (IOException invalid) { close(); throw invalid; }
            if (data.count > 0) {
                hasEntriesOut[0] = true;
                latestCursorOut[0] = Math.max(latestCursorOut[0], data.cursor);
            }
            for (Asset asset : data.assets) if (seen.add(asset.key())) {
                result.add(asset);
                if (result.size() > CameraMediaSession.MAX_LISTED_PHOTOS) {
                    exceededOut[0] = true;
                    if (result.size() >= CameraMediaSession.MAX_LISTED_PHOTOS * 2) SonyMobileSession.trimRecentAssets(result);
                }
            }
            if (data.count < 100) return;
            if (data.cursor <= cursor) throw new IOException("Remote contents cursor did not advance");
            cursor = data.cursor;
        }
        // 1000 页仍未到卡尾时游标停在卡中段，不能当增量起点静默放行：继续按上限拒绝，避免把卡内既有照片当新拍下载。
        SonyMobileSession.trimRecentAssets(result);
        rememberAssets(result);
        throw new CameraMediaSession.PhotoLimitExceededException("Remote contents page limit exceeded", result);
    }

    private void rememberAssets(List<Asset> assets) {
        if (knownAssets.size() + assets.size() > CameraMediaSession.MAX_LISTED_PHOTOS * 2) knownAssets.clear();
        for (Asset asset : assets) knownAssets.add(asset.key());
    }

    private boolean hasRemoteAsset(Asset target) throws IOException {
        long cursor = target.created > 0 ? target.created - 1 : 0;
        for (int page = 0; page < 1000; page++) {
            byte[] bytes = call(0x923c, new int[]{(int)cursor, (int)(cursor>>>32), 100, target.slot, 0}, null, LIMIT, true);
            SonyMobileSession.Page data;
            try { data = parseContents(bytes, this, target.slot); } catch (IOException invalid) { close(); throw invalid; }
            for (Asset candidate : data.assets) if (target.same(candidate)) return true;
            if (data.count < 100 || data.cursor > target.created) return false;
            if (data.cursor <= cursor) throw new IOException("Remote contents cursor did not advance");
            cursor = data.cursor;
        }
        return false;
    }

    public synchronized String download(Asset asset,OutputStream destination) throws IOException {
        if (asset == null || asset.owner != this || !knownAssets.contains(asset.key())) throw new IOException("Unknown remote original");
        if (asset.size<=0 || asset.size>(1L<<30)) throw new CameraMediaSession.PhotoTransferException("Remote original size outside budget");
        MessageDigest digest;
        try { digest=MessageDigest.getInstance("SHA-256"); } catch (NoSuchAlgorithmException e) { throw new IOException(e); }
        for (long offset=0;offset<asset.size;) {
            int count=(int)Math.min(3<<20,asset.size-offset);
            byte[] bytes=call(0x923d,new int[]{asset.content,(asset.slot<<24)|asset.file,(int)offset,(int)(offset>>>32),count},null,count,true);
            if (bytes.length!=count) throw new CameraMediaSession.PhotoTransferException("Remote original chunk truncated");
            if (offset==0) {
                if (!SonyCameraNative.nativeValidatePhotoHeader(asset.name, bytes)) throw new CameraMediaSession.PhotoTransferException("Remote original header mismatch");
            }
            destination.write(bytes); digest.update(bytes); offset+=bytes.length;
        }
        destination.flush();
        if (!hasRemoteAsset(asset)) throw new CameraMediaSession.PhotoTransferException(CameraMediaSession.FailureKind.SOURCE_CHANGED, "Remote card object changed during transfer");
        StringBuilder hash=new StringBuilder(); for (byte b:digest.digest()) hash.append(String.format(Locale.ROOT,"%02x",b&255));
        return hash.toString();
    }

    private synchronized byte[] call(int op,int[] params,byte[] outgoing,int limit,boolean required) throws IOException {
        if (closed) throw new IOException("Remote session closed");
        if (!Arrays.asList(0x1001,0x1002,0x1004,0x1007,0x1008,0x100a,0x101b,0x9201,0x9202,0x9205,0x9207,0x9209,0x9212,0x923b,0x923c,0x923d).contains(op) || params.length>5 || limit<0 || limit>LIMIT)
            throw new IOException("Operation outside the remote profile");
        if(outgoing!=null) {
            if(purpose!=Purpose.TETHER || !remoteReady || params.length!=1) throw new IOException("Write outside tether ownership");
            if(op==0x9207) {
                int control=params[0];
                if(!controls.contains(control)) throw new IOException("Unsupported remote control write");
                if(control==0xd2c1 || control==0xd2c2 || control==0xd2e5) {
                    if(outgoing.length!=2 || outgoing[1]!=0 || (outgoing[0]!=1 && outgoing[0]!=2))
                        throw new IOException("Unsupported remote control write");
                    if(outgoing[0]==2 && stopRequested) throw new IOException("Remote press stopped");
                } else if(control==0xd2dc || control==0xd2e4) {
                    if(outgoing.length!=4 || stopRequested) throw new IOException("Unsupported remote control write");
                    long packed=leU32(outgoing,0);
                    int x=(int)(packed>>>16);
                    int y=(int)(packed&0xffffL);
                    if(x<0 || x>639 || y<0 || y>479) throw new IOException("Remote focus point out of range");
                } else throw new IOException("Unsupported remote control write");
            } else if(op==0x9205) {
                int type=parameterType(params[0]);
                if(!supportsParameterWrites() || stopRequested || type==0 || outgoing.length!=(type==6?4:2))
                    throw new IOException("Unsupported camera parameter write");
            } else throw new IOException("Unsupported remote write operation");
        }
        for (int attempt = 0; ; attempt++) {
            try { return exchange(op,params,outgoing,limit,required); }
            catch (RemoteResponseException rejected) {
                if (outgoing != null || rejected.getKind() != CameraMediaSession.FailureKind.TRANSIENT_READ
                    || attempt >= 2 || closed || stopRequested) throw rejected;
                pause(100L * (attempt + 1));
            }
            catch (IOException fatal) { close(); throw fatal; }
        }
    }

    private byte[] exchange(int op,int[] params,byte[] outgoing,int limit,boolean required) throws IOException {
        int tid=op==0x1002 ? (transaction=0) : ++transaction;
        OutputStream cmdOut = command.getOutputStream();
        byte[] opReq = SonyCameraNative.nativeOpReqPacket(outgoing==null?1:2, op, tid, params);
        if (outgoing!=null) {
            byte[] start = SonyCameraNative.nativeStartDataPacket(tid, outgoing.length);
            byte[] end = SonyCameraNative.nativeEndDataPacket(tid, outgoing);
            ByteArrayOutputStream batch = new ByteArrayOutputStream(opReq.length + start.length + end.length);
            batch.write(opReq); batch.write(start); batch.write(end);
            cmdOut.write(batch.toByteArray()); cmdOut.flush();
        } else {
            cmdOut.write(opReq); cmdOut.flush();
        }
        boolean started=false,ended=false; long expected=-1;
        ByteArrayOutputStream data=new ByteArrayOutputStream();
        byte[] probeResp = null;
        for (int packetCount=0;packetCount<10000;packetCount++) {
            Packet packet=readPacket(command,Math.max(4096,limit+4));
            if (packet.type==9) {
                long[] start = SonyCameraNative.nativeParseStartData(packet.bytes);
                if (started || (int)start[0]!=tid) throw new IOException("Invalid remote data start");
                expected=start[1]; if (expected<0 || expected>limit) throw new IOException("Remote data budget exceeded"); started=true;
            } else if (packet.type==10 || packet.type==12) {
                Reader r=new Reader(packet.bytes);
                if (!started || ended || r.i32()!=tid) throw new IOException("Remote data transaction mismatch");
                int count=r.remaining(); if (count>limit-data.size() || data.size()+count>expected) throw new IOException("Remote data length exceeded");
                data.write(r.take(count));
                if (packet.type==12) { if (data.size()!=expected) throw new IOException("Remote data truncated"); ended=true; }
            } else if (packet.type==7) {
                int[] resp = SonyCameraNative.nativeParseResponse(packet.bytes);
                int code=resp[0]; if (resp[1]!=tid) throw new IOException("Remote response transaction mismatch");
                if (started && !ended) throw new IOException("Remote response before complete data");
                if (code!=0x2001) throw new RemoteResponseException(op,code);
                if (required && !started) throw new IOException("Remote data missing");
                reporter.report(String.format(Locale.ROOT,"remote_operation op=0x%04x bytes=%d",op,data.size()));
                return data.toByteArray();
            } else if (packet.type==13 && packet.bytes.length==0) {
                if (probeResp == null) probeResp = SonyCameraNative.nativeProbeRespPacket();
                cmdOut.write(probeResp); cmdOut.flush();
            }
            else throw new IOException("Unexpected remote packet "+packet.type);
        }
        throw new IOException("Remote packet budget exceeded");
    }

    @Override public void close() { closed=true; try { command.close(); } catch (IOException ignored) {} try { event.close(); } catch (IOException ignored) {} }
    public boolean isOpen() { return !closed; }

    /** 主动退出先中止按下序列并释放；失联时两秒硬截止，不能阻塞 UI。 */
    public void requestStop() {
        stopRequested=true;
        if(!captureInFlight) { close();return; }
        Thread deadline=new Thread(() -> {
            try { Thread.sleep(2000); } catch(InterruptedException ignored) { Thread.currentThread().interrupt(); }
            if(!closed) { reporter.report("remote_release_deadline_check_camera");close(); }
        },"camera-tether-stop");
        deadline.setDaemon(true);deadline.start();
    }

    public static final class Property {
        public final int code,type,enabled,form;
        public final boolean writable;
        private final Object value;
        private final Long minimum,maximum,step;
        private final List<Long> settable;
        Property(int code,int type,boolean writable,int enabled,Object value,int form,Long minimum,Long maximum,Long step,List<Long> settable) {
            this.code=code;this.type=type;this.writable=writable;this.enabled=enabled;this.value=value;this.form=form;
            this.minimum=minimum;this.maximum=maximum;this.step=step;this.settable=Collections.unmodifiableList(new ArrayList<>(settable));
        }
        public long number() throws IOException { if (!(value instanceof Long)) throw new IOException("Property is not numeric"); return (Long)value; }
        public String text() throws IOException { if (!(value instanceof String)) throw new IOException("Property is not text"); return (String)value; }
        private long[] toChoiceArray() {
            long[] arr = new long[settable.size()];
            for (int i = 0; i < settable.size(); i++) arr[i] = settable.get(i);
            return arr;
        }
        public List<Long> options() {
            long[] opts = SonyCameraNative.nativePropertyOptions(
                code, type, writable, enabled, form,
                minimum != null && maximum != null && step != null,
                minimum != null ? minimum : 0L,
                maximum != null ? maximum : 0L,
                step != null ? step : 0L,
                toChoiceArray(),
                false, false, 4096);
            if (opts.length == 0) return Collections.emptyList();
            List<Long> result = new ArrayList<>(opts.length);
            for (long v : opts) result.add(v);
            return Collections.unmodifiableList(result);
        }
        public boolean canSet(long requested) {
            return SonyCameraNative.nativePropertyCanSet(
                code, type, writable, enabled, form,
                minimum != null && maximum != null && step != null,
                minimum != null ? minimum : 0L,
                maximum != null ? maximum : 0L,
                step != null ? step : 0L,
                toChoiceArray(),
                requested);
        }
    }
    public static Map<Integer,Property> parseProperties(byte[] bytes) throws IOException { return parseProperties(bytes,2); }
    static Map<Integer,Property> parseProperties(byte[] bytes,int enumTables) throws IOException {
        List<SonyCameraNative.DecodedProperty> decoded = SonyCameraNative.parseProperties(bytes, enumTables);
        Map<Integer,Property> result=new LinkedHashMap<>();
        for(SonyCameraNative.DecodedProperty p : decoded) {
            Object val;
            if (p.getValueKind() == SonyCameraNative.VALUE_KIND_NUMBER) val = p.getNumberValue();
            else if (p.getValueKind() == SonyCameraNative.VALUE_KIND_TEXT) val = p.getTextValue();
            else val = new byte[0];
            Long min = p.getHasRange() ? p.getMinimum() : null;
            Long max = p.getHasRange() ? p.getMaximum() : null;
            Long step = p.getHasRange() ? p.getStep() : null;
            List<Long> choices = new ArrayList<>(p.getChoices().length);
            for (long c : p.getChoices()) choices.add(c);
            result.put(p.getCode(), new Property(p.getCode(), p.getType(), p.getWritable(), p.getEnabled(), val, p.getForm(), min, max, step, choices));
        }
        return result;
    }
    public static URL liveViewURL(String raw,InetAddress camera) throws IOException {
        try {
            URI uri=new URI(raw); String host=uri.getHost();
            if (!"http".equals(uri.getScheme()) || host==null || !(host.equals("localhost") || host.equals(camera.getHostAddress())) ||
                uri.getPort()<1 || uri.getPort()>65535 || uri.getUserInfo()!=null || uri.getFragment()!=null || !"/liveviewstream".equals(uri.getRawPath()))
                throw new IOException("Unsupported camera live-view URL");
            return new URL("http",camera.getHostAddress(),uri.getPort(),uri.getRawPath()+(uri.getRawQuery()==null?"":"?"+uri.getRawQuery()));
        } catch (URISyntaxException invalid) { throw new IOException("Invalid camera live-view URL",invalid); }
    }
    public static LiveViewFrame readFrameWithMetadata(InputStream input) throws IOException {
        DataInputStream stream=new DataInputStream(input); byte[] header=new byte[16]; stream.readFully(header); Reader r=new Reader(header);
        int[] fields = {r.i32(), r.i32(), r.i32(), r.i32()};
        SonyCameraNative.LiveFrameBounds bounds = SonyCameraNative.parseLiveFrameBounds(fields, LIMIT);
        byte[] body=new byte[bounds.getBodySize()]; stream.readFully(body);
        int imgOff = bounds.getImageOffset();
        byte[] jpeg=Arrays.copyOfRange(body, imgOff, imgOff + bounds.getImageLength());
        if (jpeg[0]!=(byte)255 || jpeg[1]!=(byte)216) throw new IOException("Live frame is not JPEG");
        byte[] meta;
        if (bounds.getHasMetadata()) {
            int metaOff = bounds.getMetadataOffset();
            meta = Arrays.copyOfRange(body, metaOff, metaOff + bounds.getMetadataLength());
        } else {
            meta = new byte[0];
        }
        return new LiveViewFrame(jpeg,meta);
    }
    public static byte[] readFrame(InputStream input) throws IOException {
        return readFrameWithMetadata(input).jpeg;
    }
    public static List<LiveViewFocusFrame> parseLiveViewFrames(byte[] metadata) {
        if (metadata==null) return Collections.emptyList();
        List<SonyCameraNative.DecodedLiveFrame> decoded = SonyCameraNative.parseLiveViewFrames(metadata);
        if (decoded.isEmpty()) return Collections.emptyList();
        List<LiveViewFocusFrame> frames=new ArrayList<>(decoded.size());
        for (SonyCameraNative.DecodedLiveFrame f : decoded) {
            LiveViewFrameKind kind;
            if (f.getKind() == 0) kind = LiveViewFrameKind.FOCUS;
            else if (f.getKind() == 1) kind = LiveViewFrameKind.FACE;
            else kind = LiveViewFrameKind.TRACKING;
            frames.add(new LiveViewFocusFrame(kind, (float)f.getCx(), (float)f.getCy(), (float)f.getWidth(), (float)f.getHeight(), f.getFocused()));
        }
        return Collections.unmodifiableList(frames);
    }
    private static long leU32(byte[] b, int off) {
        return (b[off]&0xffL)|((b[off+1]&0xffL)<<8)|((b[off+2]&0xffL)<<16)|((b[off+3]&0xffL)<<24);
    }
}
