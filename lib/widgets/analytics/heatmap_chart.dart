import 'package:flutter/material.dart';
import '../../models/advanced_analytics_data.dart';
import 'animated_chart.dart';

/// 时间热力图组件（24小时×7天）
class HeatmapChart extends StatelessWidget {
  final ActivityHeatmap heatmap;

  const HeatmapChart({super.key, required this.heatmap});

  @override
  Widget build(BuildContext context) {
    return AnimatedChart(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 动态计算单元格高度，确保能在一屏内显示
          final availableHeight = constraints.maxHeight > 0
              ? constraints.maxHeight
              : 600.0;
          final cellHeight = ((availableHeight - 100) / 24).clamp(8.0, 12.0);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 星期标签
              Padding(
                padding: const EdgeInsets.only(left: 35),
                child: Row(
                  children: List.generate(7, (index) {
                    final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
                    return Expanded(
                      child: Center(
                        child: Text(
                          weekdays[index],
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(fontSize: 11),
                        ),
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(height: 4),

              // 热力图主体
              ...List.generate(24, (hour) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(
                    children: [
                      // 小时标签
                      SizedBox(
                        width: 30,
                        child: Text(
                          '${hour.toString().padLeft(2, '0')}:00',
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(fontSize: 9),
                        ),
                      ),
                      const SizedBox(width: 5),

                      // 7天的色块
                      ...List.generate(7, (weekday) {
                        final value = heatmap.getNormalizedValue(
                          hour,
                          weekday + 1,
                        );
                        final count = heatmap.getCount(hour, weekday + 1);

                        return Expanded(
                          child: Tooltip(
                            message: '$count 条消息',
                            child: Container(
                              height: cellHeight,
                              margin: const EdgeInsets.symmetric(
                                horizontal: 0.5,
                              ),
                              decoration: BoxDecoration(
                                color: _getHeatColor(value),
                                borderRadius: BorderRadius.circular(1),
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                );
              }),

              const SizedBox(height: 12),

              // 图例
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '少',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                  const SizedBox(width: 8),
                  ...List.generate(5, (index) {
                    return Container(
                      width: 14,
                      height: 14,
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      decoration: BoxDecoration(
                        color: _getHeatColor(index / 4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    );
                  }),
                  const SizedBox(width: 8),
                  Text(
                    '多',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Color _getHeatColor(double value) {
    if (value == 0) return Colors.grey[200]!;

    // 使用微信绿色渐变
    const baseColor = Color(0xFF07C160);

    if (value < 0.2) return baseColor.withOpacity(0.2);
    if (value < 0.4) return baseColor.withOpacity(0.4);
    if (value < 0.6) return baseColor.withOpacity(0.6);
    if (value < 0.8) return baseColor.withOpacity(0.8);
    return baseColor;
  }
}
