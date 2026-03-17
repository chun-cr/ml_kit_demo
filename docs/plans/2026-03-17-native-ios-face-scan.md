# Native iOS Face Scan Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current Flutter-driven iOS face scan pipeline with a native Swift face scan experience that performs camera capture, face landmarking, scan gating, overlay rendering, and capture readiness entirely on iOS.

**Architecture:** Keep Flutter as the app shell and entry point, but move iOS face scanning into a native full-screen controller presented from a lightweight method channel. The native screen owns AVCaptureSession, Vision requests, pose/quality gating, temporal smoothing, and overlay rendering. Flutter receives only high-level result payloads instead of per-frame landmarks.

**Tech Stack:** Flutter, Swift, UIKit, AVFoundation, Vision

---

### Task 1: Add Flutter-to-native face scan launcher

**Files:**
- Create: `lib/services/native_face_scan_channel.dart`
- Modify: `lib/screens/face_detection_screen.dart`

**Step 1: Add a launcher service**

Create a single-purpose method channel wrapper that opens the native iOS face scan screen and returns a result map.

**Step 2: Replace iOS per-frame logic in Flutter**

Remove the iOS camera-stream / EventChannel landmark path from `face_detection_screen.dart`. On iOS, render a native-launch UI instead of processing camera frames in Dart.

**Step 3: Preserve Android behavior**

Keep the Android ML Kit path intact so only iOS behavior changes.

### Task 2: Add native iOS face scan screen

**Files:**
- Create: `ios/Runner/NativeFaceScanViewController.swift`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`

**Step 1: Build the native controller**

Add a full-screen UIKit controller that owns:
- `AVCaptureSession`
- `AVCaptureVideoDataOutput`
- `AVCaptureVideoPreviewLayer`
- overlay layers for face box, landmarks, and scan status text

**Step 2: Add Vision request pipeline**

Run `VNDetectFaceLandmarksRequest` on camera frames with correct front-camera orientation handling. Use concrete gating signals that are already available from Vision in this repo-friendly path:
- single-face count
- face bounding-box size
- face center inside guide area
- yaw threshold from `VNFaceObservation.yaw` when available
- roll threshold from `VNFaceObservation.roll` when available
- stable-frame counter

**Step 3: Add temporal smoothing and gating**

Only update visible landmarks when all of the following pass:
- single face detected
- face box size threshold (initial area threshold: `> 0.10` of normalized frame)
- face center inside guide oval bounds
- yaw threshold (initial absolute threshold: `< 0.35` radians when present)
- roll threshold (initial absolute threshold: `< 0.25` radians when present)
- continuous stable-frame counter

If yaw/roll are unavailable on a frame, fall back to box-size + centering + stability only rather than blocking the scan.

**Step 4: Return high-level result**

When the scan reaches stability, return a compact result payload to Flutter such as status, quality, face bounds summary, and landmark count.

### Task 3: Wire native presentation in AppDelegate

**Files:**
- Modify: `ios/Runner/AppDelegate.swift`

**Step 1: Add face scan launcher channel**

Create a new method channel dedicated to presenting the native face scan screen.

**Step 2: Present and resolve result**

Present the native controller from the root `FlutterViewController`, keep a completion callback, and resolve the Flutter method call when the native scan completes or is cancelled.

**Step 3: Remove obsolete iOS face-stream wiring**

Delete or stop registering the old `face/frame` and `face/mesh/stream` pipeline for the face-detection screen only. Do **not** remove shared Vision helpers that are still used by the tongue flow; preserve tongue-related behavior and refactor only what is safe.

### Task 4: Verify native migration safely

**Files:**
- Modify as needed based on implementation

**Step 1: Diagnostics**

Run language diagnostics on all changed Dart and Swift files.

**Step 2: Flutter verification**

Run `flutter analyze`.
Expected: no new Dart analyzer errors in changed files.

**Step 3: iOS verification**

Run a Flutter iOS build (or Xcode build if needed) to validate Swift compilation and project wiring.
Expected: Swift sources compile and the new native face scan file is included in the Runner target.

**Step 4: Manual QA**

Confirm:
- Android face page still uses the existing Flutter/ML Kit path.
- iOS face page opens the native scanner.
- Native scanner shows stable guidance instead of raw jitter.
- Completion/cancel returns cleanly to Flutter.

Executable QA checklist:
- Android manual: open the face tab on Android and confirm the existing camera preview still renders in Flutter.
- iOS manual: open the face tab on iOS and confirm a native full-screen scanner opens without any per-frame Flutter channel traffic.
- iOS manual: move out of frame / rotate too far / re-center and confirm the status text changes accordingly.
- iOS manual: hold a centered frontal face steady until completion and confirm Flutter receives a completion payload.
