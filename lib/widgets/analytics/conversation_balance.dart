import 'package:flutter/material.dart';
import '../../models/advanced_analytics_data.dart';

/// 对话天平图组件
class ConversationBalanceWidget extends StatelessWidget {
  final ConversationBalance balance;
  final String displayName;

  const ConversationBalanceWidget({
    super.key,
    required this.balance,
    required this.displayName,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 消息数量对比
        _buildComparisonBar(
          context,
          '消息数量',
          '我',
          balance.sentCount,
          displayName,
          balance.receivedCount,
        ),

        const SizedBox(height: 16),

        // 字数对比
        _buildComparisonBar(
          context,
          '总字数',
          '我',
          balance.sentWords,
          displayName,
          balance.receivedWords,
        ),

        const SizedBox(height: 16),

        // 对话段主动性对比（基于超过20分钟的间隔统计）
        _buildComparisonBar(
          context,
          '对话段发起（超过20分钟算新段）',
          '我',
          balance.segmentsInitiatedByMe,
          displayName,
          balance.segmentsInitiatedByOther,
        ),

        const SizedBox(height: 12),

        // 对话段统计信息
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[50],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey[200]!),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Column(
                children: [
                  Text(
                    '${balance.conversationSegments}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                  Text(
                    '总对话段',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
              Container(width: 1, height: 40, color: Colors.grey[300]),
              Column(
                children: [
                  Text(
                    '${balance.segmentsInitiatedByMe}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF07C160),
                    ),
                  ),
                  Text(
                    '我发起',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
              Container(width: 1, height: 40, color: Colors.grey[300]),
              Column(
                children: [
                  Text(
                    '${balance.segmentsInitiatedByOther}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.pink,
                    ),
                  ),
                  Text(
                    'TA发起',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // 结论
        _buildConclusion(context),
      ],
    );
  }

  Widget _buildComparisonBar(
    BuildContext context,
    String label,
    String leftLabel,
    int leftValue,
    String rightLabel,
    int rightValue,
  ) {
    final total = leftValue + rightValue;
    final leftRatio = total > 0 ? leftValue / total : 0.5;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),

        Row(
          children: [
            // 我的数值
            SizedBox(
              width: 80,
              child: Text(
                '$leftValue',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Color(0xFF07C160),
                ),
              ),
            ),

            const SizedBox(width: 12),

            // 对比条
            Expanded(
              child: Stack(
                children: [
                  // 背景
                  Container(
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),

                  // 左侧（我）
                  FractionallySizedBox(
                    widthFactor: leftRatio,
                    child: Container(
                      height: 24,
                      decoration: BoxDecoration(
                        color: const Color(0xFF07C160),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),

                  // 中间分割线
                  Positioned(
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        width: 2,
                        height: 24,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 12),

            // 对方的数值
            SizedBox(
              width: 80,
              child: Text(
                '$rightValue',
                textAlign: TextAlign.left,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Colors.grey[600],
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 4),

        // 标签
        Row(
          children: [
            const SizedBox(width: 80),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    leftLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF07C160),
                    ),
                  ),
                  Text(
                    rightLabel,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const SizedBox(width: 80),
          ],
        ),
      ],
    );
  }

  Widget _buildConclusion(BuildContext context) {
    String conclusion;
    IconData icon;
    Color color;

    final moreActive = balance.moreActive;

    if (moreActive == 'me') {
      conclusion = '你是这段关系中更主动的"话痨" 😊';
      icon = Icons.chat_bubble;
      color = const Color(0xFF07C160);
    } else if (moreActive == 'other') {
      conclusion = '$displayName 在这段关系中更主动';
      icon = Icons.favorite;
      color = Colors.pink;
    } else {
      conclusion = '你们的互动非常平衡 ⚖️';
      icon = Icons.balance;
      color = Colors.blue;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3), width: 1),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              conclusion,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
