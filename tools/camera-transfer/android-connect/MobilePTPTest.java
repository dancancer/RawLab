package com.rawlab.android.camera.protocol;

import java.io.*;
import java.net.*;
import java.util.*;
import javax.net.SocketFactory;

public final class MobilePTPTest {
    private static byte[] concat(byte[]... pieces) throws IOException { ByteArrayOutputStream b = new ByteArrayOutputStream(); for (byte[] p : pieces) b.write(p); return b.toByteArray(); }
    private static byte[] text(String value) throws IOException { return concat(new byte[]{(byte)(value.length() + 1)}, (value + "\0").getBytes("UTF-16LE")); }
    private static void exercise(boolean wrongTransaction) throws Exception {
        try (ServerSocket server = new ServerSocket(0, 2, InetAddress.getLoopbackAddress())) {
            Thread responder = new Thread(() -> {
                try (Socket command = server.accept()) {
                    SonyMobileSession.Packet init = SonyMobileSession.readPacket(command, 1024);
                    if (init.type != 1) throw new AssertionError("Expected command init");
                    SonyMobileSession.writePacket(command, 2, concat(SonyMobileSession.u32(7), new byte[20]));
                    try (Socket event = server.accept()) {
                        SonyMobileSession.Packet e = SonyMobileSession.readPacket(event, 32);
                        if (e.type != 3 || new SonyMobileSession.Reader(e.bytes).i32() != 7) throw new AssertionError("Wrong event connection id");
                        SonyMobileSession.writePacket(event, 4, new byte[0]);
                        SonyMobileSession.Packet request = SonyMobileSession.readPacket(command, 128);
                        SonyMobileSession.Reader r = new SonyMobileSession.Reader(request.bytes);
                        if (request.type != 6 || r.i32() != 1 || r.u16() != 0x1001) throw new AssertionError("Wrong device-info request");
                        int tid = r.i32() + (wrongTransaction ? 1 : 0);
                        byte[] data = concat(SonyMobileSession.u16(100), SonyMobileSession.u32(17), SonyMobileSession.u16(100), text("Sony"), SonyMobileSession.u16(0),
                            SonyMobileSession.u32(1), SonyMobileSession.u16(0x1001), new byte[16], text("Sony Corporation"), text("ILCE-7CM2"), text("2.00"), text("test"));
                        SonyMobileSession.writePacket(command, 9, concat(SonyMobileSession.u32(tid), SonyMobileSession.u32(data.length), SonyMobileSession.u32(0)));
                        SonyMobileSession.writePacket(command, 12, concat(SonyMobileSession.u32(tid), data));
                        SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2001), SonyMobileSession.u32(tid)));
                        while (command.getInputStream().read() >= 0) {}
                    }
                } catch (IOException ignored) {}
            });
            responder.start();
            SocketFactory factory = new SocketFactory() {
                @Override public Socket createSocket() { return new Socket() {
                    @Override public void connect(SocketAddress ignored, int timeout) throws IOException { super.connect(new InetSocketAddress(InetAddress.getLoopbackAddress(), server.getLocalPort()), timeout); }
                }; }
                @Override public Socket createSocket(String h,int p) { throw new UnsupportedOperationException(); }
                @Override public Socket createSocket(String h,int p,InetAddress l,int lp) { throw new UnsupportedOperationException(); }
                @Override public Socket createSocket(InetAddress h,int p) { throw new UnsupportedOperationException(); }
                @Override public Socket createSocket(InetAddress h,int p,InetAddress l,int lp) { throw new UnsupportedOperationException(); }
            };
            try (SonyMobileSession client = new SonyMobileSession(factory, InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                try {
                    SonyMobileSession.Device info = client.deviceInfo();
                    if (wrongTransaction) throw new AssertionError("Accepted wrong transaction");
                    if (!info.model.equals("ILCE-7CM2")) throw new AssertionError("Wrong model");
                } catch (IOException error) { if (!wrongTransaction || !error.getMessage().contains("start data")) throw error; }
            }
            responder.join(2000);
            if (responder.isAlive()) throw new AssertionError("Responder leaked");
        }
    }
    public static void main(String[] args) throws Exception {
        exercise(false); exercise(true);
        try { new SonyMobileSession.Reader(new byte[]{3, 65}).ptpString(); throw new AssertionError("Accepted truncation"); } catch (EOFException expected) {}
        byte[] path = "/DCIM/100MSDCF/DSC00001.ARW\0".getBytes("UTF-8");
        byte[] contents = concat(new byte[144], SonyMobileSession.u32(1), SonyMobileSession.u32(1), SonyMobileSession.u32(9), new byte[20],
            SonyMobileSession.u32(1234), SonyMobileSession.u32(0), new byte[36], SonyMobileSession.u32(0), SonyMobileSession.u32(1), SonyMobileSession.u32(2),
            SonyMobileSession.u32(path.length), path, SonyMobileSession.u32(0), SonyMobileSession.u32(46280704), SonyMobileSession.u32(0), new byte[32], new byte[12]);
        SonyMobileSession.Page page = SonyMobileSession.parseContents(contents, null);
        if (page.count != 1 || page.cursor != 1234 || page.assets.size() != 1 || !page.assets.get(0).name.equals("DSC00001.ARW")
            || page.assets.get(0).size != 46280704) throw new AssertionError("Incorrect contents parser");
        try { SonyMobileSession.parseContents(Arrays.copyOf(contents, contents.length - 1), null); throw new AssertionError("Accepted truncated contents"); } catch (IOException expected) {}
        try { SonyMobileSession.parseContents(concat(new byte[144], SonyMobileSession.u32(101)), null); throw new AssertionError("Accepted excessive page"); } catch (IOException expected) {}
        System.out.println("MobilePTP tests passed: dual-channel handshake, device identity, transaction mismatch, contents parsing and bounds");
    }
}
