import 'package:flutter/material.dart';

/// 图表动画包装组件，带淡入和滑动效果
class AnimatedChart extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;

  const AnimatedChart({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 800),
  });

  @override
  State<AnimatedChart> createState() => _AnimatedChartState();
}

class _AnimatedChartState extends State<AnimatedChart>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: widget.duration, vsync: this);

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    // 延迟后开始动画
    Future.delayed(widget.delay, () {
      if (mounted) {
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
      child: SlideTransition(position: _slideAnimation, child: widget.child),
    );
  }
}

/// 交错动画列表包装器，适合为多个元素添加依次出现的动画效果
class StaggeredAnimatedList extends StatelessWidget {
  final List<Widget> children;
  final Duration staggerDelay;
  final Duration itemDuration;

  const StaggeredAnimatedList({
    super.key,
    required this.children,
    this.staggerDelay = const Duration(milliseconds: 50),
    this.itemDuration = const Duration(milliseconds: 500),
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: children.asMap().entries.map((entry) {
        final index = entry.key;
        final child = entry.value;

        return AnimatedChart(
          delay: staggerDelay * index,
          duration: itemDuration,
          child: child,
        );
      }).toList(),
    );
  }
}
