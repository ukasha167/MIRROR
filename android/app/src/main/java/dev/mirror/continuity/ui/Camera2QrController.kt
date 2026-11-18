package dev.mirror.continuity.ui

import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.util.Size
import android.view.Surface
import android.view.TextureView
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.math.max

/**
 * Lightweight Camera2 + ML Kit QR detector writing live frames from a [TextureView] preview
 * without CameraX compileSdk constraints.
 */
internal class Camera2QrController(
    context: Context,
    private val onQrDetected: (String) -> Unit,
    private val onError: (String) -> Unit
) {
    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val scanner = BarcodeScanning.getClient(
        BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
    )
    private val mainHandler = Handler(Looper.getMainLooper())
    private val emitted = AtomicBoolean(false)
    private val released = AtomicBoolean(false)
    private val processingFrame = AtomicBoolean(false)
    private val consecutiveScanErrors = AtomicInteger(0)

    private var handlerThread: HandlerThread? = null
    private var bgHandler: Handler? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var previewRequestBuilder: CaptureRequest.Builder? = null
    private var imageReader: ImageReader? = null
    private var sensorOrientation = 90
    private var lensFacing = CameraCharacteristics.LENS_FACING_BACK
    private var streamWidth = 1280
    private var streamHeight = 720
    private var supportedAfModes: IntArray = IntArray(0)

    @Suppress("MissingPermission")
    fun startCamera(textureView: TextureView, surfaceTexture: SurfaceTexture, viewWidth: Int, viewHeight: Int) {
        val cameraId = selectBackCameraId() ?: run {
            postError("No back camera available")
            return
        }
        val chars = cameraManager.getCameraCharacteristics(cameraId)
        sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        lensFacing = chars.get(CameraCharacteristics.LENS_FACING) ?: CameraCharacteristics.LENS_FACING_BACK
        supportedAfModes = chars.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: IntArray(0)
        val chosen = selectStreamSize(chars)
        streamWidth = chosen.width
        streamHeight = chosen.height

        val thread = HandlerThread("ContinuityQrCamera").also { it.start() }
        handlerThread = thread
        val handler = Handler(thread.looper)
        bgHandler = handler

        surfaceTexture.setDefaultBufferSize(streamWidth, streamHeight)
        configurePreviewTransform(textureView, viewWidth, viewHeight)

        val previewSurface = Surface(surfaceTexture)
        val reader = ImageReader.newInstance(streamWidth, streamHeight, ImageFormat.YUV_420_888, 2).apply {
            setOnImageAvailableListener({ r ->
                val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
                if (released.get() || emitted.get() || !processingFrame.compareAndSet(false, true)) {
                    image.close()
                    return@setOnImageAvailableListener
                }
                val rotation = computeImageRotation(textureView.display?.rotation ?: Surface.ROTATION_0)
                val input = InputImage.fromMediaImage(image, rotation)
                scanner.process(input)
                    .addOnSuccessListener { barcodes ->
                        consecutiveScanErrors.set(0)
                        val raw = barcodes.firstOrNull { !it.rawValue.isNullOrBlank() }?.rawValue
                        if (raw != null && emitted.compareAndSet(false, true)) {
                            mainHandler.post { onQrDetected(raw) }
                        }
                    }
                    .addOnFailureListener { e ->
                        Log.w("Camera2QrController", "QR frame analysis failed", e)
                        if (consecutiveScanErrors.incrementAndGet() == 10) {
                            postError("QR detector failed: ${e.localizedMessage ?: "retry"}")
                        }
                    }
                    .addOnCompleteListener {
                        processingFrame.set(false)
                        image.close()
                    }
            }, handler)
        }
        imageReader = reader

        runCatching {
            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    if (released.get()) {
                        camera.close()
                        return
                    }
                    cameraDevice = camera
                    createCaptureSession(camera, previewSurface, reader.surface, handler)
                }
                override fun onDisconnected(camera: CameraDevice) { camera.close() }
                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    postError("Camera failed ($error)")
                }
            }, handler)
        }.onFailure { postError(it.message ?: "Unable to open camera") }
    }

    fun configurePreviewTransform(
        textureView: TextureView,
        viewWidth: Int,
        viewHeight: Int,
        bufW: Int = streamWidth,
        bufH: Int = streamHeight
    ) {
        if (viewWidth <= 0 || viewHeight <= 0) return
        val matrix = Matrix()
        val viewRect = RectF(0f, 0f, viewWidth.toFloat(), viewHeight.toFloat())
        val displayDeg = surfaceRotationDegrees(textureView.display?.rotation ?: Surface.ROTATION_0)
        val isRotated = ((sensorOrientation - displayDeg + 360) % 180) != 0
        val bufferRect = RectF(0f, 0f, (if (isRotated) bufH else bufW).toFloat(), (if (isRotated) bufW else bufH).toFloat())
        val centerX = viewRect.centerX()
        val centerY = viewRect.centerY()
        bufferRect.offset(centerX - bufferRect.centerX(), centerY - bufferRect.centerY())
        matrix.setRectToRect(viewRect, bufferRect, Matrix.ScaleToFit.FILL)
        val scale = max(viewHeight.toFloat() / bufferRect.height(), viewWidth.toFloat() / bufferRect.width())
        matrix.postScale(scale, scale, centerX, centerY)
        if (displayDeg != 0) matrix.postRotate(-displayDeg.toFloat(), centerX, centerY)
        textureView.setTransform(matrix)
    }

    @Suppress("DEPRECATION")
    private fun createCaptureSession(camera: CameraDevice, previewSurface: Surface, readerSurface: Surface, handler: Handler) {
        val builder = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
            addTarget(previewSurface)
            addTarget(readerSurface)
            set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
            set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            when {
                supportedAfModes.contains(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE) ->
                    set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                supportedAfModes.contains(CaptureRequest.CONTROL_AF_MODE_AUTO) ->
                    set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
            }
        }
        previewRequestBuilder = builder

        runCatching {
            camera.createCaptureSession(
                listOf(previewSurface, readerSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        runCatching { session.setRepeatingRequest(builder.build(), null, handler) }
                    }
                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        postError("Camera preview session failed")
                    }
                },
                handler
            )
        }
    }

    fun setTorch(enabled: Boolean) {
        val builder = previewRequestBuilder ?: return
        val session = captureSession ?: return
        val handler = bgHandler ?: return
        builder.set(CaptureRequest.FLASH_MODE, if (enabled) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF)
        runCatching { session.setRepeatingRequest(builder.build(), null, handler) }
    }

    fun release() {
        if (!released.compareAndSet(false, true)) return
        runCatching { captureSession?.close() }
        captureSession = null
        runCatching { cameraDevice?.close() }
        cameraDevice = null
        runCatching { imageReader?.close() }
        imageReader = null
        runCatching { handlerThread?.quitSafely() }
        handlerThread = null
        runCatching { scanner.close() }
    }

    private fun postError(message: String) {
        if (!released.get()) mainHandler.post { onError(message) }
    }

    private fun surfaceRotationDegrees(rotation: Int): Int = when (rotation) {
        Surface.ROTATION_90 -> 90
        Surface.ROTATION_180 -> 180
        Surface.ROTATION_270 -> 270
        else -> 0
    }

    private fun computeImageRotation(displayRotation: Int): Int {
        val displayDeg = surfaceRotationDegrees(displayRotation)
        return if (lensFacing == CameraCharacteristics.LENS_FACING_FRONT) {
            (sensorOrientation + displayDeg) % 360
        } else {
            (sensorOrientation - displayDeg + 360) % 360
        }
    }

    private fun selectStreamSize(chars: CameraCharacteristics): Size {
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val yuv = map?.getOutputSizes(ImageFormat.YUV_420_888)?.toList().orEmpty()
        val preview = map?.getOutputSizes(SurfaceTexture::class.java)?.toSet().orEmpty()
        val common = yuv.filter { s -> preview.isEmpty() || preview.contains(s) }
        val pool = common.ifEmpty { yuv }
        return pool
            .filter { it.width in 960..1920 && it.height in 540..1440 }
            .minByOrNull { abs(it.width * it.height - 1920 * 1080) }
            ?: pool.maxByOrNull { it.width * it.height }
            ?: Size(1280, 720)
    }

    private fun selectBackCameraId(): String? {
        for (id in cameraManager.cameraIdList) {
            if (cameraManager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK) {
                return id
            }
        }
        return cameraManager.cameraIdList.firstOrNull()
    }
}
