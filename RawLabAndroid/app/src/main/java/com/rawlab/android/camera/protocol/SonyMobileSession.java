package com.rawlab.android.camera.protocol;

import java.io.*;
import java.net.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;
import javax.net.SocketFactory;

/** 手机直连模式的有界 PTP/IP 实验客户端；与 PC Remote SSH profile 分开验证。 */
public final class SonyMobileSession implements CameraMediaSession {
    public interface Reporter { void report(String message); }
    public interface Progress { void transferred(long bytes, long total); }
    /** 相机完整结束了本次事务，预览不可用等响应不会破坏后续报文边界。 */
    public static final class ResponseException extends IOException {
        ResponseException(int operation, int code) {
            super(String.format(Locale.ROOT, "PTP op 0x%04x response 0x%04x", operation, code));
        }
    }
    private final Socket command, event;
    private final Reporter report;
    private int transaction;
    private volatile boolean closed;
    private static final int LIMIT = 8 << 20;
    private static final int THUMBNAIL_LIMIT = 2 << 20;
    private static final int LARGE_PREVIEW_LIMIT = 8 << 20;
    private static final Set<Integer> ALLOWED = new HashSet<>(Arrays.asList(0x1001, 0x1002, 0x1003, 0x1004, 0x1007, 0x1008, 0x1009, 0x923b, 0x923c, 0x923d, 0x923e));

    public SonyMobileSession(SocketFactory factory, InetAddress address, UUID guid, Reporter reporter) throws IOException {
        report = reporter;
        command = factory.createSocket();
        event = factory.createSocket();
        try {
            command.connect(new InetSocketAddress(address, 15740), 10000); command.setSoTimeout(15000); command.setTcpNoDelay(true);
            ByteArrayOutputStream init = new ByteArrayOutputStream();
            ByteBuffer id = ByteBuffer.allocate(16); id.putLong(guid.getMostSignificantBits()).putLong(guid.getLeastSignificantBits());
            init.write(id.array()); init.write("RawLab Android\0".getBytes(StandardCharsets.UTF_16LE)); init.write(u32(0x10000));
            writePacket(command, 1, init.toByteArray());
            Packet ack = readPacket(command, 4096);
            if (ack.type != 2 || ack.bytes.length < 24) throw new IOException("PTP/IP command rejected type=" + ack.type);
            int number = new Reader(ack.bytes).i32();
            report.report("ptpip_command_acknowledged");
            event.connect(new InetSocketAddress(address, 15740), 10000); event.setSoTimeout(15000);
            writePacket(event, 3, u32(number));
            Packet ea = readPacket(event, 4096);
            if (ea.type != 4 || ea.bytes.length != 0) throw new IOException("Invalid PTP/IP event acknowledgement");
            event.setSoTimeout(0); event.setTcpNoDelay(true);
            report.report("ptpip_event_acknowledged");
            new Thread(() -> {
                try {
                    while (!closed) {
                        Packet packet = readPacket(event, 4096);
                        if (packet.type == 13 && packet.bytes.length == 0) writePacket(event, 14, new byte[0]);
                        else if (packet.type != 8 || packet.bytes.length < 6) throw new IOException("Invalid PTP/IP event");
                    }
                } catch (IOException error) { if (!closed) { report.report("ptpip_event_closed " + error.getClass().getSimpleName()); close(); } }
            }, "camera-ptpip-events").start();
        } catch (IOException error) { close(); throw error; }
    }

    public Device deviceInfo() throws IOException {
        Reader r = new Reader(operation(0x1001, new int[0], true, 1 << 20));
        r.u16(); long vendor = r.u32(); r.u16(); r.ptpString(); r.u16();
        Set<Integer> operations = r.u16Array();
        for (int n = 0; n < 4; n++) r.u16Array();
        Device result = new Device(r.ptpString(), r.ptpString(), r.ptpString(), operations);
        r.ptpString();
        if (vendor != 17 || !result.manufacturer.toLowerCase(Locale.ROOT).contains("sony")
            || result.model.isEmpty() || result.firmware.isEmpty())
            throw new CameraMediaSession.UnsupportedCameraException(result.model + " / " + result.firmware);
        return result;
    }

    public void openSession() throws IOException { operation(0x1002, new int[]{1}, false, 0); }

    public byte[] preview(Asset asset, boolean large) throws IOException {
        if (asset == null || asset.owner != this) throw new IOException("Preview asset outside this session");
        return operation(0x923e, new int[]{asset.content, (1 << 24) | asset.file, large ? 2 : 1}, true,
                large ? LARGE_PREVIEW_LIMIT : THUMBNAIL_LIMIT);
    }

    public List<Asset> listPhotos(Device device) throws IOException {
        if (!device.operations.contains(0x923c)) throw new IOException("Mobile contents operation 0x923C not advertised");
        ArrayList<Asset> result = new ArrayList<>();
        HashSet<String> seen = new HashSet<>();
        long after = 0;
        for (int page = 0; page < 100; page++) {
            byte[] data = operation(0x923c, new int[]{(int)after, (int)(after >>> 32), 100, 1, 0}, true, LIMIT);
            Page parsed = parseContents(data, this);
            for (Asset asset : parsed.assets) {
                if (seen.add(asset.content + ":" + asset.file)) result.add(asset);
                if (result.size() > 10000) throw new IOException("Photo list exceeds limit");
            }
            if (parsed.count < 100) return result;
            if (parsed.cursor <= after) throw new IOException("Photo list cursor did not advance");
            after = parsed.cursor;
        }
        throw new IOException("Photo page limit exceeded");
    }

    public String download(Device device, Asset asset, OutputStream destination) throws IOException {
        return download(device, asset, destination, null);
    }

    public String download(Device device, Asset asset, OutputStream destination, Progress progress) throws IOException {
        if (asset.owner != this || asset.size <= 0 || asset.size > (1L << 30) || !device.operations.contains(0x923d))
            throw new IOException("Photo outside this session or download budget");
        Progress listener = progress == null ? (bytes, total) -> {} : progress;
        MessageDigest digest;
        try { digest = MessageDigest.getInstance("SHA-256"); } catch (NoSuchAlgorithmException error) { throw new IOException(error); }
        long offset = 0;
        while (offset < asset.size) {
            int size = (int)Math.min(3 << 20, asset.size - offset);
            byte[] bytes = operation(0x923d, new int[]{asset.content, (1 << 24) | asset.file, (int)offset, (int)(offset >>> 32), size}, true, size);
            if (bytes.length != size) throw new IOException("Original photo chunk length mismatch");
            if (offset == 0) validateHeader(asset.name, bytes);
            destination.write(bytes); digest.update(bytes); offset += bytes.length;
            listener.transferred(offset, asset.size);
            report.report("photo_bytes " + offset + "/" + asset.size);
        }
        destination.flush();
        boolean unchanged = false;
        for (Asset candidate : listPhotos(device)) if (asset.same(candidate)) { unchanged = true; break; }
        if (!unchanged) throw new IOException("Camera photo metadata changed during transfer");
        StringBuilder hash = new StringBuilder(); for (byte b : digest.digest()) hash.append(String.format(Locale.ROOT, "%02x", b & 255));
        return hash.toString();
    }

    private static void validateHeader(String name, byte[] data) throws IOException {
        String lower = name.toLowerCase(Locale.ROOT);
        boolean tiff = data.length >= 4 && ((data[0] == 0x49 && data[1] == 0x49 && data[2] == 0x2a && data[3] == 0)
            || (data[0] == 0x4d && data[1] == 0x4d && data[2] == 0 && data[3] == 0x2a));
        boolean jpeg = data.length >= 3 && (data[0] & 255) == 255 && (data[1] & 255) == 216 && (data[2] & 255) == 255;
        if ((lower.endsWith(".arw") && tiff) || ((lower.endsWith(".jpg") || lower.endsWith(".jpeg")) && jpeg)) return;
        throw new IOException("Downloaded bytes do not have the expected RAW/JPEG header");
    }

    static Page parseContents(byte[] data, Object owner) throws IOException {
        Reader r = new Reader(data); r.skip(144); long count = r.u32();
        if (count > 100) throw new IOException("Contents page too large");
        ArrayList<Asset> assets = new ArrayList<>(); long cursor = 0;
        for (int n = 0; n < count; n++) {
            r.i32(); int content = r.i32(); r.skip(20); long created = r.i64(); cursor = created;
            r.skip(36); long marks = r.u32();
            if (marks > (1 << 20)) throw new IOException("Too many shot marks"); r.skip((int)marks);
            long files = r.u32(); if (files > 32) throw new IOException("Too many files per image");
            for (int f = 0; f < files; f++) {
                long file = r.u32(), length = r.u32();
                if (file > 65535 || length == 0 || length > 4096) throw new IOException("Invalid camera file metadata");
                byte[] path = r.take((int)length);
                if (path[path.length - 1] != 0) throw new IOException("Unterminated camera path");
                String full = new String(path, 0, path.length - 1, StandardCharsets.UTF_8);
                String name = full.substring(full.lastIndexOf('/') + 1);
                if (name.isEmpty() || name.equals(".") || name.equals("..") || name.indexOf('\0') >= 0 || name.indexOf('\\') >= 0)
                    throw new IOException("Invalid camera filename");
                r.i32(); long size = r.i64(); r.skip(32);
                if (r.i32() != 0) r.skip(8);
                boolean video = r.i32() != 0; if (video) r.skip(76);
                boolean audio = r.i32() != 0; if (audio) r.skip(16);
                String lower = name.toLowerCase(Locale.ROOT);
                if (!video && !audio && size > 0 && (lower.endsWith(".arw") || lower.endsWith(".jpg") || lower.endsWith(".jpeg")))
                    assets.add(new Asset(owner, content, (int)file, name, size, created));
            }
        }
        return new Page((int)count, cursor, assets);
    }

    public static final class Asset {
        final Object owner; final int content, file; public final String name; public final long size, created;
        Asset(Object owner, int content, int file, String name, long size, long created) {
            this.owner = owner; this.content = content; this.file = file; this.name = name; this.size = size; this.created = created;
        }
        public String key() { return content + ":" + file + ":" + name + ":" + size + ":" + created; }
        boolean same(Asset other) { return content == other.content && file == other.file && name.equals(other.name) && size == other.size && created == other.created; }
    }
    static final class Page {
        final int count; final long cursor; final List<Asset> assets;
        Page(int count, long cursor, List<Asset> assets) { this.count = count; this.cursor = cursor; this.assets = assets; }
    }

    synchronized byte[] operation(int op, int[] parameters, boolean requireData, int limit) throws IOException {
        if (!ALLOWED.contains(op) || parameters.length > 5 || limit < 0 || limit > LIMIT) throw new IOException("Operation outside mobile experiment allowlist");
        if (closed) throw new IOException("Camera session is closed");
        try {
            return exchange(op, parameters, requireData, limit);
        } catch (ResponseException response) {
            throw response;
        } catch (IOException failure) {
            // 读取中断或报文错误后，流中可能仍有旧事务数据，不能再复用任一通道。
            close();
            throw failure;
        }
    }

    private byte[] exchange(int op, int[] parameters, boolean requireData, int limit) throws IOException {
        int tid = op == 0x1002 ? (transaction = 0) : ++transaction;
        ByteArrayOutputStream request = new ByteArrayOutputStream();
        request.write(u32(1)); request.write(u16(op)); request.write(u32(tid));
        for (int parameter : parameters) request.write(u32(parameter));
        writePacket(command, 6, request.toByteArray());
        boolean started = false, ended = false;
        long expected = -1;
        ByteArrayOutputStream data = new ByteArrayOutputStream();
        for (int packets = 0; packets < 10000; packets++) {
            Packet packet = readPacket(command, Math.max(4096, limit + 4));
            Reader r = new Reader(packet.bytes);
            if (packet.type == 9) {
                if (started || packet.bytes.length != 12 || r.i32() != tid) throw new IOException("Invalid PTP start data");
                expected = r.i64();
                if (expected < 0 || expected > limit) throw new IOException("PTP data exceeds budget");
                started = true;
            } else if (packet.type == 10 || packet.type == 12) {
                if (!started || ended || r.i32() != tid) throw new IOException("PTP data transaction mismatch");
                int size = packet.bytes.length - 4;
                if (size > limit - data.size() || data.size() + size > expected) throw new IOException("PTP data exceeds declared length");
                data.write(r.take(size));
                if (packet.type == 12) {
                    if (data.size() != expected) throw new IOException("Incomplete PTP data");
                    ended = true;
                }
            } else if (packet.type == 7) {
                if (packet.bytes.length < 6 || packet.bytes.length > 26 || (packet.bytes.length - 6) % 4 != 0) throw new IOException("Invalid PTP response");
                int code = r.u16();
                if (r.i32() != tid) throw new IOException("PTP response transaction mismatch");
                if (started && !ended) throw new IOException("PTP response before complete data");
                if (code != 0x2001) throw new ResponseException(op, code);
                if (requireData && !started) throw new IOException("PTP response before complete data");
                report.report(String.format(Locale.ROOT, "ptp_complete op=0x%04x bytes=%d", op, data.size()));
                return data.toByteArray();
            } else if (packet.type == 13 && packet.bytes.length == 0) writePacket(command, 14, new byte[0]);
            else throw new IOException("Unexpected PTP/IP packet " + packet.type);
        }
        throw new IOException("PTP packet budget exceeded");
    }

    @Override public void close() {
        closed = true;
        try { command.close(); } catch (IOException ignored) {}
        try { event.close(); } catch (IOException ignored) {}
    }

    static byte[] u16(int value) { return ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort((short)value).array(); }
    static byte[] u32(int value) { return ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array(); }
    static void writePacket(Socket socket, int type, byte[] payload) throws IOException {
        // 小报文拆成头/体多次 write 会与相机延迟 ACK 叠加，逐对象查询出现累积等待。
        byte[] packet = ByteBuffer.allocate(payload.length + 8).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(payload.length + 8).putInt(type).put(payload).array();
        OutputStream out = socket.getOutputStream(); out.write(packet); out.flush();
    }
    static Packet readPacket(Socket socket, int max) throws IOException {
        DataInputStream in = new DataInputStream(socket.getInputStream());
        int length = Integer.reverseBytes(in.readInt()), type = Integer.reverseBytes(in.readInt());
        if (length < 8 || length - 8 > max) throw new IOException("Invalid PTP/IP packet length " + length);
        byte[] bytes = new byte[length - 8]; in.readFully(bytes); return new Packet(type, bytes);
    }
    static final class Packet { final int type; final byte[] bytes; Packet(int type, byte[] bytes) { this.type = type; this.bytes = bytes; } }
    public static final class Device {
        public final String manufacturer, model, firmware;
        public final Set<Integer> operations;
        Device(String manufacturer, String model, String firmware, Set<Integer> operations) {
            this.manufacturer = manufacturer; this.model = model; this.firmware = firmware; this.operations = Collections.unmodifiableSet(new HashSet<>(operations));
        }
    }
    static final class Reader {
        private final ByteBuffer buffer;
        Reader(byte[] bytes) { buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN); }
        int remaining() { return buffer.remaining(); }
        byte[] take(int size) throws IOException {
            if (size < 0 || size > buffer.remaining()) throw new EOFException("Truncated PTP data");
            byte[] out = new byte[size]; buffer.get(out); return out;
        }
        void skip(int size) throws IOException { if (size < 0 || size > buffer.remaining()) throw new EOFException("Truncated PTP data"); buffer.position(buffer.position() + size); }
        int u8() throws IOException { if (remaining() < 1) throw new EOFException(); return buffer.get() & 255; }
        int u16() throws IOException { if (remaining() < 2) throw new EOFException(); return buffer.getShort() & 65535; }
        int i32() throws IOException { if (remaining() < 4) throw new EOFException(); return buffer.getInt(); }
        long u32() throws IOException { return Integer.toUnsignedLong(i32()); }
        long i64() throws IOException { if (remaining() < 8) throw new EOFException(); return buffer.getLong(); }
        String ptpString() throws IOException {
            int count = u8(); if (count == 0) return "";
            byte[] text = take(count * 2);
            if (text[text.length - 1] != 0 || text[text.length - 2] != 0) throw new IOException("Unterminated PTP string");
            String value = new String(text, 0, text.length - 2, StandardCharsets.UTF_16LE);
            if (value.indexOf('\0') >= 0) throw new IOException("Embedded NUL in PTP string");
            return value;
        }
        Set<Integer> u16Array() throws IOException {
            long size = u32(); if (size > 4096 || size * 2 > remaining()) throw new IOException("Invalid PTP array size");
            Set<Integer> out = new HashSet<>(); for (int i = 0; i < size; i++) out.add(u16()); return out;
        }
    }
}
