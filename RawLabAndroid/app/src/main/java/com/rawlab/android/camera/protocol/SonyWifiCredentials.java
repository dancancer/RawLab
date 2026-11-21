package com.rawlab.android.camera.protocol;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

public final class SonyWifiCredentials {
    public static String decode(byte[] value, boolean password) {
        if (value == null || value.length <= 3 || (value[0] & 255) != value.length - 1)
            throw new IllegalArgumentException("相机 Wi-Fi 参数长度不完整");
        int end = value.length;
        while (end > 3 && value[end - 1] == 0) end--;
        int length = end - 3;
        if (length < (password ? 8 : 1) || length > (password ? 63 : 32))
            throw new IllegalArgumentException("相机 Wi-Fi 参数长度无效");
        for (int i = 3; i < end; i++)
            if (value[i] < 32 || value[i] > 126) throw new IllegalArgumentException("相机 Wi-Fi 参数包含无效字符");
        return new String(Arrays.copyOfRange(value, 3, end), StandardCharsets.US_ASCII);
    }
}
