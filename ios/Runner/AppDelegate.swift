import Flutter
import UIKit
import MediaPipeTasksVision

@main
@objc class AppDelegate: FlutterAppDelegate {

    // MARK: - Channel Names

    // Gesture
    private let methodChannelName   = "gesture/frame"
    private let gestureChannelName  = "gesture/stream"
    private let landmarkChannelName = "landmark/stream"

    // Face Mesh (iOS-only, via MediaPipe FaceLandmarker)
    private let faceFrameChannelName = "face/frame"
    private let faceMeshChannelName  = "face/mesh/stream"

    // MARK: - MediaPipe

    private var gestureRecognizer: GestureRecognizer?
    private var faceLandmarker: FaceLandmarker?

    // MARK: - Event Sinks

    private var gestureSink: FlutterEventSink?
    private var landmarkSink: FlutterEventSink?
    private var faceMeshSink: FlutterEventSink?

    // MARK: - Throttle

    private var lastGestureTime:  TimeInterval = 0
    private var lastLandmarkTime: TimeInterval = 0
    private var lastFaceMeshTime: TimeInterval = 0

    private let gestureIntervalSec:  TimeInterval = 0.1   // 100ms
    private let landmarkIntervalSec: TimeInterval = 0.03  // 30ms
    private let faceMeshIntervalSec: TimeInterval = 0.033 // ~30fps

    private var gestureFrameTimestamp: Int = 0
    private var faceFrameTimestamp:    Int = 0

    // MARK: - Lifecycle

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        guard let controller = window?.rootViewController as? FlutterViewController else {
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }

        setupGestureRecognizer()
        setupFaceLandmarker()

        setupGestureMethodChannel(controller: controller)
        setupGestureEventChannels(controller: controller)

        setupFaceMethodChannel(controller: controller)
        setupFaceMeshChannel(controller: controller)

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - Asset Path Helper

    /// 在 Flutter bundle 内递归查找指定文件名（含后缀），返回绝对路径
    private func findAsset(named fileName: String) -> String? {
        // 优先从 flutter_assets 目录直接查找（Release 和 Debug 真机常见路径）
        let candidates: [String] = [
            "Frameworks/App.framework/flutter_assets/assets/\(fileName)",
            "flutter_assets/assets/\(fileName)",
            "assets/\(fileName)",
        ]
        for relative in candidates {
            if let path = Bundle.main.path(forResource: nil, ofType: nil),
               FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(relative)) {
                return (path as NSString).appendingPathComponent(relative)
            }
            // Bundle.main.resourcePath 方式
            if let root = Bundle.main.resourcePath {
                let full = (root as NSString).appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: full) { return full }
            }
        }

        // 兜底：递归搜索整个 bundle
        guard let root = Bundle.main.resourcePath,
              let enumerator = FileManager.default.enumerator(atPath: root) else { return nil }
        while let entry = enumerator.nextObject() as? String {
            if entry.hasSuffix("/\(fileName)") || entry == fileName {
                return (root as NSString).appendingPathComponent(entry)
            }
        }
        return nil
    }

    // MARK: - Gesture Recognizer Init

    private func setupGestureRecognizer() {
        guard let modelPath = findAsset(named: "gesture_recognizer.task") else {
            NSLog("[GestureRecognizer] ❌ Model file 'gesture_recognizer.task' not found in bundle")
            return
        }
        NSLog("[GestureRecognizer] Found model at: \(modelPath)")
        do {
            let baseOptions = BaseOptions()
            baseOptions.modelAssetPath = modelPath

            let options = GestureRecognizerOptions()
            options.baseOptions = baseOptions
            options.runningMode = .liveStream
            options.minHandDetectionConfidence = 0.5
            options.minTrackingConfidence = 0.5
            options.minHandPresenceConfidence = 0.5
            options.numHands = 2
            options.gestureRecognizerLiveStreamDelegate = self

            gestureRecognizer = try GestureRecognizer(options: options)
            NSLog("[GestureRecognizer] ✅ Initialized successfully")
        } catch {
            NSLog("[GestureRecognizer] ❌ Init failed: \(error)")
        }
    }

    // MARK: - Face Landmarker Init

    private func setupFaceLandmarker() {
        guard let modelPath = findAsset(named: "face_landmarker.task") else {
            NSLog("[FaceLandmarker] ❌ Model file 'face_landmarker.task' not found in bundle")
            return
        }
        NSLog("[FaceLandmarker] Found model at: \(modelPath)")
        do {
            let baseOptions = BaseOptions()
            baseOptions.modelAssetPath = modelPath

            let options = FaceLandmarkerOptions()
            options.baseOptions = baseOptions
            options.runningMode = .liveStream
            options.numFaces = 2
            options.minFaceDetectionConfidence = 0.5
            options.minTrackingConfidence = 0.5
            options.minFacePresenceConfidence = 0.5
            options.faceLandmarkerLiveStreamDelegate = self

            faceLandmarker = try FaceLandmarker(options: options)
            NSLog("[FaceLandmarker] ✅ Initialized successfully")
        } catch {
            NSLog("[FaceLandmarker] ❌ Init failed: \(error)")
        }
    }

    // MARK: - Gesture Channels

    private func setupGestureMethodChannel(controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: methodChannelName,
            binaryMessenger: controller.binaryMessenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            switch call.method {
            case "processFrame":
                guard let args = call.arguments as? [String: Any],
                      let bytes = args["bytes"] as? FlutterStandardTypedData,
                      let width = args["width"] as? Int,
                      let height = args["height"] as? Int,
                      let rotation = args["rotation"] as? Int
                else {
                    result(FlutterError(code: "INVALID_ARGS", message: "Missing frame data", details: nil))
                    return
                }
                self.processGestureFrame(bytes: bytes.data, width: width, height: height, rotation: rotation)
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func setupGestureEventChannels(controller: FlutterViewController) {
        FlutterEventChannel(name: gestureChannelName, binaryMessenger: controller.binaryMessenger)
            .setStreamHandler(SinkHandler { [weak self] sink in self?.gestureSink = sink })
        FlutterEventChannel(name: landmarkChannelName, binaryMessenger: controller.binaryMessenger)
            .setStreamHandler(SinkHandler { [weak self] sink in self?.landmarkSink = sink })
    }

    // MARK: - Face Channels

    private func setupFaceMethodChannel(controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: faceFrameChannelName,
            binaryMessenger: controller.binaryMessenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            switch call.method {
            case "processFrame":
                guard let args = call.arguments as? [String: Any],
                      let bytes = args["bytes"] as? FlutterStandardTypedData,
                      let width = args["width"] as? Int,
                      let height = args["height"] as? Int,
                      let rotation = args["rotation"] as? Int
                else {
                    result(FlutterError(code: "INVALID_ARGS", message: "Missing frame data", details: nil))
                    return
                }
                self.processFaceFrame(bytes: bytes.data, width: width, height: height, rotation: rotation)
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func setupFaceMeshChannel(controller: FlutterViewController) {
        FlutterEventChannel(name: faceMeshChannelName, binaryMessenger: controller.binaryMessenger)
            .setStreamHandler(SinkHandler { [weak self] sink in self?.faceMeshSink = sink })
    }

    // MARK: - Frame Processing

    private func buildMPImage(bytes: Data, width: Int, height: Int, rotation: Int) -> MPImage? {
        guard let cgImage = createCGImage(from: bytes, width: width, height: height) else { return nil }
        let orientation = imageOrientation(for: rotation)
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
        return try? MPImage(uiImage: uiImage)
    }

    private func processGestureFrame(bytes: Data, width: Int, height: Int, rotation: Int) {
        guard let recognizer = gestureRecognizer else { return }
        guard let mpImage = buildMPImage(bytes: bytes, width: width, height: height, rotation: rotation) else { return }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        guard timestamp > gestureFrameTimestamp else { return }
        gestureFrameTimestamp = timestamp

        do {
            try recognizer.recognizeAsync(image: mpImage, timestampInMilliseconds: timestamp)
        } catch {
            NSLog("[GestureRecognizer] recognizeAsync error: \(error)")
        }
    }

    private func processFaceFrame(bytes: Data, width: Int, height: Int, rotation: Int) {
        guard let landmarker = faceLandmarker else { return }
        guard let mpImage = buildMPImage(bytes: bytes, width: width, height: height, rotation: rotation) else { return }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        guard timestamp > faceFrameTimestamp else { return }
        faceFrameTimestamp = timestamp

        do {
            try landmarker.detectAsync(image: mpImage, timestampInMilliseconds: timestamp)
        } catch {
            NSLog("[FaceLandmarker] detectAsync error: \(error)")
        }
    }

    // MARK: - Image Helpers

    private func createCGImage(from data: Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, !data.isEmpty else { return nil }
        let bytesPerPixel = data.count / (width * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo

        if bytesPerPixel == 4 {
            // BGRA8888
            bitmapInfo = CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        } else if bytesPerPixel == 3 {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        } else {
            // Fallback: try JPEG/PNG decode
            if let provider = CGDataProvider(data: data as CFData) {
                return CGImage(jpegDataProviderSource: provider, decode: nil,
                               shouldInterpolate: true, intent: .defaultIntent)
            }
            return nil
        }

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: bytesPerPixel * 8,
            bytesPerRow: bytesPerPixel * width,
            space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private func imageOrientation(for rotation: Int) -> UIImage.Orientation {
        switch rotation {
        case 90:  return .right
        case 180: return .down
        case 270: return .left
        default:  return .up
        }
    }
}

// MARK: - GestureRecognizerLiveStreamDelegate

extension AppDelegate: GestureRecognizerLiveStreamDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: GestureRecognizer,
        didFinishRecognition result: GestureRecognizerResult?,
        timestampInMilliseconds: Int,
        error: Error?
    ) {
        if let error = error {
            NSLog("[GestureRecognizer] callback error: \(error)")
            return
        }
        guard let result = result else { return }
        let now = Date().timeIntervalSince1970

        if now - lastLandmarkTime >= landmarkIntervalSec {
            lastLandmarkTime = now
            pushGestureLandmarks(result)
        }
        if now - lastGestureTime >= gestureIntervalSec {
            lastGestureTime = now
            pushGestureResult(result)
        }
    }

    private func pushGestureLandmarks(_ result: GestureRecognizerResult) {
        guard let sink = landmarkSink else { return }
        var allHands: [[[String: Double]]] = []
        for handLandmarks in result.landmarks {
            allHands.append(handLandmarks.map { ["x": Double($0.x), "y": Double($0.y)] })
        }
        DispatchQueue.main.async {
            sink(["hands": allHands, "numHands": allHands.count])
        }
    }

    private func pushGestureResult(_ result: GestureRecognizerResult) {
        guard let sink = gestureSink else { return }

        if result.gestures.isEmpty {
            DispatchQueue.main.async {
                sink(["gesture": "None", "confidence": 0.0, "handedness": "", "numHands": 0])
            }
            return
        }

        var allHands: [[String: Any]] = []
        for (i, gestures) in result.gestures.enumerated() {
            guard let top = gestures.first else { continue }
            let handedness: String
            if i < result.handedness.count, let first = result.handedness[i].first {
                handedness = first.categoryName ?? "Unknown"
            } else {
                handedness = "Unknown"
            }
            allHands.append([
                "gesture":    top.categoryName ?? "Unknown",
                "confidence": Double(top.score),
                "handedness": handedness,
            ])
        }
        guard let primary = allHands.first else { return }
        DispatchQueue.main.async {
            sink([
                "gesture":    primary["gesture"]!,
                "confidence": primary["confidence"]!,
                "handedness": primary["handedness"]!,
                "numHands":   allHands.count,
                "allHands":   allHands,
            ])
        }
    }
}

// MARK: - FaceLandmarkerLiveStreamDelegate

extension AppDelegate: FaceLandmarkerLiveStreamDelegate {
    func faceLandmarker(
        _ faceLandmarker: FaceLandmarker,
        didFinishDetection result: FaceLandmarkerResult?,
        timestampInMilliseconds: Int,
        error: Error?
    ) {
        if let error = error {
            NSLog("[FaceLandmarker] callback error: \(error)")
            return
        }
        guard let result = result else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastFaceMeshTime >= faceMeshIntervalSec else { return }
        lastFaceMeshTime = now

        pushFaceMeshResult(result)
    }

    private func pushFaceMeshResult(_ result: FaceLandmarkerResult) {
        guard let sink = faceMeshSink else { return }

        // result.faceLandmarks: [[NormalizedLandmark]]，每张脸 478 个点（normalized 0~1）
        let faces: [[[String: Double]]] = result.faceLandmarks.map { landmarks in
            landmarks.map { lm in
                ["x": Double(lm.x), "y": Double(lm.y), "z": Double(lm.z)]
            }
        }
        DispatchQueue.main.async {
            sink(["faces": faces, "numFaces": faces.count])
        }
    }
}

// MARK: - Stream Handler Helper

class SinkHandler: NSObject, FlutterStreamHandler {
    private let onChanged: (FlutterEventSink?) -> Void
    init(onChanged: @escaping (FlutterEventSink?) -> Void) { self.onChanged = onChanged }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onChanged(events); return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onChanged(nil); return nil
    }
}
