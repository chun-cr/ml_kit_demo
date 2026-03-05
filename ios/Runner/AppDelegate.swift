import Flutter
import UIKit
import MediaPipeTasksVision

@main
@objc class AppDelegate: FlutterAppDelegate {

    // MARK: - Constants
    private let methodChannelName = "gesture/frame"
    private let gestureChannelName = "gesture/stream"
    private let landmarkChannelName = "landmark/stream"
    private let modelAsset = "gesture_recognizer"

    // MARK: - MediaPipe
    private var gestureRecognizer: GestureRecognizer?

    // MARK: - Event Sinks
    private var gestureSink: FlutterEventSink?
    private var landmarkSink: FlutterEventSink?

    // MARK: - Throttle
    private var lastGestureTime: TimeInterval = 0
    private var lastLandmarkTime: TimeInterval = 0
    private let gestureIntervalSec: TimeInterval = 0.1   // 100ms
    private let landmarkIntervalSec: TimeInterval = 0.03  // 30ms
    private var frameTimestamp: Int = 0

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
        setupMethodChannel(controller: controller)
        setupGestureChannel(controller: controller)
        setupLandmarkChannel(controller: controller)

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - MediaPipe Init

    private func setupGestureRecognizer() {
        guard let modelPath = Bundle.main.path(
            forResource: modelAsset, ofType: "task", inDirectory: "Frameworks/App.framework/flutter_assets/assets"
        ) ?? Bundle.main.path(
            forResource: modelAsset, ofType: "task"
        ) else {
            NSLog("[GestureRecognizer] Model file not found in bundle")
            // Try alternative path for Flutter assets
            if let altPath = findModelInFlutterAssets() {
                initRecognizer(modelPath: altPath)
            }
            return
        }
        initRecognizer(modelPath: modelPath)
    }

    private func findModelInFlutterAssets() -> String? {
        let fm = FileManager.default
        guard let bundlePath = Bundle.main.resourcePath else { return nil }

        // Search recursively for the model file
        if let enumerator = fm.enumerator(atPath: bundlePath) {
            while let path = enumerator.nextObject() as? String {
                if path.hasSuffix("gesture_recognizer.task") {
                    return (bundlePath as NSString).appendingPathComponent(path)
                }
            }
        }
        return nil
    }

    private func initRecognizer(modelPath: String) {
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
            NSLog("[GestureRecognizer] Initialized successfully from: \(modelPath)")
        } catch {
            NSLog("[GestureRecognizer] Init failed: \(error.localizedDescription)")
        }
    }

    // MARK: - MethodChannel

    private func setupMethodChannel(controller: FlutterViewController) {
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
                self.processFrame(
                    bytes: bytes.data,
                    width: width,
                    height: height,
                    rotation: rotation
                )
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - EventChannels

    private func setupGestureChannel(controller: FlutterViewController) {
        let channel = FlutterEventChannel(
            name: gestureChannelName,
            binaryMessenger: controller.binaryMessenger
        )
        channel.setStreamHandler(GestureStreamHandler { [weak self] sink in
            self?.gestureSink = sink
        })
    }

    private func setupLandmarkChannel(controller: FlutterViewController) {
        let channel = FlutterEventChannel(
            name: landmarkChannelName,
            binaryMessenger: controller.binaryMessenger
        )
        channel.setStreamHandler(GestureStreamHandler { [weak self] sink in
            self?.landmarkSink = sink
        })
    }

    // MARK: - Frame Processing

    private func processFrame(bytes: Data, width: Int, height: Int, rotation: Int) {
        guard let recognizer = gestureRecognizer else { return }

        // Create CGImage from BGRA8888 data
        guard let cgImage = createCGImage(from: bytes, width: width, height: height) else {
            return
        }

        let uiImage: UIImage
        if rotation != 0 {
            let orientation = imageOrientation(for: rotation)
            uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
        } else {
            uiImage = UIImage(cgImage: cgImage)
        }

        guard let mpImage = try? MPImage(uiImage: uiImage) else { return }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        guard timestamp > frameTimestamp else { return }
        frameTimestamp = timestamp

        do {
            try recognizer.recognizeAsync(image: mpImage, timestampInMilliseconds: timestamp)
        } catch {
            NSLog("[GestureRecognizer] recognizeAsync error: \(error.localizedDescription)")
        }
    }

    private func createCGImage(from data: Data, width: Int, height: Int) -> CGImage? {
        let bytesPerPixel = data.count / (width * height)

        // Determine color space based on bytes per pixel
        let colorSpace: CGColorSpace
        let bitmapInfo: CGBitmapInfo

        if bytesPerPixel == 4 {
            // BGRA or RGBA
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        } else if bytesPerPixel == 3 {
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        } else {
            // Grayscale or unknown format — try to create from JPEG/PNG data
            guard let provider = CGDataProvider(data: data as CFData),
                  let img = CGImage(
                    jpegDataProviderSource: provider,
                    decode: nil, shouldInterpolate: true,
                    intent: .defaultIntent
                  ) else {
                return nil
            }
            return img
        }

        let bytesPerRow = bytesPerPixel * width

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: bytesPerPixel * 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func imageOrientation(for rotation: Int) -> UIImage.Orientation {
        switch rotation {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
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
            NSLog("[GestureRecognizer] Error: \(error.localizedDescription)")
            return
        }

        guard let result = result else { return }
        let now = Date().timeIntervalSince1970

        // ── Landmarks (30ms throttle) ──
        if now - lastLandmarkTime >= landmarkIntervalSec {
            lastLandmarkTime = now
            pushLandmarks(result)
        }

        // ── Gesture (100ms throttle) ──
        if now - lastGestureTime >= gestureIntervalSec {
            lastGestureTime = now
            pushGesture(result)
        }
    }

    private func pushLandmarks(_ result: GestureRecognizerResult) {
        guard let sink = landmarkSink else { return }

        var allHands: [[[String: Double]]] = []

        for handLandmarks in result.landmarks {
            var points: [[String: Double]] = []
            for lm in handLandmarks {
                points.append(["x": Double(lm.x), "y": Double(lm.y)])
            }
            allHands.append(points)
        }

        DispatchQueue.main.async {
            sink([
                "hands": allHands,
                "numHands": allHands.count
            ])
        }
    }

    private func pushGesture(_ result: GestureRecognizerResult) {
        guard let sink = gestureSink else { return }

        if result.gestures.isEmpty {
            DispatchQueue.main.async {
                sink([
                    "gesture": "None",
                    "confidence": 0.0,
                    "handedness": "",
                    "numHands": 0
                ])
            }
            return
        }

        var allHands: [[String: Any]] = []

        for (i, gestures) in result.gestures.enumerated() {
            guard let topGesture = gestures.first else { continue }
            let handedness: String
            if i < result.handedness.count, let first = result.handedness[i].first {
                handedness = first.categoryName ?? "Unknown"
            } else {
                handedness = "Unknown"
            }

            allHands.append([
                "gesture": topGesture.categoryName ?? "Unknown",
                "confidence": Double(topGesture.score),
                "handedness": handedness
            ])
        }

        guard let primary = allHands.first else { return }

        DispatchQueue.main.async {
            sink([
                "gesture": primary["gesture"]!,
                "confidence": primary["confidence"]!,
                "handedness": primary["handedness"]!,
                "numHands": allHands.count,
                "allHands": allHands
            ])
        }
    }
}

// MARK: - Stream Handler Helper

class GestureStreamHandler: NSObject, FlutterStreamHandler {
    private let onSinkChanged: (FlutterEventSink?) -> Void

    init(onSinkChanged: @escaping (FlutterEventSink?) -> Void) {
        self.onSinkChanged = onSinkChanged
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onSinkChanged(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onSinkChanged(nil)
        return nil
    }
}
