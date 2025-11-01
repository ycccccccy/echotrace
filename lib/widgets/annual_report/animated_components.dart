import 'package:flutter/material.dart';

/// 数字滚动动画组件
class AnimatedNumberDisplay extends StatelessWidget {
  final double value;
  final String suffix;
  final TextStyle? style;
  final Duration duration;

  const AnimatedNumberDisplay({
    super.key,
    required this.value,
    this.suffix = '',
    this.style,
    this.duration = const Duration(seconds: 2),
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Text('${value.toInt()}$suffix', style: style);
      },
    );
  }
}

/// 文字淡入动画组件
class FadeInText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final Duration delay;
  final Duration duration;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  const FadeInText({
    super.key,
    required this.text,
    this.style,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 800),
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  @override
  State<FadeInText> createState() => _FadeInTextState();
}

class _FadeInTextState extends State<FadeInText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    // 使用更柔和的缓动曲线
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );

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
      opacity: _animation,
      child: Text(
        widget.text,
        style: widget.style,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
        textAlign: widget.textAlign,
      ),
    );
  }
}

/// 卡片滑入动画组件
class SlideInCard extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;
  final Offset begin;

  const SlideInCard({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 600),
    this.begin = const Offset(0, 0.3),
  });

  @override
  State<SlideInCard> createState() => _SlideInCardState();
}

class _SlideInCardState extends State<SlideInCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _slideAnimation = Tween<Offset>(begin: widget.begin, end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _controller,
            curve: Curves.easeOutCubic, // 使用更柔和的缓动曲线
          ),
        );
    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

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
    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(opacity: _fadeAnimation, child: widget.child),
    );
  }
}

/// 环形进度条组件
class ProgressRing extends StatelessWidget {
  final double progress; // 0.0 到 1.0
  final double size;
  final double strokeWidth;
  final Color color;
  final Color backgroundColor;

  const ProgressRing({
    super.key,
    required this.progress,
    this.size = 100,
    this.strokeWidth = 8,
    this.color = Colors.blue,
    this.backgroundColor = Colors.grey,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: progress),
      duration: const Duration(milliseconds: 1500),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _ProgressRingPainter(
              progress: value,
              strokeWidth: strokeWidth,
              color: color,
              backgroundColor: backgroundColor,
            ),
            child: Center(
              child: Text(
                '${(value * 100).toInt()}%',
                style: TextStyle(
                  fontSize: size * 0.2,
                  fontWeight: FontWeight.bold,
                  color: color,
                  fontFamily: 'HarmonyOS_SansSC',
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProgressRingPainter extends CustomPainter {
  final double progress;
  final double strokeWidth;
  final Color color;
  final Color backgroundColor;

  _ProgressRingPainter({
    required this.progress,
    required this.strokeWidth,
    required this.color,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    // 绘制背景圆环
    final backgroundPaint = Paint()
      ..color = backgroundColor.withOpacity(0.3)
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, backgroundPaint);

    // 绘制进度圆环
    final progressPaint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const startAngle = -90.0 * (3.14159 / 180.0); // 从顶部开始
    final sweepAngle = 360.0 * progress * (3.14159 / 180.0);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(_ProgressRingPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

/// 带淡入效果的富文本组件 - 用于显示数据融入文案的句子
class FadeInRichText extends StatefulWidget {
  final String text;
  final TextStyle baseStyle;
  final Map<String, TextStyle> highlights;
  final Duration delay;
  final Duration duration;
  final TextAlign textAlign;

  const FadeInRichText({
    super.key,
    required this.text,
    required this.baseStyle,
    required this.highlights,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 800),
    this.textAlign = TextAlign.center,
  });

  @override
  State<FadeInRichText> createState() => _FadeInRichTextState();
}

class _FadeInRichTextState extends State<FadeInRichText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );

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
    // 构建富文本的 spans
    List<InlineSpan> spans = [];
    String remaining = widget.text;

    // 找到所有高亮部分
    List<_HighlightMatch> matches = [];
    for (var entry in widget.highlights.entries) {
      int index = 0;
      while ((index = remaining.indexOf(entry.key, index)) != -1) {
        matches.add(
          _HighlightMatch(
            start: index,
            end: index + entry.key.length,
            text: entry.key,
            style: entry.value,
          ),
        );
        index += entry.key.length;
      }
    }

    // 排序
    matches.sort((a, b) => a.start.compareTo(b.start));

    // 构建 spans
    int pos = 0;
    for (var match in matches) {
      if (pos < match.start) {
        spans.add(
          TextSpan(
            text: remaining.substring(pos, match.start),
            style: widget.baseStyle,
          ),
        );
      }
      spans.add(TextSpan(text: match.text, style: match.style));
      pos = match.end;
    }

    if (pos < remaining.length) {
      spans.add(
        TextSpan(text: remaining.substring(pos), style: widget.baseStyle),
      );
    }

    return FadeTransition(
      opacity: _animation,
      child: RichText(
        text: TextSpan(children: spans),
        textAlign: widget.textAlign,
      ),
    );
  }
}

class _HighlightMatch {
  final int start;
  final int end;
  final String text;
  final TextStyle style;

  _HighlightMatch({
    required this.start,
    required this.end,
    required this.text,
    required this.style,
  });
}
