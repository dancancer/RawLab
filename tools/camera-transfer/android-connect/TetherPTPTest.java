package com.rawlab.android.camera.protocol;

import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import javax.net.SocketFactory;

public final class TetherPTPTest {
    interface Throwing { void run() throws Exception; }
    static void rejects(Throwing work) throws Exception {
        try { work.run(); throw new AssertionError("Accepted invalid input"); }
        catch (IOException expected) { }
    }
    static byte[] cat(byte[]... parts) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (byte[] part : parts) out.write(part);
        return out.toByteArray();
    }
    static byte[] u16(int n) { return SonyMobileSession.u16(n); }
    static byte[] u32(int n) { return SonyMobileSession.u32(n); }
    static byte[] string(String s, boolean nul) throws Exception {
        String encoded = s + (nul ? "\0" : "");
        return cat(new byte[]{(byte)encoded.length()}, encoded.getBytes("UTF-16LE"));
    }
    static byte[] objectInfo(String name,int size) throws Exception {
        return cat(u32(65537),u16(0x3801),u16(0),u32(size),new byte[40],string(name,true),string("20261109T233000",true),string("",true),string("",true));
    }
    enum Case { NORMAL, REJECT_PRESS, WRONG_TRANSACTION, STOP_HALF, MALFORMED_PROPERTIES, MISSING_CONTROLS, READONLY_ZVE10_PROBE, IMPORT_NO_CAPTURE, ZVE10_REMOTE_PROBE, ZVE10_STORAGE_PROBE, ZVE10_CONTENTS_PROBE, ZVE10_CONTENTS_REJECTED, ZVE10_FILES, ZVE10_WHOLE, ZVE10_CAPTURE }
    static void controls(Case scenario) throws Exception {
        boolean failHalfPress=scenario==Case.REJECT_PRESS, wrongTransaction=scenario==Case.WRONG_TRANSACTION, stopAfterHalf=scenario==Case.STOP_HALF;
        List<String> buttons = Collections.synchronizedList(new ArrayList<>());
        List<String> modes = Collections.synchronizedList(new ArrayList<>());
        AtomicReference<Throwable> serverFailure = new AtomicReference<>();
        AtomicReference<SonyTetherSession> clientRef = new AtomicReference<>();
        try (ServerSocket server = new ServerSocket(0, 2, InetAddress.getLoopbackAddress())) {
            Thread worker = new Thread(() -> {
                try (Socket cmd = server.accept()) {
                    cmd.setSoTimeout(5000);
                    if (SonyMobileSession.readPacket(cmd, 4096).type != 1) throw new AssertionError("Missing init");
                    SonyMobileSession.writePacket(cmd, 2, cat(u32(3), new byte[20]));
                    try (Socket events = server.accept()) {
                        if (SonyMobileSession.readPacket(events, 32).type != 3) throw new AssertionError("Missing event init");
                        SonyMobileSession.writePacket(events, 4, new byte[0]);
                        int lists=0;
                        while (true) {
                            SonyMobileSession.Packet packet;
                            try { packet = SonyMobileSession.readPacket(cmd, 1024); } catch (EOFException done) { break; }
                            SonyMobileSession.Reader r = new SonyMobileSession.Reader(packet.bytes);
                            int phase = r.i32(), op = r.u16(), tid = r.i32();
                            if (packet.type != 6) throw new AssertionError("Missing operation request");
                            if(scenario==Case.READONLY_ZVE10_PROBE && op!=0x1001) throw new AssertionError("Probe changed device state");
                            byte[] data = null; int code = 0x2001;
                            if (op == 0x1001) {
                                boolean legacy=scenario.name().startsWith("ZVE10_");
                                int[] ops = legacy ? new int[]{0x1001,0x1002,0x1004,0x1007,0x1008,0x1009,0x101b,0x9201,0x9202,0x9207,0x9209,0x9212}
                                    : new int[]{0x1001,0x1002,0x9201,0x9202,0x9207,0x9209,0x923c,0x923d};
                                ByteArrayOutputStream operations = new ByteArrayOutputStream(); operations.write(u32(ops.length));
                                for (int value : ops) operations.write(u16(value));
                                data = cat(u16(100), u32(17), u16(100), string("Sony", true), u16(0), operations.toByteArray(), new byte[16],
                                    string("Sony Corporation", true), string(scenario==Case.READONLY_ZVE10_PROBE || legacy?"ZV-E10":"ILCE-7CM2", true), string(legacy?"2.02":"2.00", true), string("test", true));
                            } else if(op==0x9212 && scenario.name().startsWith("ZVE10_CONTENTS_")) {
                                if(r.i32()!=2) throw new AssertionError("Wrong contents-mode selector");
                                int enabled=r.i32(),release=r.i32();
                                if(enabled==1 && release==0 && modes.isEmpty()) modes.add("enter");
                                else if(enabled==0 && release==1 && modes.equals(Arrays.asList("enter"))) modes.add("exit");
                                else throw new AssertionError("Wrong contents-mode transition");
                            } else if(op==0x1004 && scenario.name().startsWith("ZVE10_")) {
                                data=cat(u32(1),u32(0x10001));
                                if(scenario==Case.ZVE10_CONTENTS_REJECTED) { data=null;code=0x2013; }
                            } else if(op==0x1007 && (scenario==Case.ZVE10_FILES || scenario==Case.ZVE10_WHOLE)) {
                                if(r.i32()!=65537 || r.i32()!=0 || r.i32()!=0 || r.remaining()!=0) throw new AssertionError("Wrong object enumeration");
                                data=cat(u32(1),u32(7));
                            } else if(op==0x1008 && (scenario==Case.ZVE10_FILES || scenario==Case.ZVE10_WHOLE)) {
                                if(r.i32()!=7 || r.remaining()!=0) throw new AssertionError("Wrong object identity");
                                data=objectInfo("DSC00007.JPG",4);
                            } else if(op==0x101b && scenario==Case.ZVE10_FILES) {
                                if(r.i32()!=7 || r.i32()!=0 || r.i32()!=4 || r.remaining()!=0) throw new AssertionError("Wrong partial download bounds");
                                data=new byte[]{(byte)255,(byte)216,(byte)255,(byte)217};
                            } else if(op==0x1009 && scenario==Case.ZVE10_WHOLE) {
                                if(r.i32()!=7 || r.remaining()!=0) throw new AssertionError("Wrong whole object identity");
                                data=new byte[]{(byte)255,(byte)216,(byte)255,(byte)217};
                            } else if (op == 0x9202) {
                                data = scenario==Case.MISSING_CONTROLS ? cat(u16(0x12c),u32(1),u16(0xd222),u32(0))
                                    : cat(u16(0x12c), u32(0), u32(2), u16(0xd2c1), u16(0xd2c2));
                            } else if (op == 0x9209) {
                                if(scenario==Case.ZVE10_REMOTE_PROBE && r.remaining()!=0) throw new AssertionError("Legacy property read must omit mode parameter");
                                data = cat(u32(2), u32(0), u16(0xd222), u16(4), new byte[]{1,1}, u16(16), u16(17), new byte[]{0},
                                    u16(0x5013), u16(4), new byte[]{1,1}, u16(1), u16(1), new byte[]{0});
                                if(scenario==Case.ZVE10_REMOTE_PROBE) data=cat(u32(2),u32(0),u16(0xd222),u16(4),new byte[]{1,1},u16(16),u16(17),new byte[]{2},
                                    u16(2),u16(16),u16(17),u16(2),u16(16),u16(17),u16(0x5013),u16(4),new byte[]{1,1},u16(1),u16(1),new byte[]{0});
                                if(scenario==Case.MALFORMED_PROPERTIES) data=Arrays.copyOf(data,data.length-2);
                                if(scenario==Case.ZVE10_CAPTURE) data=cat(u32(2),u32(0),u16(0xd222),u16(4),new byte[]{1,1},u16(1),u16(1),new byte[]{0},
                                    u16(0x5013),u16(4),new byte[]{1,1},u16(1),u16(1),new byte[]{0});
                            } else if (op == 0x923c) {
                                if(lists++==0) code=0x2005; else data=new byte[148];
                            } else if (op == 0x9207) {
                                int control = r.i32();
                                if (phase != 2) throw new AssertionError("Control lacks outbound data phase");
                                SonyMobileSession.Packet start = SonyMobileSession.readPacket(cmd, 32), end = SonyMobileSession.readPacket(cmd, 32);
                                SonyMobileSession.Reader sr = new SonyMobileSession.Reader(start.bytes), er = new SonyMobileSession.Reader(end.bytes);
                                if (start.type != 9 || sr.i32() != tid || sr.i64() != 2 || end.type != 12 || er.i32() != tid)
                                    throw new AssertionError("Bad control data framing");
                                int value = er.u16(); buttons.add(String.format("%04x:%d",control,value));
                                if (r.remaining() != 0 || er.remaining() != 0) throw new AssertionError("Unexpected control payload");
                                if (control == 0xd2c1 && value == 2 && failHalfPress) code = 0x2019;
                                if (control == 0xd2c1 && value == 2 && wrongTransaction) tid++;
                                if (control == 0xd2c1 && value == 2 && stopAfterHalf) clientRef.get().requestStop();
                            } else if (op != 0x1002 && op != 0x9201) throw new AssertionError("Unexpected write/operation " + op);
                            if (data != null) {
                                SonyMobileSession.writePacket(cmd, 9, cat(u32(tid),u32(data.length),u32(0)));
                                SonyMobileSession.writePacket(cmd, 12, cat(u32(tid),data));
                            }
                            SonyMobileSession.writePacket(cmd, 7, cat(u16(code),u32(tid)));
                        }
                    }
                } catch (Throwable failure) { serverFailure.set(failure); }
            });
            worker.start();
            SocketFactory factory = new SocketFactory() {
                public Socket createSocket() { return new Socket() {
                    public void connect(SocketAddress ignored, int timeout) throws IOException {
                        super.connect(new InetSocketAddress(InetAddress.getLoopbackAddress(),server.getLocalPort()),timeout);
                    }
                }; }
                public Socket createSocket(String h,int p) { throw new UnsupportedOperationException(); }
                public Socket createSocket(String h,int p,InetAddress l,int lp) { throw new UnsupportedOperationException(); }
                public Socket createSocket(InetAddress h,int p) { throw new UnsupportedOperationException(); }
                public Socket createSocket(InetAddress h,int p,InetAddress l,int lp) { throw new UnsupportedOperationException(); }
            };
            try (SonyTetherSession client = new SonyTetherSession(factory, InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {},scenario==Case.IMPORT_NO_CAPTURE?SonyTetherSession.Purpose.IMPORT:SonyTetherSession.Purpose.TETHER)) {
                clientRef.set(client);
                if(scenario==Case.READONLY_ZVE10_PROBE) {
                    SonyMobileSession.Device info=client.inspectDevice();
                    if(!info.model.equals("ZV-E10") || !info.firmware.equals("2.00") || !info.operations.contains(0x9207)) throw new AssertionError("Wrong probe result");
                }
                else if(scenario==Case.IMPORT_NO_CAPTURE) { client.connectRemote();rejects(client::capture); }
                else if(scenario==Case.ZVE10_REMOTE_PROBE) {
                    client.connectRemote(SonyTetherSession.Profile.ZVE10_2_02);
                    if(client.properties().get(0xd222).number()!=17) throw new AssertionError("Missing legacy properties");
                }
                else if(scenario==Case.ZVE10_STORAGE_PROBE) {
                    if(!client.probeLegacyStorage().equals(Arrays.asList(65537L))) throw new AssertionError("Wrong storage identifiers");
                }
                else if(scenario==Case.ZVE10_CAPTURE) {
                    client.connectRemote(SonyTetherSession.Profile.ZVE10_2_02);
                    rejects(client::capture);rejects(() -> client.captureWithConfirmedCardSaving(false));client.captureWithConfirmedCardSaving(true);
                }
                else if(scenario==Case.ZVE10_FILES || scenario==Case.ZVE10_WHOLE) {
                    client.connectRemote(SonyTetherSession.Profile.ZVE10_2_02);
                    List<SonyTetherSession.LegacyObject> files=client.listLegacyPhotos();
                    if(files.size()!=1 || !files.get(0).name.equals("DSC00007.JPG")) throw new AssertionError("Missing legacy original");
                    ByteArrayOutputStream original=new ByteArrayOutputStream();
                    if(scenario==Case.ZVE10_WHOLE) client.downloadLegacyWhole(files.get(0),original);else client.downloadLegacy(files.get(0),original);
                    if(original.size()!=4) throw new AssertionError("Legacy original incomplete");
                }
                else if(scenario.name().startsWith("ZVE10_CONTENTS_")) {
                    client.connectRemote(SonyTetherSession.Profile.ZVE10_2_02);
                    if(scenario==Case.ZVE10_CONTENTS_REJECTED) rejects(client::probeLegacyContentsStorage);
                    else if(!client.probeLegacyContentsStorage().equals(Arrays.asList(65537L))) throw new AssertionError("Wrong contents storage identifiers");
                    rejects(() -> client.captureWithConfirmedCardSaving(true));
                }
                else if(scenario==Case.MISSING_CONTROLS) rejects(client::connectRemote);
                else {
                    client.connectRemote();
                    if(scenario==Case.MALFORMED_PROPERTIES) {
                        rejects(client::properties);
                        rejects(client::listPhotos);
                        rejects(client::listPhotos);
                    } else {
                        try { client.listPhotos(); throw new AssertionError("Expected temporary contents rejection"); }
                        catch(SonyTetherSession.RemoteResponseException response) { if(response.operation!=0x923c || response.code!=0x2005) throw response; }
                        if(!client.listPhotos().isEmpty()) throw new AssertionError("Response rejection desynchronized the session");
                        if (failHalfPress || wrongTransaction || stopAfterHalf) rejects(client::capture); else client.capture();
                        if (wrongTransaction) rejects(client::properties);
                    }
                }
            }
            worker.join(6000);
            if (worker.isAlive()) throw new AssertionError("Responder leaked");
            if (serverFailure.get() != null) throw new AssertionError("Responder failed",serverFailure.get());
            List<String> expected = scenario==Case.MISSING_CONTROLS || scenario==Case.MALFORMED_PROPERTIES || scenario==Case.READONLY_ZVE10_PROBE || scenario==Case.IMPORT_NO_CAPTURE || scenario.name().startsWith("ZVE10_") && scenario!=Case.ZVE10_CAPTURE ? Collections.emptyList()
                : wrongTransaction ? Arrays.asList("d2c1:2") : failHalfPress || stopAfterHalf ? Arrays.asList("d2c1:2","d2c1:1")
                : Arrays.asList("d2c1:2","d2c2:2","d2c2:1","d2c1:1");
            if (!buttons.equals(expected)) throw new AssertionError("Unexpected shutter replay/release: " + buttons);
            if(scenario.name().startsWith("ZVE10_CONTENTS_") && !modes.equals(Arrays.asList("enter","exit"))) throw new AssertionError("Contents mode was not released: "+modes);
        }
    }
    public static void main(String[] args) throws Exception {
        SonyTetherSession.LegacyObject legacy=SonyTetherSession.parseLegacyObject(7,objectInfo("DSC00007.JPG",4));
        if(legacy.handle!=7 || legacy.storage!=65537 || legacy.size!=4 || !legacy.created.equals("20261109T233000")) throw new AssertionError("ObjectInfo fields lost");
        rejects(() -> SonyTetherSession.parseLegacyObject(7,Arrays.copyOf(objectInfo("DSC00007.JPG",4),53)));
        rejects(() -> SonyTetherSession.parseLegacyObject(7,objectInfo("../photo.JPG",4)));
        rejects(() -> SonyTetherSession.parseLegacyObject(7,cat(objectInfo("photo.JPG",4),new byte[1])));
        String url = "http://localhost:60152/liveviewstream?token=example";
        byte[] properties = cat(u32(2), u32(0),
            u16(0xd222), u16(4), new byte[]{1, 1}, u16(16), u16(17), new byte[]{2},
            u16(3), u16(1), u16(16), u16(17), u16(0),
            u16(0xd278), u16(0xffff), new byte[]{0, 1}, string("", true), string(url, false), new byte[]{0});
        Map<Integer, SonyTetherSession.Property> parsed = SonyTetherSession.parseProperties(properties);
        if (parsed.get(0xd222).number() != 17 || !url.equals(parsed.get(0xd278).text()))
            throw new AssertionError("Property values lost or non-NUL string rejected");
        byte[] legacyProperties=cat(u32(2),u32(0),u16(0x5013),u16(4),new byte[]{1,1},u16(1),u16(1),new byte[]{2},
            u16(2),u16(1),u16(2),u16(0xd222),u16(4),new byte[]{1,1},u16(16),u16(17),new byte[]{0});
        if(SonyTetherSession.parseProperties(legacyProperties,1).get(0xd222).number()!=17) throw new AssertionError("Legacy enum consumed next descriptor");
        rejects(() -> SonyTetherSession.parseProperties(Arrays.copyOf(properties, properties.length - 1)));
        rejects(() -> SonyTetherSession.parseProperties(cat(u32(10001), u32(0))));
        InetAddress camera = InetAddress.getByName("192.168.122.1");
        URL target = SonyTetherSession.liveViewURL(url, camera);
        if (!target.toString().equals("http://192.168.122.1:60152/liveviewstream?token=example"))
            throw new AssertionError("Live view was not bound to the camera");
        for (String invalid : Arrays.asList("https://localhost:60152/liveviewstream", "http://example.com:80/liveviewstream",
            "http://user@localhost:60152/liveviewstream", "http://localhost:60152/elsewhere", "http://localhost:60152/liveviewstream#secret"))
            rejects(() -> SonyTetherSession.liveViewURL(invalid, camera));
        byte[] jpeg = new byte[]{(byte)255, (byte)216, (byte)255, (byte)217};
        byte[] frame = cat(u32(16), u32(4), u32(20), u32(2), jpeg, new byte[]{5, 6});
        if (!Arrays.equals(jpeg, SonyTetherSession.readFrame(new ByteArrayInputStream(frame))))
            throw new AssertionError("Wrong JPEG extraction");
        rejects(() -> SonyTetherSession.readFrame(new ByteArrayInputStream(Arrays.copyOf(frame, frame.length - 1))));
        rejects(() -> SonyTetherSession.readFrame(new ByteArrayInputStream(cat(u32(16), u32(-1), u32(0), u32(0)))));
        rejects(() -> SonyTetherSession.readFrame(new ByteArrayInputStream(cat(u32(8), u32(4), u32(16), u32(0)))));
        rejects(() -> SonyTetherSession.readFrame(new ByteArrayInputStream(cat(u32(16), u32(4), u32(18), u32(4), jpeg, new byte[2]))));
        for(Case scenario:Case.values()) controls(scenario);
        System.out.println("Tether tests passed: bounded properties/frames/URL, control data framing, release on rejection, no retry after ambiguous response");
    }
}
