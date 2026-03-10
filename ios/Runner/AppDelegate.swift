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

    // MARK: - Retained Channels (prevent ARC dealloc)

    private var gestureMethodChannel: FlutterMethodChannel?
    private var faceMethodChannel:    FlutterMethodChannel?
    private var gestureEventChannel:  FlutterEventChannel?
    private var landmarkEventChannel: FlutterEventChannel?
    private var faceMeshEventChannel: FlutterEventChannel?

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
        NSLog("[AppDelegate] >> didFinishLaunchingWithOptions")
        GeneratedPluginRegistrant.register(with: self)

        guard let controller = window?.rootViewController as? FlutterViewController else {
            NSLog("[AppDelegate] FAIL: rootViewController is not FlutterViewController")
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }

        guard let registrar = self.registrar(forPlugin: "AppDelegatePlugin") else {
            NSLog("[AppDelegate] FAIL: registrar for AppDelegatePlugin is nil")
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }
        NSLog("[AppDelegate] registrar OK, setting up channels")

        setupGestureRecognizer(registrar: registrar)
        setupFaceLandmarker(registrar: registrar)

        setupGestureMethodChannel(controller: controller)
        setupGestureEventChannels(controller: controller)

        setupFaceMethodChannel(controller: controller)
        setupFaceMeshChannel(controller: controller)

        NSLog("[AppDelegate] << all channels set up")
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - Asset Path Helper

    /// 优先用 Flutter 标准 registrar.lookupKey 获取资产路径，失败后先登录候选路径再递归搜索
    private func findAsset(named fileName: String, registrar: FlutterPluginRegistrar) -> String? {
        // 方式 1：标准 Flutter 资产路径（最可靠）
        let assetKey = registrar.lookupKey(forAsset: "assets/\(fileName)")
        if let path = Bundle.main.path(forResource: assetKey, ofType: nil) {
            NSLog("[Asset] Found via registrar: %@", path)
            return path
        }

        // 方式 2：候选路径列表
        let candidates: [String] = [
            "Frameworks/App.framework/flutter_assets/assets/\(fileName)",
            "flutter_assets/assets/\(fileName)",
            "assets/\(fileName)",
        ]
        if let root = Bundle.main.resourcePath {
            for relative in candidates {
                let full = (root as NSString).appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: full) {
                    NSLog("[Asset] Found via candidate path: %@", full)
                    return full
                }
            }
        }

        // 方式 3：兑底递归搜索
        guard let root = Bundle.main.resourcePath,
              let enumerator = FileManager.default.enumerator(atPath: root) else { return nil }
        while let entry = enumerator.nextObject() as? String {
            if entry.hasSuffix("/\(fileName)") || entry == fileName {
                let full = (root as NSString).appendingPathComponent(entry)
                NSLog("[Asset] Found via recursive search: %@", full)
                return full
            }
        }
        return nil
    }

    // MARK: - Gesture Recognizer Init

    private func setupGestureRecognizer(registrar: FlutterPluginRegistrar) {
        guard let modelPath = findAsset(named: "gesture_recognizer.task", registrar: registrar) else {
            NSLog("[GestureRecognizer] FAIL: Model file 'gesture_recognizer.task' not found in bundle")
            return
        }
        NSLog("[GestureRecognizer] Found model at: %@", modelPath)
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
            NSLog("[GestureRecognizer] OK: Initialized successfully")
        } catch {
            NSLog("[GestureRecognizer] FAIL: Init failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Face Landmarker Init

    private func setupFaceLandmarker(registrar: FlutterPluginRegistrar) {
        guard let modelPath = findAsset(named: "face_landmarker.task", registrar: registrar) else {
            NSLog("[FaceLandmarker] FAIL: Model file 'face_landmarker.task' not found in bundle")
            return
        }
        NSLog("[FaceLandmarker] Found model at: %@", modelPath)
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
            NSLog("[FaceLandmarker] OK: Initialized successfully")
        } catch {
            NSLog("[FaceLandmarker] FAIL: Init failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Gesture Channels

    private func setupGestureMethodChannel(controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: methodChannelName,
            binaryMessenger: controller.binaryMessenger
        )
        gestureMethodChannel = channel   // retain to prevent ARC dealloc
        NSLog("[AppDelegate] setupGestureMethodChannel: registering handler")
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            NSLog("[Gesture] MethodChannel invoked: %@", call.method)
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
                let bytesPerRow = (args["bytesPerRow"] as? Int) ?? (width * 4)
                self.processGestureFrame(bytes: bytes.data, width: width, height: height,
                                         bytesPerRow: bytesPerRow, rotation: rotation)
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func setupGestureEventChannels(controller: FlutterViewController) {
        let gChannel = FlutterEventChannel(name: gestureChannelName, binaryMessenger: controller.binaryMessenger)
        gestureEventChannel = gChannel   // retain
        gChannel.setStreamHandler(SinkHandler { [weak self] sink in self?.gestureSink = sink })
        let lChannel = FlutterEventChannel(name: landmarkChannelName, binaryMessenger: controller.binaryMessenger)
        landmarkEventChannel = lChannel   // retain
        lChannel.setStreamHandler(SinkHandler { [weak self] sink in self?.landmarkSink = sink })
    }

    // MARK: - Face Channels

    private func setupFaceMethodChannel(controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: faceFrameChannelName,
            binaryMessenger: controller.binaryMessenger
        )
        faceMethodChannel = channel   // retain to prevent ARC dealloc
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
                let bytesPerRow = (args["bytesPerRow"] as? Int) ?? (width * 4)
                self.processFaceFrame(bytes: bytes.data, width: width, height: height,
                                      bytesPerRow: bytesPerRow, rotation: rotation)
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func setupFaceMeshChannel(controller: FlutterViewController) {
        let channel = FlutterEventChannel(name: faceMeshChannelName, binaryMessenger: controller.binaryMessenger)
        faceMeshEventChannel = channel   // retain
        channel.setStreamHandler(SinkHandler { [weak self] sink in self?.faceMeshSink = sink })
    }

    // MARK: - Frame Processing

    private func buildMPImage(bytes: Data, width: Int, height: Int,
                              bytesPerRow: Int, rotation: Int) -> MPImage? {
        guard let cgImage = createCGImage(from: bytes, width: width, height: height,
                                           bytesPerRow: bytesPerRow) else {
            NSLog("[Gesture] FAIL createCGImage - bytes:%d %dx%d", bytes.count, width, height)
            return nil
        }
        let orientation = imageOrientation(for: rotation)
        NSLog("[Gesture] orientation: %d", orientation.rawValue)
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
        do {
            let mp = try MPImage(uiImage: uiImage)
            NSLog("[Gesture] OK MPImage built")
            return mp
        } catch {
            NSLog("[Gesture] FAIL MPImage: %@", error.localizedDescription)
            return nil
        }
    }

    private func processGestureFrame(bytes: Data, width: Int, height: Int,
                                     bytesPerRow: Int, rotation: Int) {
        NSLog("[Gesture] >> frame arrived - %dx%d rot:%d bytes:%d recognizer:%d", width, height, rotation, bytes.count, gestureRecognizer != nil ? 1 : 0)
        guard let recognizer = gestureRecognizer else { return }
        guard let mpImage = buildMPImage(bytes: bytes, width: width, height: height,
                                         bytesPerRow: bytesPerRow, rotation: rotation) else { return }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        guard timestamp > gestureFrameTimestamp else { return }
        gestureFrameTimestamp = timestamp

        do {
            try recognizer.recognizeAsync(image: mpImage, timestampInMilliseconds: timestamp)
        } catch {
            NSLog("[GestureRecognizer] recognizeAsync error: %@", error.localizedDescription)
        }
    }

    private func processFaceFrame(bytes: Data, width: Int, height: Int,
                                  bytesPerRow: Int, rotation: Int) {
        guard let landmarker = faceLandmarker else { return }
        guard let mpImage = buildMPImage(bytes: bytes, width: width, height: height,
                                         bytesPerRow: bytesPerRow, rotation: rotation) else { return }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        guard timestamp > faceFrameTimestamp else { return }
        faceFrameTimestamp = timestamp

        do {
            try landmarker.detectAsync(image: mpImage, timestampInMilliseconds: timestamp)
        } catch {
            NSLog("[FaceLandmarker] detectAsync error: %@", error.localizedDescription)
        }
    }

    // MARK: - Image Helpers

    /// 使用真实 bytesPerRow 构建 CGImage，避免 stride padding 造成图像错乱
    private func createCGImage(from data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard width > 0, height > 0, !data.isEmpty else { return nil }

        // BGRA8888: bytesPerRow 可能 > width*4（stride padding）
        // 直接使用传入的 bytesPerRow 而非自行计算
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
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
        didFinishGestureRecognition result: GestureRecognizerResult?,
        timestampInMilliseconds: Int,
        error: Error?
    ) {
        NSLog("[Gesture] << callback - gestures:%d error:%@", result?.gestures.count ?? -1, error?.localizedDescription ?? "nil")
        if let error = error {
            NSLog("[GestureRecognizer] callback error: %@", error.localizedDescription)
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
            allHands.append(handLandmarks.map { ["x": 1.0 - Double($0.x), "y": Double($0.y)] })
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
            NSLog("[FaceLandmarker] callback error: %@", error.localizedDescription)
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
                ["x": 1.0 - Double(lm.x), "y": Double(lm.y), "z": Double(lm.z)]
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
