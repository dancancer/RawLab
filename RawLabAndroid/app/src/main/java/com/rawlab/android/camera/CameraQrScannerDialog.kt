package com.rawlab.android.camera

import android.util.Log
import android.util.Size
import android.view.MotionEvent
import android.view.ViewGroup
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.GlobalHistogramBinarizer
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import com.rawlab.android.BuildConfig
import com.rawlab.android.R
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.delay

@Composable
internal fun CameraQrScannerDialog(
    onScanned: (CameraWifiQrCredentials) -> Unit,
    onDismiss: () -> Unit,
    onUnavailable: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val mainExecutor = remember(context) { ContextCompat.getMainExecutor(context) }
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    val delivered = remember { AtomicBoolean(false) }
    var invalidHint by remember { mutableStateOf(false) }
    var cameraProvider by remember { mutableStateOf<ProcessCameraProvider?>(null) }
    var boundCamera by remember { mutableStateOf<Camera?>(null) }
    var zoomRatio by remember { mutableFloatStateOf(1.5f) }
    var maxZoomRatio by remember { mutableFloatStateOf(1f) }
    val previewView = remember(context) {
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
    }

    fun triggerFocusAndExposure(camera: Camera, x: Float, y: Float) {
        runCatching {
            val point = previewView.meteringPointFactory.createPoint(x, y)
            val action = FocusMeteringAction.Builder(
                point,
                FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE,
            )
                .setAutoCancelDuration(3, TimeUnit.SECONDS)
                .build()
            camera.cameraControl.startFocusAndMetering(action)
        }
    }

    LaunchedEffect(boundCamera, previewView) {
        val camera = boundCamera ?: return@LaunchedEffect
        // Periodically meter AF + AE on the center framing box so backlit camera LCDs
        // don't blow out against a darker room and small QR codes stay tack-sharp.
        delay(250)
        while (true) {
            val width = previewView.width
            val height = previewView.height
            if (width > 0 && height > 0) {
                triggerFocusAndExposure(camera, width * 0.5f, height * 0.5f)
            }
            delay(3_000)
        }
    }

    LaunchedEffect(boundCamera, zoomRatio, maxZoomRatio) {
        val camera = boundCamera ?: return@LaunchedEffect
        if (maxZoomRatio > 1.05f) {
            val clamped = zoomRatio.coerceIn(1f, maxZoomRatio)
            runCatching { camera.cameraControl.setZoomRatio(clamped) }
        }
    }

    DisposableEffect(lifecycleOwner, previewView) {
        var disposed = false
        val future = ProcessCameraProvider.getInstance(context)
        val analyzer = QrFrameAnalyzer(
            delivered = delivered,
            onValid = { credentials, summary ->
                mainExecutor.execute {
                    if (disposed) return@execute
                    CameraDiagnostics.breadcrumb(
                        stage = "qrCodeScanned",
                        message = "Scanned valid camera Wi-Fi QR code",
                        context = mapOf("summary" to summary),
                    )
                    runCatching { cameraProvider?.unbindAll() }
                    onScanned(credentials)
                }
            },
            onInvalid = { summary ->
                mainExecutor.execute {
                    if (disposed) return@execute
                    invalidHint = true
                    CameraDiagnostics.breadcrumb(
                        stage = "qrCodeIgnored",
                        message = "Scanned QR code is not a supported camera Wi-Fi payload",
                        level = "warn",
                        context = mapOf("summary" to summary),
                    )
                }
            },
        )
        previewView.setOnTouchListener { view, event ->
            if (event.action == MotionEvent.ACTION_UP) {
                boundCamera?.let { triggerFocusAndExposure(it, event.x, event.y) }
                view.performClick()
            }
            true
        }
        future.addListener(
            {
                if (disposed) return@addListener
                try {
                    val provider = future.get()
                    cameraProvider = provider
                    val preview = Preview.Builder().build().also {
                        it.surfaceProvider = previewView.surfaceProvider
                    }
                    // Prefer 1080p/720p YUV frames instead of CameraX's 640x480 default so small
                    // camera LCD QR codes have enough pixels per module to decode on the first frame.
                    val resolutionSelector = ResolutionSelector.Builder()
                        .setResolutionStrategy(
                            ResolutionStrategy(
                                Size(1920, 1080),
                                ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
                            ),
                        )
                        .build()
                    val analysis = ImageAnalysis.Builder()
                        .setResolutionSelector(resolutionSelector)
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                        .build()
                        .also { it.setAnalyzer(analysisExecutor, analyzer) }
                    val selector = when {
                        provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) -> CameraSelector.DEFAULT_BACK_CAMERA
                        provider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) -> CameraSelector.DEFAULT_FRONT_CAMERA
                        else -> {
                            onUnavailable()
                            return@addListener
                        }
                    }
                    provider.unbindAll()
                    val camera = provider.bindToLifecycle(lifecycleOwner, selector, preview, analysis)
                    boundCamera = camera
                    val maxZoom = camera.cameraInfo.zoomState.value?.maxZoomRatio ?: 1f
                    maxZoomRatio = maxZoom
                    val initialZoom = if (maxZoom >= 2.0f) 1.5f else 1f
                    zoomRatio = initialZoom
                    if (initialZoom > 1f) {
                        runCatching { camera.cameraControl.setZoomRatio(initialZoom) }
                    }
                } catch (error: Throwable) {
                    CameraDiagnostics.error(
                        stage = "qrScannerBind",
                        error = error,
                    )
                    onUnavailable()
                }
            },
            mainExecutor,
        )
        onDispose {
            disposed = true
            previewView.setOnTouchListener(null)
            boundCamera = null
            runCatching { cameraProvider?.unbindAll() }
            cameraProvider = null
            analysisExecutor.shutdown()
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            dismissOnClickOutside = false,
        ),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black)
                .testTag("camera-qr-scanner"),
        ) {
            AndroidView(
                factory = { previewView },
                modifier = Modifier.fillMaxSize(),
            )
            // Center framing box matching the center AF/AE metering point and primary QR ROI.
            Box(
                modifier = Modifier
                    .align(Alignment.Center)
                    .size(240.dp)
                    .border(
                        border = BorderStroke(2.dp, Color.White.copy(alpha = 0.85f)),
                        shape = RoundedCornerShape(12.dp),
                    ),
            )
            Row(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .fillMaxWidth()
                    .background(Color.Black.copy(alpha = 0.55f))
                    .statusBarsPadding()
                    .padding(horizontal = 8.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(
                    onClick = onDismiss,
                    modifier = Modifier.testTag("camera-qr-close"),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Close,
                        contentDescription = stringResource(R.string.cancel),
                        tint = Color.White,
                    )
                }
                Text(
                    text = stringResource(R.string.camera_scan_qr),
                    color = Color.White,
                    style = MaterialTheme.typography.titleMedium,
                )
            }
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .background(Color.Black.copy(alpha = 0.65f))
                    .navigationBarsPadding()
                    .padding(horizontal = 24.dp, vertical = 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (maxZoomRatio >= 2.0f) {
                    val zoomPresets = remember(maxZoomRatio) {
                        listOf(1f, 1.5f, 2f).filter { it <= maxZoomRatio }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        zoomPresets.forEach { preset ->
                            val selected = kotlin.math.abs(zoomRatio - preset) < 0.1f
                            val label = if (preset == 1.5f) "1.5×" else "${preset.toInt()}×"
                            FilterChip(
                                selected = selected,
                                onClick = { zoomRatio = preset },
                                label = { Text(label) },
                                colors = FilterChipDefaults.filterChipColors(
                                    labelColor = Color.White,
                                    selectedLabelColor = Color.Black,
                                    selectedContainerColor = Color.White,
                                ),
                                modifier = Modifier.testTag("camera-qr-zoom-$label"),
                            )
                        }
                    }
                }
                Text(
                    text = stringResource(R.string.camera_qr_guide),
                    color = Color.White,
                    style = MaterialTheme.typography.bodyMedium,
                    textAlign = TextAlign.Center,
                )
                if (invalidHint) {
                    Text(
                        text = stringResource(R.string.camera_qr_invalid),
                        color = Color(0xFFFFB74D),
                        style = MaterialTheme.typography.bodySmall,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.testTag("camera-qr-invalid-hint"),
                    )
                }
            }
        }
    }
}

private class QrFrameAnalyzer(
    private val delivered: AtomicBoolean,
    private val onValid: (CameraWifiQrCredentials, String) -> Unit,
    private val onInvalid: (String) -> Unit,
) : ImageAnalysis.Analyzer {
    private val reader = QRCodeReader()
    private val hints = mapOf(
        DecodeHintType.TRY_HARDER to true,
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.CHARACTER_SET to "UTF-8",
    )
    private var yBuffer = ByteArray(0)
    private var rowBytes = ByteArray(0)
    private var frameCount = 0
    private var loggedResolution = false
    private var lastInvalidAtMs = 0L

    override fun analyze(image: ImageProxy) {
        try {
            if (delivered.get()) return
            val width = image.width
            val height = image.height
            if (width <= 0 || height <= 0) return
            if (!loggedResolution) {
                loggedResolution = true
                if (BuildConfig.DEBUG) {
                    runCatching {
                        Log.d(
                            "RawLabCamera",
                            "QR analyzer frame=${width}x${height} rot=${image.imageInfo.rotationDegrees}",
                        )
                    }
                }
            }
            val yPlane = image.planes.firstOrNull() ?: return
            val packed = extractLuminance(yPlane, width, height)
            frameCount++

            // 1. Center square ROI matching the viewfinder box (eliminates dark surrounding room
            //    so local and global thresholding lock onto the bright camera LCD QR code).
            val minSide = minOf(width, height)
            val roiSide = (minSide * 0.72f).toInt().coerceAtLeast(1)
            val roiLeft = (width - roiSide) / 2
            val roiTop = (height - roiSide) / 2
            val centerSource = PlanarYUVLuminanceSource(
                packed,
                width,
                height,
                roiLeft,
                roiTop,
                roiSide,
                roiSide,
                false,
            )

            // 2. Full frame fallback when the QR code sits closer or slightly off-center.
            val fullSource = PlanarYUVLuminanceSource(
                packed,
                width,
                height,
                0,
                0,
                width,
                height,
                false,
            )

            val decoded = decodeMultiStrategy(centerSource)
                ?: decodeMultiStrategy(fullSource)
                ?: (if (frameCount % 2 == 0) decodeHybrid(centerSource.invert()) else null)
                ?: return

            val parsed = CameraWifiQrCode.parse(decoded)
            val summary = CameraWifiQrCode.safeSummary(decoded)
            if (parsed != null) {
                if (delivered.compareAndSet(false, true)) {
                    onValid(parsed, summary)
                }
            } else {
                val now = System.currentTimeMillis()
                if (now - lastInvalidAtMs >= 1_500L) {
                    lastInvalidAtMs = now
                    onInvalid(summary)
                }
            }
        } catch (_: Throwable) {
            // Ignore transient frame decode issues and continue scanning.
        } finally {
            image.close()
        }
    }

    private fun decodeMultiStrategy(source: LuminanceSource): String? =
        decodeHybrid(source) ?: decodeGlobal(source)

    private fun decodeHybrid(source: LuminanceSource): String? = try {
        reader.decode(BinaryBitmap(HybridBinarizer(source)), hints).text
    } catch (_: NotFoundException) {
        null
    } catch (_: Exception) {
        null
    } finally {
        reader.reset()
    }

    private fun decodeGlobal(source: LuminanceSource): String? = try {
        reader.decode(BinaryBitmap(GlobalHistogramBinarizer(source)), hints).text
    } catch (_: NotFoundException) {
        null
    } catch (_: Exception) {
        null
    } finally {
        reader.reset()
    }

    private fun extractLuminance(plane: ImageProxy.PlaneProxy, width: Int, height: Int): ByteArray {
        val needed = width * height
        if (yBuffer.size != needed) yBuffer = ByteArray(needed)
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        if (pixelStride == 1 && rowStride == width) {
            buffer.rewind()
            buffer.get(yBuffer, 0, needed)
            return yBuffer
        }
        if (rowBytes.size < rowStride) rowBytes = ByteArray(rowStride)
        val limit = buffer.limit()
        var dst = 0
        for (row in 0 until height) {
            val rowStart = row * rowStride
            val available = (limit - rowStart).coerceAtMost(rowStride).coerceAtLeast(0)
            if (available == 0) break
            buffer.position(rowStart)
            buffer.get(rowBytes, 0, available)
            if (pixelStride == 1) {
                val copyLen = width.coerceAtMost(available)
                System.arraycopy(rowBytes, 0, yBuffer, dst, copyLen)
                dst += width
            } else {
                var col = 0
                while (col < width && col * pixelStride < available) {
                    yBuffer[dst++] = rowBytes[col * pixelStride]
                    col++
                }
            }
        }
        return yBuffer
    }
}
