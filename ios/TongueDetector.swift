// TongueDetector.swift
// 根据 Apple Vision 原生框架进行适配
import Foundation
import Vision
import AVFoundation
import UIKit

protocol TongueDetectorDelegate: AnyObject {
    func tongueDetector(_ detector: TongueDetector, didUpdateGuideState state: [String: Any])
    func tongueDetector(_ detector: TongueDetector, didCapture jpegData: Data)
}

final class TongueDetector {
    // 阈值调整: Vision返回的是相对boundingBox的归一化点或绝对点，我们自己处理
    private let mouthOpenThreshold: Double = 0.04   // 上下唇中间 y 的差距 (归一化到整个画面高度)
    private let redPixelThreshold:  Double = 0.15   // 红色像素占比
    private let stableFramesNeeded: Int    = 10

    weak var delegate: TongueDetectorDelegate?

    private var stableCount: Int = 0
    private var hasCaptured: Bool = false

    private var lastProcessTime: TimeInterval = 0
    private let processIntervalSec: TimeInterval = 0.1

    func processFrame(
        observation: VNFaceObservation,
        image: UIImage
    ) {
        let now = Date().timeIntervalSince1970
        guard now - lastProcessTime >= processIntervalSec else { return }
        lastProcessTime = now

        // Vision 的点坐标：基于图像尺寸的归一化，且原点在左下角！
        guard let landmarks = observation.landmarks,
              let outerLips = landmarks.outerLips,
              let innerLips = landmarks.innerLips else {
            resetStable()
            pushGuideState(faceDetected: false, mouthOpen: false, tongueVisible: false, isStable: false, progress: 0, hint: "请将面部对准摄像头")
            return
        }

        // 判断张嘴
        // innerLips 点通常: 0~1 是上唇内边, 后面是下唇内边。或者通过 boundingBox 高度来算
        // 简单计算上下唇最大垂直距离 (转化为整图归一化值，由于 bbox 的 y 在图里，所以要乘 boundingBox 高さ)
        
        let bbox = observation.boundingBox // 这个 bbox 的 (0,0) 在左下角，取值 0~1
        let upperLipPts = innerLips.normalizedPoints.prefix(upTo: innerLips.pointCount / 2)
        let lowerLipPts = innerLips.normalizedPoints.suffix(from: innerLips.pointCount / 2)
        
        // y轴差距。注意坐标系是脸部框内的 0~1
        let upperH = upperLipPts.map { $0.y }.max() ?? 0
        let lowerH = lowerLipPts.map { $0.y }.min() ?? 1.0
        
        // 嘴巴张开的高度在整图中的归一化高度
        let mouthGap = Double(abs(upperH - lowerH) * bbox.height)
        let mouthOpen = mouthGap > mouthOpenThreshold

        var tongueVisible = false
        if mouthOpen {
            tongueVisible = detectTongueInROI(
                uiImage: image,
                observation: observation,
                outerLips: outerLips
            )
        }

        if mouthOpen && tongueVisible {
            stableCount = min(stableCount + 1, stableFramesNeeded)
        } else {
            stableCount = max(stableCount - 1, 0)
        }

        let progress = Double(stableCount) / Double(stableFramesNeeded)
        let isStable = stableCount >= stableFramesNeeded

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
            faceDetected: true,
            mouthOpen: mouthOpen,
            tongueVisible: tongueVisible,
            isStable: isStable,
            progress: progress,
            hint: hint
        )

        if isStable && !hasCaptured {
            hasCaptured = true
            captureFrame(image: image)
        }
    }

    func reset() {
        stableCount = 0
        hasCaptured = false
    }

    private func detectTongueInROI(
        uiImage: UIImage,
        observation: VNFaceObservation,
        outerLips: VNFaceLandmarkRegion2D
    ) -> Bool {
        let bbox = observation.boundingBox
        let width = uiImage.size.width
        let height = uiImage.size.height
        
        let xs = outerLips.normalizedPoints.map { $0.x }
        let ys = outerLips.normalizedPoints.map { $0.y } // 也是人脸框内的 0~1

        let minX = (xs.min() ?? 0) * bbox.width + bbox.minX
        let maxX = (xs.max() ?? 1) * bbox.width + bbox.minX
        let minY = (ys.min() ?? 0) * bbox.height + bbox.minY
        let maxY = (ys.max() ?? 1) * bbox.height + bbox.minY

        // 注意 Vision 坐标系：y=0 在图像左下角，由于我们要截取 UIImage（它的原点在左上角），我们要翻转 y！
        let imageMinY = 1.0 - maxY
        let imageMaxY = 1.0 - minY

        let roiMinX = minX - 0.02
        let roiMaxX = maxX + 0.02
        let roiMinY = imageMinY
        let roiMaxY = imageMaxY + 0.03  // 向下扩展（在 UI 坐标系向下是变大）

        let xStart = max(0, Int(roiMinX * width))
        let xEnd = min(Int(width) - 1, Int(roiMaxX * width))
        let yStart = max(0, Int(roiMinY * height))
        let yEnd = min(Int(height) - 1, Int(roiMaxY * height))

        let roiWidth = xEnd - xStart
        let roiHeight = yEnd - yStart
        guard roiWidth > 0 && roiHeight > 0 else { return false }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = roiWidth * 4
        var pixelData = [UInt8](repeating: 0, count: roiHeight * bytesPerRow)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

        guard let context = CGContext(data: &pixelData,
                                      width: roiWidth,
                                      height: roiHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo.rawValue) else { return false }

        UIGraphicsPushContext(context)
        context.translateBy(x: 0, y: CGFloat(roiHeight))
        context.scaleBy(x: 1.0, y: -1.0)
        
        uiImage.draw(at: CGPoint(x: -CGFloat(xStart), y: -CGFloat(yStart)))
        UIGraphicsPopContext()

        var redCount = 0
        var total = 0

        for y in 0..<roiHeight {
            for x in 0..<roiWidth {
                let offset = y * bytesPerRow + x * 4
                let r = Double(pixelData[offset])
                let g = Double(pixelData[offset + 1])
                let b = Double(pixelData[offset + 2])
                total += 1

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

    private func captureFrame(image: UIImage) {
        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        let finalImage = normalizedImage ?? image
        guard let jpeg = finalImage.jpegData(compressionQuality: 0.85) else { return }
        delegate?.tongueDetector(self, didCapture: jpeg)
    }

    private func pushGuideState(
        faceDetected: Bool, mouthOpen: Bool, tongueVisible: Bool, isStable: Bool, progress: Double, hint: String
    ) {
        let state: [String: Any] = [
            "faceDetected": faceDetected,
            "mouthOpen": mouthOpen,
            "tongueVisible": tongueVisible,
            "isStable": isStable,
            "stableProgress": progress,
            "hint": hint,
        ]
        delegate?.tongueDetector(self, didUpdateGuideState: state)
    }

    private func resetStable() {
        stableCount = 0
    }
}
