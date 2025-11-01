import 'package:flutter/material.dart';
import '../../models/advanced_analytics_data.dart';

/// 日历热力图组件（GitHub风格）
class CalendarHeatmap extends StatelessWidget {
  final IntimacyCalendar calendar;

  const CalendarHeatmap({super.key, required this.calendar});

  @override
  Widget build(BuildContext context) {
    // 计算需要显示的周数
    final weeks = _calculateWeeks();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 月份标签
          _buildMonthLabels(context),
          const SizedBox(height: 8),

          // 日历网格
          SizedBox(
            height: 112, // 7*14 + 6*2 + 一点安全余度
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(weeks.length, (weekIndex) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(7, (dayIndex) {
                        final date = weeks[weekIndex][dayIndex];
                        if (date == null) {
                          return Container(
                            width: 14,
                            height: 14,
                            margin: const EdgeInsets.only(bottom: 2),
                          );
                        }

                        final count = calendar.getMessageCount(date);
                        final level = calendar.getHeatLevel(date);

                        return Tooltip(
                          message:
                              '${date.year}-${date.month}-${date.day}\n$count 条消息',
                          child: Container(
                            width: 14,
                            height: 14,
                            margin: const EdgeInsets.only(bottom: 2),
                            decoration: BoxDecoration(
                              color: _getColorByLevel(level),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        );
                      }),
                    ),
                  );
                }),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // 图例
          _buildLegend(context),
        ],
      ),
    );
  }

  Widget _buildMonthLabels(BuildContext context) {
    // 简化版：只显示起止月份
    final startMonth = calendar.startDate.month;
    final endMonth = calendar.endDate.month;

    return Row(
      children: [
        Text(
          '$startMonth月',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
        ),
        const Spacer(),
        Text(
          '$endMonth月',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
        ),
      ],
    );
  }

  Widget _buildLegend(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '少',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
        ),
        const SizedBox(width: 8),
        ...List.generate(6, (index) {
          return Container(
            width: 14,
            height: 14,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: _getColorByLevel(index),
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
        const SizedBox(width: 8),
        Text(
          '多',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
        ),
      ],
    );
  }

  List<List<DateTime?>> _calculateWeeks() {
    final weeks = <List<DateTime?>>[];

    // 从开始日期的周一开始
    DateTime current = calendar.startDate;
    while (current.weekday != 1) {
      current = current.subtract(const Duration(days: 1));
    }

    DateTime end = calendar.endDate;

    while (current.isBefore(end) || current.isAtSameMomentAs(end)) {
      final week = <DateTime?>[];

      for (int i = 0; i < 7; i++) {
        if (current.isAfter(end)) {
          week.add(null);
        } else if (current.isBefore(calendar.startDate)) {
          week.add(null);
        } else {
          week.add(current);
        }
        current = current.add(const Duration(days: 1));
      }

      weeks.add(week);
    }

    return weeks;
  }

  Color _getColorByLevel(int level) {
    const baseColor = Color(0xFF07C160);

    switch (level) {
      case 0:
        return Colors.grey[200]!;
      case 1:
        return baseColor.withOpacity(0.2);
      case 2:
        return baseColor.withOpacity(0.4);
      case 3:
        return baseColor.withOpacity(0.6);
      case 4:
        return baseColor.withOpacity(0.8);
      case 5:
        return baseColor;
      default:
        return Colors.grey[200]!;
    }
  }
}
