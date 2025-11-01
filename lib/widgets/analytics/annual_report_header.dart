import 'package:flutter/material.dart';

/// 聊天报告头部组件
class AnnualReportHeader extends StatelessWidget {
  final VoidCallback? onBack;
  final VoidCallback? onClearCache;
  final String? yearText; // 显示选择的年份，如 "2024年" 或 "全部"

  const AnnualReportHeader({
    super.key,
    this.onBack,
    this.onClearCache,
    this.yearText,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 80,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SafeArea(
        child: Stack(
          children: [
            // 返回按钮
            if (onBack != null)
              Positioned(
                left: 16,
                top: 16,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onBack,
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.arrow_back,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),

            // 标题
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '聊天报告',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (yearText != null)
                    Text(
                      yearText!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                ],
              ),
            ),

            // 缓存管理按钮
            if (onClearCache != null)
              Positioned(
                right: 16,
                top: 16,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onClearCache,
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.storage,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
