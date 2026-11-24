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
    public void previewRetriesBusyResponsesOnTheSameChannels() throws Exception {
        byte[] expected = new byte[]{1, 2, 3};
        try (FakeServer server = new FakeServer(command -> {
            int previous = -1;
            for (int attempt = 0; attempt < 3; attempt++) {
                Request request = readRequest(command);
                assertEquals(0x923e, request.operation);
                assertTrue(request.transaction > previous);
                previous = request.transaction;
                if (attempt < 2) SonyMobileSession.writePacket(command, 7,
                        concat(SonyMobileSession.u16(0x2019), SonyMobileSession.u32(request.transaction)));
                else sendData(command, request.transaction, expected, expected.length);
            }
            // A write/control response must surface immediately, without replaying OpenSession.
            Request open = readRequest(command);
            assertEquals(0x1002, open.operation);
            SonyMobileSession.writePacket(command, 7,
                    concat(SonyMobileSession.u16(0x2019), SonyMobileSession.u32(open.transaction)));
            Request next = readRequest(command);
            assertEquals(0x923e, next.operation);
            sendData(command, next.transaction, expected, expected.length);
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Asset asset = new SonyMobileSession.Asset(session, CONTENT, FILE, "DSC00001.ARW", 100, 123);
                assertArrayEquals(expected, session.preview(asset, false));
                try { session.openSession(); fail("expected busy control response"); }
                catch (SonyMobileSession.ResponseException error) { assertEquals(CameraMediaSession.FailureKind.ITEM, error.getKind()); }
                assertTrue(session.isOpen());
                assertArrayEquals(expected, session.preview(asset, false));
            }
            server.finish();
        }
    }

    @Test
    public void responseKindsCoverUsedPartialAndThumbnailReadsWithoutReplayingControls() {
        for (int op : new int[]{0x1001, 0x1004, 0x1007, 0x1008, 0x100a, 0x101b, 0x9202, 0x9209, 0x923c, 0x923d, 0x923e}) {
            assertEquals(Integer.toHexString(op), CameraMediaSession.FailureKind.TRANSIENT_READ,
                    CameraMediaSession.responseFailureKind(op, 0x2019));
            assertEquals(Integer.toHexString(op), op == 0x923c ? CameraMediaSession.FailureKind.TRANSIENT_READ : CameraMediaSession.FailureKind.ITEM,
                    CameraMediaSession.responseFailureKind(op, 0x2005));
        }
        for (int op : new int[]{0x1002, 0x1003, 0x9201, 0x9205, 0x9207, 0x9212, 0x923f}) {
            assertEquals(CameraMediaSession.FailureKind.ITEM, CameraMediaSession.responseFailureKind(op, 0x2019));
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

    @Test public void malformedPreviewTransactionClosesBothChannels() throws Exception {
        assertFatalPreviewClosesChannels("transaction");
    }

    @Test public void malformedPreviewPacketLengthClosesBothChannels() throws Exception {
        assertFatalPreviewClosesChannels("length");
    }

    @Test public void previewTimeoutClosesBothChannels() throws Exception {
        assertFatalPreviewClosesChannels("timeout");
    }

    private static void assertFatalPreviewClosesChannels(String failure) throws Exception {
        try (FakeServer server = new FakeServer(command -> {
            Request request = readRequest(command);
            if (failure.equals("transaction")) {
                SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2001),
                        SonyMobileSession.u32(request.transaction + 1)));
            } else if (failure.equals("length")) {
                command.getOutputStream().write(concat(SonyMobileSession.u32(7), SonyMobileSession.u32(7)));
                command.getOutputStream().flush();
            }
            waitForClose(command, null);
        }, 250)) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Asset asset = new SonyMobileSession.Asset(session, CONTENT, FILE, "DSC00001.ARW", 100, 123);
                try {
                    session.preview(asset, false);
                    fail("accepted fatal preview " + failure);
                } catch (IOException expected) {
                    assertTrue("fatal preview left a reusable socket", server.clients.stream().allMatch(Socket::isClosed));
                }
            }
            server.finish();
        }
    }

    @Test public void unavailablePreviewResponseKeepsAlignedSessionUsable() throws Exception {
        byte[] bytes = new byte[]{1, 2, 3};
        try (FakeServer server = new FakeServer(command -> {
            Request unavailable = readRequest(command);
            SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2005),
                    SonyMobileSession.u32(unavailable.transaction)));
            Request retry = readRequest(command);
            sendData(command, retry.transaction, bytes, bytes.length);
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Asset asset = new SonyMobileSession.Asset(session, CONTENT, FILE, "DSC00001.ARW", 100, 123);
                try { session.preview(asset, false); fail("expected unavailable preview"); }
                catch (IOException expected) { assertTrue(expected.getMessage().contains("0x2005")); }
                assertFalse(server.clients.stream().anyMatch(Socket::isClosed));
                assertArrayEquals(bytes, session.preview(asset, false));
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
            assertArrayEquals(new int[]{122, 0, 100, 1, 0}, list.parameters);
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
    public void listPhotosExceeding10000FilesThrowsPhotoLimitAndKeepsSessionOpen() throws Exception {
        byte[] thumb = new byte[]{0x09, 0x08, 0x07};
        try (FakeServer server = new FakeServer(command -> {
            int nextIndex = 1;
            for (int page = 0; page < 101; page++) {
                Request list = readRequest(command);
                assertEquals(0x923c, list.operation);
                int pageCount = page < 100 ? 100 : 1;
                ByteArrayOutputStream body = new ByteArrayOutputStream();
                body.write(new byte[144]);
                body.write(SonyMobileSession.u32(pageCount));
                for (int item = 0; item < pageCount; item++) {
                    int id = nextIndex++;
                    long created = 1_730_000_000_000L + id * 1000L;
                    byte[] path = String.format(java.util.Locale.ROOT, "/DCIM/100MSDCF/DSC%05d.ARW\0", id).getBytes("UTF-8");
                    body.write(concat(
                            SonyMobileSession.u32(1), SonyMobileSession.u32(id), new byte[20],
                            SonyMobileSession.u32((int) created), SonyMobileSession.u32((int) (created >>> 32)),
                            new byte[36], SonyMobileSession.u32(0), SonyMobileSession.u32(1),
                            SonyMobileSession.u32(1), SonyMobileSession.u32(path.length), path,
                            SonyMobileSession.u32(0), SonyMobileSession.u32(104), SonyMobileSession.u32(0),
                            new byte[32], new byte[12]));
                }
                byte[] bytes = body.toByteArray();
                sendData(command, list.transaction, bytes, bytes.length);
            }
            Request preview = readRequest(command);
            assertEquals(0x923e, preview.operation);
            sendData(command, preview.transaction, thumb, thumb.length);
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Device device = new SonyMobileSession.Device("Sony Corporation", "ILCE-7CM2",
                        "2.00", new java.util.HashSet<>(Arrays.asList(0x923c, 0x923d, 0x923e)));
                try {
                    session.listPhotos(device);
                    fail("expected photo limit exceeded");
                } catch (CameraMediaSession.PhotoLimitExceededException expected) {
                    assertEquals(10000, expected.recentAssets.size());
                    assertEquals("DSC10001.ARW", expected.recentAssets.get(0).name);
                    assertTrue(session.isOpen());
                    assertFalse(server.clients.stream().anyMatch(Socket::isClosed));
                    assertArrayEquals(thumb, session.preview(expected.recentAssets.get(0), false));
                }
            }
            server.finish();
        }
    }

    @Test
    public void downloadAndTailReadRangeSeekDirectlyWithoutFullCardRelist() throws Exception {
        byte[] photo = new byte[128];
        photo[0] = 0x49;
        photo[1] = 0x49;
        photo[2] = 0x2a;
        photo[3] = 0x00;
        final int totalPhotos = 500;
        final int targetIndex = 450;
        final long targetCreated = 1_000_000L + targetIndex * 1000L;
        final List<Long> listAfterCursors = new CopyOnWriteArrayList<>();

        try (FakeServer server = new FakeServer(command -> {
            // 1) download() chunk + post-flush hasAsset()
            Request download = readRequest(command);
            assertEquals(0x923d, download.operation);
            sendData(command, download.transaction, photo, photo.length);

            Request listAfterDownload = readRequest(command);
            assertEquals(0x923c, listAfterDownload.operation);
            long cursor1 = Integer.toUnsignedLong(listAfterDownload.parameters[0])
                    | (Integer.toUnsignedLong(listAfterDownload.parameters[1]) << 32);
            listAfterCursors.add(cursor1);
            byte[] page = buildContentsRange(cursor1, totalPhotos, 100, photo.length, false);
            sendData(command, listAfterDownload.transaction, page, page.length);

            // 2) tail readRange() + post-tail hasAsset()
            Request tailRead = readRequest(command);
            assertEquals(0x923d, tailRead.operation);
            sendData(command, tailRead.transaction, Arrays.copyOfRange(photo, 64, 128), 64);

            Request listAfterTail = readRequest(command);
            assertEquals(0x923c, listAfterTail.operation);
            long cursor2 = Integer.toUnsignedLong(listAfterTail.parameters[0])
                    | (Integer.toUnsignedLong(listAfterTail.parameters[1]) << 32);
            listAfterCursors.add(cursor2);
            byte[] tailPage = buildContentsRange(cursor2, totalPhotos, 100, photo.length, false);
            sendData(command, listAfterTail.transaction, tailPage, tailPage.length);
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Device device = new SonyMobileSession.Device("Sony Corporation", "ILCE-7CM2",
                        "2.00", new java.util.HashSet<>(Arrays.asList(0x923c, 0x923d)));
                SonyMobileSession.Asset asset = new SonyMobileSession.Asset(
                        session, 1, targetIndex + 1,
                        String.format(java.util.Locale.ROOT, "DSC%05d.ARW", targetIndex + 1),
                        photo.length, targetCreated);
                ByteArrayOutputStream output = new ByteArrayOutputStream();
                session.download(device, asset, output);
                assertArrayEquals(photo, output.toByteArray());
                assertArrayEquals(Arrays.copyOfRange(photo, 64, 128), session.readRange(device, asset, 64, 64));
            }
            server.finish();
        }
        assertEquals(Arrays.asList(targetCreated - 1, targetCreated - 1), listAfterCursors);
    }

    @Test
    public void duplicateTimestampsResolveInSingleContentsPage() throws Exception {
        byte[] photo = new byte[]{0x49, 0x49, 0x2a, 0x00, 1, 2};
        long sharedCreated = 1_700_000_000L;
        List<Long> cursors = new CopyOnWriteArrayList<>();
        try (FakeServer server = new FakeServer(command -> {
            Request download = readRequest(command);
            assertEquals(0x923d, download.operation);
            sendData(command, download.transaction, photo, photo.length);

            Request list = readRequest(command);
            assertEquals(0x923c, list.operation);
            long after = Integer.toUnsignedLong(list.parameters[0])
                    | (Integer.toUnsignedLong(list.parameters[1]) << 32);
            cursors.add(after);
            byte[] page = buildDualFormatPage(sharedCreated, photo.length);
            sendData(command, list.transaction, page, page.length);
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Device device = new SonyMobileSession.Device("Sony Corporation", "ILCE-7CM2",
                        "2.00", new java.util.HashSet<>(Arrays.asList(0x923c, 0x923d)));
                SonyMobileSession.Asset arw = new SonyMobileSession.Asset(
                        session, 1, 2, "DSC00001.ARW", photo.length, sharedCreated);
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                session.download(device, arw, out);
                assertArrayEquals(photo, out.toByteArray());
            }
            server.finish();
        }
        assertEquals(Arrays.asList(sharedCreated - 1), cursors);
    }

    @Test
    public void deletedPhotoStopsAfterSinglePageWhenCursorPassesTargetCreated() throws Exception {
        byte[] photo = new byte[]{0x49, 0x49, 0x2a, 0x00, 1, 2};
        long deletedCreated = 1_000_500L;
        List<Long> cursors = new CopyOnWriteArrayList<>();
        try (FakeServer server = new FakeServer(command -> {
            Request download = readRequest(command);
            assertEquals(0x923d, download.operation);
            sendData(command, download.transaction, photo, photo.length);

            // Exactly 100 newer items (all with created > deletedCreated), so count == 100.
            // Without `parsed.cursor > target.created`, hasAsset() would scan subsequent pages!
            Request list = readRequest(command);
            assertEquals(0x923c, list.operation);
            long after = Integer.toUnsignedLong(list.parameters[0])
                    | (Integer.toUnsignedLong(list.parameters[1]) << 32);
            cursors.add(after);
            byte[] page = buildContentsRange(deletedCreated + 1000L, 600, 100, photo.length, false);
            sendData(command, list.transaction, page, page.length);
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Device device = new SonyMobileSession.Device("Sony Corporation", "ILCE-7CM2",
                        "2.00", new java.util.HashSet<>(Arrays.asList(0x923c, 0x923d)));
                SonyMobileSession.Asset missing = new SonyMobileSession.Asset(
                        session, 1, 999, "DSC00999.ARW", photo.length, deletedCreated);
                try {
                    session.download(device, missing, new ByteArrayOutputStream());
                    fail("expected SOURCE_CHANGED for deleted photo");
                } catch (CameraMediaSession.PhotoTransferException expected) {
                    assertEquals(CameraMediaSession.FailureKind.SOURCE_CHANGED, expected.getKind());
                }
            }
            server.finish();
        }
        assertEquals(Arrays.asList(deletedCreated - 1), cursors);
    }

    @Test
    public void emptyCardAndZeroCreatedFallbackStopCleanly() throws Exception {
        byte[] photo = new byte[]{0x49, 0x49, 0x2a, 0x00, 1, 2};
        List<Long> cursors = new CopyOnWriteArrayList<>();
        try (FakeServer server = new FakeServer(command -> {
            Request download = readRequest(command);
            assertEquals(0x923d, download.operation);
            sendData(command, download.transaction, photo, photo.length);

            Request list = readRequest(command);
            assertEquals(0x923c, list.operation);
            long after = Integer.toUnsignedLong(list.parameters[0])
                    | (Integer.toUnsignedLong(list.parameters[1]) << 32);
            cursors.add(after);
            byte[] emptyPage = concat(new byte[144], SonyMobileSession.u32(0));
            sendData(command, list.transaction, emptyPage, emptyPage.length);
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Device device = new SonyMobileSession.Device("Sony Corporation", "ILCE-7CM2",
                        "2.00", new java.util.HashSet<>(Arrays.asList(0x923c, 0x923d)));
                SonyMobileSession.Asset zeroCreated = new SonyMobileSession.Asset(
                        session, 1, 1, "DSC00001.ARW", photo.length, 0);
                try {
                    session.download(device, zeroCreated, new ByteArrayOutputStream());
                    fail("expected SOURCE_CHANGED on empty card");
                } catch (CameraMediaSession.PhotoTransferException expected) {
                    assertEquals(CameraMediaSession.FailureKind.SOURCE_CHANGED, expected.getKind());
                }
            }
            server.finish();
        }
        assertEquals(Arrays.asList(0L), cursors);
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

    @Test
    public void listsDualCardSlotsAndRoutesSlotTwoToPreviewAndReadRange() throws Exception {
        List<int[]> previewParams = new CopyOnWriteArrayList<>();
        List<int[]> readParams = new CopyOnWriteArrayList<>();
        List<Integer> hasAssetSlots = new CopyOnWriteArrayList<>();
        List<Integer> probedSlots = new CopyOnWriteArrayList<>();
        byte[] sampleBytes = "II*\0sample-slot-two-payload".getBytes("US-ASCII");
        try (FakeServer server = new FakeServer(command -> {
            while (true) {
                Request request;
                try {
                    request = readRequest(command);
                } catch (java.io.EOFException done) {
                    return;
                }
                if (request.operation == 0x1002) {
                    SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2001), SonyMobileSession.u32(request.transaction)));
                } else if (request.operation == 0x923b) {
                    assertEquals(1, request.parameters.length);
                    int slot = request.parameters[0];
                    assertTrue(slot == 1 || slot == 2);
                    probedSlots.add(slot);
                    byte[] slotInfo = concat(SonyMobileSession.u32(1), SonyMobileSession.u32(0), SonyMobileSession.u32(0));
                    sendData(command, request.transaction, slotInfo, slotInfo.length);
                } else if (request.operation == 0x923c) {
                    int slot = request.parameters[3];
                    long after = Integer.toUnsignedLong(request.parameters[0])
                            | (Integer.toUnsignedLong(request.parameters[1]) << 32);
                    if (after > 0) hasAssetSlots.add(slot);
                    long size = slot == 2 ? sampleBytes.length : 1024L;
                    long created = slot == 2 ? 2000L : 1000L;
                    byte[] page = contentsPage(10, 1, "DSC00001.ARW", size, created);
                    sendData(command, request.transaction, page, page.length);
                } else if (request.operation == 0x923e) {
                    previewParams.add(request.parameters);
                    sendData(command, request.transaction, new byte[]{(byte) 0xff, (byte) 0xd8, (byte) 0xff, (byte) 0xd9}, 4);
                } else if (request.operation == 0x923d) {
                    readParams.add(request.parameters);
                    sendData(command, request.transaction, sampleBytes, sampleBytes.length);
                } else {
                    throw new AssertionError("unexpected op " + request.operation);
                }
            }
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Device device = new SonyMobileSession.Device("Sony Corporation", "ILCE-7M5",
                        "1.00", new java.util.HashSet<>(Arrays.asList(0x1001, 0x1002, 0x923b, 0x923c, 0x923d, 0x923e)));
                session.openSession();
                List<SonyMobileSession.Asset> listed = session.listPhotos(device);
                assertEquals(2, listed.size());
                SonyMobileSession.Asset slot1 = listed.get(0);
                SonyMobileSession.Asset slot2 = listed.get(1);
                assertEquals(1, slot1.slot);
                assertEquals(2, slot2.slot);
                assertFalse(slot1.key().startsWith("s2:"));
                assertTrue(slot2.key().startsWith("s2:"));
                assertTrue(slot2.resumeIdentity().startsWith("mobile:s2:"));

                session.preview(slot2, false);
                assertEquals((2 << 24) | 1, previewParams.get(0)[1]);

                byte[] read = session.readRange(device, slot2, 0, sampleBytes.length);
                assertArrayEquals(sampleBytes, read);
                assertEquals((2 << 24) | 1, readParams.get(0)[1]);
                assertTrue(hasAssetSlots.contains(2));
                assertEquals(Arrays.asList(1, 2), probedSlots);
            }
            server.finish();
        }
    }

    @Test
    public void skipsSecondSlotWhen0x923bReturnsUnsupported() throws Exception {
        try (FakeServer server = new FakeServer(command -> {
            while (true) {
                Request request;
                try {
                    request = readRequest(command);
                } catch (java.io.EOFException done) {
                    return;
                }
                if (request.operation == 0x1002) {
                    SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2001), SonyMobileSession.u32(request.transaction)));
                } else if (request.operation == 0x923b) {
                    SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2008), SonyMobileSession.u32(request.transaction)));
                } else if (request.operation == 0x923c) {
                    assertEquals(1, request.parameters[3]);
                    byte[] page = contentsPage(10, 1, "DSC00001.ARW", 128L, 1000L);
                    sendData(command, request.transaction, page, page.length);
                } else {
                    throw new AssertionError("unexpected op " + request.operation);
                }
            }
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Device device = new SonyMobileSession.Device("Sony Corporation", "ILCE-7M5",
                        "1.00", new java.util.HashSet<>(Arrays.asList(0x1001, 0x1002, 0x923b, 0x923c, 0x923d)));
                session.openSession();
                List<SonyMobileSession.Asset> listed = session.listPhotos(device);
                assertEquals(1, listed.size());
                assertEquals(1, listed.get(0).slot);
            }
            server.finish();
        }
    }

    @Test
    public void initializeRemoteContentsSendsExpectedInitializationSequence() throws Exception {
        List<String> sequence = new CopyOnWriteArrayList<>();
        try (FakeServer server = new FakeServer(command -> {
            while (true) {
                Request request;
                try {
                    request = readRequest(command);
                } catch (java.io.EOFException done) {
                    return;
                }
                sequence.add(String.format(java.util.Locale.ROOT, "0x%04x:%s", request.operation, Arrays.toString(request.parameters)));
                if (request.operation == 0x9202) {
                    sendData(command, request.transaction, SonyMobileSession.u16(0x12c), 2);
                } else {
                    SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2001), SonyMobileSession.u32(request.transaction)));
                }
            }
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Device device = new SonyMobileSession.Device("Sony Corporation", "ILCE-7M5",
                        "1.00", new java.util.HashSet<>(Arrays.asList(0x1001, 0x1002, 0x9201, 0x9202, 0x923c, 0x923d)));
                session.openSession(device, true);
            }
            server.finish();
        }
        assertEquals(Arrays.asList(
                "0x1002:[1]",
                "0x9201:[1, 0, 0]",
                "0x9201:[2, 0, 0]",
                "0x9202:[300, 1]",
                "0x9201:[3, 0, 0]"), sequence);
    }

    @Test
    public void listsSlot2WhenSlot1IsEmpty() throws Exception {
        List<Integer> listSlots = new CopyOnWriteArrayList<>();
        List<int[]> downloadParams = new CopyOnWriteArrayList<>();
        byte[] sampleBytes = "II*\0slot-2-only-arw".getBytes("US-ASCII");
        try (FakeServer server = new FakeServer(command -> {
            while (true) {
                Request request;
                try {
                    request = readRequest(command);
                } catch (java.io.EOFException done) {
                    return;
                }
                if (request.operation == 0x1002) {
                    SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2001), SonyMobileSession.u32(request.transaction)));
                } else if (request.operation == 0x923b) {
                    int slot = request.parameters[0];
                    if (slot == 1) {
                        SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x201d), SonyMobileSession.u32(request.transaction)));
                    } else {
                        byte[] slotInfo = concat(SonyMobileSession.u32(1), SonyMobileSession.u32(0), SonyMobileSession.u32(0));
                        sendData(command, request.transaction, slotInfo, slotInfo.length);
                    }
                } else if (request.operation == 0x923c) {
                    int slot = request.parameters[3];
                    listSlots.add(slot);
                    assertEquals(2, slot);
                    byte[] page = contentsPage(10, 1, "DSC00002.ARW", sampleBytes.length, 2000L);
                    sendData(command, request.transaction, page, page.length);
                } else if (request.operation == 0x923d) {
                    downloadParams.add(request.parameters);
                    sendData(command, request.transaction, sampleBytes, sampleBytes.length);
                } else {
                    throw new AssertionError("unexpected op " + request.operation);
                }
            }
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Device device = new SonyMobileSession.Device("Sony Corporation", "ILCE-7M5",
                        "1.00", new java.util.HashSet<>(Arrays.asList(0x1001, 0x1002, 0x923b, 0x923c, 0x923d)));
                session.openSession();
                List<SonyMobileSession.Asset> listed = session.listPhotos(device);
                assertEquals(1, listed.size());
                assertEquals(2, listed.get(0).slot);
                assertFalse(listSlots.contains(1));
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                session.download(device, listed.get(0), out);
                assertArrayEquals(sampleBytes, out.toByteArray());
                assertEquals((2 << 24) | 1, downloadParams.get(0)[1]);
            }
            server.finish();
        }
    }

    @Test
    public void handlesLargeDateListIn0x923b() throws Exception {
        ByteArrayOutputStream largeDates = new ByteArrayOutputStream();
        largeDates.write(SonyMobileSession.u32(200));
        for (int i = 0; i < 200; i++) {
            largeDates.write(new byte[8]);
        }
        byte[] datePayload = largeDates.toByteArray();
        assertTrue(datePayload.length > 1024);

        try (FakeServer server = new FakeServer(command -> {
            while (true) {
                Request request;
                try {
                    request = readRequest(command);
                } catch (java.io.EOFException done) {
                    return;
                }
                if (request.operation == 0x1002) {
                    SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2001), SonyMobileSession.u32(request.transaction)));
                } else if (request.operation == 0x923b) {
                    if (request.parameters[0] == 1) {
                        sendData(command, request.transaction, datePayload, datePayload.length);
                    } else {
                        SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x201d), SonyMobileSession.u32(request.transaction)));
                    }
                } else if (request.operation == 0x923c) {
                    byte[] page = contentsPage(10, 1, "DSC00001.ARW", 128L, 1000L);
                    sendData(command, request.transaction, page, page.length);
                } else {
                    throw new AssertionError("unexpected op " + request.operation);
                }
            }
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Device device = new SonyMobileSession.Device("Sony Corporation", "ILCE-7M5",
                        "1.00", new java.util.HashSet<>(Arrays.asList(0x1001, 0x1002, 0x923b, 0x923c, 0x923d)));
                session.openSession();
                List<SonyMobileSession.Asset> listed = session.listPhotos(device);
                assertEquals(1, listed.size());
                assertEquals("DSC00001.ARW", listed.get(0).name);
            }
            server.finish();
        }
    }

    @Test
    public void initializeRemoteContentsRetriesEmpty9202() throws Exception {
        final int[] attempts9202 = {0};
        try (FakeServer server = new FakeServer(command -> {
            while (true) {
                Request request;
                try {
                    request = readRequest(command);
                } catch (java.io.EOFException done) {
                    return;
                }
                if (request.operation == 0x9202) {
                    attempts9202[0]++;
                    if (attempts9202[0] < 3) {
                        SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2001), SonyMobileSession.u32(request.transaction)));
                    } else {
                        sendData(command, request.transaction, SonyMobileSession.u16(0x12c), 2);
                    }
                } else {
                    SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2001), SonyMobileSession.u32(request.transaction)));
                }
            }
        })) {
            try (SonyMobileSession session = new SonyMobileSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {})) {
                SonyMobileSession.Device device = new SonyMobileSession.Device("Sony Corporation", "ILCE-7M5",
                        "1.00", new java.util.HashSet<>(Arrays.asList(0x1001, 0x1002, 0x9201, 0x9202, 0x923c, 0x923d)));
                session.openSession(device, true);
                assertEquals(3, attempts9202[0]);
            }
            server.finish();
        }
    }

    @Test
    public void tetherListsSlot2WhenSlot1IsEmptyAndDownloadsSlot2() throws Exception {
        List<Integer> listSlots = new CopyOnWriteArrayList<>();
        List<int[]> downloadParams = new CopyOnWriteArrayList<>();
        byte[] sampleBytes = "II*\0tether-slot-2-arw".getBytes("US-ASCII");
        try (FakeServer server = new FakeServer(command -> {
            while (true) {
                Request request;
                try {
                    request = readRequest(command);
                } catch (java.io.EOFException done) {
                    return;
                }
                if (request.operation == 0x1001) {
                    int[] ops = new int[]{0x1001, 0x1002, 0x9201, 0x9202, 0x9209, 0x923b, 0x923c, 0x923d};
                    ByteArrayOutputStream opsOut = new ByteArrayOutputStream();
                    opsOut.write(SonyMobileSession.u32(ops.length));
                    for (int op : ops) opsOut.write(SonyMobileSession.u16(op));
                    byte[] deviceInfo = concat(
                            SonyMobileSession.u16(100), SonyMobileSession.u32(17), SonyMobileSession.u16(100),
                            ptpText("Sony"), SonyMobileSession.u16(0), opsOut.toByteArray(), new byte[16],
                            ptpText("Sony Corporation"), ptpText("ILCE-7M5"), ptpText("1.00"), ptpText("fixture"));
                    sendData(command, request.transaction, deviceInfo, deviceInfo.length);
                } else if (request.operation == 0x1002 || request.operation == 0x9201) {
                    SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x2001), SonyMobileSession.u32(request.transaction)));
                } else if (request.operation == 0x9202) {
                    byte[] desc = concat(SonyMobileSession.u16(0x12c), SonyMobileSession.u32(0), SonyMobileSession.u32(0));
                    sendData(command, request.transaction, desc, desc.length);
                } else if (request.operation == 0x923b) {
                    int slot = request.parameters[0];
                    if (slot == 1) {
                        SonyMobileSession.writePacket(command, 7, concat(SonyMobileSession.u16(0x201d), SonyMobileSession.u32(request.transaction)));
                    } else {
                        byte[] slotInfo = concat(SonyMobileSession.u32(1), SonyMobileSession.u32(0), SonyMobileSession.u32(0));
                        sendData(command, request.transaction, slotInfo, slotInfo.length);
                    }
                } else if (request.operation == 0x923c) {
                    int slot = request.parameters[3];
                    listSlots.add(slot);
                    assertEquals(2, slot);
                    byte[] page = contentsPage(10, 1, "DSC00002.ARW", sampleBytes.length, 2000L);
                    sendData(command, request.transaction, page, page.length);
                } else if (request.operation == 0x923d) {
                    downloadParams.add(request.parameters);
                    sendData(command, request.transaction, sampleBytes, sampleBytes.length);
                } else {
                    throw new AssertionError("unexpected tether op " + request.operation);
                }
            }
        })) {
            try (SonyTetherSession session = new SonyTetherSession(server.factory(),
                    InetAddress.getLoopbackAddress(), UUID.randomUUID(), message -> {}, SonyTetherSession.Purpose.TETHER)) {
                session.connectRemote();
                List<SonyMobileSession.Asset> listed = session.listPhotos();
                assertEquals(1, listed.size());
                assertEquals(2, listed.get(0).slot);
                assertFalse(listSlots.contains(1));
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                session.download(listed.get(0), out);
                assertArrayEquals(sampleBytes, out.toByteArray());
                assertEquals((2 << 24) | 1, downloadParams.get(0)[1]);
            }
            server.finish();
        }
    }

    private static byte[] ptpText(String value) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(value.length() + 1);
        out.write((value + "\0").getBytes("UTF-16LE"));
        return out.toByteArray();
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

    private static byte[] buildContentsRange(long after, int totalItems, int maxPerPage, long size, boolean zeroBased) throws IOException {
        int start = 0;
        while (start < totalItems && (1_000_000L + start * 1000L) <= after) start++;
        int count = Math.min(maxPerPage, totalItems - start);
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        body.write(new byte[144]);
        body.write(SonyMobileSession.u32(count));
        for (int i = 0; i < count; i++) {
            int idx = start + i;
            int id = zeroBased ? idx : idx + 1;
            long created = 1_000_000L + idx * 1000L;
            byte[] path = String.format(java.util.Locale.ROOT, "/DCIM/100MSDCF/DSC%05d.ARW\0", id).getBytes("UTF-8");
            body.write(concat(
                    SonyMobileSession.u32(1), SonyMobileSession.u32(1), new byte[20],
                    SonyMobileSession.u32((int) created), SonyMobileSession.u32((int) (created >>> 32)),
                    new byte[36], SonyMobileSession.u32(0), SonyMobileSession.u32(1),
                    SonyMobileSession.u32(id), SonyMobileSession.u32(path.length), path,
                    SonyMobileSession.u32(0), SonyMobileSession.u32((int) size),
                    SonyMobileSession.u32((int) (size >>> 32)), new byte[32], new byte[12]));
        }
        return body.toByteArray();
    }

    private static byte[] buildDualFormatPage(long created, long size) throws IOException {
        byte[] jpgPath = "/DCIM/100MSDCF/DSC00001.JPG\0".getBytes("UTF-8");
        byte[] arwPath = "/DCIM/100MSDCF/DSC00001.ARW\0".getBytes("UTF-8");
        return concat(
                new byte[144], SonyMobileSession.u32(2),
                // entry 0: JPG
                SonyMobileSession.u32(1), SonyMobileSession.u32(1), new byte[20],
                SonyMobileSession.u32((int) created), SonyMobileSession.u32((int) (created >>> 32)),
                new byte[36], SonyMobileSession.u32(0), SonyMobileSession.u32(1),
                SonyMobileSession.u32(1), SonyMobileSession.u32(jpgPath.length), jpgPath,
                SonyMobileSession.u32(0), SonyMobileSession.u32((int) size),
                SonyMobileSession.u32((int) (size >>> 32)), new byte[32], new byte[12],
                // entry 1: ARW (same created timestamp)
                SonyMobileSession.u32(2), SonyMobileSession.u32(1), new byte[20],
                SonyMobileSession.u32((int) created), SonyMobileSession.u32((int) (created >>> 32)),
                new byte[36], SonyMobileSession.u32(0), SonyMobileSession.u32(1),
                SonyMobileSession.u32(2), SonyMobileSession.u32(arwPath.length), arwPath,
                SonyMobileSession.u32(0), SonyMobileSession.u32((int) size),
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
        final List<Socket> clients = new CopyOnWriteArrayList<>();
        final int timeout;
        final Thread thread;

        FakeServer(Responder responder) throws IOException {
            this(responder, 15000);
        }

        FakeServer(Responder responder, int timeout) throws IOException {
            this.responder = responder;
            this.timeout = timeout;
            server = new ServerSocket(0, 2, InetAddress.getLoopbackAddress());
            thread = new Thread(() -> run(), "sony-mobile-session-test-server");
            thread.start();
        }

        SocketFactory factory() {
            return new SocketFactory() {
                @Override public Socket createSocket() {
                    Socket socket = new Socket() {
                        @Override public void connect(SocketAddress ignored, int timeout) throws IOException {
                            super.connect(new InetSocketAddress(InetAddress.getLoopbackAddress(), server.getLocalPort()), timeout);
                        }
                        @Override public void setSoTimeout(int milliseconds) throws SocketException {
                            super.setSoTimeout(milliseconds == 0 ? 0 : Math.min(milliseconds, FakeServer.this.timeout));
                        }
                    };
                    clients.add(socket);
                    return socket;
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
