package com.rawlab.android.camera.protocol;

import java.io.Closeable;
import java.io.IOException;
import java.io.OutputStream;
import java.util.List;

/** 选片导入只持有媒体接口，不具备拍摄或更改相机设置的入口。 */
public interface CameraMediaSession extends Closeable {
    final class UnsupportedCameraException extends IOException {
        public UnsupportedCameraException(String identity) { super("Unsupported camera profile: "+identity); }
    }
    SonyMobileSession.Device deviceInfo() throws IOException;
    void openSession() throws IOException;
    List<SonyMobileSession.Asset> listPhotos(SonyMobileSession.Device device) throws IOException;
    byte[] preview(SonyMobileSession.Asset asset,boolean large) throws IOException;
    String download(SonyMobileSession.Device device,SonyMobileSession.Asset asset,OutputStream destination,SonyMobileSession.Progress progress) throws IOException;
}
