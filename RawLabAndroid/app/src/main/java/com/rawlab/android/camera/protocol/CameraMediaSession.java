package com.rawlab.android.camera.protocol;

import java.io.Closeable;
import java.io.IOException;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** 选片导入只持有媒体接口，不具备拍摄或更改相机设置的入口。 */
public interface CameraMediaSession extends Closeable {
    int MAX_LISTED_PHOTOS = 10000;

    final class UnsupportedCameraException extends IOException {
        public UnsupportedCameraException(String identity) { super("Unsupported camera profile: "+identity); }
    }
    /** 单张原件被相机拒绝或内容不合预期，但会话报文边界仍然完整，可继续传输其余照片。 */
    class PhotoTransferException extends IOException {
        public PhotoTransferException(String message) { super(message); }
        public PhotoTransferException(String message, Throwable cause) { super(message, cause); }
        public boolean isSessionFailure() { return false; }
    }
    /** 存储卡内照片或句柄超出单次列表上限；携带已截取的最近照片供上层继续浏览与导入。 */
    final class PhotoLimitExceededException extends IOException {
        public final List<SonyMobileSession.Asset> recentAssets;
        public PhotoLimitExceededException(String message) { this(message, Collections.emptyList()); }
        public PhotoLimitExceededException(String message, List<SonyMobileSession.Asset> recentAssets) {
            super(message);
            this.recentAssets = Collections.unmodifiableList(new ArrayList<>(recentAssets));
        }
    }
    default boolean isOpen() { return true; }
    SonyMobileSession.Device deviceInfo() throws IOException;
    void openSession() throws IOException;
    List<SonyMobileSession.Asset> listPhotos(SonyMobileSession.Device device) throws IOException;
    byte[] preview(SonyMobileSession.Asset asset,boolean large) throws IOException;
    String download(SonyMobileSession.Device device,SonyMobileSession.Asset asset,OutputStream destination,SonyMobileSession.Progress progress) throws IOException;
}
