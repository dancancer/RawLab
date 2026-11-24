# Keep all JNI entry points and native method host classes.
-keepclasseswithmembernames,includedescriptorclasses class com.rawlab.android.** {
    native <methods>;
}

-keep class com.rawlab.android.engine.NativeProcessor { *; }
-keep class com.rawlab.android.engine.NativeLookBridge { *; }
-keep class com.rawlab.android.engine.NativeDcpBridge { *; }
-keep class com.rawlab.android.engine.NativeHDRBridge { *; }
-keep class com.rawlab.android.engine.HDRProgressListener { void onProgress(int); }
-keep class com.rawlab.android.engine.ToneCurveSampling { *; }
-keep class com.rawlab.android.raster.NativeMpf { *; }
-keep class com.rawlab.android.raster.NativePng16 { *; }
-keep class com.rawlab.android.editor.inspection.InspectionNative { *; }
-keep class com.rawlab.android.editor.canvas.ViewportNative { *; }

# Aliyun RUM's native libraries resolve types in these packages by JNI class name.
-keep class com.alibabacloud.rum.capture.anr.** { *; }
-keep class com.alibabacloud.rum.config.** { *; }
-keep class com.alibabacloud.rum.producer.** { *; }

# Keep all 19 app classes, constructors, and callbacks looked up by initJniCache in jni_sdr.cpp.
-keep class com.rawlab.android.engine.NativeFrame {
    <init>(int, int, android.graphics.Bitmap, float, float, int, int[]);
    static android.graphics.Bitmap allocateBitmap(int, int, android.graphics.Bitmap);
}
-keep class com.rawlab.android.engine.NativeProcessingException {
    <init>(int, java.lang.String, int);
}
-keep class com.rawlab.android.engine.HDRProcessingException {
    <init>(int, int, int);
}
-keep class com.rawlab.android.looks.DcpCompilationException {
    <init>(int);
}
-keep class com.rawlab.android.engine.LUTColorContractException {
    <init>(int);
}
-keep class com.rawlab.android.photo.HDRSourceInfo {
    <init>(int, int, int, int, int, int, float, int, byte[], boolean, int);
}
-keep class com.rawlab.android.engine.NativeRoiBounds {
    <init>(int, int, int, int, int, int);
    <fields>;
}
-keep class com.rawlab.android.engine.NativeRoiFrame {
    <init>(com.rawlab.android.engine.NativeFrame, com.rawlab.android.engine.NativeRoiBounds);
    <fields>;
}
-keep class com.rawlab.android.engine.NativeWbProbeResult {
    <init>(int, float, float, int, int);
    <fields>;
}
-keep class com.rawlab.android.engine.NativeHslProbeResult {
    <init>(int, boolean, float[], float[]);
    <fields>;
}
-keep class com.rawlab.android.engine.NativeMigrationResult {
    <init>(int, int, int, int, float, float, float, float, float, float, float, float, float, float, float, float, float, float);
    <fields>;
}
-keep class com.rawlab.android.engine.LensCandidate {
    <init>(java.lang.String, java.lang.String, java.lang.String, boolean, boolean, boolean, boolean);
    <fields>;
}
-keep class com.rawlab.android.engine.NativeLensReport {
    <init>(int, java.lang.String, java.lang.String, boolean, boolean, float, boolean);
    <fields>;
}
-keep class com.rawlab.android.engine.NativeLensInspection {
    <init>(boolean, boolean, boolean);
    <fields>;
}
-keep class com.rawlab.android.engine.NativeLookValidation {
    <init>(int, int, int);
    <fields>;
}
-keep class com.rawlab.android.engine.NativeCameraWhiteBalance {
    <init>(float, float);
    <fields>;
}
-keep class com.rawlab.android.engine.NativeHDRPairInfo {
    <init>(int, int, int, int, int, int, float, float);
    <fields>;
}
-keep class com.rawlab.android.engine.NativeHDRRoiPair {
    <init>(long, com.rawlab.android.engine.NativeRoiBounds);
    <fields>;
}

# Keep standard Serializable members for LUTCompatibility models.
-keepclassmembers class * implements java.io.Serializable {
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# Keep mwiede/jsch classes loaded via reflection for Sony Access Authentication (SSH).
-keep class com.jcraft.jsch.** { *; }
-keep interface com.jcraft.jsch.** { *; }
-keepclassmembers class * implements com.jcraft.jsch.UserInfo { *; }
-keepclassmembers class * implements com.jcraft.jsch.UIKeyboardInteractive { *; }
-keepclassmembers class * implements com.jcraft.jsch.HostKeyRepository { *; }
-keepclassmembers class * implements com.jcraft.jsch.SocketFactory { *; }
-keepclassmembers class * implements com.jcraft.jsch.Logger { *; }

# Optional desktop/agent/logging/BouncyCastle adapters probed reflectively by JSch at runtime.
-dontwarn com.sun.jna.**
-dontwarn org.apache.logging.log4j.**
-dontwarn org.bouncycastle.**
-dontwarn org.ietf.jgss.**
-dontwarn org.newsclub.net.unix.**
-dontwarn org.slf4j.**
