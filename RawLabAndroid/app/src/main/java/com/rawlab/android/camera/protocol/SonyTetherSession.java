package com.rawlab.android.camera.protocol;

import java.io.*;
import java.net.*;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;
import javax.net.SocketFactory;
import com.rawlab.android.camera.protocol.SonyMobileSession.Reader;
import static com.rawlab.android.camera.protocol.SonyMobileSession.*;

/** 独立遥控 profile；选片导入必须使用 Purpose.IMPORT，禁止任何快门写入。 */
public final class SonyTetherSession implements Closeable {
    public enum Profile { A7CII_2_00, ZVE10_2_02, GENERIC }
    public enum Purpose { IMPORT, TETHER }
    private static final int LIMIT = 8 << 20;
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

    public static final class RemoteResponseException extends IOException {
        public final int operation, code;
        RemoteResponseException(int operation,int code) { super(String.format(Locale.ROOT,"PTP op 0x%04x response 0x%04x",operation,code));this.operation=operation;this.code=code; }
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
            ByteArrayOutputStream init = new ByteArrayOutputStream();
            init.write(ByteBuffer.allocate(16).putLong(guid.getMostSignificantBits()).putLong(guid.getLeastSignificantBits()).array());
            init.write("RawLab\0".getBytes(StandardCharsets.UTF_16LE)); init.write(u32(0x10000));
            writePacket(command,1,init.toByteArray());
            Packet ack = readPacket(command,4096);
            if (ack.type != 2 || ack.bytes.length < 24) throw new IOException("Remote PTP command init rejected");
            int connection = new Reader(ack.bytes).i32();
            event.connect(new InetSocketAddress(address,15740),10000); event.setSoTimeout(10000);
            writePacket(event,3,u32(connection));
            Packet ready = readPacket(event,4096);
            if (ready.type != 4 || ready.bytes.length != 0) throw new IOException("Remote PTP event init rejected");
            event.setSoTimeout(0); event.setTcpNoDelay(true);
            new Thread(this::readEvents,"camera-tether-events").start();
        } catch (IOException failure) { close(); throw failure; }
    }

    private void readEvents() {
        try {
            while (!closed) {
                Packet packet = readPacket(event,4096);
                if (packet.type == 13 && packet.bytes.length == 0) { writePacket(event,14,new byte[0]); continue; }
                if (packet.type != 8 || packet.bytes.length < 6 || packet.bytes.length > 18 || (packet.bytes.length - 6) % 4 != 0)
                    throw new IOException("Invalid remote event");
                Reader r = new Reader(packet.bytes); int code = r.u16(); long tid = r.u32();
                List<Long> params = new ArrayList<>(); while (r.remaining() > 0) params.add(r.u32());
                reporter.report(String.format(Locale.ROOT,"remote_event code=0x%04x tid=%d parameters=%s",code,tid,params));
            }
        } catch (IOException failure) { if (!closed) { reporter.report("remote_event_failed " + failure.getClass().getSimpleName()); close(); } }
    }

    public synchronized Device inspectDevice() throws IOException {
        Reader d = new Reader(call(0x1001,new int[0],null,1 << 20,true));
        d.u16(); long vendor = d.u32(); d.u16(); d.ptpString(); d.u16(); operations = d.u16Array();
        for (int i=0;i<4;i++) d.u16Array();
        String maker = d.ptpString(), model = d.ptpString(), firmware = d.ptpString(); d.ptpString();
        if(vendor!=17 || !(maker.equals("Sony") || maker.equals("Sony Corporation"))) throw new IOException("Not a Sony PTP device");
        return new Device(maker,model,firmware,operations);
    }

    public void connectRemote() throws IOException { connectRemote(Profile.GENERIC); }

    public synchronized void connectRemote(Profile profile) throws IOException {
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
                Reader info = new Reader(bytes); int version = info.u16();
                Set<Integer> properties = info.u16Array(); controls.addAll(info.u16Array());
                if ((version != 0x12c && version != 0xc8) || info.remaining() != 0)
                    throw new IOException("Unsupported Sony remote protocol descriptor version="+version);
                propertyEnumTables=version==0x12c?2:1;
                reporter.report("remote_extended protocol=" + version + " properties=" + properties.size() + " controls=" + controls);
                if (!properties.isEmpty() || !controls.isEmpty()) break;
            }
            pause(100);
        }
        call(0x9201,new int[]{3,0,0},null,65536,false);
        remoteReady = true;
        remoteReadyNanos = System.nanoTime();
        captureReady = true;
        reporter.report("remote_handshake_complete");
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
        public boolean isPhoto() { String lower=name.toLowerCase(Locale.ROOT);return size>0 && size<=(1L<<30) && (lower.endsWith(".arw") || lower.endsWith(".jpg") || lower.endsWith(".jpeg")); }
    }

    static LegacyObject parseLegacyObject(int handle,byte[] bytes) throws IOException {
        Reader r=new Reader(bytes);int storage=r.i32(),format=r.u16();r.u16();long size=r.u32();r.take(40);
        String name=r.ptpString(),created=r.ptpString(),modified=r.ptpString();r.ptpString();
        if(r.remaining()!=0 || name.isEmpty() || name.equals(".") || name.equals("..") || name.indexOf('/')>=0 || name.indexOf('\\')>=0 || name.indexOf('\0')>=0)
            throw new IOException("Invalid legacy object metadata");
        return new LegacyObject(handle,storage,format,size,name,created,modified);
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
            byte[] bytes=call(0x1007,new int[]{(int)storage,0,0},null,40004,true);
            try {
                Reader r=new Reader(bytes);long count=r.u32();
                if(count>10000 || r.remaining()!=count*4) throw new IOException("Invalid legacy object handles");
                for(int i=0;i<count;i++) { int handle=r.i32();if(!handles.add(handle) || handles.size()>10000) throw new IOException("Duplicate/excessive legacy object handles"); }
            } catch(IOException invalid) { close();throw invalid; }
        }
        return handles;
    }

    public synchronized List<LegacyObject> listLegacyPhotos(Set<Integer> baseline) throws IOException {
        List<LegacyObject> result=new ArrayList<>();
        for(int handle:legacyHandles()) {
            if(baseline.contains(handle)) continue;
            LegacyObject object=legacyObject(handle);
            if(object.isPhoto()) { result.add(object);knownLegacyObjects.add(object.key()); }
        }
        return result;
    }

    public synchronized byte[] previewLegacy(LegacyObject object) throws IOException {
        if(object==null || object.owner!=this || !knownLegacyObjects.contains(object.key()) || !operations.contains(0x100a)) throw new IOException("Legacy thumbnail unavailable");
        return call(0x100a,new int[]{object.handle},null,2<<20,true);
    }

    public synchronized String downloadLegacy(LegacyObject object,OutputStream destination) throws IOException {
        if(object==null || object.owner!=this || !object.isPhoto() || !knownLegacyObjects.contains(object.key()) || !operations.contains(0x101b)) throw new IOException("Unknown or unsupported legacy original");
        if(!object.key().equals(legacyObject(object.handle).key())) throw new IOException("Legacy original changed before transfer");
        MessageDigest digest;try { digest=MessageDigest.getInstance("SHA-256"); } catch(NoSuchAlgorithmException error) { throw new IOException(error); }
        for(long offset=0;offset<object.size;) {
            int count=(int)Math.min(3<<20,object.size-offset);
            byte[] bytes=call(0x101b,new int[]{object.handle,(int)offset,count},null,count,true);
            if(bytes.length!=count) throw new IOException("Legacy original chunk truncated");
            if(offset==0) {
                boolean tiff=bytes.length>=4 && (bytes[0]==73 && bytes[1]==73 && bytes[2]==42 && bytes[3]==0 || bytes[0]==77 && bytes[1]==77 && bytes[2]==0 && bytes[3]==42);
                boolean jpeg=bytes.length>=3 && bytes[0]==(byte)255 && bytes[1]==(byte)216 && bytes[2]==(byte)255;
                if(object.name.toLowerCase(Locale.ROOT).endsWith(".arw")?!tiff:!jpeg) throw new IOException("Legacy original header mismatch");
            }
            destination.write(bytes);digest.update(bytes);offset+=bytes.length;
        }
        destination.flush();
        if(!object.key().equals(legacyObject(object.handle).key())) throw new IOException("Legacy original changed during transfer");
        StringBuilder hash=new StringBuilder();for(byte b:digest.digest()) hash.append(String.format(Locale.ROOT,"%02x",b&255));return hash.toString();
    }

    public synchronized String downloadLegacyWhole(LegacyObject object,OutputStream destination) throws IOException {
        if(closed || object==null || object.owner!=this || !object.isPhoto() || !knownLegacyObjects.contains(object.key()) || !operations.contains(0x1009)) throw new IOException("Unknown or unsupported legacy original");
        if(!object.key().equals(legacyObject(object.handle).key())) throw new IOException("Legacy original changed before transfer");
        String hash=downloadLegacyBytes(object,destination);
        if(!object.key().equals(legacyObject(object.handle).key())) throw new IOException("Legacy original changed during transfer");
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
        boolean tiff=prefix[0]==73 && prefix[1]==73 && prefix[2]==42 && prefix[3]==0 || prefix[0]==77 && prefix[1]==77 && prefix[2]==0 && prefix[3]==42;
        boolean jpeg=prefix[0]==(byte)255 && prefix[1]==(byte)216 && prefix[2]==(byte)255;
        if(prefixSize[0]<4 || (object.name.toLowerCase(Locale.ROOT).endsWith(".arw")?!tiff:!jpeg)) throw new IOException("Legacy original header mismatch");
        destination.flush();StringBuilder hash=new StringBuilder();for(byte b:digest.digest()) hash.append(String.format(Locale.ROOT,"%02x",b&255));return hash.toString();
    }

    /** 标准 GetObject 可能把整个 RAW 放在单个 PTP/IP 数据包中；按块写出，避免随包长分配。 */
    private void streamObject(int handle,long size,OutputStream destination) throws IOException {
        int tid=++transaction;long received=0;boolean started=false,ended=false;
        try {
            ByteArrayOutputStream request=new ByteArrayOutputStream();request.write(u32(1));request.write(u16(0x1009));request.write(u32(tid));request.write(u32(handle));
            writePacket(command,6,request.toByteArray());
            DataInputStream input=new DataInputStream(command.getInputStream());byte[] header=new byte[8],buffer=new byte[65536];
            for(int packets=0;packets<100000;packets++) {
                input.readFully(header);Reader h=new Reader(header);long length=h.u32();int type=h.i32();
                if(length<8 || length>size+20) throw new IOException("Invalid streamed packet length");
                int body=(int)(length-8);
                if(type==9) {
                    if(started || body!=12) throw new IOException("Invalid streamed data start");
                    byte[] bytes=new byte[12];input.readFully(bytes);Reader r=new Reader(bytes);
                    if(r.i32()!=tid || r.i64()!=size) throw new IOException("Streamed object size/transaction mismatch");started=true;
                } else if(type==10 || type==12) {
                    if(!started || ended || body<4 || body-4>size-received) throw new IOException("Invalid streamed object data");
                    byte[] id=new byte[4];input.readFully(id);if(new Reader(id).i32()!=tid) throw new IOException("Streamed data transaction mismatch");
                    for(int remaining=body-4;remaining>0;) { int count=Math.min(buffer.length,remaining);input.readFully(buffer,0,count);destination.write(buffer,0,count);received+=count;remaining-=count; }
                    if(type==12) { if(received!=size) throw new IOException("Streamed object truncated");ended=true; }
                } else if(type==7) {
                    if(body<6 || body>26 || (body-6)%4!=0) throw new IOException("Invalid streamed response");
                    byte[] bytes=new byte[body];input.readFully(bytes);Reader r=new Reader(bytes);int code=r.u16();
                    if(r.i32()!=tid || started && !ended) throw new IOException("Streamed response transaction mismatch");
                    if(code!=0x2001) throw new RemoteResponseException(0x1009,code);
                    if(!ended) throw new IOException("Streamed object missing");
                    reporter.report("remote_operation op=0x1009 bytes="+received);return;
                } else if(type==13 && body==0) writePacket(command,14,new byte[0]);
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
            case 0x5005:case 0x5007:case 0x500a:case 0xd20f:return 4;
            case 0x5010:return 3;
            case 0xd20d:case 0xd21e:case 0xd226:return 6;
            default:return 0;
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

    public synchronized List<Asset> listPhotos() throws IOException {
        if (!remoteReady) throw new IOException("Remote handshake incomplete");
        List<Asset> result = new ArrayList<>(); Set<String> seen = new HashSet<>(); long cursor=0;
        for (int page=0;page<100;page++) {
            byte[] bytes=call(0x923c,new int[]{(int)cursor,(int)(cursor>>>32),100,1,0},null,LIMIT,true);
            SonyMobileSession.Page data;
            try { data=parseContents(bytes,this); } catch(IOException invalid) { close();throw invalid; }
            for (Asset asset : data.assets) if (seen.add(asset.key())) { result.add(asset); knownAssets.add(asset.key()); }
            if (result.size()>10000 || knownAssets.size()>10000) throw new IOException("Remote contents budget exceeded");
            if (data.count<100) return result;
            if (data.cursor<=cursor) throw new IOException("Remote contents cursor did not advance");
            cursor=data.cursor;
        }
        throw new IOException("Remote contents page limit exceeded");
    }

    public synchronized String download(Asset asset,OutputStream destination) throws IOException {
        if (asset == null || asset.owner != this || !knownAssets.contains(asset.key()) || asset.size<=0 || asset.size>(1L<<30)) throw new IOException("Unknown remote original");
        MessageDigest digest;
        try { digest=MessageDigest.getInstance("SHA-256"); } catch (NoSuchAlgorithmException e) { throw new IOException(e); }
        for (long offset=0;offset<asset.size;) {
            int count=(int)Math.min(3<<20,asset.size-offset);
            byte[] bytes=call(0x923d,new int[]{asset.content,(1<<24)|asset.file,(int)offset,(int)(offset>>>32),count},null,count,true);
            if (bytes.length!=count) throw new IOException("Remote original chunk truncated");
            if (offset==0) {
                boolean tiff=bytes.length>=4 && ((bytes[0]==73 && bytes[1]==73 && bytes[2]==42 && bytes[3]==0) ||
                    (bytes[0]==77 && bytes[1]==77 && bytes[2]==0 && bytes[3]==42));
                boolean jpeg=bytes.length>=3 && bytes[0]==(byte)255 && bytes[1]==(byte)216 && bytes[2]==(byte)255;
                if (asset.name.toLowerCase(Locale.ROOT).endsWith(".arw") ? !tiff : !jpeg) throw new IOException("Remote original header mismatch");
            }
            destination.write(bytes); digest.update(bytes); offset+=bytes.length;
        }
        destination.flush();
        boolean matches=false;
        for (Asset now:listPhotos()) if (asset.same(now)) { matches=true; break; }
        if (!matches) throw new IOException("Remote card object changed during transfer");
        StringBuilder hash=new StringBuilder(); for (byte b:digest.digest()) hash.append(String.format(Locale.ROOT,"%02x",b&255));
        return hash.toString();
    }

    private synchronized byte[] call(int op,int[] params,byte[] outgoing,int limit,boolean required) throws IOException {
        if (closed) throw new IOException("Remote session closed");
        if (!Arrays.asList(0x1001,0x1002,0x1004,0x1007,0x1008,0x100a,0x101b,0x9201,0x9202,0x9205,0x9207,0x9209,0x9212,0x923c,0x923d).contains(op) || params.length>5 || limit<0 || limit>LIMIT)
            throw new IOException("Operation outside the remote profile");
        if(outgoing!=null) {
            if(purpose!=Purpose.TETHER || !remoteReady || params.length!=1) throw new IOException("Write outside tether ownership");
            if(op==0x9207) {
                if(!controls.contains(params[0]) || (params[0]!=0xd2c1 && params[0]!=0xd2c2) || outgoing.length!=2 ||
                    outgoing[1]!=0 || (outgoing[0]!=1 && outgoing[0]!=2)) throw new IOException("Unsupported remote control write");
                if(outgoing[0]==2 && stopRequested) throw new IOException("Remote press stopped");
            } else if(op==0x9205) {
                int type=parameterType(params[0]);
                if(!supportsParameterWrites() || stopRequested || type==0 || outgoing.length!=(type==6?4:2))
                    throw new IOException("Unsupported camera parameter write");
            } else throw new IOException("Unsupported remote write operation");
        }
        try { return exchange(op,params,outgoing,limit,required); }
        catch (RemoteResponseException rejected) { throw rejected; }
        catch (IOException fatal) { close(); throw fatal; }
    }

    private byte[] exchange(int op,int[] params,byte[] outgoing,int limit,boolean required) throws IOException {
        int tid=op==0x1002 ? (transaction=0) : ++transaction;
        ByteArrayOutputStream request=new ByteArrayOutputStream();
        request.write(u32(outgoing==null?1:2)); request.write(u16(op)); request.write(u32(tid));
        for (int param:params) request.write(u32(param));
        writePacket(command,6,request.toByteArray());
        if (outgoing!=null) {
            ByteArrayOutputStream start=new ByteArrayOutputStream(); start.write(u32(tid)); start.write(u32(outgoing.length)); start.write(u32(0));
            writePacket(command,9,start.toByteArray());
            ByteArrayOutputStream end=new ByteArrayOutputStream(); end.write(u32(tid)); end.write(outgoing); writePacket(command,12,end.toByteArray());
        }
        boolean started=false,ended=false; long expected=-1;
        ByteArrayOutputStream data=new ByteArrayOutputStream();
        for (int packetCount=0;packetCount<10000;packetCount++) {
            Packet packet=readPacket(command,Math.max(4096,limit+4)); Reader r=new Reader(packet.bytes);
            if (packet.type==9) {
                if (started || packet.bytes.length!=12 || r.i32()!=tid) throw new IOException("Invalid remote data start");
                expected=r.i64(); if (expected<0 || expected>limit) throw new IOException("Remote data budget exceeded"); started=true;
            } else if (packet.type==10 || packet.type==12) {
                if (!started || ended || r.i32()!=tid) throw new IOException("Remote data transaction mismatch");
                int count=r.remaining(); if (count>limit-data.size() || data.size()+count>expected) throw new IOException("Remote data length exceeded");
                data.write(r.take(count));
                if (packet.type==12) { if (data.size()!=expected) throw new IOException("Remote data truncated"); ended=true; }
            } else if (packet.type==7) {
                if (packet.bytes.length<6 || packet.bytes.length>26 || (packet.bytes.length-6)%4!=0) throw new IOException("Invalid remote response");
                int code=r.u16(); if (r.i32()!=tid) throw new IOException("Remote response transaction mismatch");
                if (started && !ended) throw new IOException("Remote response before complete data");
                if (code!=0x2001) throw new RemoteResponseException(op,code);
                if (required && !started) throw new IOException("Remote data missing");
                reporter.report(String.format(Locale.ROOT,"remote_operation op=0x%04x bytes=%d",op,data.size()));
                return data.toByteArray();
            } else if (packet.type==13 && packet.bytes.length==0) writePacket(command,14,new byte[0]);
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
        public List<Long> options() {
            if(form==2) return settable;
            if(form!=1 || minimum==null || maximum==null || step==null || step<=0 || maximum<minimum) return Collections.emptyList();
            long distance;
            try { distance=Math.subtractExact(maximum,minimum); } catch(ArithmeticException overflow) { return Collections.emptyList(); }
            long count=distance/step+1;
            if(count<=0 || count>4096) return Collections.emptyList();
            List<Long> result=new ArrayList<>();for(long i=0;i<count;i++) result.add(minimum+i*step);
            return Collections.unmodifiableList(result);
        }
        public boolean canSet(long requested) {
            if(!writable || enabled!=1 || !(type==3 && requested>=Short.MIN_VALUE && requested<=Short.MAX_VALUE ||
                type==4 && requested>=0 && requested<=0xffff || type==6 && requested>=0 && requested<=0xffffffffL)) return false;
            if(form==2) return settable.contains(requested);
            return form==1 && minimum!=null && maximum!=null && step!=null && step>0 && requested>=minimum && requested<=maximum && (requested-minimum)%step==0;
        }
    }
    public static Map<Integer,Property> parseProperties(byte[] bytes) throws IOException { return parseProperties(bytes,2); }
    static Map<Integer,Property> parseProperties(byte[] bytes,int enumTables) throws IOException {
        if(enumTables!=1 && enumTables!=2) throw new IOException("Unknown property profile");
        Reader r=new Reader(bytes);long count=r.i64();if(count<0 || count>4096) throw new IOException("Property count exceeds budget");
        Map<Integer,Property> result=new LinkedHashMap<>();int enumCount=0;
        for(int i=0;i<count;i++) {
            int code=r.u16(),type=r.u16(),writable=r.u8(),enabled=r.u8();
            value(r,type);Object current=value(r,type);int form=r.u8();
            Long minimum=null,maximum=null,step=null;List<Long> settable=new ArrayList<>();
            if(form==1) {
                Object low=value(r,type),high=value(r,type),increment=value(r,type);
                if(low instanceof Long && high instanceof Long && increment instanceof Long) { minimum=(Long)low;maximum=(Long)high;step=(Long)increment; }
            } else if(form==2) for(int table=0;table<enumTables;table++) {
                int n=r.u16();enumCount+=n;
                if(n>4096 || enumCount>65536) throw new IOException("Property enum exceeds budget");
                for(int j=0;j<n;j++) { Object option=value(r,type);if(table==0 && option instanceof Long) settable.add((Long)option); }
            } else if(form!=0) throw new IOException("Unknown property form="+form+" code=0x"+Integer.toHexString(code));
            if(result.put(code,new Property(code,type,writable==1,enabled,current,form,minimum,maximum,step,settable))!=null) throw new IOException("Duplicate property");
        }
        if(r.remaining()!=0) throw new IOException("Trailing property bytes");
        return result;
    }
    private static Object value(Reader r,int type) throws IOException {
        if (type==0xffff) {
            int count=r.u8(); byte[] bytes=r.take(count*2); int size=bytes.length;
            if (size>=2 && bytes[size-1]==0 && bytes[size-2]==0) size-=2;
            String text=new String(bytes,0,size,StandardCharsets.UTF_16LE);
            if (text.indexOf('\0')>=0) throw new IOException("Embedded NUL in property string"); return text;
        }
        if ((type&0x4000)!=0) {
            long count=r.u32(); int scalar=type&~0x4000;
            if (scalar<1 || scalar>10 || count>4096) throw new IOException("Property array exceeds budget");
            for (int i=0;i<count;i++) value(r,scalar); return new byte[0];
        }
        switch(type) {
            case 1:return (long)(byte)r.u8(); case 2:return (long)r.u8();
            case 3:return (long)(short)r.u16(); case 4:return (long)r.u16();
            case 5:return (long)r.i32(); case 6:return r.u32(); case 7:case 8:return r.i64();
            case 9:case 10:return r.take(16); default:throw new IOException("Unknown property type "+type);
        }
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
    public static byte[] readFrame(InputStream input) throws IOException {
        DataInputStream stream=new DataInputStream(input); byte[] header=new byte[16]; stream.readFully(header); Reader r=new Reader(header);
        long imageOffset=r.u32(),imageLength=r.u32(),metaOffset=r.u32(),metaLength=r.u32();
        long imageEnd=imageOffset+imageLength,metaEnd=metaOffset+metaLength,total=Math.max(imageEnd,metaLength==0?16:metaEnd);
        if (imageOffset<16 || imageLength<4 || total>LIMIT || (metaLength>0 && (metaOffset<16 || imageOffset<metaEnd && metaOffset<imageEnd)))
            throw new IOException("Invalid live frame bounds");
        byte[] body=new byte[(int)total-16]; stream.readFully(body);
        byte[] jpeg=Arrays.copyOfRange(body,(int)imageOffset-16,(int)imageEnd-16);
        if (jpeg[0]!=(byte)255 || jpeg[1]!=(byte)216) throw new IOException("Live frame is not JPEG");
        return jpeg;
    }
}
