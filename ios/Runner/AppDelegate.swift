import Flutter
import UIKit
import MediaPipeTasksVision
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate {

    // MARK: - Channel Names

    // Gesture
    private let methodChannelName   = "gesture/frame"
    private let gestureChannelName  = "gesture/stream"
    private let landmarkChannelName = "landmark/stream"

    // Face Mesh (iOS-only, now via Apple Vision)
    private let faceFrameChannelName = "face/frame"
    private let faceMeshChannelName  = "face/mesh/stream"

    // MARK: - MediaPipe & Vision

    private var gestureRecognizer: GestureRecognizer?
    private var gestureModelPath: String?
    
    // Replace FaceLandmarker with Vision sequence handler for stabilization
    private var visionSequenceHandler = VNSequenceRequestHandler()

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

    // MARK: - Tongue Detection (additive)

    private var tongueDetector:         TongueDetector?
    private var tongueGuideEventChannel: FlutterEventChannel?
    private var tongueCaptureEventChannel: FlutterEventChannel?
    private var tongueMethodChannel:    FlutterMethodChannel?
    private var tongueGuideSink:        FlutterEventSink?
    private var tongueCaptureSink:      FlutterEventSink?
    
    // Stores the latest image for tongue capture
    private var latestTongueImage: UIImage?

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
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }

        guard let registrar = self.registrar(forPlugin: "AppDelegatePlugin") else {
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }

        gestureModelPath = findAsset(named: "gesture_recognizer.task", registrar: registrar)

        setupGestureMethodChannel(controller: controller)
        setupGestureEventChannels(controller: controller)

        setupFaceMethodChannel(controller: controller)
        setupFaceMeshChannel(controller: controller)

        setupTongueChannels(controller: controller)

        NSLog("[AppDelegate] << all channels set up")
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - Asset Path Helper

    private func findAsset(named fileName: String, registrar: FlutterPluginRegistrar) -> String? {
        let assetKey = registrar.lookupKey(forAsset: "assets/\(fileName)")
        if let path = Bundle.main.path(forResource: assetKey, ofType: nil) {
            return path
        }

        let candidates: [String] = [
            "Frameworks/App.framework/flutter_assets/assets/\(fileName)",
            "flutter_assets/assets/\(fileName)",
            "assets/\(fileName)",
        ]
        if let root = Bundle.main.resourcePath {
            for relative in candidates {
                let full = (root as NSString).appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: full) {
                    return full
                }
            }
        }

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
        guard let modelPath = gestureModelPath else { return }
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
        } catch {}
    }

    // MARK: - Gesture Channels

    private func setupGestureMethodChannel(controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: methodChannelName,
            binaryMessenger: controller.binaryMessenger
        )
        gestureMethodChannel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            switch call.method {
            case "warmup":
                self.warmupGestureRecognizerIfNeeded()
                result(true)
            case "processFrame":
                self.warmupGestureRecognizerIfNeeded()
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
        gestureEventChannel = gChannel
        gChannel.setStreamHandler(SinkHandler { [weak self] sink in self?.gestureSink = sink })
        
        let lChannel = FlutterEventChannel(name: landmarkChannelName, binaryMessenger: controller.binaryMessenger)
        landmarkEventChannel = lChannel
        lChannel.setStreamHandler(SinkHandler { [weak self] sink in self?.landmarkSink = sink })
    }

    // MARK: - Face Channels

    private func setupFaceMethodChannel(controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: faceFrameChannelName,
            binaryMessenger: controller.binaryMessenger
        )
        faceMethodChannel = channel
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
        faceMeshEventChannel = channel
        channel.setStreamHandler(SinkHandler { [weak self] sink in self?.faceMeshSink = sink })
    }

    // MARK: - Frame Processing

    private func buildMPImage(bytes: Data, width: Int, height: Int,
                              bytesPerRow: Int, rotation: Int) -> MPImage? {
        guard let cgImage = createCGImage(from: bytes, width: width, height: height,
                                           bytesPerRow: bytesPerRow) else { return nil }
        let orientation = imageOrientation(for: rotation)
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
        do {
            return try MPImage(uiImage: uiImage)
        } catch {
            return nil
        }
    }

    private func processGestureFrame(bytes: Data, width: Int, height: Int,
                                     bytesPerRow: Int, rotation: Int) {
        warmupGestureRecognizerIfNeeded()
        guard let recognizer = gestureRecognizer else { return }
        guard let mpImage = buildMPImage(bytes: bytes, width: width, height: height,
                                         bytesPerRow: bytesPerRow, rotation: rotation) else { return }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        guard timestamp > gestureFrameTimestamp else { return }
        gestureFrameTimestamp = timestamp

        do {
            try recognizer.recognizeAsync(image: mpImage, timestampInMilliseconds: timestamp)
        } catch {}
    }

    private func processFaceFrame(bytes: Data, width: Int, height: Int,
                                  bytesPerRow: Int, rotation: Int) {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        guard timestamp > faceFrameTimestamp else { return }
        faceFrameTimestamp = timestamp

        guard let cgImage = createCGImage(from: bytes, width: width, height: height, bytesPerRow: bytesPerRow) else { return }
        
        // Vision orientation
        let cvOrientation = cgImagePropertyOrientation(for: rotation)
        let request = VNDetectFaceLandmarksRequest { [weak self] req, error in
            guard let self = self else { return }
            guard let results = req.results as? [VNFaceObservation] else { return }
            
            let now = Date().timeIntervalSince1970
            if now - self.lastFaceMeshTime >= self.faceMeshIntervalSec {
                self.lastFaceMeshTime = now
                self.pushFaceMeshResult(results)
            }
        }
        
        do {
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cvOrientation, options: [:])
            try handler.perform([request])
        } catch {
            NSLog("[Vision] perform error: %@", error.localizedDescription)
        }
    }

    // MARK: - Image Helpers

    private func createCGImage(from data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard width > 0, height > 0, !data.isEmpty else { return nil }

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
        case 0:   return .up
        default:  return .up
        }
    }
    
    private func cgImagePropertyOrientation(for rotation: Int) -> CGImagePropertyOrientation {
        switch rotation {
        case 90:  return .right
        case 180: return .down
        case 270: return .left
        case 0:   return .up
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
        if let error = error { return }
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

// MARK: - Vision Results (Replaces FaceLandmarker)
extension AppDelegate {
    private func pushFaceMeshResult(_ results: [VNFaceObservation]) {
        guard let sink = faceMeshSink else { return }

        var faces: [[[String: Double]]] = []
        for obs in results {
            guard let landmarks = obs.landmarks, let allP = landmarks.allPoints else { continue }
            
            let bbox = obs.boundingBox
            var facePoints: [[String: Double]] = []
            
            // Vision points are 0~1 inside the bbox. We map to 0~1 image.
            for p in allP.normalizedPoints {
                let imageX = Double(p.x * bbox.width + bbox.minX)
                // native coords y=0 is BOTTOM, flutter y=0 is TOP
                let imageY = Double(p.y * bbox.height + bbox.minY)
                let flutterY = 1.0 - imageY
                
                facePoints.append(["x": imageX, "y": flutterY, "z": 0.0])
            }
            faces.append(facePoints)
        }
        
        DispatchQueue.main.async {
            sink([
                "faces": faces,
                "numFaces": faces.count,
                "timestampMs": Int(Date().timeIntervalSince1970 * 1000)
            ])
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

// MARK: - Tongue Channel Setup

extension AppDelegate {

    private func warmupGestureRecognizerIfNeeded() {
        guard gestureRecognizer == nil else { return }
        setupGestureRecognizer()
    }

    func setupTongueChannels(controller: FlutterViewController) {
        let mChannel = FlutterMethodChannel(
            name: "tongue/frame",
            binaryMessenger: controller.binaryMessenger
        )
        tongueMethodChannel = mChannel
        mChannel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            if call.method == "warmup" {
                if self.tongueDetector == nil {
                    let detector = TongueDetector()
                    detector.delegate = self
                    self.tongueDetector = detector
                }
                result(true)
                return
            }
            guard call.method == "processFrame",
                  let args        = call.arguments as? [String: Any],
                  let bytes       = args["bytes"]   as? FlutterStandardTypedData,
                  let width       = args["width"]   as? Int,
                  let height      = args["height"]  as? Int,
                  let rotation    = args["rotation"] as? Int
             else { result(FlutterMethodNotImplemented); return }

            let bytesPerRow = (args["bytesPerRow"] as? Int) ?? (width * 4)

            guard let cgImage = self.createCGImage(
                from: bytes.data, width: width, height: height, bytesPerRow: bytesPerRow
            ) else { return }
            let uiImage = UIImage(
                cgImage: cgImage, scale: 1.0, orientation: self.imageOrientation(for: rotation)
            )
            self.latestTongueImage = uiImage

            if self.tongueDetector == nil {
                let detector = TongueDetector()
                detector.delegate = self
                self.tongueDetector = detector
            }

            let cvOrientation = self.cgImagePropertyOrientation(for: rotation)
            let request = VNDetectFaceLandmarksRequest { [weak self] req, error in
                guard let self = self else { return }
                guard let results = req.results as? [VNFaceObservation] else { return }
                
                // For native TongueDetector
                if let face = results.first {
                    self.tongueDetector?.processFrame(observation: face, image: uiImage)
                }

                // Push points to flutter side anyway
                let now = Date().timeIntervalSince1970
                if now - self.lastFaceMeshTime >= self.faceMeshIntervalSec {
                    self.lastFaceMeshTime = now
                    self.pushFaceMeshResult(results)
                }
            }
            
            do {
                // To track faces stably across frames we use VNSequenceRequestHandler
                try self.visionSequenceHandler.perform([request], on: cgImage, orientation: cvOrientation)
            } catch {
                NSLog("[TongueChannel] perform error: %@", error.localizedDescription)
            }
            
            result(true)
        }

        let gChannel = FlutterEventChannel(name: "tongue/guide/stream", binaryMessenger: controller.binaryMessenger)
        tongueGuideEventChannel = gChannel
        gChannel.setStreamHandler(SinkHandler { [weak self] sink in self?.tongueGuideSink = sink })

        let cChannel = FlutterEventChannel(name: "tongue/capture/stream", binaryMessenger: controller.binaryMessenger)
        tongueCaptureEventChannel = cChannel
        cChannel.setStreamHandler(SinkHandler { [weak self] sink in self?.tongueCaptureSink = sink })
    }
}

// MARK: - TongueDetectorDelegate

extension AppDelegate: TongueDetectorDelegate {
    func tongueDetector(_ detector: TongueDetector, didUpdateGuideState state: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.tongueGuideSink?(state)
        }
    }

    func tongueDetector(_ detector: TongueDetector, didCapture jpegData: Data) {
        DispatchQueue.main.async { [weak self] in
            self?.tongueCaptureSink?(FlutterStandardTypedData(bytes: jpegData))
            detector.reset()
        }
    }
}
