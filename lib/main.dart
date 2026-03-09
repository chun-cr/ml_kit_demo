import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/face_detection_screen.dart';
import 'gesture_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
    ),
  );
  runApp(const MLKitApp());
}

class MLKitApp extends StatelessWidget {
  const MLKitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ML Kit Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A0F),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C63FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const MainNavScreen(),
    );
  }
}

/// 主导航页面：底部切换 面部检测 / 手势识别
class MainNavScreen extends StatefulWidget {
  const MainNavScreen({super.key});

  @override
  State<MainNavScreen> createState() => _MainNavScreenState();
}

class _MainNavScreenState extends State<MainNavScreen> {
  int _currentIndex = 0;

  // 用 key 强制在切换时重建页面，确保摄像头资源正确释放/重新初始化
  int _faceKey = 0;
  int _gestureKey = 0;

  void _onTabChanged(int index) {
    if (index == _currentIndex) return;
    setState(() {
      _currentIndex = index;
      // 切换时递增 key，强制重建目标页面以重新初始化摄像头
      if (index == 0) {
        _faceKey++;
      } else {
        _gestureKey++;
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
          // 不使用 IndexedStack 缓存，而是用 key 切换来释放摄像头
          _currentIndex == 0
              ? FaceDetectionScreen(key: ValueKey('face_$_faceKey'))
              : const SizedBox.shrink(),
          _currentIndex == 1
              ? GestureScreen(key: ValueKey('gesture_$_gestureKey'))
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
            color: Colors.white.withOpacity(0.06),
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
                  colors: isSelected
                      ? colors
                      : [Colors.white38, Colors.white38],
                ).createShader(bounds),
                child: Icon(
                  icon,
                  size: 24,
                  color: Colors.white, // 被 ShaderMask 覆盖
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
