import 'dart:async';

import 'package:flutter/material.dart';

import '../gesture_screen.dart';
import '../services/module_preloader.dart';
import 'face_detection_screen.dart';
import 'tongue_capture_screen.dart';

/// 主导航页面：底部切换 面部检测 / 手势识别 / 舌诊
class MainNavScreen extends StatefulWidget {
  const MainNavScreen({super.key});

  @override
  State<MainNavScreen> createState() => _MainNavScreenState();
}

class _MainNavScreenState extends State<MainNavScreen> {
  int _currentIndex = 0;

  int _faceKey = 0;
  int _gestureKey = 0;
  int _tongueKey = 0;
  Timer? _warmupTimer;

  @override
  void initState() {
    super.initState();
    _warmupTimer = Timer(
      const Duration(milliseconds: 800),
      ModulePreloader.warmupSecondaryModulesInBackground,
    );
  }

  @override
  void dispose() {
    _warmupTimer?.cancel();
    super.dispose();
  }

  void _onTabChanged(int index) {
    if (index == _currentIndex) return;
    setState(() {
      _currentIndex = index;
      if (index == 0) {
        _faceKey++;
      } else if (index == 1) {
        _gestureKey++;
      } else {
        _tongueKey++;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _currentIndex == 0
              ? FaceDetectionScreen(key: ValueKey('face_$_faceKey'))
              : const SizedBox.shrink(),
          _currentIndex == 1
              ? GestureScreen(key: ValueKey('gesture_$_gestureKey'))
              : const SizedBox.shrink(),
          _currentIndex == 2
              ? TongueCaptureScreen(
                  key: ValueKey('tongue_$_tongueKey'),
                  claudeApiKey: 'sk-NhuFDxlwQhp8w0D5sfLftCdLg0XeUFrPZDljo3n9wJdwKm9p',
                )
              : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111118),
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.06),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(
            children: [
              _buildNavItem(
                index: 0,
                icon: Icons.face_retouching_natural_rounded,
                label: '面部检测',
                colors: [const Color(0xFF00C9FF), const Color(0xFF92FE9D)],
              ),
              const SizedBox(width: 12),
              _buildNavItem(
                index: 1,
                icon: Icons.back_hand_rounded,
                label: '手势识别',
                colors: [const Color(0xFF6C63FF), const Color(0xFFF093FB)],
              ),
              const SizedBox(width: 12),
              _buildNavItem(
                index: 2,
                icon: Icons.medical_services_rounded,
                label: '舌诊',
                colors: [const Color(0xFFFF6B6B), const Color(0xFFFFD93D)],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required int index,
    required IconData icon,
    required String label,
    required List<Color> colors,
  }) {
    final isSelected = _currentIndex == index;

    return Expanded(
      child: GestureDetector(
        onTap: () => _onTabChanged(index),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: isSelected
                ? LinearGradient(
                    colors: [
                      colors[0].withValues(alpha: 0.15),
                      colors[1].withValues(alpha: 0.05),
                    ],
                  )
                : null,
            border: isSelected
                ? Border.all(color: colors[0].withValues(alpha: 0.3), width: 1)
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  colors: isSelected ? colors : [Colors.white38, Colors.white38],
                ).createShader(bounds),
                child: Icon(
                  icon,
                  size: 24,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected ? colors[0] : Colors.white38,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
