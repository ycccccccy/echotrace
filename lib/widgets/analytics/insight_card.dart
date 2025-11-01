import 'package:flutter/material.dart';

/// 洞察卡片（带渐变边框和悬浮效果）
class InsightCard extends StatefulWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget child;
  final Gradient? gradient;

  const InsightCard({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    required this.child,
    this.gradient,
  });

  @override
  State<InsightCard> createState() => _InsightCardState();
}

class _InsightCardState extends State<InsightCard> {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white,
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (widget.icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(widget.icon, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.subtitle!,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          widget.child,
        ],
      ),
    );
  }
}
