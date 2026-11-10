package com.rawlab.android.camera.protocol;

import static org.junit.Assert.*;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import javax.net.SocketFactory;
import org.junit.Test;

public class SonyCameraParameterTest {
    private static byte[] cat(byte[]... parts) throws IOException { ByteArrayOutputStream out=new ByteArrayOutputStream();for(byte[] part:parts) out.write(part);return out.toByteArray(); }
    private static byte[] u16(int n) { return SonyMobileSession.u16(n); }
    private static byte[] u32(int n) { return SonyMobileSession.u32(n); }
    private static byte[] text(String s) throws IOException { return cat(new byte[]{(byte)(s.length()+1)},(s+"\0").getBytes("UTF-16LE")); }
    private static byte[] properties(long current,boolean enabled) throws IOException {
        return cat(u32(2),u32(0),u16(0xd21e),u16(6),new byte[]{1,(byte)(enabled?1:2)},u32(100),u32((int)current),new byte[]{2},
            u16(3),u32(100),u32(200),u32(400),u16(4),u32(50),u32(100),u32(200),u32(400),
            u16(0x5010),u16(3),new byte[]{1,1},u16(0),u16(0),new byte[]{1},u16(-2000),u16(2000),u16(1000));
    }

    @Test public void onlySettableValuesAndAlignedSignedRangeValuesAreOffered() throws Exception {
        Map<Integer,SonyTetherSession.Property> map=SonyTetherSession.parseProperties(properties(100,true));
        assertEquals(Arrays.asList(100L,200L,400L),map.get(0xd21e).options());
        assertFalse(map.get(0xd21e).canSet(50));
        assertEquals(Arrays.asList(-2000L,-1000L,0L,1000L,2000L),map.get(0x5010).options());
        assertTrue(map.get(0x5010).canSet(-1000));assertFalse(map.get(0x5010).canSet(-1500));
        assertFalse(SonyTetherSession.parseProperties(properties(100,false)).get(0xd21e).canSet(200));
    }

    @Test public void valueIsWrittenOnceWithItsDescriptorTypeAndConfirmedByReadback() throws Exception {
        try(Responder responder=new Responder(true,true);SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote();
            SonyTetherSession.ParameterResult result=session.setNumericProperty(0xd21e,200);
            assertTrue(result.confirmed);assertEquals(200,result.properties.get(0xd21e).number());
            assertEquals(1,responder.writes);session.close();responder.check();
        }
    }

    @Test public void anAcknowledgementWithoutTheRequestedValueNeverRetriesTheWrite() throws Exception {
        try(Responder responder=new Responder(true,false);SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote();
            SonyTetherSession.ParameterResult result=session.setNumericProperty(0xd21e,200);
            assertFalse(result.confirmed);assertEquals(100,result.properties.get(0xd21e).number());
            assertEquals(1,responder.writes);session.close();responder.check();
        }
    }

    @Test public void staleOrIllegalChoicesAndUnrelatedSettingsNeverReachTheCamera() throws Exception {
        try(Responder responder=new Responder(false,true);SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote();
            assertThrows(IOException.class,() -> session.setNumericProperty(0xd21e,200));
            assertThrows(IOException.class,() -> session.setNumericProperty(0x5010,-1500));
            assertThrows(IOException.class,() -> session.setNumericProperty(0xd222,1));
            assertEquals(0,responder.writes);assertTrue(session.isOpen());session.close();responder.check();
        }
    }

    @Test public void importPurposeNeverWritesShootingParameters() throws Exception {
        try(Responder responder=new Responder(true,true);SonyTetherSession session=responder.session(SonyTetherSession.Purpose.IMPORT)) {
            session.connectRemote();
            assertThrows(IOException.class,() -> session.setNumericProperty(0xd21e,200));
            assertEquals(0,responder.writes);session.close();responder.check();
        }
    }

    @Test public void genericRemoteProfileAcceptsAnUnverifiedSonyIdentity() throws Exception {
        try(Responder responder=new Responder(true,true,"ILCE-7M4","1.00");
            SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote(SonyTetherSession.Profile.GENERIC);
            assertTrue(session.isRemoteReady());
            session.close(); responder.check();
        }
    }

    @Test public void knownModelWithoutShutterStillConnectsWithItsAdvertisedParameterCapabilities() throws Exception {
        try(Responder responder=new Responder(true,true,"ILCE-7CM2","2.00",false);
            SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote(SonyTetherSession.Profile.A7CII_2_00);
            assertTrue(session.isRemoteReady());
            assertFalse(session.supportsShutter());
            assertTrue(session.supportsParameterWrites());
            assertTrue(session.setNumericProperty(0xd21e,200).confirmed);
            session.close(); responder.check();
        }
    }

    @Test public void newFirmwareOnAKnownModelFallsBackToCapabilities() throws Exception {
        try(Responder responder=new Responder(true,true,"ILCE-7CM2","3.00");
            SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote(SonyTetherSession.Profile.A7CII_2_00);
            assertTrue(session.isRemoteReady());
            session.close();responder.check();
        }
    }

    @Test public void missingCapturePreconditionsAreReportedBeforeAnyShutterCommand() throws Exception {
        try(Responder responder=new Responder(true,true);
            SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote();
            assertThrows(SonyTetherSession.CaptureNotSentException.class,session::capture);
            assertEquals(0,responder.writes);
            session.close();responder.check();
        }
    }

    private static final class Responder implements AutoCloseable {
        final ServerSocket server=new ServerSocket(0,2,InetAddress.getLoopbackAddress());
        final AtomicReference<Throwable> failure=new AtomicReference<>();final Thread worker;
        final String model, firmware;
        volatile int writes;long current=100;
        Responder(boolean enabled,boolean apply) throws IOException { this(enabled,apply,"ILCE-7CM2","2.00"); }
        Responder(boolean enabled,boolean apply,String model,String firmware) throws IOException {
            this(enabled,apply,model,firmware,true);
        }
        Responder(boolean enabled,boolean apply,String model,String firmware,boolean shutter) throws IOException {
            this.model=model; this.firmware=firmware;
            worker=new Thread(() -> {
                try(Socket command=server.accept()) {
                    command.setSoTimeout(5000);assertEquals(1,SonyMobileSession.readPacket(command,4096).type);
                    SonyMobileSession.writePacket(command,2,cat(u32(1),new byte[20]));
                    try(Socket event=server.accept()) {
                        assertEquals(3,SonyMobileSession.readPacket(event,4096).type);SonyMobileSession.writePacket(event,4,new byte[0]);
                        while(true) {
                            SonyMobileSession.Packet packet;try { packet=SonyMobileSession.readPacket(command,4096); } catch(EOFException done) { break; }
                            assertEquals(6,packet.type);SonyMobileSession.Reader r=new SonyMobileSession.Reader(packet.bytes);
                            int phase=r.i32(),op=r.u16(),tid=r.i32();byte[] data=null;
                            if(op==0x1001) {
                                int[] codes=shutter ? new int[]{0x1001,0x1002,0x9201,0x9202,0x9205,0x9207,0x9209,0x923c,0x923d}
                                    : new int[]{0x1001,0x1002,0x9201,0x9202,0x9205,0x9209,0x923c,0x923d};
                                ByteArrayOutputStream ops=new ByteArrayOutputStream();ops.write(u32(codes.length));for(int code:codes) ops.write(u16(code));
                                data=cat(u16(100),u32(17),u16(100),text("Sony"),u16(0),ops.toByteArray(),new byte[16],text("Sony Corporation"),text(model),text(firmware),text("fixture"));
                            } else if(op==0x9202) data=cat(u16(0x12c),u32(0),u32(2),u16(0xd2c1),u16(0xd2c2));
                            else if(op==0x9209) data=properties(current,enabled);
                            else if(op==0x9205) {
                                assertEquals(2,phase);assertEquals(0xd21e,r.i32());assertEquals(0,r.remaining());
                                SonyMobileSession.Packet start=SonyMobileSession.readPacket(command,4096);assertEquals(9,start.type);
                                SonyMobileSession.Reader sr=new SonyMobileSession.Reader(start.bytes);assertEquals(tid,sr.i32());assertEquals(4,sr.i64());
                                SonyMobileSession.Packet end=SonyMobileSession.readPacket(command,4096);assertEquals(12,end.type);
                                SonyMobileSession.Reader er=new SonyMobileSession.Reader(end.bytes);assertEquals(tid,er.i32());long value=er.u32();assertEquals(0,er.remaining());
                                assertEquals(200,value);writes++;if(apply) current=value;
                            } else if(op!=0x1002 && op!=0x9201) throw new AssertionError("Unexpected parameter operation "+op);
                            if(data!=null) { SonyMobileSession.writePacket(command,9,cat(u32(tid),u32(data.length),u32(0)));SonyMobileSession.writePacket(command,12,cat(u32(tid),data)); }
                            SonyMobileSession.writePacket(command,7,cat(u16(0x2001),u32(tid)));
                        }
                    }
                } catch(Throwable error) { failure.set(error); }
            });worker.start();
        }
        SonyTetherSession session(SonyTetherSession.Purpose purpose) throws IOException {
            SocketFactory factory=new SocketFactory() {
                public Socket createSocket() { return new Socket() { @Override public void connect(SocketAddress ignored,int timeout) throws IOException { super.connect(new InetSocketAddress(InetAddress.getLoopbackAddress(),server.getLocalPort()),timeout); } }; }
                public Socket createSocket(String h,int p) { throw new UnsupportedOperationException(); }
                public Socket createSocket(String h,int p,InetAddress a,int ap) { throw new UnsupportedOperationException(); }
                public Socket createSocket(InetAddress h,int p) { throw new UnsupportedOperationException(); }
                public Socket createSocket(InetAddress h,int p,InetAddress a,int ap) { throw new UnsupportedOperationException(); }
            };
            return new SonyTetherSession(factory,InetAddress.getLoopbackAddress(),UUID.randomUUID(),m -> {},purpose);
        }
        void check() throws Exception { worker.join(6000);assertFalse(worker.isAlive());if(failure.get()!=null) throw new AssertionError(failure.get()); }
        public void close() throws Exception { server.close();worker.join(6000); }
    }
}
