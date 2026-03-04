import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'face_detection_screen.dart';

/// Main page: full-screen camera preview with face detection overlay.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  CameraDescription? _camera;
  bool _isCameraReady = false;
  bool _isCameraInitialized = false;
  bool _isCameraInitializing = false;
  bool _isDisposed = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      controller.dispose();
      _controller = null;
      _isCameraReady = false;
      _isCameraInitialized = false;
      _isCameraInitializing = false;
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  Future<void> _initCamera() async {
    if (_isDisposed || _isCameraInitialized || _isCameraInitializing) return;
    _isCameraInitializing = true;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() => _errorMessage = '未发现可用摄像头');
        }
        return;
      }

      _camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        _camera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.nv21,
      );

      await _controller!.initialize();
      if (_isDisposed) return;

      _isCameraInitialized = true;
      if (mounted) {
        setState(() => _isCameraReady = true);
      }
    } catch (e) {
      _isCameraInitialized = false;
      if (mounted) {
        setState(() => _errorMessage = '摄像头初始化失败：$e');
      }
    } finally {
      _isCameraInitializing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ),
        ),
      );
    }

    if (!_isCameraReady || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF00FF88)),
              SizedBox(height: 16),
              Text(
                '正在初始化摄像头…',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: AspectRatio(
          aspectRatio: 1 / _controller!.value.aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CameraPreview(_controller!),
              FaceDetectionScreen(
                key: const ValueKey('face'),
                controller: _controller!,
                camera: _camera!,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
