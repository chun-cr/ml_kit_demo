// TongueDetector.swift
// 舌诊引导检测器：基于 FaceLandmarker 结果分析张嘴状态和舌头可见性
// 不修改任何现有文件；由 AppDelegate 实例化并在 FaceLandmarker 回调中调用

import Foundation
import MediaPipeTasksVision
import AVFoundation

// MARK: - Delegate Protocol

protocol TongueDetectorDelegate: AnyObject {
    /// 每帧引导状态更新
    func tongueDetector(_ detector: TongueDetector, didUpdateGuideState state: [String: Any])
    /// 满足稳定条件时推送抓拍 JPEG 字节
    func tongueDetector(_ detector: TongueDetector, didCapture jpegData: Data)
}

// MARK: - TongueDetector

final class TongueDetector {

    // MARK: Constants

    private let mouthOpenThreshold: Float  = 0.04   // 上下唇 y 距离
    private let redPixelThreshold:  Double = 0.15   // 红色像素占比
    private let stableFramesNeeded: Int    = 10     // 连续稳定帧数

    // MARK: State

    weak var delegate: TongueDetectorDelegate?

    private var stableCount: Int = 0
    private var hasCaptured:  Bool = false           // 本轮已抓拍，等待重置

    // 上一帧的 CM 时间戳（限流：最快 10fps 做像素分析）
    private var lastProcessTime: TimeInterval = 0
    private let processIntervalSec: TimeInterval = 0.1

    // MARK: Public API

    /// AppDelegate 在 FaceLandmarker 回调中调用此方法
    /// result 是原始 FaceLandmarkerResult；pixelBuffer 是相机帧
    func processFrame(
        result: FaceLandmarkerResult,
        sampleBuffer: CMSampleBuffer
    ) {
        let now = Date().timeIntervalSince1970
        guard now - lastProcessTime >= processIntervalSec else { return }
        lastProcessTime = now

        // 无人脸
        guard !result.faceLandmarks.isEmpty else {
            resetStable()
            pushGuideState(
                faceDetected:   false,
                mouthOpen:      false,
                tongueVisible:  false,
                isStable:       false,
                progress:       0,
                hint:           "请将面部对准摄像头"
            )
            return
        }

        let landmarks = result.faceLandmarks[0]

        // 张嘴检测（landmark 13 = 上唇中点，14 = 下唇中点）
        guard landmarks.count > 14 else { return }
        let upperLip = landmarks[13]
        let lowerLip = landmarks[14]
        let mouthGap = abs(lowerLip.y - upperLip.y)
        let mouthOpen = mouthGap > mouthOpenThreshold

        // 舌头可见检测（红色像素分析）
        var tongueVisible = false
        if mouthOpen,
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            tongueVisible = detectTongueInROI(
                pixelBuffer: pixelBuffer,
                landmarks: landmarks
            )
        }

        // 稳定帧计数
        if mouthOpen && tongueVisible {
            stableCount = min(stableCount + 1, stableFramesNeeded)
        } else {
            stableCount = max(stableCount - 1, 0)
        }

        let progress = Double(stableCount) / Double(stableFramesNeeded)
        let isStable = stableCount >= stableFramesNeeded

        // 构建提示文字
        let hint: String
        if !mouthOpen {
            hint = "请张开嘴巴"
        } else if !tongueVisible {
            hint = "请将舌头伸出来"
        } else if !isStable {
            hint = "请保持不动"
        } else {
            hint = "正在拍摄..."
        }

        pushGuideState(
            faceDetected:  true,
            mouthOpen:     mouthOpen,
            tongueVisible: tongueVisible,
            isStable:      isStable,
            progress:      progress,
            hint:          hint
        )

        // 稳定后抓拍一次
        if isStable && !hasCaptured {
            hasCaptured = true
            captureFrame(sampleBuffer: sampleBuffer)
        }
    }

    // MARK: - 重置（Flutter 重新开始检测时调用）

    func reset() {
        stableCount = 0
        hasCaptured = false
    }

    // MARK: - 舌头 ROI 红色像素检测

    private func detectTongueInROI(
        pixelBuffer: CVPixelBuffer,
        landmarks: [NormalizedLandmark]
    ) -> Bool {
        // 嘴部 ROI 由 61(左嘴角) 291(右嘴角) 0(上唇顶) 17(下唇底) 围成
        guard landmarks.count > 291 else { return false }

        let pts = [landmarks[61], landmarks[291], landmarks[0], landmarks[17]]
        let xs = pts.map { $0.x }
        let ys = pts.map { $0.y }
        let roiMinX = xs.min()! - 0.02
        let roiMaxX = xs.max()! + 0.02
        let roiMinY = ys.min()!
        let roiMaxY = ys.max()! + 0.03  // 向下扩展一点覆盖舌头

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width    = CVPixelBufferGetWidth(pixelBuffer)
        let height   = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }

        let xStart = max(0, Int(roiMinX * Float(width)))
        let xEnd   = min(width - 1, Int(roiMaxX * Float(width)))
        let yStart = max(0, Int(roiMinY * Float(height)))
        let yEnd   = min(height - 1, Int(roiMaxY * Float(height)))

        var redCount = 0
        var total    = 0

        let ptr = base.assumingMemoryBound(to: UInt8.self)

        for y in yStart...yEnd {
            for x in xStart...xEnd {
                let offset = y * bytesPerRow + x * 4
                // BGRA: B=offset+0, G=offset+1, R=offset+2, A=offset+3
                let b = Double(ptr[offset])
                let g = Double(ptr[offset + 1])
                let r = Double(ptr[offset + 2])
                total += 1

                // HSV 判断：S > 0.3, V > 0.3, H in [0, 20] or [340, 360]
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let delta = maxC - minC
                guard maxC > 0 else { continue }
                let s = delta / maxC
                let v = maxC / 255.0
                guard s > 0.3 && v > 0.3 && delta > 0 else { continue }

                var h: Double = 0
                if maxC == r {
                    h = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
                } else if maxC == g {
                    h = 60.0 * ((b - r) / delta + 2)
                } else {
                    h = 60.0 * ((r - g) / delta + 4)
                }
                if h < 0 { h += 360 }

                if h <= 20 || h >= 340 {
                    redCount += 1
                }
            }
        }

        guard total > 0 else { return false }
        return Double(redCount) / Double(total) > redPixelThreshold
    }

    // MARK: - 抓拍

    private func captureFrame(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 将 CVPixelBuffer 转为 JPEG Data
        let ciImage  = CIImage(cvPixelBuffer: pixelBuffer)
        let context  = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage  = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        guard let jpeg = uiImage.jpegData(compressionQuality: 0.85) else { return }

        delegate?.tongueDetector(self, didCapture: jpeg)
    }

    // MARK: - 推送引导状态

    private func pushGuideState(
        faceDetected: Bool,
        mouthOpen: Bool,
        tongueVisible: Bool,
        isStable: Bool,
        progress: Double,
        hint: String
    ) {
        let state: [String: Any] = [
            "faceDetected":   faceDetected,
            "mouthOpen":      mouthOpen,
            "tongueVisible":  tongueVisible,
            "isStable":       isStable,
            "stableProgress": progress,
            "hint":           hint,
        ]
        delegate?.tongueDetector(self, didUpdateGuideState: state)
    }

    // MARK: Private helpers

    private func resetStable() {
        stableCount = 0
    }
}
