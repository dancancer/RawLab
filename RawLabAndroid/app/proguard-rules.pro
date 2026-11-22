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

# Keep all 22 classes, constructors, static callbacks, and fields looked up by initJniCache in rawlab_jni.cpp.
-keep class com.rawlab.android.engine.NativeFrame {
    <init>(int, int, android.graphics.Bitmap, float, float, int, int[]);
    static android.graphics.Bitmap allocateBitmap(int, int, android.graphics.Bitmap);
}
-keep class com.rawlab.android.engine.NativeProcessingException {
    <init>(...);
}
-keep class com.rawlab.android.engine.HDRProcessingException {
    <init>(int, int, int);
}
-keep class com.rawlab.android.looks.DcpCompilationException {
    <init>(int);
}

-keep class com.rawlab.android.engine.NativeProcessInput { <fields>; }
-keep class com.rawlab.android.engine.NativeProcessOutput { <fields>; }
-keep class com.rawlab.android.engine.NativeProcessWhiteBalance { <fields>; }
-keep class com.rawlab.android.engine.NativeProcessTone { <fields>; }
-keep class com.rawlab.android.engine.NativeDenoiseConfig { <fields>; }
-keep class com.rawlab.android.engine.NativePhotoEffectsConfig { <fields>; }
-keep class com.rawlab.android.engine.NativeHslProbeTarget { <fields>; }
-keep class com.rawlab.android.engine.NativeProcessRequest { <fields>; }
-keep class com.rawlab.android.engine.NativeGeometry { <fields>; }
-keep class com.rawlab.android.engine.NativeToneCurve { <fields>; }
-keep class com.rawlab.android.engine.NativeToneCurveParametric { <fields>; }
-keep class com.rawlab.android.engine.NativeColorGrading { <fields>; }
-keep class com.rawlab.android.engine.NativeColorGradingV2 { <fields>; }
-keep class com.rawlab.android.engine.NativeHDRTone { <fields>; }
-keep class com.rawlab.android.engine.NativeHDRColor { <fields>; }
-keep class com.rawlab.android.engine.NativeHDRRendition { <fields>; }
-keep class com.rawlab.android.engine.NativeHDRDetail { <fields>; }
-keep class com.rawlab.android.engine.NativeHDRLook { <fields>; }
-keep class com.rawlab.android.engine.NativeHDRChannelCurves { <fields>; }
-keep class com.rawlab.android.engine.NativeHDRRenderRequest { <fields>; }

# Keep standard Serializable members for LUTCompatibility models.
-keepclassmembers class * implements java.io.Serializable {
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}
