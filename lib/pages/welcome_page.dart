import 'package:flutter/material.dart';

/// 欢迎页面（简约大气）
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Padding(
                  padding: const EdgeInsets.all(48),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 标题
                      Text(
                        'EchoTrace',
                        style: Theme.of(context).textTheme.displayLarge
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.5,
                            ),
                      ),

                      const SizedBox(height: 16),

                      // 副标题
                      Text(
                        '微信聊天记录查看工具',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.5),
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 免责声明 - 页面底部
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 500),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceVariant.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withOpacity(0.1),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '本工具仅用于个人数据备份查看，请确保拥有合法使用权',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
