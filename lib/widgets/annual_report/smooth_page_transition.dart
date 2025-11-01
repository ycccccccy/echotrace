import 'package:flutter/material.dart';

/// 页面过渡包装器
/// 为PageView中的每个页面添加流畅的过渡动画效果
class SmoothPageWrapper extends StatefulWidget {
  final Widget child;
  final Duration transitionDuration;

  const SmoothPageWrapper({
    super.key,
    required this.child,
    this.transitionDuration = const Duration(milliseconds: 400),
  });

  @override
  State<SmoothPageWrapper> createState() => _SmoothPageWrapperState();
}

class _SmoothPageWrapperState extends State<SmoothPageWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<Offset> _slideAnimation;
  bool _hasAnimated = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.transitionDuration,
    );

    // 淡入淡出动画
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.8, curve: Curves.easeOut),
      ),
    );

    // 缩放动画
    _scaleAnimation = Tween<double>(
      begin: 0.96,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    // 滑动动画
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0.02, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    // 延迟一小段时间后开始动画，确保页面已经构建
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_hasAnimated) {
        _hasAnimated = true;
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: SlideTransition(position: _slideAnimation, child: widget.child),
      ),
    );
  }
}
