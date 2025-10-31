import 'package:flutter/material.dart';

/// 交叉溶解过渡
/// 页面固定在原位，通过暗化和垂直浮起营造过渡效果

class ElegantPageTransition extends StatelessWidget {
  final Widget child;
  final int pageIndex;
  final int currentPage;
  final PageController pageController;
  final Duration transitionDuration;

  const ElegantPageTransition({
    super.key,
    required this.child,
    required this.pageIndex,
    required this.currentPage,
    required this.pageController,
    this.transitionDuration = const Duration(milliseconds: 700),
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pageController,
      builder: (context, child) {
        if (!pageController.position.hasContentDimensions) {
          return this.child;
        }

        final screenWidth = MediaQuery.of(context).size.width;
        final page = pageController.page ?? pageController.initialPage.toDouble();
        final delta = (page - pageIndex).clamp(-1.5, 1.5);
        final absDelta = delta.abs().clamp(0.0, 1.0);

        // ============ 过渡参数 ============
        
        // 1. 抵消PageView的水平位移
        final pageViewOffset = delta * screenWidth;
        
        // 2. 透明度
        final opacity = Curves.easeInOutCubic.transform(1.0 - absDelta);
        
        // 3. 暗化效果
        final brightness = Curves.easeInOut.transform(1.0 - absDelta * 0.12);
        
        // 4. 轻微上移
        final verticalShift = absDelta * 12.0;
        
        // 5. 颜色过渡层：在切换点前后软化颜色变化
        final colorTransitionOpacity = _calculateColorTransitionOpacity(absDelta);

        return Stack(
          children: [
            // 主内容层 - 水平抵消 + 垂直浮起 + 暗化 + 透明度
            Transform.translate(
              offset: Offset(pageViewOffset, -verticalShift),
              child: ColorFiltered(
                colorFilter: ColorFilter.matrix([
                  brightness, 0, 0, 0, 0,
                  0, brightness, 0, 0, 0,
                  0, 0, brightness, 0, 0,
                  0, 0, 0, 1, 0,
                ]),
                child: Opacity(
                  opacity: opacity,
                  child: this.child,
                ),
              ),
            ),
            
            // 颜色过渡层 - 径向渐变的白色闪光
            if (colorTransitionOpacity > 0.001)
              Positioned.fill(
                child: IgnorePointer(
                  child: Transform.translate(
                    offset: Offset(pageViewOffset, -verticalShift),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment.center,
                          radius: 1.2,
                          colors: [
                            Colors.white.withOpacity(colorTransitionOpacity * 1.2),
                            Colors.white.withOpacity(colorTransitionOpacity * 0.8),
                            Colors.white.withOpacity(colorTransitionOpacity * 0.3),
                          ],
                          stops: const [0.0, 0.5, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            
            // 细微的边界高光
            if (opacity > 0.85)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 1.0,
                child: Transform.translate(
                  offset: Offset(pageViewOffset, -verticalShift),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.white.withOpacity(0.0),
                          Colors.white.withOpacity((1.0 - absDelta) * 0.2),
                          Colors.white.withOpacity(0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
      child: child,
    );
  }

  /// 计算颜色过渡层的不透明度
  /// 使用钟形曲线分布，在切换中点达到峰值
  double _calculateColorTransitionOpacity(double absDelta) {
    // 在0.15到0.85之间有过渡效果
    if (absDelta < 0.15 || absDelta > 0.85) {
      return 0.0;
    }
    
    // 使用平滑的钟形曲线
    final normalizedDelta = (absDelta - 0.15) / 0.7;
    final bellCurve = Curves.easeInOutCubic.transform(
      1.0 - (normalizedDelta - 0.5).abs() * 2
    );
    
    return bellCurve * 0.22; // 峰值22%不透明度
  }
}

/// 页面内容进入动画 - 极简版
class ElegantPageWrapper extends StatefulWidget {
  final Widget child;
  final Duration transitionDuration;

  const ElegantPageWrapper({
    super.key,
    required this.child,
    this.transitionDuration = const Duration(milliseconds: 500),
  });

  @override
  State<ElegantPageWrapper> createState() => _ElegantPageWrapperState();
}

class _ElegantPageWrapperState extends State<ElegantPageWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  bool _hasAnimated = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.transitionDuration,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOut,
      ),
    );

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
      child: widget.child,
    );
  }
}
