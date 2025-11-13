import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/chat_session.dart';
import '../utils/string_utils.dart';
import '../providers/app_state.dart';

/// 会话列表项组件
class ChatSessionItem extends StatelessWidget {
  final ChatSession session;
  final bool isSelected;
  final VoidCallback onTap;
  final String? avatarUrl;

  const ChatSessionItem({
    super.key,
    required this.session,
    required this.isSelected,
    required this.onTap,
    this.avatarUrl,
  });

  /// 安全获取头像文本
  String _getAvatarText(BuildContext context, ChatSession session) {
    final myWxid =
        context.read<AppState>().databaseService.currentAccountWxid ?? '';

    // 如果是当前账号，显示"我"
    if (session.username == myWxid) {
      return '我';
    }

    final displayName = session.displayName ?? session.username;

    // 使用 StringUtils 安全地获取第一个字符
    // 这个方法会正确处理 emoji 等占用多个 code units 的字符
    return StringUtils.getFirstChar(displayName, defaultChar: '?');
  }

  /// 安全获取显示名称
  String _getDisplayName(BuildContext context, ChatSession session) {
    final myWxid =
        context.read<AppState>().databaseService.currentAccountWxid ?? '';

    // 如果是当前账号，显示"我"
    if (session.username == myWxid) {
      return '我';
    }

    final displayName = session.displayName ?? session.username;

    // 使用 StringUtils 清理并验证
    return StringUtils.cleanOrDefault(displayName, '未知联系人');
  }

  /// 清理字符串（使用工具类）
  String _cleanString(String input) {
    return StringUtils.cleanUtf16(input);
  }

  /// 显示会话详细信息对话框
  void _showDetailDialog(BuildContext context) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('正在加载详细信息...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final appState = context.read<AppState>();
      final detailInfo = await appState.databaseService.getSessionDetailInfo(
        session.username,
      );

      if (!context.mounted) {
        return;
      }

      Navigator.pop(context);

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('会话详细信息'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildInfoRow('显示名称', detailInfo.displayName),
                  _buildInfoRow('微信ID', detailInfo.wxid),
                  if (detailInfo.remark != null)
                    _buildInfoRow('备注', detailInfo.remark!),
                  if (detailInfo.nickName != null)
                    _buildInfoRow('昵称', detailInfo.nickName!),
                  if (detailInfo.alias != null)
                    _buildInfoRow('微信号', detailInfo.alias!),
                  const Divider(height: 24),
                  _buildInfoRow('消息总数', '${detailInfo.messageCount} 条'),
                  if (detailInfo.firstMessageTime != null)
                    _buildInfoRow(
                      '第一条消息时间',
                      _formatTimestamp(detailInfo.firstMessageTime!),
                    ),
                  if (detailInfo.latestMessageTime != null)
                    _buildInfoRow(
                      '最后消息时间',
                      _formatTimestamp(detailInfo.latestMessageTime!),
                    ),
                  const Divider(height: 24),
                  const Text(
                    '消息表分布',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (detailInfo.messageTables.isEmpty)
                    const Text('未找到消息表', style: TextStyle(color: Colors.grey))
                  else
                    ...detailInfo.messageTables.map(
                      (table) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '• ${table.databaseName}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '表名: ${table.tableName}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  Text(
                                    '消息数: ${table.messageCount} 条',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!context.mounted) {
        return;
      }
      Navigator.pop(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('加载详细信息失败: $e')));
    }
  }

  /// 构建信息行
  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                color: Colors.black87,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }

  /// 格式化时间戳
  String _formatTimestamp(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // 包装在 try-catch 中以捕获任何 UTF-16 错误
    try {
      return GestureDetector(
        onSecondaryTapDown: (details) {
          // 右键点击，显示上下文菜单
          final RenderBox overlay =
              Overlay.of(context).context.findRenderObject() as RenderBox;
          showMenu(
            context: context,
            position: RelativeRect.fromRect(
              details.globalPosition & const Size(40, 40),
              Offset.zero & overlay.size,
            ),
            items: [
              const PopupMenuItem(
                value: 'detail',
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 18),
                    SizedBox(width: 8),
                    Text('查看详细信息'),
                  ],
                ),
              ),
            ],
          ).then((value) {
            if (value == 'detail') {
              _showDetailDialog(context);
            }
          });
        },
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isSelected
                  ? Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withValues(alpha: 0.5)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 头像
                CircleAvatar(
                  radius: 24,
                  backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                  backgroundImage: (avatarUrl != null && avatarUrl!.isNotEmpty)
                      ? NetworkImage(avatarUrl!)
                      : null,
                  child: (avatarUrl == null || avatarUrl!.isEmpty)
                      ? Text(
                          _cleanString(_getAvatarText(context, session)),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 12),

                // 会话信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 用户名和时间
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _getDisplayName(context, session),
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                              maxLines: 1,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _cleanString(session.formattedLastTime),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),

                      // 摘要
                      Text(
                        _cleanString(session.displaySummary),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e, stackTrace) {
      // 捕获 UTF-16 错误并记录详细信息
      debugPrint('[ERROR] ChatSessionItem 渲染错误: $e');
      debugPrint('   会话ID: ${session.username}');
      debugPrint('   显示名称: ${session.displayName}');
      debugPrint('   摘要: ${session.displaySummary}');
      debugPrint('   堆栈跟踪: $stackTrace');

      // 返回一个安全的替代Widget
      return InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected
                ? Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.5)
                : Colors.transparent,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
              ),
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.2),
                child: const Icon(Icons.error),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '会话加载错误',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Text(
                      session.username,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
  }
}
