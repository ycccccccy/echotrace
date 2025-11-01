import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

/// 解密进度覆盖层
///
/// 在解密数据库时显示进度提示
class DecryptProgressOverlay extends StatelessWidget {
  const DecryptProgressOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        if (!appState.isDecrypting) {
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
                      '正在加载数据库',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
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
                              value: appState.decryptProgressPercent,
                              strokeWidth: 8,
                              backgroundColor: Colors.grey.shade200,
                            ),
                          ),
                          Text(
                            '${(appState.decryptProgressPercent * 100).toStringAsFixed(0)}%',
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

                    // 数据库名称
                    if (appState.decryptingDatabase.isNotEmpty)
                      Text(
                        '解密: ${appState.decryptingDatabase}',
                        style: Theme.of(context).textTheme.bodyLarge,
                        textAlign: TextAlign.center,
                      ),

                    const SizedBox(height: 8),

                    // 进度详情
                    if (appState.decryptTotal > 0)
                      Text(
                        '${appState.decryptProgress} / ${appState.decryptTotal} 页',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey.shade600,
                        ),
                      ),

                    const SizedBox(height: 16),

                    // 提示信息
                    Text(
                      '首次加载可能需要几秒钟...',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
