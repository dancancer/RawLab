package com.rawlab.android.camera.protocol;

import java.nio.charset.StandardCharsets;

public final class WifiPayloadTest {
    private static byte[] packet(String text) {
        byte[] result = new byte[text.length() + 3]; result[0] = (byte)(result.length - 1);
        System.arraycopy(text.getBytes(StandardCharsets.US_ASCII), 0, result, 3, text.length()); return result;
    }
    private static void reject(byte[] data, boolean password) {
        try { SonyWifiCredentials.decode(data, password); throw new AssertionError("Malformed input was accepted"); }
        catch (IllegalArgumentException expected) {}
    }
    public static void main(String[] args) {
        if (!SonyWifiCredentials.decode(packet("DIRECT-camera"), false).equals("DIRECT-camera")) throw new AssertionError();
        if (!SonyWifiCredentials.decode(packet("A1234567"), true).equals("A1234567")) throw new AssertionError();
        reject(new byte[]{1, 0}, false);
        reject(new byte[]{8, 0, 0, 65}, false);
        reject(packet("short"), true);
        reject(packet("camera\0hidden"), false);
        reject(packet("x".repeat(33)), false);
        reject(packet("x".repeat(64)), true);
        System.out.println("WifiPayload tests passed: valid packets, truncation, embedded NUL and bounds");
    }
}
