import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../models/message.dart';
import '../utils/string_utils.dart';
import '../utils/xml_message_parser.dart';
import '../providers/app_state.dart';
import 'emoji_message_widget.dart';
import 'image_message_widget.dart';
import 'voice_message_widget.dart';

/// 消息气泡组件
class MessageBubble extends StatefulWidget {
  final Message message;
  final bool isFromMe;
  final String? senderDisplayName;
  final String sessionUsername;
  final bool shouldShowTime;
  final String? avatarUrl;
  final bool enableAvatarFade;

  const MessageBubble({
    super.key,
    required this.message,
    this.isFromMe = false,
    this.senderDisplayName,
    required this.sessionUsername,
    this.shouldShowTime = false,
    this.avatarUrl,
    this.enableAvatarFade = true,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  String? _renderedPatMessage; // 渲染后的拍一拍消息

  @override
  void initState() {
    super.initState();

    // 如果是拍一拍消息，异步查询wxid对应的真实姓名
    if (widget.message.localType == 266287972401 &&
        widget.message.patInfo != null) {
      _loadPatMessageNames();
    }
  }

  /// 加载拍一拍消息中的真实姓名
  Future<void> _loadPatMessageNames() async {
    final patInfo = widget.message.patInfo;
    if (patInfo == null) return;

    final template = patInfo['template'] as String?;
    final wxids = patInfo['wxids'] as List<dynamic>?;

    if (template == null || wxids == null || wxids.isEmpty) {
      return;
    }

    try {
      final appState = context.read<AppState>();
      final wxidList = wxids.cast<String>();

      // 查询所有wxid的真实姓名
      final wxidToName = await appState.databaseService.getDisplayNames(
        wxidList,
      );

      // 渲染消息
      if (mounted) {
        setState(() {
          _renderedPatMessage = XmlMessageParser.renderPatMessage(
            template,
            wxidToName,
          );
        });
      }
    } catch (e) {
      // 查询失败，使用原始模板
      if (mounted) {
        setState(() {
          _renderedPatMessage = template;
        });
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// 清理字符串中的无效UTF-16字符
  String _cleanString(String input) {
    return StringUtils.cleanUtf16(input);
  }

  /// 获取显示内容（处理拍一拍消息）
  String _getDisplayContent() {
    // 如果是拍一拍消息且已渲染，使用渲染后的内容
    if (widget.message.localType == 266287972401 &&
        _renderedPatMessage != null) {
      return _renderedPatMessage!;
    }

    final content = widget.message.displayContent;

    return content;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.message.isSystemLike) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.shouldShowTime)
              Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _cleanString(widget.message.formattedCreateTime),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                          fontSize: 10,
                        ),
                  ),
                ),
              ),
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  _cleanString(_getDisplayContent()),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7),
                      ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: widget.isFromMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          // 时间分隔符（只在需要时显示）
          if (widget.shouldShowTime)
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _cleanString(widget.message.formattedCreateTime),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                    fontSize: 10,
                  ),
                ),
              ),
            ),

          // 群聊中显示发送者名称（在消息气泡上方）
          if (!widget.isFromMe &&
              widget.senderDisplayName != null &&
              widget.senderDisplayName!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: 44,
                bottom: 4,
              ), // 44 = 头像宽度(36) + 间距(8)
              child: SelectableText(
                _cleanString(widget.senderDisplayName!),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

          // 消息内容
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: widget.isFromMe
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: widget.isFromMe
                ? _buildFromMeLayout(context)
                : _buildFromOtherLayout(context),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildFromMeLayout(BuildContext context) {
    return [
      // 消息气泡
      Flexible(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 真实消息
            if (widget.message.localType == 34)
              VoiceMessageWidget(
                message: widget.message,
                sessionUsername: widget.sessionUsername,
                isFromMe: true,
              )
            else if (widget.message.localType == 47)
              EmojiMessageWidget(
                message: widget.message,
                isFromMe: true,
              )
            else if (widget.message.hasImage)
              ImageMessageWidget(
                message: widget.message,
                sessionUsername: widget.sessionUsername,
                isFromMe: true,
              )
            else
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SelectableText(
                  _cleanString(_getDisplayContent()),
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            // 引用消息（放在下方）
            if (widget.message.quotedContent.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.05),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(12),
                    bottomRight: Radius.circular(12),
                    topLeft: Radius.circular(12),
                  ),
                ),
                child: SelectableText(
                  _cleanString(widget.message.quotedContent),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(width: 8),
      // 头像
      if (widget.avatarUrl != null && widget.avatarUrl!.isNotEmpty)
        CachedNetworkImage(
          imageUrl: widget.avatarUrl!,
          fadeInDuration: widget.enableAvatarFade
              ? const Duration(milliseconds: 200)
              : Duration.zero,
          fadeOutDuration: widget.enableAvatarFade
              ? const Duration(milliseconds: 200)
              : Duration.zero,
          imageBuilder: (context, imageProvider) => CircleAvatar(
            radius: 18,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.2),
            backgroundImage: imageProvider,
          ),
          placeholder: (context, url) => CircleAvatar(
            radius: 18,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.2),
            child: Icon(
              Icons.person,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          errorWidget: (context, url, error) => CircleAvatar(
            radius: 18,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.2),
            child: Icon(
              Icons.person,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        )
      else
        CircleAvatar(
          radius: 18,
          backgroundColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.2),
          child: Icon(
            Icons.person,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
    ];
  }

  List<Widget> _buildFromOtherLayout(BuildContext context) {
    return [
      // 头像
      if (widget.avatarUrl != null && widget.avatarUrl!.isNotEmpty)
        CachedNetworkImage(
          imageUrl: widget.avatarUrl!,
          fadeInDuration: widget.enableAvatarFade
              ? const Duration(milliseconds: 200)
              : Duration.zero,
          fadeOutDuration: widget.enableAvatarFade
              ? const Duration(milliseconds: 200)
              : Duration.zero,
          imageBuilder: (context, imageProvider) => CircleAvatar(
            radius: 18,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.secondary.withValues(alpha: 0.2),
            backgroundImage: imageProvider,
          ),
          placeholder: (context, url) => CircleAvatar(
            radius: 18,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.secondary.withValues(alpha: 0.2),
            child: Icon(
              Icons.person,
              size: 20,
              color: Theme.of(context).colorScheme.secondary,
            ),
          ),
          errorWidget: (context, url, error) => CircleAvatar(
            radius: 18,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.secondary.withValues(alpha: 0.2),
            child: Icon(
              Icons.person,
              size: 20,
              color: Theme.of(context).colorScheme.secondary,
            ),
          ),
        )
      else
        CircleAvatar(
          radius: 18,
          backgroundColor: Theme.of(
            context,
          ).colorScheme.secondary.withValues(alpha: 0.2),
          child: Icon(
            Icons.person,
            size: 20,
            color: Theme.of(context).colorScheme.secondary,
          ),
        ),
      const SizedBox(width: 8),
      // 消息气泡
      Flexible(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 真实消息
            if (widget.message.localType == 34)
              VoiceMessageWidget(
                message: widget.message,
                sessionUsername: widget.sessionUsername,
                isFromMe: false,
              )
            else if (widget.message.localType == 47)
              EmojiMessageWidget(
                message: widget.message,
                isFromMe: false,
              )
            else if (widget.message.hasImage)
              ImageMessageWidget(
                message: widget.message,
                sessionUsername: widget.sessionUsername,
                isFromMe: false,
              )
            else
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: _getMessageBubbleColor(context),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SelectableText(
                  _cleanString(_getDisplayContent()),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: _getMessageTextColor(context),
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            // 引用消息（放在下方）
            if (widget.message.quotedContent.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.04),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(12),
                    bottomRight: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                ),
                child: SelectableText(
                  _cleanString(widget.message.quotedContent),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
          ],
        ),
      ),
    ];
  }

  /// 获取消息气泡颜色
  Color _getMessageBubbleColor(BuildContext context) {
    // 系统消息单独弱化显示
    if (widget.message.isSystemMessage) {
      return Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
    }
    // 对方的所有消息（包含特殊类型）统一使用与文本一致的浅色背景
    if (!widget.isFromMe) {
      return Theme.of(context).colorScheme.surfaceContainerHighest;
    }
    // 自己的消息颜色由 _buildFromMeLayout 固定为主色，这里仅用于他人消息
    return Theme.of(context).colorScheme.surfaceContainerHighest;
  }

  /// 获取消息文本颜色
  Color _getMessageTextColor(BuildContext context) {
    if (widget.message.isSystemMessage) {
      return Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    } else {
      return Theme.of(context).colorScheme.onSurface;
    }
  }
}
