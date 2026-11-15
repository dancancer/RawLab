package com.rawlab.android.raster

import java.io.File

/** Shared native MPF validation for JPEG containers with indexed auxiliary images. */
internal object NativeMpf {
    init { System.loadLibrary("rawlab-jni") }

    fun inspectSdrJpegMpf(file: File): Int = nativeInspectSdrJpegMpf(file.path)

    private external fun nativeInspectSdrJpegMpf(path: String): Int
}
