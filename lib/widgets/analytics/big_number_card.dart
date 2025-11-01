import 'package:flutter/material.dart';

/// 大数字展示卡片
class BigNumberCard extends StatefulWidget {
  final String number;
  final String description;
  final IconData? icon;
  final Color? color;
  final Duration? animationDuration;

  const BigNumberCard({
    super.key,
    required this.number,
    required this.description,
    this.icon,
    this.color,
    this.animationDuration,
  });

  @override
  State<BigNumberCard> createState() => _BigNumberCardState();
}

class _BigNumberCardState extends State<BigNumberCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.animationDuration ?? const Duration(milliseconds: 800),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(
      begin: 0.8,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Container(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 64, color: color),
                const SizedBox(height: 24),
              ],
              AnimatedNumber(
                number: widget.number,
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                  fontSize: 72,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.description,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white.withOpacity(0.9),
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 数字滚动动画组件
class AnimatedNumber extends StatefulWidget {
  final String number;
  final TextStyle? style;

  const AnimatedNumber({super.key, required this.number, this.style});

  @override
  State<AnimatedNumber> createState() => _AnimatedNumberState();
}

class _AnimatedNumberState extends State<AnimatedNumber>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  double? _targetNumber;

  @override
  void initState() {
    super.initState();
    _targetNumber = _parseNumber(widget.number);

    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    if (_targetNumber != null) {
      _animation = Tween<double>(begin: 0, end: _targetNumber).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
      );
      _controller.forward();
    }
  }

  double? _parseNumber(String text) {
    final match = RegExp(r'\d+').firstMatch(text);
    return match != null ? double.tryParse(match.group(0)!) : null;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_targetNumber == null) {
      return Text(widget.number, style: widget.style);
    }

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final value = _animation.value.toInt();
        final displayText = widget.number.replaceFirst(
          RegExp(r'\d+'),
          value.toString(),
        );
        return Text(displayText, style: widget.style);
      },
    );
  }
}
