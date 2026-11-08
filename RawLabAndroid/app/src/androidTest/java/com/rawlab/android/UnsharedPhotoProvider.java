package com.rawlab.android;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.UUID;

/** 独立测试 APK 的组件只依赖系统类，不依赖目标应用提供的 Kotlin 运行库。 */
public class UnsharedPhotoProvider extends ContentProvider {
    private File source;

    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return "image/png"; }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        MatrixCursor cursor = new MatrixCursor(new String[] { OpenableColumns.DISPLAY_NAME });
        cursor.addRow(new Object[] { "shared.png" });
        return cursor;
    }
    @Override public synchronized ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (source == null) {
            source = new File(getContext().getCacheDir(), "forwarding-provider.png");
            try (FileOutputStream output = new FileOutputStream(source)) {
                output.write(png());
            } catch (IOException error) {
                source = null;
                throw new FileNotFoundException(error.toString());
            }
        }
        return ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public Uri insert(Uri uri, ContentValues values) { return null; }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) { return 0; }
    @Override public int delete(Uri uri, String selection, String[] selectionArgs) { return 0; }

    public static byte[] png() {
        Bitmap bitmap = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888);
        try {
            bitmap.eraseColor(android.graphics.Color.MAGENTA);
            UUID unique = UUID.randomUUID();
            long[] parts = { unique.getMostSignificantBits(), unique.getLeastSignificantBits() };
            for (int index = 0; index < parts.length; index++) {
                bitmap.setPixel(index * 2, 0, (int) parts[index] | 0xff000000);
                bitmap.setPixel(index * 2 + 1, 0, (int) (parts[index] >>> 32) | 0xff000000);
            }
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) throw new AssertionError("PNG compression failed");
            return output.toByteArray();
        } finally { bitmap.recycle(); }
    }
}
