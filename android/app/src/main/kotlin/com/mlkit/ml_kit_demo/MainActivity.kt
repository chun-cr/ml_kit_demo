package com.mlkit.ml_kit_demo

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizer
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizerResult
import com.google.mediapipe.tasks.vision.core.RunningMode
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "GestureRecognizer"
        private const val METHOD_CHANNEL = "gesture/frame"
        private const val EVENT_CHANNEL = "gesture/stream"
        private const val LANDMARK_CHANNEL = "landmark/stream"
        private const val MODEL_ASSET = "flutter_assets/assets/gesture_recognizer.task"
    }

    private var gestureRecognizer: GestureRecognizer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var landmarkSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var frameTimestamp: Long = 0

    // ── 独立节流时间戳 ──────────────────────────────────────────
    private var lastGestureTime: Long = 0
    private var lastLandmarkTime: Long = 0
    private val gestureIntervalMs = 100L   // 手势识别 100ms 一次
    private val landmarkIntervalMs = 30L   // 关键点描点 30ms 一次

    // ── 系统级异常兜底（兼容 OPPO/OnePlus ROM）──────────────────────
    override fun getSystemService(name: String): Any? {
        return try {
            super.getSystemService(name)
        } catch (e: IndexOutOfBoundsException) {
            Log.e(TAG, "Caught system IndexOutOfBoundsException: ${e.message}")
            null
        } catch (e: Exception) {
            Log.e(TAG, "Caught system exception: ${e.message}")
            null
        }
    }

    // ── 生命周期 ─────────────────────────────────────────────────
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val defaultExceptionHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            val stackTrace = throwable.stackTraceToString()
            if (throwable is IndexOutOfBoundsException && stackTrace.contains("OplusCameraUtils")) {
                Log.e(TAG, "Intercepted OplusCameraUtils crash: ${throwable.message}")
            } else {
                defaultExceptionHandler?.uncaughtException(thread, throwable)
            }
        }
    }

    override fun onDestroy() {
        gestureRecognizer?.close()
        gestureRecognizer = null
        tongueDetector?.close()
        tongueDetector = null
        super.onDestroy()
    }

    // ── Flutter Engine 配置 ──────────────────────────────────────
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        setupMethodChannel(flutterEngine)
        setupEventChannel(flutterEngine)
        setupLandmarkChannel(flutterEngine)

        // Tongue channels (new, additive)
        setupTongueChannels(flutterEngine)
    }

    // ── Tongue module additions ────────────────────────────────────
    private var tongueDetector: TongueDetector? = null
    private var tongueGuideSink:   EventChannel.EventSink? = null
    private var tongueCaptureSink: EventChannel.EventSink? = null

    private fun ensureGestureRecognizer() {
        if (gestureRecognizer == null) {
            setupGestureRecognizer()
        }
    }

    private fun ensureTongueDetector(): TongueDetector {
        tongueDetector?.let { return it }

        val detector = TongueDetector()
        detector.listener = object : TongueDetectorListener {
            override fun onGuideState(state: Map<String, Any>) {
                mainHandler.post { tongueGuideSink?.success(state) }
            }

            override fun onCapture(jpegBytes: ByteArray) {
                mainHandler.post { tongueCaptureSink?.success(jpegBytes) }
                detector.reset()
            }
        }

        tongueDetector = detector
        return detector
    }

    private fun setupTongueChannels(flutterEngine: FlutterEngine) {
        // MethodChannel: tongue/frame
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tongue/frame")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "warmup" -> {
                        ensureTongueDetector()
                        result.success(true)
                    }
                    "processFrame" -> {
                        val bytes    = call.argument<ByteArray>("bytes")
                        val width    = call.argument<Int>("width")    ?: 0
                        val height   = call.argument<Int>("height")   ?: 0
                        val rotation = call.argument<Int>("rotation") ?: 0
                        if (bytes != null && width > 0 && height > 0) {
                            ensureTongueDetector().processFrame(bytes, width, height, rotation)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGS", "Missing frame data", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // EventChannel: tongue/guide/stream
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "tongue/guide/stream")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    tongueGuideSink = events
                }
                override fun onCancel(arguments: Any?) { tongueGuideSink = null }
            })

        // EventChannel: tongue/capture/stream
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "tongue/capture/stream")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    tongueCaptureSink = events
                }
                override fun onCancel(arguments: Any?) { tongueCaptureSink = null }
            })
    }

    // ── 初始化 MediaPipe GestureRecognizer ──────────────────────
    private fun setupGestureRecognizer() {
        try {
            val baseOptions = BaseOptions.builder()
                .setModelAssetPath(MODEL_ASSET)
                .setDelegate(Delegate.CPU)
                .build()

            val options = GestureRecognizer.GestureRecognizerOptions.builder()
                .setBaseOptions(baseOptions)
                .setRunningMode(RunningMode.LIVE_STREAM)
                .setMinHandDetectionConfidence(0.5f)
                .setMinTrackingConfidence(0.5f)
                .setMinHandPresenceConfidence(0.5f)
                .setNumHands(2)
                .setResultListener { result: GestureRecognizerResult, _ ->
                    onGestureResult(result)
                }
                .setErrorListener { e ->
                    Log.e(TAG, "MediaPipe error: ${e.message}")
                }
                .build()

            gestureRecognizer = GestureRecognizer.createFromOptions(this, options)
            Log.i(TAG, "GestureRecognizer initialized successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to init GestureRecognizer: ${e.message}", e)
        }
    }

    // ── MethodChannel：接收 Flutter 传来的相机帧 ─────────────────
    private fun setupMethodChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "warmup" -> {
                        ensureGestureRecognizer()
                        result.success(true)
                    }
                    "processFrame" -> {
                        ensureGestureRecognizer()
                        val bytes = call.argument<ByteArray>("bytes")
                        val width = call.argument<Int>("width") ?: 0
                        val height = call.argument<Int>("height") ?: 0
                        val rotation = call.argument<Int>("rotation") ?: 0

                        if (bytes != null && width > 0 && height > 0) {
                            processFrame(bytes, width, height, rotation)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGS", "Missing or invalid frame data", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── EventChannel（手势识别结果） ────────────────────────────
    private fun setupEventChannel(flutterEngine: FlutterEngine) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    Log.i(TAG, "GestureChannel: Flutter started listening")
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    Log.i(TAG, "GestureChannel: Flutter stopped listening")
                }
            })
    }

    // ── EventChannel（关键点数据） ──────────────────────────────
    private fun setupLandmarkChannel(flutterEngine: FlutterEngine) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LANDMARK_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    landmarkSink = events
                    Log.i(TAG, "LandmarkChannel: Flutter started listening")
                }

                override fun onCancel(arguments: Any?) {
                    landmarkSink = null
                    Log.i(TAG, "LandmarkChannel: Flutter stopped listening")
                }
            })
    }

    // ── 帧处理：NV21 ByteArray → Bitmap → MPImage → recognizeAsync ─
    private fun processFrame(nv21Bytes: ByteArray, width: Int, height: Int, rotation: Int) {
        ensureGestureRecognizer()
        if (gestureRecognizer == null) return

        try {
            val yuvImage = YuvImage(nv21Bytes, ImageFormat.NV21, width, height, null)
            val out = ByteArrayOutputStream()
            yuvImage.compressToJpeg(Rect(0, 0, width, height), 80, out)
            val jpegBytes = out.toByteArray()
            var bitmap = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size)
                ?: return

            if (rotation != 0) {
                val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
                bitmap = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            }

            val mpImage = BitmapImageBuilder(bitmap).build()
            val timestamp = System.currentTimeMillis()

            if (timestamp <= frameTimestamp) return
            frameTimestamp = timestamp

            gestureRecognizer?.recognizeAsync(mpImage, timestamp)
        } catch (e: Exception) {
            Log.e(TAG, "processFrame error: ${e.message}")
        }
    }

    // ── 识别结果回调（分开节流：关键点 30ms，手势 100ms）─────────
    private fun onGestureResult(result: GestureRecognizerResult) {
        val now = System.currentTimeMillis()

        // ── 关键点推送（30ms 节流）──────────────────────────────
        if (now - lastLandmarkTime >= landmarkIntervalMs) {
            lastLandmarkTime = now
            pushLandmarks(result)
        }

        // ── 手势推送（100ms 节流）─────────────────────────────
        if (now - lastGestureTime >= gestureIntervalMs) {
            lastGestureTime = now
            pushGesture(result)
        }
    }

    // ── 推送关键点数据 ──────────────────────────────────────────
    private fun pushLandmarks(result: GestureRecognizerResult) {
        if (landmarkSink == null) return

        val allHandsLandmarks = mutableListOf<List<Map<String, Double>>>()

        for (handLandmarks in result.landmarks()) {
            val points = mutableListOf<Map<String, Double>>()
            for (lm in handLandmarks) {
                points.add(mapOf("x" to lm.x().toDouble(), "y" to lm.y().toDouble()))
            }
            allHandsLandmarks.add(points)
        }

        mainHandler.post {
            landmarkSink?.success(
                mapOf(
                    "hands" to allHandsLandmarks,
                    "numHands" to allHandsLandmarks.size
                )
            )
        }
    }

    // ── 推送手势结果 ────────────────────────────────────────────
    private fun pushGesture(result: GestureRecognizerResult) {
        if (eventSink == null) return

        if (result.gestures().isEmpty()) {
            mainHandler.post {
                eventSink?.success(
                    mapOf(
                        "gesture" to "None",
                        "confidence" to 0.0,
                        "handedness" to "",
                        "numHands" to 0
                    )
                )
            }
            return
        }

        val allHands = mutableListOf<Map<String, Any>>()

        for (i in result.gestures().indices) {
            val topGesture = result.gestures()[i][0]
            val handedness = if (result.handednesses().size > i) {
                result.handednesses()[i][0].categoryName()
            } else {
                "Unknown"
            }

            allHands.add(
                mapOf(
                    "gesture" to topGesture.categoryName(),
                    "confidence" to topGesture.score().toDouble(),
                    "handedness" to handedness
                )
            )
        }

        val primary = allHands[0]
        mainHandler.post {
            eventSink?.success(
                mapOf(
                    "gesture" to primary["gesture"]!!,
                    "confidence" to primary["confidence"]!!,
                    "handedness" to primary["handedness"]!!,
                    "numHands" to allHands.size,
                    "allHands" to allHands
                )
            )
        }
    }
}
