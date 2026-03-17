import UIKit
import AVFoundation
import Vision

final class NativeFaceScanViewController: UIViewController {

    var onFinish: (([String: Any]) -> Void)?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "native.face.scan.session")
    private let visionQueue = DispatchQueue(label: "native.face.scan.vision")
    private let stateQueue = DispatchQueue(label: "native.face.scan.state")
    private let previewView = UIView()
    private let overlayView = FaceScanOverlayView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isSessionConfigured = false
    private var isProcessingFrame = false
    private var hasCompleted = false
    private var stableFrameCount = 0
    private var smoothedPoints: [CGPoint] = []
    private var latestHint = "请将面部移动到取景框中央"
    private var latestBoundingBox: CGRect = .zero

    private let requiredStableFrames = 12
    private let minimumFaceArea: CGFloat = 0.10
    private let guideRectNormalized = CGRect(x: 0.18, y: 0.16, width: 0.64, height: 0.68)
    private let maximumYaw: Double = 0.35
    private let maximumRoll: Double = 0.25
    private let smoothingAlpha: CGFloat = 0.28

    private var guideRectInView: CGRect {
        CGRect(
            x: previewView.bounds.width * guideRectNormalized.origin.x,
            y: previewView.bounds.height * guideRectNormalized.origin.y,
            width: previewView.bounds.width * guideRectNormalized.width,
            height: previewView.bounds.height * guideRectNormalized.height
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupViews()
        updateStatus(title: "正在准备相机…", detail: "原生 Swift + Vision 正在启动")
        ensureCameraAuthorizationAndConfigureIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isSessionConfigured else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewView.bounds
        overlayView.frame = previewView.bounds
        overlayView.updateGuidePath()
    }

    private func setupViews() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)
        view.addSubview(overlayView)

        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlayView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: previewView.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: previewView.bottomAnchor),
        ])

        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.65).cgColor,
        ]
        gradient.locations = [0.0, 0.35, 1.0]
        gradient.frame = view.bounds
        gradient.zPosition = 1
        previewView.layer.addSublayer(gradient)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        closeButton.layer.cornerRadius = 18
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.text = "原生面部扫描"

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        statusLabel.numberOfLines = 0

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        detailLabel.font = .systemFont(ofSize: 14, weight: .regular)
        detailLabel.numberOfLines = 0

        let statusStack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, detailLabel])
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.axis = .vertical
        statusStack.spacing = 8
        statusStack.alignment = .fill

        let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.layer.cornerRadius = 24
        panel.clipsToBounds = true
        panel.contentView.addSubview(statusStack)

        view.addSubview(closeButton)
        view.addSubview(panel)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            statusStack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 20),
            statusStack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -20),
            statusStack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 18),
            statusStack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -18),
        ])
    }

    private func configureSessionIfNeeded() {
        guard !isSessionConfigured else { return }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            captureSession.commitConfiguration()
            DispatchQueue.main.async {
                self.updateStatus(title: "无法访问前置摄像头", detail: "当前设备没有可用的前置相机。")
            }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard captureSession.canAddInput(input) else {
                captureSession.commitConfiguration()
                return
            }
            captureSession.addInput(input)
        } catch {
            captureSession.commitConfiguration()
            DispatchQueue.main.async {
                self.updateStatus(title: "相机初始化失败", detail: error.localizedDescription)
            }
            return
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }

        captureSession.commitConfiguration()
        isSessionConfigured = true

        DispatchQueue.main.async {
            let previewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = self.previewView.bounds
            self.previewView.layer.insertSublayer(previewLayer, at: 0)
            self.previewLayer = previewLayer
            self.overlayView.updateGuidePath()
            self.updateStatus(title: "请将面部移动到取景框中央", detail: "系统会在原生层做稳定性判断，满足条件后自动完成。")
        }
    }

    private func ensureCameraAuthorizationAndConfigureIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { [weak self] in
                self?.configureSessionIfNeeded()
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self = self else { return }
                if granted {
                    self.sessionQueue.async {
                        self.configureSessionIfNeeded()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.updateStatus(title: "需要相机权限", detail: "请在系统设置中允许相机访问后再重试。")
                    }
                }
            }
        case .denied, .restricted:
            updateStatus(title: "需要相机权限", detail: "请在系统设置中允许相机访问后再重试。")
        @unknown default:
            updateStatus(title: "无法访问相机", detail: "当前设备未返回可用的相机授权状态。")
        }
    }

    @objc private func closeTapped() {
        finish(with: [
            "cancelled": true,
            "completed": false,
            "hint": latestHint,
        ])
    }

    private func handleObservations(_ observations: [VNFaceObservation]) {
        guard let previewLayer else {
            setProcessingFrame(false)
            return
        }

        guard observations.count == 1, let observation = observations.first else {
            stableFrameCount = 0
            smoothedPoints = []
            latestBoundingBox = .zero
            latestHint = observations.isEmpty ? "请将面部移动到取景框中央" : "请确保画面中只有一张人脸"

            DispatchQueue.main.async {
                self.overlayView.render(faceRect: nil, landmarks: [], stableProgress: 0, stable: false)
                self.updateStatus(title: self.latestHint, detail: "检测到合格单人脸后才会开始稳定描点。")
            }
            setProcessingFrame(false)
            return
        }

        let bbox = observation.boundingBox
        latestBoundingBox = bbox
        let bboxArea = bbox.width * bbox.height
        let faceRect = rectForBoundingBox(bbox, previewLayer: previewLayer)
        let faceCenter = CGPoint(x: faceRect.midX, y: faceRect.midY)
        let isCentered = guideRectInView.contains(faceCenter)

        let yaw = observation.yaw?.doubleValue
        let roll = observation.roll?.doubleValue
        let yawOk = yaw.map { abs($0) < maximumYaw } ?? true
        let rollOk = roll.map { abs($0) < maximumRoll } ?? true
        let sizeOk = bboxArea > minimumFaceArea

        var hint = "请保持面部稳定"
        var detail = "系统正在检测人脸姿态和稳定帧。"

        if !sizeOk {
            hint = "请靠近一点"
            detail = "需要更大的正脸区域才能稳定描点。"
        } else if !isCentered {
            hint = "请将面部移到中央"
            detail = "把脸对准取景框中间的高亮区域。"
        } else if !yawOk || !rollOk {
            hint = "请正对镜头"
            detail = "当前转头或倾斜角度过大，系统暂不接受这一帧。"
        }

        let imagePoints = extractImagePoints(from: observation)
        let smoothed = smooth(points: imagePoints)
        let isStable = sizeOk && isCentered && yawOk && rollOk && !smoothed.isEmpty

        if isStable {
            stableFrameCount += 1
            hint = stableFrameCount >= requiredStableFrames ? "扫描完成" : "请保持不动"
            detail = stableFrameCount >= requiredStableFrames
                ? "已达到稳定帧要求，正在返回结果。"
                : "继续保持当前姿态，系统会自动完成。"
        } else {
            stableFrameCount = 0
        }

        latestHint = hint
        let progress = min(CGFloat(stableFrameCount) / CGFloat(requiredStableFrames), 1.0)
        let layerPoints = smoothed.map { layerPoint(fromImagePoint: $0, previewLayer: previewLayer) }

        DispatchQueue.main.async {
            self.overlayView.render(faceRect: faceRect, landmarks: layerPoints, stableProgress: progress, stable: isStable)
            self.updateStatus(title: hint, detail: detail)
        }

        if stableFrameCount >= requiredStableFrames {
            finish(with: [
                "cancelled": false,
                "completed": true,
                "hint": hint,
                "stableFrames": stableFrameCount,
                "landmarkCount": smoothed.count,
                "faceBounds": [
                    "x": bbox.origin.x,
                    "y": bbox.origin.y,
                    "width": bbox.width,
                    "height": bbox.height,
                ],
                "timestampMs": Int(Date().timeIntervalSince1970 * 1000),
            ])
            return
        }

        setProcessingFrame(false)
    }

    private func extractImagePoints(from observation: VNFaceObservation) -> [CGPoint] {
        guard let allPoints = observation.landmarks?.allPoints else { return [] }
        return allPoints.normalizedPoints.map {
            CGPoint(
                x: observation.boundingBox.origin.x + CGFloat($0.x) * observation.boundingBox.width,
                y: observation.boundingBox.origin.y + CGFloat($0.y) * observation.boundingBox.height
            )
        }
    }

    private func smooth(points: [CGPoint]) -> [CGPoint] {
        guard !points.isEmpty else {
            smoothedPoints = []
            return []
        }

        guard smoothedPoints.count == points.count else {
            smoothedPoints = points
            return points
        }

        let output = zip(smoothedPoints, points).map { previous, current in
            CGPoint(
                x: previous.x + smoothingAlpha * (current.x - previous.x),
                y: previous.y + smoothingAlpha * (current.y - previous.y)
            )
        }
        smoothedPoints = output
        return output
    }

    private func rectForBoundingBox(_ boundingBox: CGRect, previewLayer: AVCaptureVideoPreviewLayer) -> CGRect {
        let topLeft = layerPoint(
            fromImagePoint: CGPoint(x: boundingBox.minX, y: boundingBox.maxY),
            previewLayer: previewLayer
        )
        let bottomRight = layerPoint(
            fromImagePoint: CGPoint(x: boundingBox.maxX, y: boundingBox.minY),
            previewLayer: previewLayer
        )

        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    private func layerPoint(fromImagePoint point: CGPoint, previewLayer: AVCaptureVideoPreviewLayer) -> CGPoint {
        let capturePoint = CGPoint(x: point.x, y: 1 - point.y)
        return previewLayer.layerPointConverted(fromCaptureDevicePoint: capturePoint)
    }

    private func finish(with payload: [String: Any]) {
        let shouldFinish = stateQueue.sync { () -> Bool in
            if hasCompleted { return false }
            hasCompleted = true
            isProcessingFrame = false
            return true
        }
        guard shouldFinish else { return }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }

        DispatchQueue.main.async {
            self.onFinish?(payload)
        }
    }

    private func updateStatus(title: String, detail: String) {
        statusLabel.text = title
        detailLabel.text = detail
    }

    private func beginProcessingFrame() -> Bool {
        stateQueue.sync {
            if hasCompleted || isProcessingFrame {
                return false
            }
            isProcessingFrame = true
            return true
        }
    }

    private func setProcessingFrame(_ value: Bool) {
        stateQueue.sync {
            if !hasCompleted {
                isProcessingFrame = value
            }
        }
    }
}

extension NativeFaceScanViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard beginProcessingFrame() else { return }

        let request = VNDetectFaceLandmarksRequest()
        if #available(iOS 13.0, *) {
            request.revision = VNDetectFaceLandmarksRequestRevision3
        }

        do {
            let handler = VNImageRequestHandler(
                cmSampleBuffer: sampleBuffer,
                orientation: .leftMirrored,
                options: [:]
            )
            try handler.perform([request])
            let observations = request.results as? [VNFaceObservation] ?? []
            handleObservations(observations)
        } catch {
            stableFrameCount = 0
            smoothedPoints = []
            latestHint = "识别中断，请稍后重试"
            DispatchQueue.main.async {
                self.updateStatus(title: "识别中断", detail: error.localizedDescription)
            }
            setProcessingFrame(false)
        }
    }
}

private final class FaceScanOverlayView: UIView {
    private let guideLayer = CAShapeLayer()
    private let faceLayer = CAShapeLayer()
    private let landmarkLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let guideRectNormalized = CGRect(x: 0.18, y: 0.16, width: 0.64, height: 0.68)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        guideLayer.strokeColor = UIColor.white.withAlphaComponent(0.6).cgColor
        guideLayer.fillColor = UIColor.clear.cgColor
        guideLayer.lineWidth = 2
        guideLayer.lineDashPattern = [8, 6]

        faceLayer.strokeColor = UIColor.systemGreen.cgColor
        faceLayer.fillColor = UIColor.clear.cgColor
        faceLayer.lineWidth = 2.5

        landmarkLayer.strokeColor = UIColor.systemTeal.withAlphaComponent(0.95).cgColor
        landmarkLayer.fillColor = UIColor.clear.cgColor
        landmarkLayer.lineWidth = 1.5
        landmarkLayer.lineJoin = .round
        landmarkLayer.lineCap = .round

        progressLayer.strokeColor = UIColor.systemGreen.cgColor
        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.lineWidth = 6
        progressLayer.lineCap = .round

        layer.addSublayer(guideLayer)
        layer.addSublayer(faceLayer)
        layer.addSublayer(landmarkLayer)
        layer.addSublayer(progressLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateGuidePath() {
        let rect = CGRect(
            x: bounds.width * guideRectNormalized.origin.x,
            y: bounds.height * guideRectNormalized.origin.y,
            width: bounds.width * guideRectNormalized.width,
            height: bounds.height * guideRectNormalized.height
        )
        guideLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 28).cgPath

        let progressPath = UIBezierPath(
            roundedRect: rect.insetBy(dx: -10, dy: -10),
            cornerRadius: 34
        )
        progressLayer.path = progressPath.cgPath
        progressLayer.strokeStart = 0
        progressLayer.strokeEnd = 0
    }

    func render(faceRect: CGRect?, landmarks: [CGPoint], stableProgress: CGFloat, stable: Bool) {
        if let faceRect {
            faceLayer.path = UIBezierPath(roundedRect: faceRect, cornerRadius: 18).cgPath
        } else {
            faceLayer.path = nil
        }

        if landmarks.isEmpty {
            landmarkLayer.path = nil
        } else {
            let path = UIBezierPath()
            for point in landmarks {
                path.move(to: point)
                path.addArc(withCenter: point, radius: 1.1, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            }
            landmarkLayer.path = path.cgPath
        }

        progressLayer.strokeColor = (stable ? UIColor.systemGreen : UIColor.systemOrange).cgColor
        progressLayer.strokeEnd = max(0, min(stableProgress, 1))
    }
}
