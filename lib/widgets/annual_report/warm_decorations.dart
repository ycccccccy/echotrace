import 'package:flutter/material.dart';
import 'dart:math' as math;

/// 温暖装饰元素组件
/// 为页面添加柔和的视觉装饰

/// 浮动的圆点背景装饰
class FloatingDots extends StatelessWidget {
  final int dotCount;
  final Color color;
  final double minSize;
  final double maxSize;
  final Duration animationDuration;

  const FloatingDots({
    super.key,
    this.dotCount = 15,
    this.color = const Color(0xFF07C160),
    this.minSize = 4.0,
    this.maxSize = 12.0,
    this.animationDuration = const Duration(seconds: 20),
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _FloatingDotsPainter(
          dotCount: dotCount,
          color: color,
          minSize: minSize,
          maxSize: maxSize,
          animationDuration: animationDuration,
        ),
      ),
    );
  }
}

class _FloatingDotsPainter extends CustomPainter {
  final int dotCount;
  final Color color;
  final double minSize;
  final double maxSize;
  final Duration animationDuration;

  _FloatingDotsPainter({
    required this.dotCount,
    required this.color,
    required this.minSize,
    required this.maxSize,
    required this.animationDuration,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(0.08)
      ..style = PaintingStyle.fill;

    final random = math.Random(42); // 固定种子，确保每次绘制相同

    for (int i = 0; i < dotCount; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final radius = minSize + random.nextDouble() * (maxSize - minSize);

      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(_FloatingDotsPainter oldDelegate) => false;
}

/// 柔和的光晕效果
class WarmGlow extends StatelessWidget {
  final Widget child;
  final Color glowColor;
  final double blurRadius;
  final double spreadRadius;

  const WarmGlow({
    super.key,
    required this.child,
    this.glowColor = const Color(0xFF07C160),
    this.blurRadius = 20.0,
    this.spreadRadius = 5.0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: glowColor.withOpacity(0.2),
            blurRadius: blurRadius,
            spreadRadius: spreadRadius,
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 渐变遮罩层 - 用于在页面边缘创建柔和的渐变效果
class GradientOverlay extends StatelessWidget {
  final AlignmentGeometry begin;
  final AlignmentGeometry end;
  final List<Color> colors;
  final double opacity;

  const GradientOverlay({
    super.key,
    this.begin = Alignment.topCenter,
    this.end = Alignment.bottomCenter,
    required this.colors,
    this.opacity = 0.3,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: begin,
            end: end,
            colors: colors.map((c) => c.withOpacity(opacity)).toList(),
          ),
        ),
      ),
    );
  }
}

/// 温暖的卡片包装器
class WarmCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final Color? backgroundColor;
  final double borderRadius;
  final List<BoxShadow>? shadows;

  const WarmCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.margin = EdgeInsets.zero,
    this.backgroundColor,
    this.borderRadius = 24,
    this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor ?? Colors.white,
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow:
            shadows ??
            [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 20,
                spreadRadius: 0,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: Colors.black.withOpacity(0.03),
                blurRadius: 10,
                spreadRadius: 0,
                offset: const Offset(0, 2),
              ),
            ],
      ),
      child: child,
    );
  }
}

/// 柔和的线条装饰
class SoftLine extends StatelessWidget {
  final double width;
  final double height;
  final Color color;
  final double opacity;

  const SoftLine({
    super.key,
    this.width = 80,
    this.height = 1,
    this.color = const Color(0xFF07C160),
    this.opacity = 0.3,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            color.withOpacity(opacity),
            Colors.transparent,
          ],
        ),
      ),
    );
  }
}
