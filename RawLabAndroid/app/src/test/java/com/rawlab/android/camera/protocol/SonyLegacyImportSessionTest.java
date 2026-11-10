package com.rawlab.android.camera.protocol;

import static org.junit.Assert.*;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import javax.net.SocketFactory;
import org.junit.Test;

public class SonyLegacyImportSessionTest {
    private static byte[] cat(byte[]... values) throws IOException { ByteArrayOutputStream out=new ByteArrayOutputStream();for(byte[] value:values) out.write(value);return out.toByteArray(); }
    private static byte[] u16(int value) { return SonyMobileSession.u16(value); }
    private static byte[] u32(int value) { return SonyMobileSession.u32(value); }
    private static byte[] text(String value) throws IOException { return cat(new byte[]{(byte)(value.length()+1)},(value+"\0").getBytes("UTF-16LE")); }
    private static final byte[] RAW={73,73,42,0,8,0,0,0};
    private static final byte[] PREVIEW={(byte)255,(byte)216,(byte)255,(byte)217};

    @Test public void standardImportUsesOriginalAndThumbnailWithoutShutterCommands() throws Exception {
        try(Responder responder=new Responder("2.02");SonyLegacyImportSession session=new SonyLegacyImportSession(responder.factory(),InetAddress.getLoopbackAddress(),UUID.randomUUID(),m -> {})) {
            SonyMobileSession.Device device=session.deviceInfo();session.openSession();
            List<SonyMobileSession.Asset> photos=session.listPhotos(device);assertEquals(1,photos.size());
            SonyMobileSession.Asset photo=photos.get(0);assertEquals("DSC00007.ARW",photo.name);
            assertTrue(photo.created>0);assertEquals(8,photo.size);
            assertArrayEquals(PREVIEW,session.preview(photo,false));
            List<Long> progress=new ArrayList<>();ByteArrayOutputStream bytes=new ByteArrayOutputStream();
            String hash=session.download(device,photo,bytes,(done,total) -> { assertEquals(8,total);progress.add(done); });
            assertArrayEquals(RAW,bytes.toByteArray());assertEquals(64,hash.length());assertEquals(Long.valueOf(8),progress.get(progress.size()-1));
            assertThrows(IOException.class,() -> session.preview(new SonyMobileSession.Asset(new Object(),65537,7,"DSC00007.ARW",8,photo.created),false));
            session.close();responder.check();
            assertTrue(responder.operations.containsAll(Arrays.asList(0x1007,0x1008,0x1009,0x100a)));
            assertFalse(responder.operations.contains(0x9207));
        }
    }

    @Test public void unverifiedFirmwareUsesTheKnownProtocolAndAdvertisedOperations() throws Exception {
        try(Responder responder=new Responder("9.99");SonyLegacyImportSession session=new SonyLegacyImportSession(responder.factory(),InetAddress.getLoopbackAddress(),UUID.randomUUID(),m -> {})) {
            SonyMobileSession.Device device=session.deviceInfo();
            assertEquals("9.99",device.firmware);
            session.openSession();assertEquals(1,session.listPhotos(device).size());
            session.close();responder.check();
            assertFalse(responder.operations.contains(0x9207));
        }
    }

    @Test public void refreshingContentsCannotRebindAnOldAsset() throws Exception {
        try(Responder responder=new Responder("2.02");SonyLegacyImportSession session=new SonyLegacyImportSession(responder.factory(),InetAddress.getLoopbackAddress(),UUID.randomUUID(),m -> {})) {
            SonyMobileSession.Device device=session.deviceInfo();session.openSession();
            SonyMobileSession.Asset old=session.listPhotos(device).get(0);
            SonyMobileSession.Asset fresh=session.listPhotos(device).get(0);
            int before=responder.operations.size();
            assertThrows(IOException.class,() -> session.preview(old,false));
            assertEquals(before,responder.operations.size());
            assertArrayEquals(PREVIEW,session.preview(fresh,false));
            session.close();responder.check();
        }
    }

    @Test public void finishLeavesContentsBeforeClosingAndCannotBeReused() throws Exception {
        try(Responder responder=new Responder("2.02");SonyLegacyImportSession session=new SonyLegacyImportSession(responder.factory(),InetAddress.getLoopbackAddress(),UUID.randomUUID(),m -> {})) {
            SonyMobileSession.Device device=session.deviceInfo();session.openSession();
            session.listPhotos(device);session.finish();
            responder.check();
            assertEquals(Arrays.asList("2:1:0","2:0:1"),responder.contents);
            assertThrows(IOException.class,() -> session.listPhotos(device));
        }
    }

    @Test public void legacyTransportRejectsASeparateObjectWithTheSameMetadata() throws Exception {
        try(Responder responder=new Responder("2.02");SonyTetherSession session=new SonyTetherSession(responder.factory(),InetAddress.getLoopbackAddress(),UUID.randomUUID(),m -> {})) {
            session.connectRemote(SonyTetherSession.Profile.ZVE10_2_02);session.enterLegacyContents();
            SonyTetherSession.LegacyObject own=session.listLegacyPhotos().get(0);
            SonyTetherSession.LegacyObject foreign=new SonyTetherSession.LegacyObject(own.handle,own.storage,own.format,own.size,own.name,own.created,own.modified);
            int before=responder.operations.size();
            assertThrows(IOException.class,() -> session.previewLegacy(foreign));
            assertThrows(IOException.class,() -> session.downloadLegacyWhole(foreign,new ByteArrayOutputStream()));
            assertEquals(before,responder.operations.size());
            assertArrayEquals(PREVIEW,session.previewLegacy(own));
            session.close();responder.check();
        }
    }

    private static class Responder implements AutoCloseable {
        final ServerSocket server=new ServerSocket(0,2,InetAddress.getLoopbackAddress());
        final List<Integer> operations=Collections.synchronizedList(new ArrayList<>());
        final List<String> contents=Collections.synchronizedList(new ArrayList<>());
        final AtomicReference<Throwable> error=new AtomicReference<>();final Thread worker;
        Responder(String firmware) throws IOException {
            worker=new Thread(() -> {
                try(Socket command=server.accept()) {
                    command.setSoTimeout(5000);assertEquals(1,SonyMobileSession.readPacket(command,4096).type);
                    SonyMobileSession.writePacket(command,2,cat(u32(1),new byte[20]));
                    try(Socket event=server.accept()) {
                        assertEquals(3,SonyMobileSession.readPacket(event,4096).type);SonyMobileSession.writePacket(event,4,new byte[0]);
                        while(true) {
                            SonyMobileSession.Packet packet;try { packet=SonyMobileSession.readPacket(command,4096); } catch(EOFException end) { break; }
                            SonyMobileSession.Reader r=new SonyMobileSession.Reader(packet.bytes);assertEquals(1,r.i32());int op=r.u16(),tid=r.i32();operations.add(op);
                            byte[] data=null;
                            if(op==0x1001) {
                                int[] supported={0x1001,0x1002,0x1004,0x1007,0x1008,0x1009,0x100a,0x9201,0x9202,0x9207,0x9209,0x9212};
                                ByteArrayOutputStream ops=new ByteArrayOutputStream();ops.write(u32(supported.length));for(int value:supported) ops.write(u16(value));
                                data=cat(u16(100),u32(17),u16(100),text("Sony"),u16(0),ops.toByteArray(),new byte[16],text("Sony Corporation"),text("ZV-E10"),text(firmware),text("serial"));
                            } else if(op==0x9202) data=cat(u16(0x12c),u32(0),u32(2),u16(0xd2c1),u16(0xd2c2));
                            else if(op==0x1004) data=cat(u32(1),u32(65537));
                            else if(op==0x1007) { assertEquals(65537,r.i32());assertEquals(0,r.i32());assertEquals(0,r.i32());data=cat(u32(1),u32(7)); }
                            else if(op==0x1008) { assertEquals(7,r.i32());data=cat(u32(65537),u16(0xb101),u16(0),u32(RAW.length),new byte[40],text("DSC00007.ARW"),text("20261109T230000"),text(""),text("")); }
                            else if(op==0x1009) { assertEquals(7,r.i32());data=RAW; }
                            else if(op==0x100a) { assertEquals(7,r.i32());data=PREVIEW; }
                            else if(op==0x9212) contents.add(r.i32()+":"+r.i32()+":"+r.i32());
                            else if(op!=0x1002 && op!=0x9201 && op!=0x9212) throw new AssertionError("Import sent unexpected operation "+op);
                            if(data!=null) {
                                SonyMobileSession.writePacket(command,9,cat(u32(tid),u32(data.length),u32(0)));
                                SonyMobileSession.writePacket(command,12,cat(u32(tid),data));
                            }
                            SonyMobileSession.writePacket(command,7,cat(u16(0x2001),u32(tid)));
                        }
                    }
                } catch(Throwable failure) { error.set(failure); }
            });worker.start();
        }
        SocketFactory factory() { return new SocketFactory() {
            public Socket createSocket() { return new Socket() { @Override public void connect(SocketAddress ignored,int timeout) throws IOException { super.connect(new InetSocketAddress(InetAddress.getLoopbackAddress(),server.getLocalPort()),timeout); } }; }
            public Socket createSocket(String h,int p) { throw new UnsupportedOperationException(); }
            public Socket createSocket(String h,int p,InetAddress l,int lp) { throw new UnsupportedOperationException(); }
            public Socket createSocket(InetAddress h,int p) { throw new UnsupportedOperationException(); }
            public Socket createSocket(InetAddress h,int p,InetAddress l,int lp) { throw new UnsupportedOperationException(); }
        }; }
        void check() throws Exception { worker.join(6000);assertFalse("Responder leaked",worker.isAlive());if(error.get()!=null) throw new AssertionError(error.get()); }
        public void close() throws Exception { server.close();worker.join(6000); }
    }
}
