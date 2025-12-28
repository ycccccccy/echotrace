import 'dart:ui';
import 'package:flutter/material.dart';

Future<bool?> showPrivacyAgreementDialog(BuildContext context) {
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'privacy_agreement',
    barrierColor: Colors.black.withValues(alpha: 0.6),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (context, animation, secondaryAnimation) {
      return const _PrivacyDialogContent();
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutBack,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.95, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _PrivacyDialogContent extends StatefulWidget {
  const _PrivacyDialogContent();

  @override
  State<_PrivacyDialogContent> createState() => _PrivacyDialogContentState();
}

class _PrivacyDialogContentState extends State<_PrivacyDialogContent> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SafeArea(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 520,
              maxHeight: 680,
            ),
            child: Material(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(20),
              elevation: 16,
              shadowColor: Colors.black.withValues(alpha: 0.2),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '免责声明与用户协议',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '使用 EchoTrace 前，请务必仔细阅读以下条款。如您同意，请点击下方“我同意”按钮继续使用本软件。',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),

                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 24),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                        ),
                      ),
                      clipBehavior: Clip.hardEdge,
                      child: Stack(
                        children: [
                          Scrollbar(
                            controller: _scrollController,
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                              child: SelectableText.rich(
                                TextSpan(
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    height: 1.6,
                                    color: colorScheme.onSurface.withValues(alpha: 0.8),
                                    fontSize: 14,
                                  ),
                                  children: _buildRichTextContent(colorScheme),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: 20,
                            child: IgnorePointer(
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      colorScheme.surfaceContainerLow,
                                      colorScheme.surfaceContainerLow.withValues(alpha: 0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            height: 40,
                            child: IgnorePointer(
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                    colors: [
                                      colorScheme.surfaceContainerLow,
                                      colorScheme.surfaceContainerLow.withValues(alpha: 0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              style: TextButton.styleFrom(
                                foregroundColor: colorScheme.onSurfaceVariant,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 16,
                                ),
                              ),
                              child: const Text('拒绝并退出'),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed: () => Navigator.of(context).pop(true),
                                style: FilledButton.styleFrom(
                                  backgroundColor: colorScheme.primary,
                                  foregroundColor: colorScheme.onPrimary,
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  elevation: 0,
                                ),
                                child: const Text(
                                  '我已阅读并同意继续使用',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'v1.0.0 • Updated 2025',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<TextSpan> _buildRichTextContent(ColorScheme colorScheme) {
    // 标题样式
    final titleStyle = TextStyle(
      fontWeight: FontWeight.bold,
      color: colorScheme.onSurface,
      fontSize: 15,
    );

    final alertStyle = TextStyle(
      fontWeight: FontWeight.bold,
      color: colorScheme.error, 
    );

    return [
      TextSpan(text: '一、总则\n', style: titleStyle),
      const TextSpan(
        text: '1. EchoTrace（以下简称“本软件”）是一个基于 GitHub 开源项目的本地数据处理工具，'
            '仅供技术研究和个人学习使用。\n'
            '2. 用户在下载、安装、使用本软件时，即视为已阅读并完全同意本协议所有条款。\n\n',
      ),
      TextSpan(text: '二、免责声明（重要）\n', style: titleStyle),
      const TextSpan(text: '1. 【按原样提供】本软件按“原样”提供，作者不提供任何明示或暗示的保证。\n'),
      const TextSpan(text: '2. 【数据风险】本软件涉及对微信本地数据库的解密与读取。由此产生的任何'),
      TextSpan(text: '数据丢失、文件损坏、隐私泄露', style: alertStyle),
      const TextSpan(text: '等后果，均由用户自行承担。作者不承担任何赔偿责任。\n'),
      const TextSpan(text: '3. 【账号风险】使用本工具可能违反微信使用条款。因此导致的'),
      TextSpan(text: '账号被警告、限制功能或封号', style: alertStyle),
      const TextSpan(text: '，作者概不负责。\n\n'),
      TextSpan(text: '三、合规使用\n', style: titleStyle),
      const TextSpan(
        text: '1. 本软件为纯本地应用，所有数据处理均在用户设备上完成。\n'
            '2. 用户不得利用本软件进行任何违反法律法规的行为（如窃取他人隐私）。'
            '因违规使用产生的一切法律责任由用户独自承担。\n\n',
      ),
      TextSpan(text: '四、其他\n', style: titleStyle),
      const TextSpan(
        text: '1. 本软件与腾讯微信官方无任何关联。\n'
            '2. 作者保留随时停止维护本软件的权利。',
      ),
    ];
  }
}