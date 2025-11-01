import 'package:flutter/material.dart';

/// 通用 Shimmer 加载效果组件
class ShimmerLoading extends StatefulWidget {
  final Widget child;
  final bool isLoading;
  final Duration duration;
  final Color baseColor;
  final Color highlightColor;

  const ShimmerLoading({
    super.key,
    required this.child,
    this.isLoading = true,
    this.duration = const Duration(milliseconds: 1500),
    this.baseColor = const Color(0xFFE0E0E0),
    this.highlightColor = const Color(0xFFF5F5F5),
  });

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading>
    with TickerProviderStateMixin {
  late AnimationController _shimmerController;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    // Shimmer 动画控制器
    _shimmerController = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    // 淡入动画控制器
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );

    if (widget.isLoading) {
      _shimmerController.repeat();
      _fadeController.forward();
    }
  }

  @override
  void didUpdateWidget(ShimmerLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoading != oldWidget.isLoading) {
      if (widget.isLoading) {
        _shimmerController.repeat();
        _fadeController.forward();
      } else {
        _shimmerController.stop();
        _fadeController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: widget.isLoading
          ? FadeTransition(
              key: const ValueKey('shimmer'),
              opacity: _fadeAnimation,
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _shimmerController,
                  builder: (context, child) {
                    return ShaderMask(
                      blendMode: BlendMode.srcATop,
                      shaderCallback: (bounds) {
                        return LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            widget.baseColor,
                            widget.highlightColor,
                            widget.baseColor,
                          ],
                          stops: const [0.0, 0.5, 1.0],
                          transform: _SlidingGradientTransform(
                            slidePercent: _shimmerController.value,
                          ),
                        ).createShader(bounds);
                      },
                      child: child,
                    );
                  },
                  child: widget.child,
                ),
              ),
            )
          : widget.child,
    );
  }
}

class _SlidingGradientTransform extends GradientTransform {
  final double slidePercent;

  const _SlidingGradientTransform({required this.slidePercent});

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(
      bounds.width * 2 * (slidePercent - 0.5),
      0.0,
      0.0,
    );
  }
}

/// 列表项 Shimmer 占位符
class ListItemShimmer extends StatelessWidget {
  final double height;
  final EdgeInsets padding;

  const ListItemShimmer({
    super.key,
    this.height = 80,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // 头像占位符
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              const SizedBox(width: 12),
              // 文字占位符
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      height: 16,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 14,
                      width: 150,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 卡片 Shimmer 占位符
class CardShimmer extends StatelessWidget {
  final double height;
  final EdgeInsets padding;
  final EdgeInsets margin;

  const CardShimmer({
    super.key,
    this.height = 200,
    this.padding = const EdgeInsets.all(16),
    this.margin = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 20,
            width: 120,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 文本行 Shimmer 占位符
class TextLineShimmer extends StatelessWidget {
  final double width;
  final double height;
  final EdgeInsets margin;

  const TextLineShimmer({
    super.key,
    this.width = double.infinity,
    this.height = 16,
    this.margin = const EdgeInsets.only(bottom: 8),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        color: Colors.grey.shade300,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

/// 带动画的页面包装器
class AnimatedPageWrapper extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Curve curve;

  const AnimatedPageWrapper({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 400),
    this.curve = Curves.easeOutCubic,
  });

  @override
  State<AnimatedPageWrapper> createState() => _AnimatedPageWrapperState();
}

class _AnimatedPageWrapperState extends State<AnimatedPageWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: widget.curve));

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.02),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: widget.curve));

    _scaleAnimation = Tween<double>(
      begin: 0.98,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: widget.curve));

    _controller.forward();
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
      child: SlideTransition(
        position: _slideAnimation,
        child: ScaleTransition(scale: _scaleAnimation, child: widget.child),
      ),
    );
  }
}
