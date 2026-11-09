package com.rawlab.android.camera.protocol;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketAddress;
import java.net.SocketException;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.CopyOnWriteArrayList;

import javax.net.SocketFactory;

import org.junit.Test;

public final class SonyMobileSessionTest {
    private static final int CONTENT = 0x01020304;
    private static final int FILE = 0x1234;

    @Test
    public void previewUses923eLayoutAndReturnsFragmentedPayload() throws Exception {
        byte[] expected = new byte[]{0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77};
        try (FakeServer server = new FakeServer(command -> {
            Request request = readRequest(command);
            assertEquals(0x923e, request.operation);
            assertArrayEquals(new int[]{CONTENT, 0x01000000 | FILE, 2}, request.parameters);
            sendData(command, request.transaction, expected, 2, 3, 2);
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Asset asset = new SonyMobileSession.Asset(
                        session, CONTENT, FILE, "DSC00001.ARW", 100, 123);
                assertArrayEquals(expected, session.preview(asset, true));
            }
            server.finish();
        }
    }

    @Test
    public void previewUsesSmallSelectorForThumbnail() throws Exception {
        byte[] expected = new byte[]{0x01, 0x02, 0x03};
        try (FakeServer server = new FakeServer(command -> {
            Request request = readRequest(command);
            assertEquals(0x923e, request.operation);
            assertArrayEquals(new int[]{CONTENT, 0x01000000 | FILE, 1}, request.parameters);
            sendData(command, request.transaction, expected, 1, 2);
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Asset asset = new SonyMobileSession.Asset(
                        session, CONTENT, FILE, "DSC00001.ARW", 100, 123);
                assertArrayEquals(expected, session.preview(asset, false));
            }
            server.finish();
        }
    }

    @Test
    public void previewRejectsResponseAboveThumbnailBudget() throws Exception {
        assertPreviewBudgetIsEnforced(false, (2 << 20) + 1);
    }

    @Test
    public void previewRejectsResponseAboveLargeBudget() throws Exception {
        assertPreviewBudgetIsEnforced(true, (8 << 20) + 1);
    }

    private static void assertPreviewBudgetIsEnforced(boolean large, int declaredLength) throws Exception {
        try (FakeServer server = new FakeServer(command -> {
            Request request = readRequest(command);
            assertEquals(0x923e, request.operation);
            sendStart(command, request.transaction, declaredLength);
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Asset asset = new SonyMobileSession.Asset(
                        session, CONTENT, FILE, "DSC00001.ARW", 100, 123);
                try {
                    session.preview(asset, large);
                    fail("accepted preview response over budget");
                } catch (IOException expected) {
                    assertTrue(expected.getMessage(), expected.getMessage().contains("budget"));
                }
            }
            server.finish();
        }
    }

    @Test
    public void previewRejectsAssetOwnedByAnotherSessionBeforeWireRequest() throws Exception {
        AtomicBoolean currentRequestSeen = new AtomicBoolean();
        try (FakeServer foreignServer = new FakeServer(command -> waitForClose(command, null));
             FakeServer currentServer = new FakeServer(command -> waitForClose(command, currentRequestSeen))) {
            SonyMobileSession foreign = new SonyMobileSession(foreignServer.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {});
            SonyMobileSession current = new SonyMobileSession(currentServer.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {});
            try {
                SonyMobileSession.Asset foreignAsset = new SonyMobileSession.Asset(
                        foreign, CONTENT, FILE, "DSC00001.ARW", 100, 123);
                try {
                    current.preview(foreignAsset, false);
                    fail("accepted an asset from another session");
                } catch (IOException expected) {
                    assertTrue(expected.getMessage(), expected.getMessage().contains("session"));
                }
                assertFalse("foreign asset caused a wire operation", currentRequestSeen.get());
            } finally {
                current.close();
                foreign.close();
            }
            currentServer.finish();
            foreignServer.finish();
        }
    }

    @Test
    public void previewFailsWhenCameraDisconnectsMidTransfer() throws Exception {
        try (FakeServer server = new FakeServer(command -> {
            Request request = readRequest(command);
            assertEquals(0x923e, request.operation);
            sendStart(command, request.transaction, 6);
            SonyMobileSession.writePacket(command, 10,
                    concat(SonyMobileSession.u32(request.transaction), new byte[]{1, 2, 3}));
            command.close();
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Asset asset = new SonyMobileSession.Asset(
                        session, CONTENT, FILE, "DSC00001.ARW", 100, 123);
                try {
                    session.preview(asset, false);
                    fail("accepted a disconnected preview transfer");
                } catch (IOException expected) {
                    assertNotNull(expected);
                }
            }
            server.finish();
        }
    }

    @Test
    public void downloadReportsStructuredProgressForEveryChunk() throws Exception {
        byte[] photo = new byte[(3 << 20) + 4];
        photo[0] = 0x49;
        photo[1] = 0x49;
        photo[2] = 0x2a;
        photo[3] = 0x00;
        List<Long> transferred = new CopyOnWriteArrayList<>();
        try (FakeServer server = new FakeServer(command -> {
            Request download = readRequest(command);
            assertEquals(0x923d, download.operation);
            assertArrayEquals(new int[]{CONTENT, 0x01000000 | FILE, 0, 0, 3 << 20}, download.parameters);
            sendData(command, download.transaction, Arrays.copyOf(photo, 3 << 20), 3 << 20);

            Request remainder = readRequest(command);
            assertEquals(0x923d, remainder.operation);
            assertArrayEquals(new int[]{CONTENT, 0x01000000 | FILE, 3 << 20, 0, 4}, remainder.parameters);
            sendData(command, remainder.transaction, Arrays.copyOfRange(photo, 3 << 20, photo.length), 4);

            Request list = readRequest(command);
            assertEquals(0x923c, list.operation);
            assertArrayEquals(new int[]{0, 0, 100, 1, 0}, list.parameters);
            byte[] contents = contentsPage(CONTENT, FILE, "DSC00001.ARW", photo.length, 123);
            sendData(command, list.transaction, contents, 47, contents.length - 47);
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Asset asset = new SonyMobileSession.Asset(
                        session, CONTENT, FILE, "DSC00001.ARW", photo.length, 123);
                ByteArrayOutputStream output = new ByteArrayOutputStream();
                String digest = session.download(new SonyMobileSession.Device("Sony Corporation", "ILCE-7CM2",
                        "2.00", new java.util.HashSet<>(Arrays.asList(0x923c, 0x923d))), asset, output,
                        (bytes, total) -> {
                            assertEquals(photo.length, total);
                            transferred.add(bytes);
                        });
                assertArrayEquals(photo, output.toByteArray());
                assertEquals(64, digest.length());
            }
            server.finish();
        }
        assertEquals(Arrays.asList((long) (3 << 20), (long) photo.length), transferred);
    }

    @Test
    public void assetKeyIncludesNameToDistinguishRenamedLocator() throws Exception {
        SonyMobileSession.Asset first = new SonyMobileSession.Asset(null, CONTENT, FILE,
                "DSC00001.ARW", 100, 123);
        SonyMobileSession.Asset renamed = new SonyMobileSession.Asset(null, CONTENT, FILE,
                "DSC00002.ARW", 100, 123);
        assertFalse(first.key().equals(renamed.key()));
        assertTrue(first.key().contains(first.name));
        assertTrue(renamed.key().contains(renamed.name));
    }

    private static Request readRequest(Socket command) throws Exception {
        SonyMobileSession.Packet packet = SonyMobileSession.readPacket(command, 256);
        if (packet.type != 6) throw new AssertionError("expected command packet");
        SonyMobileSession.Reader reader = new SonyMobileSession.Reader(packet.bytes);
        if (reader.i32() != 1) throw new AssertionError("wrong command container");
        int operation = reader.u16();
        int transaction = reader.i32();
        int count = (reader.remaining()) / 4;
        int[] parameters = new int[count];
        for (int n = 0; n < count; n++) parameters[n] = reader.i32();
        return new Request(operation, transaction, parameters);
    }

    private static void sendStart(Socket command, int transaction, long length) throws IOException {
        if (length > Integer.MAX_VALUE) throw new IllegalArgumentException("test length");
        SonyMobileSession.writePacket(command, 9, concat(SonyMobileSession.u32(transaction),
                SonyMobileSession.u32((int) length), new byte[4]));
    }

    private static void sendData(Socket command, int transaction, byte[] data, int... fragments) throws IOException {
        sendStart(command, transaction, data.length);
        int offset = 0;
        for (int n = 0; n < fragments.length; n++) {
            int size = fragments[n];
            if (size <= 0 || offset + size > data.length) throw new IllegalArgumentException("bad test fragment");
            int type = n == fragments.length - 1 ? 12 : 10;
            SonyMobileSession.writePacket(command, type, concat(SonyMobileSession.u32(transaction),
                    Arrays.copyOfRange(data, offset, offset + size)));
            offset += size;
        }
        if (offset != data.length) throw new IllegalArgumentException("incomplete test fragments");
        SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2001),
                SonyMobileSession.u32(transaction)));
    }

    private static byte[] contentsPage(int content, int file, String name, long size, long created) throws IOException {
        byte[] path = ("/DCIM/100MSDCF/" + name + "\0").getBytes("UTF-8");
        return concat(new byte[144], SonyMobileSession.u32(1), SonyMobileSession.u32(1),
                SonyMobileSession.u32(content), new byte[20], SonyMobileSession.u32((int) created),
                SonyMobileSession.u32((int) (created >>> 32)), new byte[36], SonyMobileSession.u32(0),
                SonyMobileSession.u32(1), SonyMobileSession.u32(file), SonyMobileSession.u32(path.length),
                path, SonyMobileSession.u32(0), SonyMobileSession.u32((int) size),
                SonyMobileSession.u32((int) (size >>> 32)), new byte[32], new byte[12]);
    }

    private static void waitForClose(Socket command, AtomicBoolean requestSeen) throws IOException {
        try {
            while (command.getInputStream().read() >= 0) {
                if (requestSeen != null) requestSeen.set(true);
            }
        } catch (SocketException expected) {
            // Closing the client is the normal end of an idle fake session.
        }
    }

    private static byte[] concat(byte[]... pieces) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        for (byte[] piece : pieces) output.write(piece);
        return output.toByteArray();
    }

    private static final class Request {
        final int operation;
        final int transaction;
        final int[] parameters;

        Request(int operation, int transaction, int[] parameters) {
            this.operation = operation;
            this.transaction = transaction;
            this.parameters = parameters;
        }
    }

    private interface Responder {
        void respond(Socket command) throws Exception;
    }

    private static final class FakeServer implements Closeable {
        final ServerSocket server;
        final Responder responder;
        final AtomicReference<Throwable> failure = new AtomicReference<>();
        final Thread thread;

        FakeServer(Responder responder) throws IOException {
            this.responder = responder;
            server = new ServerSocket(0, 2, InetAddress.getLoopbackAddress());
            thread = new Thread(() -> run(), "sony-mobile-session-test-server");
            thread.start();
        }

        SocketFactory factory() {
            return new SocketFactory() {
                @Override public Socket createSocket() {
                    return new Socket() {
                        @Override public void connect(SocketAddress ignored, int timeout) throws IOException {
                            super.connect(new InetSocketAddress(InetAddress.getLoopbackAddress(), server.getLocalPort()), timeout);
                        }
                    };
                }

                @Override public Socket createSocket(String host, int port) { throw new UnsupportedOperationException(); }
                @Override public Socket createSocket(String host, int port, InetAddress local, int localPort) { throw new UnsupportedOperationException(); }
                @Override public Socket createSocket(InetAddress host, int port) { throw new UnsupportedOperationException(); }
                @Override public Socket createSocket(InetAddress host, int port, InetAddress local, int localPort) { throw new UnsupportedOperationException(); }
            };
        }

        private void run() {
            try (Socket command = server.accept()) {
                SonyMobileSession.Packet init = SonyMobileSession.readPacket(command, 4096);
                if (init.type != 1) throw new AssertionError("expected command init");
                SonyMobileSession.writePacket(command, 2, concat(SonyMobileSession.u32(7), new byte[20]));
                try (Socket event = server.accept()) {
                    SonyMobileSession.Packet eventInit = SonyMobileSession.readPacket(event, 32);
                    SonyMobileSession.Reader eventReader = new SonyMobileSession.Reader(eventInit.bytes);
                    if (eventInit.type != 3 || eventReader.i32() != 7) throw new AssertionError("wrong event init");
                    SonyMobileSession.writePacket(event, 4, new byte[0]);
                    responder.respond(command);
                    waitForClose(command, null);
                }
            } catch (Throwable error) {
                if (!(error instanceof IOException)) failure.set(error);
            }
        }

        void finish() throws Exception {
            thread.join(3000);
            if (thread.isAlive()) throw new AssertionError("fake server leaked");
            Throwable error = failure.get();
            if (error != null) throw new AssertionError("fake server failed", error);
        }

        @Override public void close() throws IOException {
            server.close();
            try { thread.join(3000); } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new IOException(interrupted);
            }
        }
    }
}
