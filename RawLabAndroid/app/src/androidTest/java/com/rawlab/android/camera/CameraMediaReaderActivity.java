package com.rawlab.android.camera;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Process;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import org.json.JSONObject;

/** 独立测试 APK/UID 的媒体读取者，不使用目标应用的 ContentResolver。 */
public class CameraMediaReaderActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        Intent report = new Intent(getIntent().getStringExtra("reportAction"));
        report.setPackage(getIntent().getStringExtra("reportPackage"));
        JSONObject result = new JSONObject();
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            long size = 0;
            try (InputStream input = getContentResolver().openInputStream(getIntent().getData())) {
                if (input == null) throw new java.io.IOException("Cannot read media");
                byte[] buffer = new byte[64 * 1024];
                for (int count; (count = input.read(buffer)) >= 0;) { digest.update(buffer, 0, count); size += count; }
            }
            StringBuilder hash = new StringBuilder();
            for (byte value : digest.digest()) hash.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
            result.put("uid", Process.myUid()).put("bytes", size).put("sha256", hash.toString());
            report.putExtra("uid", Process.myUid()).putExtra("bytes", size).putExtra("sha256", hash.toString());
        } catch (Exception error) {
            report.putExtra("error", error.toString());
            try { result.put("error", error.toString()); } catch (Exception ignored) { }
        }
        try (java.io.FileOutputStream output = openFileOutput("camera-media-reader.json", MODE_PRIVATE)) {
            output.write(result.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) { }
        if (getIntent().getStringExtra("reportAction") != null && getIntent().getStringExtra("reportPackage") != null) sendBroadcast(report);
        finish();
    }
}
