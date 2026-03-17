# iOS MediaPipe Rollback Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current iOS native Vision face-scan flow with the prior Flutter camera stream + iOS MediaPipe Face Landmarker bridge.

**Architecture:** Flutter regains ownership of the camera preview and scan page for iOS. Camera frames are sent over `face/frame`, `AppDelegate.swift` runs MediaPipe `FaceLandmarker` in `.liveStream` mode, and normalized landmarks are pushed back over `face/mesh/stream` for Flutter painting and smoothing. Android and tongue flows remain intact.

**Tech Stack:** Flutter, Swift, MediaPipeTasksVision, MethodChannel, EventChannel

---

### Task 1: Restore Flutter iOS face stream path

**Files:**
- Modify: `lib/screens/face_detection_screen.dart`
- Delete: `lib/services/native_face_scan_channel.dart`

Restore iOS camera stream handling, channel listeners, iOS landmark smoothing, and `FacePainter` overlay usage. Remove the temporary native-launch UI and `face/native` launcher dependency.

### Task 2: Restore AppDelegate face channels with MediaPipe FaceLandmarker

**Files:**
- Modify: `ios/Runner/AppDelegate.swift`

Reintroduce `face/frame` and `face/mesh/stream` channels, initialize a `FaceLandmarker` in `.liveStream`, enforce monotonic timestamps for `detectAsync`, and emit normalized face landmarks to Flutter from the delegate callback.

### Task 3: Remove native Vision-only face scan artifacts

**Files:**
- Delete: `ios/Runner/NativeFaceScanViewController.swift`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`

Remove the native Vision full-screen scanner from the Runner target and stop exposing the `face/native` method channel.

### Task 4: Verify rollback

**Files:**
- Modify as needed based on implementation

Run targeted Dart analysis on changed Flutter files, run `flutter analyze`, and confirm the iOS rollback does not introduce new analyzer errors. If Swift compilation cannot be executed in this environment, explicitly report that limitation.
