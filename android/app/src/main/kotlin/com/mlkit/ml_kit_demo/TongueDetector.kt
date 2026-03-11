// TongueDetector.kt
// Android 舌诊引导检测器：使用 ML Kit FaceDetector 关键点检测张嘴状态，
// 再对相机帧 ROI 区域做红色像素分析判断舌头可见性
// 不修改任何现有文件；由 MainActivity 实例化

package com.mlkit.ml_kit_demo

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.face.FaceLandmark
import com.google.mlkit.vision.face.FaceContour
import java.io.ByteArrayOutputStream
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

// 引导状态回调
interface TongueDetectorListener {
    fun onGuideState(state: Map<String, Any>)
    fun onCapture(jpegBytes: ByteArray)
}

class TongueDetector {

    companion object {
        private const val TAG = "TongueDetector"
        private const val MOUTH_OPEN_THRESHOLD_PX = 20f  // 上下嘴唇 y 像素距离
        private const val RED_PIXEL_RATIO_THRESHOLD = 0.15
        private const val STABLE_FRAMES_NEEDED = 10
    }

    var listener: TongueDetectorListener? = null

    private var stableCount    = 0
    private var hasCaptured    = false
    private var lastProcessMs  = 0L
    private val processIntervalMs = 100L

    private val faceDetector: FaceDetector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
            .setContourMode(FaceDetectorOptions.CONTOUR_MODE_ALL)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_NONE)
            .build()
    )

    // 处理 NV21 帧（与 MainActivity 一致的参数格式）
    fun processFrame(nv21Bytes: ByteArray, width: Int, height: Int, rotation: Int) {
        val now = System.currentTimeMillis()
        if (now - lastProcessMs < processIntervalMs) return
        lastProcessMs = now

        val bitmap = nv21ToBitmap(nv21Bytes, width, height, rotation) ?: return
        val inputImage = InputImage.fromBitmap(bitmap, 0)

        faceDetector.process(inputImage)
            .addOnSuccessListener { faces ->
                if (faces.isEmpty()) {
                    resetStable()
                    pushGuideState(false, false, false, false, 0.0, "请将面部对准摄像头")
                    return@addOnSuccessListener
                }
                val face = faces[0]
                val mouthOpen = isMouthOpen(face)
                val tongueVisible = if (mouthOpen) detectTongue(bitmap, face) else false

                if (mouthOpen && tongueVisible) {
                    stableCount = min(stableCount + 1, STABLE_FRAMES_NEEDED)
                } else {
                    stableCount = max(stableCount - 1, 0)
                }

                val progress = stableCount.toDouble() / STABLE_FRAMES_NEEDED
                val isStable = stableCount >= STABLE_FRAMES_NEEDED

                val hint = when {
                    !mouthOpen     -> "请张开嘴巴"
                    !tongueVisible -> "请将舌头伸出来"
                    !isStable      -> "请保持不动"
                    else           -> "正在拍摄..."
                }
                pushGuideState(true, mouthOpen, tongueVisible, isStable, progress, hint)

                if (isStable && !hasCaptured) {
                    hasCaptured = true
                    captureFrame(bitmap)
                }
            }
            .addOnFailureListener { e ->
                Log.e(TAG, "FaceDetector error: ${e.message}")
            }
    }

    fun reset() {
        stableCount = 0
        hasCaptured = false
    }

    fun close() {
        faceDetector.close()
    }

    // ── 张嘴检测 ─────────────────────────────────────────────────

    private fun isMouthOpen(face: Face): Boolean {
        val upperLip = face.getContour(FaceContour.UPPER_LIP_BOTTOM)?.points ?: return false
        val lowerLip = face.getContour(FaceContour.LOWER_LIP_TOP)?.points    ?: return false
        
        // 取上下唇中点的距离
        if (upperLip.isEmpty() || lowerLip.isEmpty()) return false
        val upMidIdx = upperLip.size / 2
        val loMidIdx = lowerLip.size / 2
        
        val gap = abs(lowerLip[loMidIdx].y - upperLip[upMidIdx].y)
        return gap > MOUTH_OPEN_THRESHOLD_PX
    }

    // ── 舌头红色像素检测 ──────────────────────────────────────────

    private fun detectTongue(bitmap: Bitmap, face: Face): Boolean {
        val leftCorner  = face.getLandmark(FaceLandmark.MOUTH_LEFT)   ?: return false
        val rightCorner = face.getLandmark(FaceLandmark.MOUTH_RIGHT)  ?: return false
        val upperContour = face.getContour(FaceContour.UPPER_LIP_BOTTOM)?.points ?: return false
        val lowerContour = face.getContour(FaceContour.LOWER_LIP_TOP)?.points    ?: return false
        
        if (upperContour.isEmpty() || lowerContour.isEmpty()) return false
        val upperY = upperContour[upperContour.size / 2].y
        val lowerY = lowerContour[lowerContour.size / 2].y

        val margin = 10
        val x1 = max(0, leftCorner.position.x.toInt()  - margin)
        val x2 = min(bitmap.width  - 1, rightCorner.position.x.toInt() + margin)
        val y1 = max(0, upperY.toInt()    - margin)
        val y2 = min(bitmap.height - 1, lowerY.toInt()   + margin + 30) // 向下多扩一点覆盖舌头

        if (x2 <= x1 || y2 <= y1) return false

        var redCount = 0
        var total    = 0

        for (y in y1..y2) {
            for (x in x1..x2) {
                val pixel = bitmap.getPixel(x, y)
                val r = (pixel shr 16) and 0xFF
                val g = (pixel shr 8)  and 0xFF
                val b =  pixel         and 0xFF
                total++

                val maxC = max(r.toFloat(), max(g.toFloat(), b.toFloat()))
                val minC = min(r.toFloat(), min(g.toFloat(), b.toFloat()))
                val delta = maxC - minC
                if (maxC == 0f) continue
                val s = delta / maxC
                val v = maxC / 255f
                if (s < 0.3f || v < 0.3f || delta == 0f) continue

                var h = when {
                    maxC == r.toFloat() -> 60f * (((g - b) / delta) % 6)
                    maxC == g.toFloat() -> 60f * ((b - r) / delta + 2)
                    else                -> 60f * ((r - g) / delta + 4)
                }
                if (h < 0) h += 360f
                if (h <= 20f || h >= 340f) redCount++
            }
        }

        return if (total > 0) redCount.toDouble() / total > RED_PIXEL_RATIO_THRESHOLD else false
    }

    // ── 抓拍 ─────────────────────────────────────────────────────

    private fun captureFrame(bitmap: Bitmap) {
        try {
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
            listener?.onCapture(out.toByteArray())
        } catch (e: Exception) {
            Log.e(TAG, "captureFrame error: ${e.message}")
        }
    }

    // ── 工具 ─────────────────────────────────────────────────────

    private fun nv21ToBitmap(nv21: ByteArray, width: Int, height: Int, rotation: Int): Bitmap? {
        return try {
            val yuv = YuvImage(nv21, ImageFormat.NV21, width, height, null)
            val out = ByteArrayOutputStream()
            yuv.compressToJpeg(Rect(0, 0, width, height), 80, out)
            var bm = BitmapFactory.decodeByteArray(out.toByteArray(), 0, out.size())
            if (rotation != 0) {
                val mat = Matrix().apply { postRotate(rotation.toFloat()) }
                bm = Bitmap.createBitmap(bm, 0, 0, bm.width, bm.height, mat, true)
            }
            bm
        } catch (e: Exception) {
            Log.e(TAG, "nv21ToBitmap error: ${e.message}")
            null
        }
    }

    private fun pushGuideState(
        faceDetected: Boolean,
        mouthOpen:    Boolean,
        tongueVisible: Boolean,
        isStable:     Boolean,
        progress:     Double,
        hint:         String
    ) {
        listener?.onGuideState(mapOf(
            "faceDetected"   to faceDetected,
            "mouthOpen"      to mouthOpen,
            "tongueVisible"  to tongueVisible,
            "isStable"       to isStable,
            "stableProgress" to progress,
            "hint"           to hint,
        ))
    }

    private fun resetStable() { stableCount = max(stableCount - 1, 0) }
}
