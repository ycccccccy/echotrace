import 'package:flutter/material.dart';

/// 分析进度覆盖层
class AnalyticsProgressOverlay extends StatelessWidget {
  final bool isAnalyzing;
  final String currentStage;
  final double progressPercent;
  final int currentProgress;
  final int totalProgress;
  final String? detailInfo; // 详细信息
  final int? elapsedSeconds; // 已用时间
  final int? estimatedRemainingSeconds; // 预估剩余时间

  const AnalyticsProgressOverlay({
    super.key,
    required this.isAnalyzing,
    required this.currentStage,
    required this.progressPercent,
    required this.currentProgress,
    required this.totalProgress,
    this.detailInfo,
    this.elapsedSeconds,
    this.estimatedRemainingSeconds,
  });

  @override
  Widget build(BuildContext context) {
    if (!isAnalyzing) {
      return const SizedBox.shrink();
    }

    return Container(
      color: Colors.black54,
      child: Center(
        child: Card(
          margin: const EdgeInsets.all(32),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 标题
                Text(
                  '正在分析数据',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 24),

                // 进度圆环
                SizedBox(
                  width: 120,
                  height: 120,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 120,
                        height: 120,
                        child: CircularProgressIndicator(
                          value: progressPercent,
                          strokeWidth: 8,
                          backgroundColor: Colors.grey.shade200,
                        ),
                      ),
                      Text(
                        '${(progressPercent * 100).toStringAsFixed(0)}%',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // 当前阶段
                if (currentStage.isNotEmpty)
                  Text(
                    currentStage,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),

                const SizedBox(height: 8),

                // 详细信息（当前处理的用户）
                if (detailInfo != null && detailInfo!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      detailInfo!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade700,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),

                if (detailInfo != null && detailInfo!.isNotEmpty)
                  const SizedBox(height: 8),

                // 进度详情
                if (totalProgress > 0)
                  Text(
                    '$currentProgress / $totalProgress',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                const SizedBox(height: 16),

                // 时间统计信息
                if (elapsedSeconds != null || estimatedRemainingSeconds != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        if (elapsedSeconds != null)
                          Text(
                            '已用时: ${_formatDuration(elapsedSeconds!)}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: Colors.grey.shade600),
                          ),
                        if (estimatedRemainingSeconds != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '预计还需: ${_formatDuration(estimatedRemainingSeconds!)}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: Colors.grey.shade600),
                            ),
                          ),
                      ],
                    ),
                  ),

                const SizedBox(height: 16),

                // 提示信息
                Text(
                  '分析过程在后台进行，不会卡顿界面',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade500),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final remainingSeconds = duration.inSeconds.remainder(60);

    final parts = <String>[];
    if (hours > 0) {
      parts.add('$hours小时');
    }
    if (minutes > 0) {
      parts.add('$minutes分钟');
    }
    if (remainingSeconds > 0) {
      parts.add('$remainingSeconds秒');
    }
    return parts.join('');
  }
}
