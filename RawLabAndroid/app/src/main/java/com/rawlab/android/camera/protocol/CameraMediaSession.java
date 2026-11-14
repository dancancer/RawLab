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
    enum FailureKind { ITEM, SOURCE_CHANGED, TRANSIENT_READ, SESSION }

    /** 只把完整响应中的可重试读取归类为瞬态；写操作不能盲目重放。 */
    static FailureKind responseFailureKind(int operation, int code) {
        if (code == 0x2003 || code == 0x2004) return FailureKind.SESSION;
        boolean read = operation == 0x1001 || operation == 0x1004 || operation == 0x1007
            || operation == 0x1008 || operation == 0x100a || operation == 0x101b
            || operation == 0x9202 || operation == 0x9209 || operation == 0x923c || operation == 0x923d;
        // Sony 机身操作期间可能暂时以 OperationNotSupported 拒绝 923C；其它操作不作此推断。
        if (read && (code == 0x2019 || operation == 0x923c && code == 0x2005)) return FailureKind.TRANSIENT_READ;
        return FailureKind.ITEM;
    }

    /** 单张内容错误、来源变化、瞬态读取和会话错误分别处理，文案仅用于展示。 */
    class PhotoTransferException extends IOException {
        private final FailureKind kind;
        public PhotoTransferException(String message) { this(FailureKind.ITEM, message); }
        public PhotoTransferException(FailureKind kind, String message) { super(message); this.kind = kind; }
        public PhotoTransferException(String message, Throwable cause) { super(message, cause); this.kind = FailureKind.ITEM; }
        public FailureKind getKind() { return kind; }
        public boolean isSessionFailure() { return getKind() == FailureKind.SESSION; }
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
    /** 不支持范围读取时返回 null；调用方回落整张传输，不凭元数据跳过下载。 */
    default byte[] readRange(SonyMobileSession.Device device, SonyMobileSession.Asset asset, long offset, int length) throws IOException { return null; }
    String download(SonyMobileSession.Device device,SonyMobileSession.Asset asset,OutputStream destination,SonyMobileSession.Progress progress) throws IOException;
}
