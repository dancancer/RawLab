package com.rawlab.android.camera.protocol;

import static org.junit.Assert.*;
import java.io.*;
import java.net.*;
import java.nio.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BiConsumer;
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

    @Test public void remoteTouchFocusRoutesPrimaryCancelRetryAndSpotFallback() throws Exception {
        // 1. Primary 0xD2E4 when 0xD284 == 1; 0xD285 == 1 exposes cancelTouchFocus
        try(FocusResponder responder=new FocusResponder(
                new int[]{0xd2c1,0xd2c2,0xd2e4,0xd2e5,0xd2dc},
                Arrays.asList(
                    FocusProp.u16(0x500a,true,1,2,2L,1L),
                    FocusProp.u16(0xd22c,true,1,0x0001,0x0001L,0x0102L),
                    FocusProp.u8(0xd284,false,1,1),
                    FocusProp.u8(0xd285,false,1,1)));
            SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote();
            Map<Integer,SonyTetherSession.Property> latest=session.setFocusPoint(160,120);
            assertEquals(1,responder.recorded9207.size());
            assertEquals(0xd2e4L,responder.recorded9207.get(0)[0]);
            assertEquals(((160L<<16)|120L),responder.recorded9207.get(0)[1]);
            assertTrue(session.canCancelTouchFocus(latest));
            session.close();responder.check();
        }

        // 2. Cancel-then-retry when 0xD284 == 0 and 0xD285 == 1
        try(FocusResponder responder=new FocusResponder(
                new int[]{0xd2c1,0xd2c2,0xd2e4,0xd2e5},
                Arrays.asList(
                    FocusProp.u16(0x500a,true,1,2,2L,1L),
                    FocusProp.u8(0xd284,false,1,0),
                    FocusProp.u8(0xd285,false,1,1)));
            SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            responder.on9207((control,val) -> {
                if(control==0xd2e5 && val==1L) {
                    responder.setProp(0xd284,1,1);
                    responder.setProp(0xd285,0,0);
                }
            });
            session.connectRemote();
            session.setFocusPoint(320,240);
            assertEquals(3,responder.recorded9207.size());
            assertArrayEquals(new long[]{0xd2e5L,2L},responder.recorded9207.get(0));
            assertArrayEquals(new long[]{0xd2e5L,1L},responder.recorded9207.get(1));
            assertArrayEquals(new long[]{0xd2e4L,(320L<<16)|240L},responder.recorded9207.get(2));
            session.close();responder.check();
        }

        // 3. Fallback 0xD2DC in Spot M (0x0102)
        try(FocusResponder responder=new FocusResponder(
                new int[]{0xd2c1,0xd2c2,0xd2dc},
                Arrays.asList(
                    FocusProp.u16(0x500a,true,1,2,2L,1L),
                    FocusProp.u16(0xd22c,true,1,0x0102,0x0001L,0x0002L,0x0102L)));
            SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote();
            session.setFocusPoint(400,100);
            assertEquals(1,responder.recorded9207.size());
            assertArrayEquals(new long[]{0xd2dcL,(400L<<16)|100L},responder.recorded9207.get(0));
            session.close();responder.check();
        }
    }

    @Test public void focusRejectionPreconditionsImportIsolationAndAlignedErrorsPreserveSession() throws Exception {
        // 1. Fixed focus areas reject with FOCUS_AREA_FIXED and 0 writes
        for(long fixed : new long[]{0x0001L,0x0003L,0x0201L,0x0203L}) {
            try(FocusResponder responder=new FocusResponder(
                    new int[]{0xd2c1,0xd2c2,0xd2dc},
                    Arrays.asList(
                        FocusProp.u16(0x500a,true,1,2,2L,1L),
                        FocusProp.u16(0xd22c,true,1,fixed,fixed,0x0102L)));
                SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
                session.connectRemote();
                SonyTetherSession.FocusUnavailableException ex=assertThrows(
                    SonyTetherSession.FocusUnavailableException.class,() -> session.setFocusPoint(100,100));
                assertEquals(SonyTetherSession.FocusUnavailableReason.FOCUS_AREA_FIXED,ex.reason);
                assertTrue(responder.recorded9207.isEmpty());
                session.close();responder.check();
            }
        }

        // 2. Manual focus (0x500A == 1) rejects with MANUAL_FOCUS and 0 writes
        try(FocusResponder responder=new FocusResponder(
                new int[]{0xd2c1,0xd2c2,0xd2dc},
                Arrays.asList(
                    FocusProp.u16(0x500a,true,1,1,1L,2L),
                    FocusProp.u16(0xd22c,true,1,0x0102,0x0102L)));
            SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote();
            SonyTetherSession.FocusUnavailableException ex=assertThrows(
                SonyTetherSession.FocusUnavailableException.class,() -> session.setFocusPoint(100,100));
            assertEquals(SonyTetherSession.FocusUnavailableReason.MANUAL_FOCUS,ex.reason);
            assertTrue(responder.recorded9207.isEmpty());
            session.close();responder.check();
        }

        // 3. Unsupported controls reject with UNSUPPORTED and 0 writes
        try(FocusResponder responder=new FocusResponder(
                new int[]{0xd2c1,0xd2c2},
                Collections.singletonList(FocusProp.u16(0x500a,true,1,2,2L)));
            SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote();
            SonyTetherSession.FocusUnavailableException ex=assertThrows(
                SonyTetherSession.FocusUnavailableException.class,() -> session.setFocusPoint(100,100));
            assertEquals(SonyTetherSession.FocusUnavailableReason.UNSUPPORTED,ex.reason);
            assertTrue(responder.recorded9207.isEmpty());
            session.close();responder.check();
        }

        // 4. Import purpose forbids tap-to-focus and 0xD22C writes with 0 writes
        try(FocusResponder responder=new FocusResponder(
                new int[]{0xd2c1,0xd2c2,0xd2e4,0xd2dc},
                Arrays.asList(
                    FocusProp.u8(0xd284,false,1,1),
                    FocusProp.u16(0xd22c,true,1,0x0001,0x0001L,0x0102L)));
            SonyTetherSession session=responder.session(SonyTetherSession.Purpose.IMPORT)) {
            session.connectRemote();
            assertThrows(SonyTetherSession.FocusUnavailableException.class,() -> session.setFocusPoint(100,100));
            assertThrows(IOException.class,() -> session.setNumericProperty(0xd22c,0x0102L));
            assertTrue(responder.recorded9207.isEmpty());
            assertTrue(responder.recorded9205.isEmpty());
            session.close();responder.check();
        }

        // 5. Aligned 0x9207 rejection keeps session open; failed cancelTouchFocus press still sends release=1
        try(FocusResponder responder=new FocusResponder(
                new int[]{0xd2c1,0xd2c2,0xd2e4,0xd2e5},
                Arrays.asList(
                    FocusProp.u16(0x500a,true,1,2,2L),
                    FocusProp.u8(0xd284,false,1,1),
                    FocusProp.u8(0xd285,false,1,1)));
            SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote();
            responder.setNext9207Status(0x2019);
            SonyTetherSession.FocusRejectedException rej=assertThrows(
                SonyTetherSession.FocusRejectedException.class,() -> session.setFocusPoint(100,100));
            assertEquals(0x2019,rej.code);
            assertTrue(session.isOpen());
            assertFalse(session.properties().isEmpty());

            responder.recorded9207.clear();
            responder.setNext9207Status(0x2005);
            SonyTetherSession.FocusRejectedException cancelRej=assertThrows(
                SonyTetherSession.FocusRejectedException.class,session::cancelTouchFocus);
            assertEquals(0x2005,cancelRej.code);
            assertTrue(session.isOpen());
            assertEquals(2,responder.recorded9207.size());
            assertArrayEquals(new long[]{0xd2e5L,2L},responder.recorded9207.get(0));
            assertArrayEquals(new long[]{0xd2e5L,1L},responder.recorded9207.get(1));
            session.close();responder.check();
        }
    }

    @Test public void focusArea0xD22CWritesUint16AndConfirmsReadback() throws Exception {
        try(FocusResponder responder=new FocusResponder(
                new int[]{0xd2c1,0xd2c2,0xd2dc},
                Arrays.asList(
                    FocusProp.u16(0x500a,true,1,2,2L,1L),
                    FocusProp.u16(0xd22c,true,1,0x0102,0x0001L,0x0002L,0x0102L)));
            SonyTetherSession session=responder.session(SonyTetherSession.Purpose.TETHER)) {
            session.connectRemote();
            SonyTetherSession.ParameterResult updated=session.setNumericProperty(0xd22c,0x0002L);
            assertTrue(updated.confirmed);
            assertEquals(0x0002L,updated.properties.get(0xd22c).number());
            assertEquals(1,responder.recorded9205.size());
            assertArrayEquals(new long[]{0xd22cL,0x0002L},responder.recorded9205.get(0));
            session.close();responder.check();
        }

        assertFalse(SonyTetherSession.isFocusLocked(null));
        assertFalse(SonyTetherSession.isFocusLocked(Collections.emptyMap()));
        long[][] focusCases={{1L,0L},{2L,1L},{3L,0L},{5L,0L},{6L,1L},{7L,0L}};
        for(long[] pair : focusCases) {
            byte[] raw=cat(u32(1),u32(0),u16(0xd213),u16(2),new byte[]{0,1,(byte)pair[0],(byte)pair[0],0});
            Map<Integer,SonyTetherSession.Property> props=SonyTetherSession.parseProperties(raw);
            assertEquals(pair[1]==1L,SonyTetherSession.isFocusLocked(props));
        }
    }

    @Test public void liveViewFrameReadWithMetadataAndParseLiveViewFrames() throws Exception {
        byte[] jpeg=new byte[]{(byte)0xff,(byte)0xd8,(byte)0xff,(byte)0xe0,1,2,(byte)0xff,(byte)0xd9};
        String a6700Hex=
            "68000200000000000100000000000000"+
            "0200000000000000fcfffffffbffffff"+
            "ff7f0000000000000000000000000000"+
            "000000000000000000000a0000800700"+
            "000000000000000000000a0000800700"+
            "000000000000000000000a0000800700"+
            "000000000000000000000a0000800700"+
            "00000000000000000000000000000000"+
            "0000000000000000";
        byte[] a6700Bytes=hexToBytes(a6700Hex);
        assertEquals(136,a6700Bytes.length);
        assertTrue(SonyTetherSession.parseLiveViewFrames(a6700Bytes).isEmpty());

        byte[] framed=cat(u32(16),u32(jpeg.length),u32(16+jpeg.length),u32(a6700Bytes.length),jpeg,a6700Bytes);
        SonyTetherSession.LiveViewFrame parsedFrame=SonyTetherSession.readFrameWithMetadata(new ByteArrayInputStream(framed));
        assertArrayEquals(jpeg,parsedFrame.jpeg);
        assertArrayEquals(a6700Bytes,parsedFrame.metadata);

        byte[] emptyMetaFrame=cat(u32(16),u32(jpeg.length),u32(0),u32(0),jpeg);
        assertEquals(0,SonyTetherSession.readFrameWithMetadata(new ByteArrayInputStream(emptyMetaFrame)).metadata.length);

        byte[] v68=synthMeta(0x68);
        List<SonyTetherSession.LiveViewFocusFrame> frames68=SonyTetherSession.parseLiveViewFrames(v68);
        assertEquals(3,frames68.size());
        assertEquals(SonyTetherSession.LiveViewFrameKind.FOCUS,frames68.get(0).kind);
        assertEquals(0.1f,frames68.get(0).cx,1e-5f);
        assertEquals(0.4f,frames68.get(0).cy,1e-5f);
        assertEquals(0.06f,frames68.get(0).width,1e-5f);
        assertEquals(0.08f,frames68.get(0).height,1e-5f);
        assertTrue(frames68.get(0).focused);

        assertEquals(SonyTetherSession.LiveViewFrameKind.FACE,frames68.get(1).kind);
        assertEquals(0.3f,frames68.get(1).cx,1e-5f);
        assertEquals(0.8f,frames68.get(1).cy,1e-5f);
        assertEquals(0.12f,frames68.get(1).width,1e-5f);
        assertEquals(0.16f,frames68.get(1).height,1e-5f);
        assertTrue(frames68.get(1).focused);

        assertEquals(SonyTetherSession.LiveViewFrameKind.TRACKING,frames68.get(2).kind);
        assertEquals(0.5f,frames68.get(2).cx,1e-5f);
        assertEquals(0.1f,frames68.get(2).cy,1e-5f);
        assertEquals(0.03f,frames68.get(2).width,1e-5f);
        assertEquals(0.04f,frames68.get(2).height,1e-5f);
        assertFalse(frames68.get(2).focused);

        List<SonyTetherSession.LiveViewFocusFrame> frames64=SonyTetherSession.parseLiveViewFrames(synthMeta(0x64));
        assertEquals(1,frames64.size());
        assertEquals(SonyTetherSession.LiveViewFrameKind.FOCUS,frames64.get(0).kind);
        assertTrue(SonyTetherSession.parseLiveViewFrames(synthMeta(0x27)).isEmpty());
        assertTrue(SonyTetherSession.parseLiveViewFrames(Arrays.copyOf(v68,0x30)).isEmpty());

        byte[] oversized=v68.clone();
        oversized[0x28+8]=(byte)0xff; oversized[0x28+9]=(byte)0xff;
        assertTrue(SonyTetherSession.parseLiveViewFrames(oversized).isEmpty());

        ByteArrayOutputStream rectBoundsMeta=new ByteArrayOutputStream();
        rectBoundsMeta.write(u16(0x68)); rectBoundsMeta.write(new byte[0x28-2]);
        rectBoundsMeta.write(metaBlock(1,1,new int[0][]));
        rectBoundsMeta.write(metaBlock(100,50,new int[][]{{1,2,10,20,4,6},{1,2,50,25,51,6},{1,2,50,25,4,101}}));
        rectBoundsMeta.write(metaBlock(100,50,new int[0][]));
        rectBoundsMeta.write(metaBlock(100,50,new int[0][]));
        List<SonyTetherSession.LiveViewFocusFrame> filtered=SonyTetherSession.parseLiveViewFrames(rectBoundsMeta.toByteArray());
        assertEquals(1,filtered.size());
        assertEquals(0.1f,filtered.get(0).cx,1e-5f);
    }

    private static byte[] hexToBytes(String hex) {
        byte[] out=new byte[hex.length()/2];
        for(int i=0;i<out.length;i++) out[i]=(byte)Integer.parseInt(hex.substring(i*2,i*2+2),16);
        return out;
    }

    private static byte[] metaBlock(long xMax,long yMax,int[][] entries) throws IOException {
        ByteArrayOutputStream out=new ByteArrayOutputStream();
        out.write(u32((int)xMax)); out.write(u32((int)yMax)); out.write(u16(entries.length)); out.write(new byte[6]);
        for(int[] e : entries) {
            out.write(u16(e[0])); out.write(u16(e[1])); out.write(u32(0));
            out.write(u32(e[2])); out.write(u32(e[3])); out.write(u32(e[4])); out.write(u32(e[5]));
        }
        return out.toByteArray();
    }

    private static byte[] synthMeta(int version) throws IOException {
        ByteArrayOutputStream out=new ByteArrayOutputStream();
        out.write(u16(version)); out.write(new byte[0x28-2]);
        out.write(metaBlock(1,1,new int[0][]));
        out.write(metaBlock(100,50,new int[][]{{1,2,10,20,4,6}}));
        if(version>0x64) {
            out.write(metaBlock(100,50,new int[][]{{2,1,30,40,8,12}}));
            out.write(metaBlock(100,50,new int[][]{{5,1,50,5,2,3}}));
        }
        return out.toByteArray();
    }

    private static final class FocusProp {
        final int code,type; final boolean writable; volatile int enabled; volatile long value; final List<Long> choices;
        FocusProp(int code,int type,boolean writable,int enabled,long value,long... choices) {
            this.code=code;this.type=type;this.writable=writable;this.enabled=enabled;this.value=value;
            List<Long> list=new ArrayList<>();for(long c : choices) list.add(c);this.choices=list;
        }
        static FocusProp u8(int code,boolean writable,int enabled,long value) { return new FocusProp(code,2,writable,enabled,value); }
        static FocusProp u16(int code,boolean writable,int enabled,long value,long... choices) { return new FocusProp(code,4,writable,enabled,value,choices); }
    }

    private static final class FocusResponder implements AutoCloseable {
        final ServerSocket server=new ServerSocket(0,2,InetAddress.getLoopbackAddress());
        final AtomicReference<Throwable> failure=new AtomicReference<>(); final Thread worker;
        final List<long[]> recorded9207=new CopyOnWriteArrayList<>();
        final List<long[]> recorded9205=new CopyOnWriteArrayList<>();
        final Map<Integer,FocusProp> props=Collections.synchronizedMap(new LinkedHashMap<>());
        final int[] controls;
        volatile int next9207Status=-1;
        volatile BiConsumer<Integer,Long> on9207Hook;

        FocusResponder(int[] controls,List<FocusProp> initialProps) throws IOException {
            this.controls=controls;
            for(FocusProp p : initialProps) props.put(p.code,p);
            worker=new Thread(() -> {
                try(Socket command=server.accept()) {
                    command.setSoTimeout(5000);assertEquals(1,SonyMobileSession.readPacket(command,4096).type);
                    SonyMobileSession.writePacket(command,2,cat(u32(1),new byte[20]));
                    try(Socket event=server.accept()) {
                        assertEquals(3,SonyMobileSession.readPacket(event,4096).type);SonyMobileSession.writePacket(event,4,new byte[0]);
                        while(true) {
                            SonyMobileSession.Packet packet;try { packet=SonyMobileSession.readPacket(command,4096); } catch(EOFException done) { break; }
                            assertEquals(6,packet.type);SonyMobileSession.Reader r=new SonyMobileSession.Reader(packet.bytes);
                            int phase=r.i32(),op=r.u16(),tid=r.i32();byte[] data=null;int status=0x2001;
                            if(op==0x1001) {
                                int[] codes={0x1001,0x1002,0x9201,0x9202,0x9205,0x9207,0x9209,0x923c,0x923d};
                                ByteArrayOutputStream ops=new ByteArrayOutputStream();ops.write(u32(codes.length));for(int code:codes) ops.write(u16(code));
                                data=cat(u16(100),u32(17),u16(100),text("Sony"),u16(0),ops.toByteArray(),new byte[16],text("Sony Corporation"),text("ILCE-7CM2"),text("2.00"),text("fixture"));
                            } else if(op==0x9202) {
                                ByteArrayOutputStream d=new ByteArrayOutputStream();
                                d.write(u16(0x12c));d.write(u32(0));
                                d.write(u32(controls.length));for(int c : controls) d.write(u16(c));
                                data=d.toByteArray();
                            } else if(op==0x9209) {
                                synchronized(props) {
                                    ByteArrayOutputStream out=new ByteArrayOutputStream();
                                    out.write(u32(props.size()));out.write(u32(0));
                                    for(FocusProp p : props.values()) {
                                        out.write(u16(p.code));out.write(u16(p.type));
                                        out.write(new byte[]{(byte)(p.writable?1:0),(byte)p.enabled});
                                        writeScalar(out,p.type,p.value);writeScalar(out,p.type,p.value);
                                        if(p.choices.isEmpty()) out.write(new byte[]{0});
                                        else {
                                            out.write(new byte[]{2});
                                            for(int t=0;t<2;t++) {
                                                out.write(u16(p.choices.size()));
                                                for(long c : p.choices) writeScalar(out,p.type,c);
                                            }
                                        }
                                    }
                                    data=out.toByteArray();
                                }
                            } else if(op==0x9207 || op==0x9205) {
                                assertEquals(2,phase);int target=r.i32();assertEquals(0,r.remaining());
                                SonyMobileSession.Packet start=SonyMobileSession.readPacket(command,4096);assertEquals(9,start.type);
                                SonyMobileSession.Reader sr=new SonyMobileSession.Reader(start.bytes);assertEquals(tid,sr.i32());long len=sr.i64();
                                SonyMobileSession.Packet end=SonyMobileSession.readPacket(command,4096);assertEquals(12,end.type);
                                SonyMobileSession.Reader er=new SonyMobileSession.Reader(end.bytes);assertEquals(tid,er.i32());
                                byte[] payload=er.take((int)len);assertEquals(0,er.remaining());
                                long val=len>=4?ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN).getInt()&0xffffffffL
                                    :(len>=2?ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN).getShort()&0xffffL:payload[0]&0xffL);
                                if(op==0x9207) {
                                    recorded9207.add(new long[]{target&0xffffffffL,val});
                                    int override=next9207Status;
                                    if(override!=-1) { next9207Status=-1;status=override; }
                                    else if(on9207Hook!=null) on9207Hook.accept(target,val);
                                } else {
                                    recorded9205.add(new long[]{target&0xffffffffL,val});
                                    FocusProp p=props.get(target);if(p!=null) p.value=val;
                                }
                            } else if(op!=0x1002 && op!=0x9201) throw new AssertionError("Unexpected operation 0x"+Integer.toHexString(op));
                            if(data!=null) { SonyMobileSession.writePacket(command,9,cat(u32(tid),u32(data.length),u32(0)));SonyMobileSession.writePacket(command,12,cat(u32(tid),data)); }
                            SonyMobileSession.writePacket(command,7,cat(u16(status),u32(tid)));
                        }
                    }
                } catch(Throwable error) { failure.set(error); }
            });worker.start();
        }
        private static void writeScalar(ByteArrayOutputStream out,int type,long value) throws IOException {
            if(type==2) out.write((byte)value);
            else if(type==6) out.write(u32((int)value));
            else out.write(u16((int)value));
        }
        void setProp(int code,long value,int enabled) { synchronized(props) { FocusProp p=props.get(code);if(p!=null) { p.value=value;p.enabled=enabled; } } }
        void setNext9207Status(int status) { next9207Status=status; }
        void on9207(BiConsumer<Integer,Long> hook) { on9207Hook=hook; }
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
