// 聊天会话模型：从数据库行构建，提供过滤、显示用摘要/时间等辅助属性

/// 聊天会话数据模型
class ChatSession {
  final String username;
  final int type;
  final int unreadCount;
  final int unreadFirstMsgSrvId;
  final int isHidden;
  final String summary;
  final String draft;
  final int status;
  final int lastTimestamp;
  final int sortTimestamp;
  final int lastClearUnreadTimestamp;
  final int lastMsgLocalId;
  final int lastMsgType;
  final int lastMsgSubType;
  final String lastMsgSender;
  final String lastSenderDisplayName;

  // 可变的显示名称（用于从 contact 数据库获取的真实姓名）
  String? displayName;

  ChatSession({
    required this.username,
    required this.type,
    required this.unreadCount,
    required this.unreadFirstMsgSrvId,
    required this.isHidden,
    required this.summary,
    required this.draft,
    required this.status,
    required this.lastTimestamp,
    required this.sortTimestamp,
    required this.lastClearUnreadTimestamp,
    required this.lastMsgLocalId,
    required this.lastMsgType,
    required this.lastMsgSubType,
    required this.lastMsgSender,
    required this.lastSenderDisplayName,
  });

  /// 从数据库Map创建ChatSession对象
  factory ChatSession.fromMap(Map<String, dynamic> map) {
    int intValue(List<String> keys, {int defaultValue = 0}) {
      for (final key in keys) {
        if (map.containsKey(key) && map[key] != null) {
          final v = map[key];
          if (v is int) return v;
          if (v is num) return v.toInt();
          final parsed = int.tryParse(v.toString());
          if (parsed != null) return parsed;
        }
      }
      return defaultValue;
    }

    String stringValue(List<String> keys) {
      for (final key in keys) {
        if (map.containsKey(key) && map[key] != null) {
          return _cleanString(map[key]);
        }
      }
      return '';
    }

    return ChatSession(
      username: stringValue(['username', 'user_name', 'userName']),
      type: intValue(['type']),
      unreadCount: intValue(['unread_count', 'unreadCount']),
      unreadFirstMsgSrvId: intValue([
        'unread_first_msg_srv_id',
        'unreadFirstMsgSrvId',
      ]),
      isHidden: intValue(['is_hidden', 'isHidden']),
      summary: stringValue(['summary', 'digest']),
      draft: stringValue(['draft']),
      status: intValue(['status']),
      lastTimestamp: intValue(['last_timestamp', 'lastTimestamp']),
      sortTimestamp: intValue(['sort_timestamp', 'sortTimestamp']),
      lastClearUnreadTimestamp: intValue([
        'last_clear_unread_timestamp',
        'lastClearUnreadTimestamp',
      ]),
      lastMsgLocalId: intValue([
        'last_msg_locald_id',
        'last_msg_localid',
        'last_msg_local_id',
        'lastMsgLocalId',
      ]),
      lastMsgType: intValue(['last_msg_type', 'lastMsgType']),
      lastMsgSubType: intValue(['last_msg_sub_type', 'lastMsgSubType']),
      lastMsgSender: stringValue(['last_msg_sender', 'lastMsgSender']),
      lastSenderDisplayName: stringValue([
        'last_sender_display_name',
        'lastSenderDisplayName',
      ]),
    );
  }

  /// 清理字符串中的无效UTF-16字符
  static String _cleanString(dynamic value) {
    if (value == null) return '';

    String str = value.toString();
    if (str.isEmpty) return str;

    try {
      // 移除控制字符和无效字符
      String cleaned = str.replaceAll(
        RegExp(r'[\x00-\x08\x0B-\x0C\x0E-\x1F\x7F-\x9F]'),
        '',
      );

      // 处理可能的孤立代理对（UTF-16编码问题）
      final codeUnits = cleaned.codeUnits;
      final validUnits = <int>[];

      for (int i = 0; i < codeUnits.length; i++) {
        final unit = codeUnits[i];

        // 检查高代理（0xD800-0xDBFF）
        if (unit >= 0xD800 && unit <= 0xDBFF) {
          // 高代理必须后跟低代理
          if (i + 1 < codeUnits.length) {
            final nextUnit = codeUnits[i + 1];
            if (nextUnit >= 0xDC00 && nextUnit <= 0xDFFF) {
              // 有效的代理对
              validUnits.add(unit);
              validUnits.add(nextUnit);
              i++; // 跳过下一个字符
              continue;
            }
          }
          // 孤立的高代理，跳过
          continue;
        }

        // 检查低代理（0xDC00-0xDFFF）
        if (unit >= 0xDC00 && unit <= 0xDFFF) {
          // 孤立的低代理，跳过
          continue;
        }

        // 普通字符
        validUnits.add(unit);
      }

      return String.fromCharCodes(validUnits);
    } catch (e) {
      // 如果清理失败，返回一个安全的替代字符串
      return str.replaceAll(
        RegExp(r'[^\u0020-\u007E\u4E00-\u9FFF\u3000-\u303F]'),
        '',
      );
    }
  }

  /// 获取会话类型描述（根据username判断）
  String get typeDescription {
    if (username.contains('@chatroom')) {
      return '群聊';
    } else if (username.startsWith('gh_')) {
      return '公众号';
    } else if (username.contains('@')) {
      return '私聊';
    }
    // 默认将非群聊/公众号的账号视为私聊，无需限定前缀
    if (username.isNotEmpty) return '私聊';

    // Fallback到type字段
    switch (type) {
      case 0:
        return '私聊';
      case 1:
        return '群聊';
      case 2:
        return '公众号';
      case 3:
        return '企业微信';
      default:
        return '未知类型($type)';
    }
  }

  /// 是否为群聊（根据username包含@chatroom判断）
  bool get isGroup => username.contains('@chatroom');

  /// 是否为公众号
  bool get isOfficialAccount => type == 2;

  /// 是否隐藏
  bool get isHiddenSession => isHidden == 1;

  /// 是否有未读消息
  bool get hasUnread => unreadCount > 0;

  /// 获取最后消息时间
  DateTime get lastMessageTime {
    return DateTime.fromMillisecondsSinceEpoch(lastTimestamp * 1000);
  }

  /// 获取格式化的最后消息时间
  String get formattedLastTime {
    final now = DateTime.now();
    final lastTime = lastMessageTime;
    final difference = now.difference(lastTime);

    if (difference.inDays > 0) {
      return '${lastTime.month}/${lastTime.day}';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}小时前';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}分钟前';
    } else {
      return '刚刚';
    }
  }

  /// 获取最后消息类型描述
  String get lastMessageTypeDescription {
    switch (lastMsgType) {
      case 1:
        return '文本';
      case 3:
        return '[图片]';
      case 34:
        return '[语音]';
      case 43:
        return '[视频]';
      case 47:
        return '[表情]';
      case 48:
        return '[位置]';
      case 10000:
        return '[系统消息]';
      case 244813135921:
        return '[引用]';
      case 17179869233:
        return '[链接]';
      case 21474836529:
        return '[图文]';
      case 154618822705:
        return '[小程序]';
      case 12884901937:
        return '[音乐]';
      case 8594229559345:
        return '[红包]';
      case 81604378673:
        return '[聊天记录]';
      case 266287972401:
        return '[拍一拍]';
      case 8589934592049:
        return '[转账]';
      case 270582939697:
        return '[直播]';
      case 25769803825:
        return '[文件]';
      default:
        return '[消息]';
    }
  }

  /// 获取显示摘要
  String get displaySummary {
    final trimmedSummary = summary.trim();

    if (lastMsgType == 34) {
      final voiceSummary = _formatVoiceSummary(trimmedSummary);
      if (voiceSummary.isNotEmpty) return voiceSummary;
    }

    if (trimmedSummary.isNotEmpty) return trimmedSummary;
    return lastMessageTypeDescription;
  }

  String _formatVoiceSummary(String raw) {
    if (raw.isEmpty) return '';
    if (raw.contains('语音')) return raw;

    final match = RegExp(r'(\d+(?:\\.\\d+)?)').firstMatch(raw);
    if (match != null) {
      final value = match.group(1)!;
      final seconds = double.tryParse(value);
      final displaySeconds = seconds != null && seconds == seconds.roundToDouble()
          ? seconds.toInt().toString()
          : value;
      return '[语音 $displaySeconds秒]';
    }

    return '[语音消息]';
  }

  /// 获取草稿提示
  String get draftHint {
    if (draft.isNotEmpty) {
      return '草稿: $draft';
    }
    return '';
  }

  /// 判断会话是否应该保留（过滤掉公众号、系统号等）
  static bool shouldKeep(String username) {
    // 排除公众号/服务号
    if (username.startsWith('gh_')) return false;

    // 排除其他系统会话
    if (username.startsWith('weixin')) return false;
    if (username.startsWith('qqmail')) return false;
    if (username.startsWith('fmessage')) return false;
    if (username.startsWith('medianote')) return false;
    if (username.startsWith('floatbottle')) return false;
    if (username.startsWith('newsapp')) return false;
    // 排除客服账号
    if (username.contains('@kefu.openim')) return false;
    if (username.contains('@openim')) return false;
    if (username.contains('service_')) return false;

    if (username == 'brandsessionholder') return false; // 订阅号/服务号文件夹
    if (username == 'brandservicesessionholder') return false; 
    if (username == 'notifymessage') return false;     // 服务通知
    if (username == 'opencustomerservicemsg') return false; // 客户服务通知
    if (username == 'notification_messages') return false; // 另一类系统通知
    if (username == 'userexperience_alarm') return false; // 某些版本的用户体验报告

    // 统一过滤逻辑：
    // 1. 群聊 (@chatroom)
    // 2. 标准wxid账号 (wxid_)
    // 3. 自定义微信号 (不含@)
    return username.contains('@chatroom') ||
        username.startsWith('wxid_') ||
        !username.contains('@');
  }

  @override
  String toString() {
    return 'ChatSession{username: $username, type: $typeDescription, unreadCount: $unreadCount, summary: $displaySummary}';
  }
}
