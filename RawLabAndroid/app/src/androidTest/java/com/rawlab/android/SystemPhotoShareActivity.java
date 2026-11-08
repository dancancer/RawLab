package com.rawlab.android;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import java.util.ArrayList;
import java.util.Arrays;

/** 从测试 APK 的独立 UID 发起分享，只给第一张照片临时读取授权。 */
public class SystemPhotoShareActivity extends Activity {
    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Uri readable = Uri.parse(getIntent().getStringExtra("readable"));
        Uri denied = Uri.parse(getIntent().getStringExtra("denied"));
        Intent share = new Intent(Intent.ACTION_SEND_MULTIPLE);
        share.setClassName(getIntent().getStringExtra("targetPackage"), "com.rawlab.android.SystemPhotoForwardActivity");
        share.setType("image/png");
        share.putParcelableArrayListExtra(Intent.EXTRA_STREAM, new ArrayList<>(Arrays.asList(readable, denied)));
        share.setClipData(ClipData.newRawUri("test", readable));
        share.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivity(share);
        finish();
    }
}
