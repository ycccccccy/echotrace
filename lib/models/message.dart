import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:zstd/zstd.dart';
import '../utils/xml_message_parser.dart';
import '../services/logger_service.dart';

/// 消息数据模型
class Message {
  final int localId;
  final int serverId;
  final int localType;
  final int sortSeq;
  final int realSenderId;
  final int createTime;
  final int status;
  final int uploadStatus;
  final int downloadStatus;
  final int serverSeq;
  final int originSource;
  final String source;
  final String messageContent;
  final String compressContent;
  final List<int> packedInfoData;
  // 0/1，是否为我发送（由查询或推断填充，可为空）
  final int? isSend;
  // 发送者的 username（从 Name2Id 查询得到，用于群聊显示）
  final String? senderUsername;
  // 图片消息的 MD5（从 XML 提取）
  final String? imageMd5;
  // 动画表情 CDN URL（从 XML 提取，已解码 &amp;）
  final String? emojiCdnUrl;
  // 动画表情 MD5（从 XML 提取）
  final String? emojiMd5;
  // 动画表情尺寸（从 XML 提取）
  final int? emojiWidth;
  final int? emojiHeight;
  // 我的wxid
  final String? myWxid;
  // 拍一拍消息的解析信息（模板和需要查询的wxid列表）
  final Map<String, dynamic>? patInfo;
  // 语音时长（秒）
  final int? voiceDurationSeconds;
  // 解析后的显示内容
  final String _parsedContent;

  DateTime get createTimeDt {
    // createTime 是秒级时间戳，需要乘以1000转为毫秒
    return DateTime.fromMillisecondsSinceEpoch(createTime * 1000);
  }

  Message({
    required this.localId,
    required this.serverId,
    required this.localType,
    required this.sortSeq,
    required this.realSenderId,
    required this.createTime,
    required this.status,
    required this.uploadStatus,
    required this.downloadStatus,
    required this.serverSeq,
    required this.originSource,
    required this.source,
    required this.messageContent,
    required this.compressContent,
    required this.packedInfoData,
    this.isSend,
    this.senderUsername,
    this.imageMd5,
    this.emojiCdnUrl,
    this.emojiMd5,
    this.emojiWidth,
    this.emojiHeight,
    this.myWxid,
    this.patInfo,
    this.voiceDurationSeconds,
    required String parsedContent,
  }) : _parsedContent = parsedContent;

  static int? _parseVoiceDurationSeconds(String input) {
    if (input.isEmpty) return null;
    final n = double.tryParse(input);
    if (n == null) return null;
    if (n <= 0) return null;
    final isDecimal = input.contains('.');
    final seconds = isDecimal || n <= 60 ? n : (n / 1000.0);
    final rounded = seconds.round();
    return rounded <= 0 ? null : rounded;
  }

  /// 从数据库Map创建Message对象
  factory Message.fromMap(Map<String, dynamic> map, {String? myWxid}) {
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

    int? nullableIntValue(List<String> keys) {
      for (final key in keys) {
        if (map.containsKey(key) && map[key] != null) {
          final v = map[key];
          if (v is int) return v;
          if (v is num) return v.toInt();
          final parsed = int.tryParse(v.toString());
          if (parsed != null) return parsed;
        }
      }
      return null;
    }

    String stringValue(List<String> keys) {
      for (final key in keys) {
        if (map.containsKey(key) && map[key] != null) {
          return _safeStringFromMap(map, key);
        }
      }
      return '';
    }

    final localType = intValue(['local_type', 'type', 'localType']);
    final messageContent = stringValue([
      'message_content',
      'WCDB_CT_message_content',
      'content',
    ]);

    // 步骤1：处理compress_content - 检查是否为blob格式
    String actualContent = '';
    String decodeMaybeCompressed(dynamic raw) {
      if (raw is Uint8List) {
        return _decodeBinaryContent(raw);
      }
      if (raw is String && raw.isNotEmpty) {
        // hex -> bytes -> 解压
        if (_looksLikeHex(raw)) {
          final bytes = _hexToBytes(raw);
          if (bytes.isNotEmpty) {
            return _decodeBinaryContent(Uint8List.fromList(bytes));
          }
        }
        // base64 -> bytes -> 解压
        if (_looksLikeBase64(raw)) {
          try {
            final bytes = base64Decode(raw);
            return _decodeBinaryContent(Uint8List.fromList(bytes));
          } catch (_) {}
        }
        return raw;
      }
      return '';
    }

    final compressContentRaw =
        map['compress_content'] ??
        map['WCDB_CT_compress_content'] ??
        map['WCDB_CT_message_content'];

    actualContent = decodeMaybeCompressed(compressContentRaw);
    if (actualContent.isEmpty && messageContent.isNotEmpty) {
      actualContent = decodeMaybeCompressed(messageContent);
    }

    final senderUsername = _safeStringFromMap(map, 'sender_username');
    final senderDisplayName = _safeStringFromMap(map, 'sender_display_name');
    int? isSendVal = _readIsSend(map);
    int? voiceDurationSeconds;
    String? emojiCdnUrl;
    String? emojiMd5;
    int? emojiWidth;
    int? emojiHeight;

    // 步骤2：根据localType解析内容
    final parsedContent = _parseMessageContent(
      actualContent,
      localType,
      messageContent,
      myWxid,
      senderUsername: senderUsername.isEmpty ? null : senderUsername,
      senderDisplayName: senderDisplayName.isEmpty ? null : senderDisplayName,
      isSendFlag: isSendVal ?? nullableIntValue(['is_send', 'isSend']),
    );

    // 语音时长：仅从消息内容/解析结果提取，不依赖解密文件
    if (localType == 34) {
      // 优先从 XML 属性提取，兼容多种字段名
      final attrs = ['voicelength', 'length', 'time', 'playlength'];
      String durationStr = '';
      for (final attr in attrs) {
        durationStr = _extractDurationFromXml(actualContent, attr).trim();
        if (durationStr.isNotEmpty) break;
      }
      if (durationStr.isEmpty) {
        for (final attr in attrs) {
          durationStr = _extractDurationFromXml(messageContent, attr).trim();
          if (durationStr.isNotEmpty) break;
        }
      }
      voiceDurationSeconds = _parseVoiceDurationSeconds(durationStr);

      // Fallback: 从解析后的文本提取 "语音 X秒"
      if (voiceDurationSeconds == null) {
        final m = RegExp(r'语音\s*(\d+)\s*秒').firstMatch(parsedContent);
        if (m != null) {
          voiceDurationSeconds = _parseVoiceDurationSeconds(m.group(1)!);
        }
      }

      // 调试日志
      logger.debug(
        'Message',
        'voice msg parsed: localId=${intValue(['local_id'])} '
            'create=${intValue(['create_time'])} '
            'sender=$senderUsername '
            'durationStr="$durationStr" -> $voiceDurationSeconds',
      );
    }

    // 提取图片MD5（如果是图片消息）
    String? imageMd5;
    if (localType == 3 && actualContent.isNotEmpty) {
      imageMd5 = _extractImageMd5(actualContent);
    }

    // 动画表情：优先从 message_content 解码 XML，提取 cdnurl
    if (localType == 47) {
      final rawMessageContent =
          map['message_content'] ??
          map['WCDB_CT_message_content'] ??
          map['content'];
      var emojiXml = decodeMaybeCompressed(rawMessageContent);
      if (emojiXml.isEmpty && messageContent.isNotEmpty) {
        emojiXml = decodeMaybeCompressed(messageContent);
      }
      if (emojiXml.isEmpty && actualContent.isNotEmpty) {
        emojiXml = actualContent;
      }
      if (emojiXml.isNotEmpty) {
        emojiCdnUrl = _extractEmojiCdnUrl(emojiXml);
        emojiMd5 = _extractImageMd5(emojiXml);
        emojiWidth = _extractIntAttribute(emojiXml, 'width');
        emojiHeight = _extractIntAttribute(emojiXml, 'height');
      }
    }

    // 提取拍一拍消息信息
    Map<String, dynamic>? patInfo;
    if (localType == 266287972401 && actualContent.isNotEmpty) {
      patInfo = XmlMessageParser.parsePatMessageInfo(actualContent);
    }

    // 系统/拍一拍消息不归属于任何一方，避免被归类为自己发送
    if (localType == 10000 || localType == 266287972401) {
      isSendVal = null;
    }

    // 额外的 is_send 判断：如果 sender_username 与 myWxid 相同，则视为我发送
    if (isSendVal == null && myWxid != null && myWxid.isNotEmpty) {
      if (senderUsername.isNotEmpty && senderUsername == myWxid) {
        isSendVal = 1;
      }
    }

    return Message(
      localId: intValue(['local_id']),
      serverId: intValue(['server_id']),
      localType: localType,
      sortSeq: intValue(['sort_seq']),
      realSenderId: intValue(['real_sender_id']),
      createTime: intValue(['create_time']),
      status: intValue(['status']),
      uploadStatus: intValue(['upload_status']),
      downloadStatus: intValue(['download_status']),
      serverSeq: intValue(['server_seq']),
      originSource: intValue(['origin_source', 'WCDB_CT_source']),
      source: stringValue(['source', 'WCDB_CT_source']),
      messageContent: messageContent,
      compressContent: actualContent, // 存储解压后的内容
      packedInfoData: () {
        final raw = map['packed_info_data'];
        if (raw == null) return <int>[];
        if (raw is Uint8List) return raw.cast<int>();
        if (raw is List<int>) return raw;
        if (raw is List) {
          return raw.map((e) => int.tryParse(e.toString()) ?? 0).toList();
        }
        if (raw is String) {
          try {
            final decoded = jsonDecode(raw);
            if (decoded is List) {
              return decoded
                  .map((e) => int.tryParse(e.toString()) ?? 0)
                  .toList();
            }
          } catch (_) {}
        }
        return <int>[];
      }(),
      isSend: isSendVal,
      senderUsername: senderUsername.isEmpty ? null : senderUsername,
      imageMd5: imageMd5,
      emojiCdnUrl: emojiCdnUrl,
      emojiMd5: emojiMd5,
      emojiWidth: emojiWidth,
      emojiHeight: emojiHeight,
      myWxid: myWxid,
      patInfo: patInfo,
      voiceDurationSeconds: voiceDurationSeconds,
      parsedContent: parsedContent,
    );
  }

  /// 轻量创建（用于批量解密/扫描）：避免解压与复杂解析，显著提升速度。
  /// 仅依赖常用字段：local_id/create_time/local_type/packed_info_data/is_send/sender_username。
  factory Message.fromMapLite(Map<String, dynamic> map, {String? myWxid}) {
    int intValue(List<String> keys, {int defaultValue = 0}) {
      for (final key in keys) {
        final v = map[key];
        if (v == null) continue;
        if (v is int) return v;
        if (v is num) return v.toInt();
        final parsed = int.tryParse(v.toString());
        if (parsed != null) return parsed;
      }
      return defaultValue;
    }

    int? nullableIntValue(List<String> keys) {
      for (final key in keys) {
        final v = map[key];
        if (v == null) continue;
        if (v is int) return v;
        if (v is num) return v.toInt();
        final parsed = int.tryParse(v.toString());
        if (parsed != null) return parsed;
      }
      return null;
    }

    String stringValue(List<String> keys) {
      for (final key in keys) {
        final v = map[key];
        if (v == null) continue;
        if (v is String) return v;
        return v.toString();
      }
      return '';
    }

    final localType = intValue(['local_type', 'type', 'localType']);
    final senderUsername = stringValue(['sender_username']);
    final isSendVal = nullableIntValue([
      'computed_is_send',
      'is_send',
      'isSend',
    ]);

    final packed = () {
      final raw = map['packed_info_data'];
      if (raw == null) return <int>[];
      if (raw is Uint8List) return raw.cast<int>();
      if (raw is List<int>) return raw;
      if (raw is List) {
        return raw.map((e) => int.tryParse(e.toString()) ?? 0).toList();
      }
      return <int>[];
    }();

    return Message(
      localId: intValue(['local_id']),
      serverId: intValue(['server_id']),
      localType: localType,
      sortSeq: intValue(['sort_seq']),
      realSenderId: intValue(['real_sender_id']),
      createTime: intValue(['create_time']),
      status: intValue(['status']),
      uploadStatus: intValue(['upload_status']),
      downloadStatus: intValue(['download_status']),
      serverSeq: intValue(['server_seq']),
      originSource: intValue(['origin_source', 'WCDB_CT_source']),
      source: stringValue(['source', 'WCDB_CT_source']),
      messageContent: '',
      compressContent: '',
      packedInfoData: packed,
      isSend: isSendVal,
      senderUsername: senderUsername.isEmpty ? null : senderUsername,
      imageMd5: null,
      emojiCdnUrl: null,
      emojiMd5: null,
      emojiWidth: null,
      emojiHeight: null,
      myWxid: myWxid,
      patInfo: null,
      voiceDurationSeconds: null,
      parsedContent: '',
    );
  }

  /// 检查解析结果，防止XML泄露
  static String _checkParseResult(
    String result,
    int localType,
    String debugContext,
  ) {
    if (kDebugMode && result.length > 500 && result.contains('<')) {
      return '[检测到解析错误-不支持的消息类型]';
    }
    return result;
  }

  /// 统一的消息内容解析方法
  static String _parseMessageContent(
    String content,
    int localType,
    String originalMessageContent,
    String? myWxid, {
    String? senderUsername,
    String? senderDisplayName,
    int? isSendFlag,
  }) {
    // 调试输出 - 特别关注74614
    final isTargetMessage =
        kDebugMode && (localType == 244813135921 || content.length > 10000);
    if (isTargetMessage) {}

    // 首先进行URL解码，处理&amp;、&lt;、&gt;等编码
    String decodedContent = _decodeHtmlEntities(content);

    if (isTargetMessage) {}

    // 特殊处理：群聊置顶消息请求/响应，避免展示原始XML/CDATA
    if (_looksLikeChatroomTopMessage(decodedContent)) {
      final name = _preferredSenderName(
        senderDisplayName,
        senderUsername,
        fallback: '群成员',
      );
      return '$name 置顶了一条消息';
    }

    // 检查解码后的内容是否包含XML
    final hasXmlContent =
        decodedContent.contains('<') &&
        decodedContent.contains('>') &&
        (decodedContent.contains('<msg>') ||
            decodedContent.contains('<appmsg') ||
            decodedContent.contains('<?xml'));

    if (isTargetMessage) {}

    // 根据localType返回对应的显示内容
    switch (localType) {
      case 1: // 文本消息
        final textContent = decodedContent.isNotEmpty
            ? decodedContent
            : originalMessageContent;

        // 如果文本消息包含XML，需要解析而不是直接显示
        if (hasXmlContent) {
          // 检查是否有过多的编码内容，如果是就认为不支持
          if (content.contains('%') && content.length > 500) {
            return '[不支持的消息类型]';
          }

          final title = _extractValueFromXml(textContent, 'title');
          if (title.isNotEmpty) return title;

          final description = _extractValueFromXml(textContent, 'des');
          if (description.isNotEmpty) return description;

          // XML无法解析
          return '[不支持的消息类型]';
        }

        // 普通文本消息，移除可能的账号前缀
        return _stripSenderPrefix(textContent);

      case 3: // 图片消息
        return '[图片]';

      case 34: // 语音消息
        final duration = _extractDurationFromXml(decodedContent, 'voicelength');
        return duration.isNotEmpty ? '[语音 $duration秒]' : '[语音消息]';

      case 42: // 名片消息
        final nickname = _extractValueFromXml(decodedContent, 'nickname');
        return nickname.isNotEmpty ? '[名片] $nickname' : '[名片]';

      case 43: // 视频消息
        final duration = _extractDurationFromXml(decodedContent, 'playlength');
        return duration.isNotEmpty ? '[视频 $duration秒]' : '[视频消息]';

      case 47: // 动画表情
        return '[动画表情]';

      case 50: // VOIP通话
        return '[通话消息]';

      case 48: // 位置消息
        final location = _extractValueFromXml(decodedContent, 'label');
        return location.isNotEmpty ? '[位置] $location' : '[位置消息]';

      case 10000: // 系统消息
        if (decodedContent.contains('revokemsg')) {
          // 处理撤回消息
          return _parseRevokeMessage(
            decodedContent,
            myWxid,
            senderUsername: senderUsername,
            senderDisplayName: senderDisplayName,
            isSendFlag: isSendFlag,
            isSystemCenter: true,
          );
        }
        final cleaned = _cleanSystemMessage(decodedContent);
        return cleaned.isNotEmpty ? cleaned : '[系统消息]';

      case 244813135921: // 引用消息
        final result = _parseQuoteMessage(
          decodedContent,
          originalMessageContent,
        );
        return _checkParseResult(result, localType, '引用消息分支');

      case 17179869233: // 卡片式链接
        final title = _extractValueFromXml(decodedContent, 'title');
        return title.isNotEmpty ? '[链接] $title' : '[链接]';

      case 21474836529: // 图文消息
        final title = _extractValueFromXml(decodedContent, 'title');
        return title.isNotEmpty ? '[图文] $title' : '[图文消息]';

      case 154618822705: // 小程序分享
        final title = _extractValueFromXml(decodedContent, 'title');
        return title.isNotEmpty ? '[小程序] $title' : '[小程序]';

      case 12884901937: // 音乐卡片
        return '[音乐]';

      case 8594229559345: // 红包卡片
        return '[红包]';

      case 81604378673: // 聊天记录合并转发
        return '[聊天记录]';

      case 266287972401: // 拍一拍消息
        return '[拍一拍]'; // 具体内容由MessageBubble异步渲染

      case 8589934592049: // 转账卡片
        return '[转账]';

      case 270582939697: // 视频号直播卡片
        return '[视频号直播]';

      case 25769803825: // 文件消息
        final fileName = _extractValueFromXml(decodedContent, 'title');
        return fileName.isNotEmpty ? '[文件] $fileName' : '[文件]';

      default:
        // 未知类型的处理
        break;
    }

    // 兜底处理：如果到这里说明上面的switch没有处理，需要进一步检查
    if (hasXmlContent) {
      // 首先检查XML内部的type值，可能是被错误分类的消息
      final xmlType = _extractValueFromXml(decodedContent, 'type');

      // 根据XML type值进行特殊处理
      if (xmlType == '57') {
        // 这是引用消息，调用引用消息解析
        final result = _parseQuoteMessage(
          decodedContent,
          originalMessageContent,
        );
        return _checkParseResult(result, localType, '兜底处理-引用消息');
      }

      // 有XML内容，尝试提取有用信息
      final title = _extractValueFromXml(decodedContent, 'title');
      if (title.isNotEmpty) {
        // 根据XML type判断标题前缀
        switch (xmlType) {
          case '5':
          case '49':
            return '[链接] $title';
          case '6':
            return '[文件] $title';
          default:
            return title;
        }
      }

      // 尝试提取description
      final description = _extractValueFromXml(decodedContent, 'des');
      if (description.isNotEmpty) {
        return description;
      }

      // 如果都提取不到，绝对不能显示原始XML
      return '[不支持的消息类型]';
    }

    // 非XML内容
    if (decodedContent.isNotEmpty) {
      // 移除可能的账号前缀
      final cleanContent = _stripSenderPrefix(decodedContent);
      final result = cleanContent.isNotEmpty
          ? cleanContent
          : '[未知消息类型($localType)]';
      return _checkParseResult(result, localType, '非XML内容处理');
    }

    return '[未知消息类型($localType)]';
  }

  static bool _looksLikeHex(String s) {
    if (s.length % 2 != 0) return false;
    final hexRe = RegExp(r'^[0-9a-fA-F]+$');
    return hexRe.hasMatch(s);
  }

  static bool _looksLikeBase64(String s) {
    if (s.length % 4 != 0) return false;
    final b64 = RegExp(r'^[A-Za-z0-9+/=]+$');
    return b64.hasMatch(s);
  }

  static List<int> _hexToBytes(String s) {
    final out = <int>[];
    for (int i = 0; i < s.length; i += 2) {
      final byteStr = s.substring(i, i + 2);
      final v = int.tryParse(byteStr, radix: 16);
      if (v == null) return <int>[];
      out.add(v);
    }
    return out;
  }

  // 移除消息前面的“username: ”样式前缀，避免群聊显示原始id
  static String _stripSenderPrefix(String input) {
    if (input.isEmpty) return input;
    final prefixPattern = RegExp(
      // 仅匹配形如 "alice: hi" 的前缀，避免把 "https://xxx" 误删为 "//xxx"
      r'^[\s\u00A0\u2000-\u200B\u202F\u205F\u3000]*([a-zA-Z0-9_-]+):(?!//)\s*',
    );
    return input.replaceFirst(prefixPattern, '');
  }

  static bool _looksLikeChatroomTopMessage(String content) {
    if (content.isEmpty) return false;
    final lower = content.toLowerCase();
    return lower.contains('chatroomtopmsgrequest') ||
        lower.contains('chatroomtopmsgresponse');
  }

  static String _preferredSenderName(
    String? displayName,
    String? username, {
    required String fallback,
  }) {
    final dn = displayName?.trim() ?? '';
    if (dn.isNotEmpty) return dn;
    final un = username?.trim() ?? '';
    if (un.isNotEmpty) return un;
    return fallback;
  }

  /// HTML实体解码
  static String _decodeHtmlEntities(String input) {
    if (input.isEmpty) return input;

    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#x20;', ' ')
        .replaceAll('&#x0A;', '\n')
        .replaceAll('&#x0D;', '\r');
  }

  /// 清理系统消息中的标签/图标，保留可读文本
  static String _cleanSystemMessage(String input) {
    if (input.isEmpty) return '';
    var text = input;
    // 去掉图片标签
    text = text.replaceAll(RegExp(r'<img[^>]*>', caseSensitive: false), '');
    // 去掉自定义链接/标签，但保留中间文字
    text = text.replaceAll(
      RegExp(r'</?[_a-zA-Z0-9]+[^>]*>', caseSensitive: false),
      '',
    );
    // 去掉多余空白
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  /// 从XML中提取指定标签的值
  static String _extractValueFromXml(String xml, String tagName) {
    if (xml.isEmpty) return '';

    try {
      final startTag = '<$tagName>';
      final endTag = '</$tagName>';
      final start = xml.toLowerCase().indexOf(startTag.toLowerCase());

      if (kDebugMode && tagName == 'title' && xml.length > 1000) {}

      if (start == -1) {
        if (kDebugMode && tagName == 'title' && xml.length > 1000) {}
        return '';
      }

      final contentStart = start + startTag.length;
      final end = xml.toLowerCase().indexOf(endTag.toLowerCase(), contentStart);

      if (kDebugMode && tagName == 'title' && xml.length > 1000) {}

      if (end == -1) {
        if (kDebugMode && tagName == 'title' && xml.length > 1000) {}
        return '';
      }

      var value = xml.substring(contentStart, end).trim();
      // 清理CDATA标记
      value = value.replaceAll(RegExp(r'<!\[CDATA\['), '');
      value = value.replaceAll(RegExp(r'\]\]>'), '');
      final result = value.trim();

      if (kDebugMode && tagName == 'title' && xml.length > 1000) {}

      return result;
    } catch (e) {
      if (kDebugMode && tagName == 'title' && xml.length > 1000) {}
      return '';
    }
  }

  /// 从XML中提取时长信息
  static String _extractDurationFromXml(String xml, String attributeName) {
    if (xml.isEmpty) return '';

    try {
      // 兼容形如 voicelength="16765" 或 length=31264
      final pattern = RegExp(
        '$attributeName\\s*=\\s*"?(\\d+(?:\\.\\d+)?)"?',
        caseSensitive: false,
      );
      final match = pattern.firstMatch(xml);
      if (match == null) return '';

      final rawStr = match.group(1) ?? '';
      final raw = double.tryParse(rawStr);
      if (raw == null) return '';

      // 微信语音时长通常毫秒，大于 1000 认为是毫秒
      final seconds = raw > 1000 ? raw / 1000.0 : raw;
      if ((seconds - seconds.round()).abs() < 0.05) {
        return seconds.round().toString();
      }
      return seconds.toStringAsFixed(1);
    } catch (e) {
      return '';
    }
  }

  /// 解析撤回消息
  static String _parseRevokeMessage(
    String xml,
    String? myWxid, {
    String? senderUsername,
    String? senderDisplayName,
    int? isSendFlag,
    bool isSystemCenter = false,
  }) {
    try {
      final resolvedSender = isSystemCenter
          ? null
          : senderUsername ??
                ((isSendFlag != null && isSendFlag == 1) ? myWxid : null);
      final resolvedDisplayName = isSystemCenter
          ? null
          : (senderDisplayName?.isNotEmpty == true ? senderDisplayName : null);

      return XmlMessageParser.parseRevokeMessage(
            xml,
            myWxid,
            resolvedSender,
            resolvedDisplayName ?? resolvedSender,
          ) ??
          '[撤回消息]';
    } catch (e) {
      return '[撤回消息]';
    }
  }

  /// 解析引用消息
  static String _parseQuoteMessage(String xml, String originalMessageContent) {
    try {
      // 提取引用者的评论（title）
      final title = _extractValueFromXml(xml, 'title');

      // 只显示评论内容，不需要前缀
      if (title.isNotEmpty) {
        return title;
      } else {
        return '[引用消息]';
      }
    } catch (e) {
      return '[引用消息]';
    }
  }

  /// 从XML中提取图片MD5
  static String? _extractImageMd5(String xml) {
    try {
      final pattern = RegExp(
        "md5\\s*=\\s*['\"]([a-fA-F0-9]+)['\"]",
        caseSensitive: false,
      );
      final match = pattern.firstMatch(xml);
      return match?.group(1);
    } catch (e) {
      return null;
    }
  }

  static String? _extractEmojiCdnUrl(String xml) {
    try {
      final pattern = RegExp(
        "cdnurl\\s*=\\s*['\"]([^'\"]+)['\"]",
        caseSensitive: false,
      );
      final match = pattern.firstMatch(xml);
      if (match == null) return null;
      final rawUrl = match.group(1)!;
      final decoded = rawUrl.replaceAll('&amp;', '&');
      if (decoded.contains('%')) {
        try {
          return Uri.decodeComponent(decoded);
        } catch (_) {
          return decoded;
        }
      }
      return decoded;
    } catch (e) {
      return null;
    }
  }

  static int? _extractIntAttribute(String xml, String name) {
    try {
      final pattern = RegExp(
        "$name\\s*=\\s*['\"](\\d+)['\"]",
        caseSensitive: false,
      );
      final match = pattern.firstMatch(xml);
      if (match == null) return null;
      return int.tryParse(match.group(1)!);
    } catch (e) {
      return null;
    }
  }

  /// 解码二进制内容（处理zstd压缩）
  static String _decodeBinaryContent(Uint8List data) {
    if (data.isEmpty) return '';

    try {
      // 检查是否是zstd压缩数据
      if (data.length >= 4) {
        final magic =
            (data[3] << 24) | (data[2] << 16) | (data[1] << 8) | data[0];
        if (magic == 0x28B52FFD || magic == 0xFD2FB528) {
          try {
            final decompressed = ZstdCodec().decode(data);
            return utf8.decode(decompressed, allowMalformed: true);
          } catch (e) {
            // zstd解压失败，继续尝试其它方式
          }
        }
      }

      // 尝试直接UTF-8解码
      final directResult = utf8.decode(data, allowMalformed: true);
      final replacementCount = directResult.split('\uFFFD').length - 1;
      if (replacementCount < directResult.length * 0.2) {
        return directResult.replaceAll('\uFFFD', '');
      }

      // 尝试Latin1解码
      return latin1.decode(data);
    } catch (e) {
      return '[解码失败]';
    }
  }

  /// 安全地从Map获取字符串值
  static String _safeStringFromMap(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value == null) return '';

    if (value is String) {
      return _cleanInvalidUtf16(value);
    }

    if (value is Uint8List) {
      return _decodeBinaryContent(value);
    }

    return _cleanInvalidUtf16(value.toString());
  }

  /// 清理字符串中的无效UTF-16字符
  static String _cleanInvalidUtf16(String input) {
    if (input.isEmpty) return input;

    try {
      // 移除控制字符和无效字符
      String cleaned = input.replaceAll(
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
      return input.replaceAll(
        RegExp(r'[^\u0020-\u007E\u4E00-\u9FFF\u3000-\u303F]'),
        '',
      );
    }
  }

  /// 兼容多种可能字段名读取 is_send
  static int? _readIsSend(Map<String, dynamic> map) {
    for (final key in [
      'is_send',
      'isSend',
      'is_sender',
      'is_sender_',
      'is_send_',
      'computed_is_send',
    ]) {
      if (map.containsKey(key)) {
        final v = map[key];
        if (v is int) return v;
        if (v is bool) return v ? 1 : 0;
        if (v is num) return v.toInt();
        if (v is String) {
          final n = int.tryParse(v);
          if (n != null) return n;
        }
      }
    }
    return null;
  }

  // 这个方法可以直接通过类名调用：Message.getTypeDescriptionFromInt(1)
  static String getTypeDescriptionFromInt(int localType) {
    switch (localType) {
      case 1:
        return '文本消息';
      case 3:
        return '图片消息';
      case 34:
        return '语音消息';
      case 42:
        return '名片消息';
      case 43:
        return '视频消息';
      case 47:
        return '动画表情';
      case 48:
        return '位置消息';
      case 50:
        return '通话消息';
      case 10000:
        return '系统消息';
      case 244813135921:
        return '引用消息';
      case 17179869233:
        return '卡片式链接';
      case 21474836529:
        return '图文消息';
      case 154618822705:
        return '小程序分享';
      case 12884901937:
        return '音乐卡片';
      case 8594229559345:
        return '红包卡片';
      case 81604378673:
        return '聊天记录合并转发';
      case 266287972401:
        return '拍一拍消息';
      case 8589934592049:
        return '转账卡片';
      case 270582939697:
        return '视频号直播卡片';
      case 25769803825:
        return '文件消息';
      case 34359738417:
        return '文件消息';
      case 103079215153:
        return '文件消息';
      default:
        return '未知类型($localType)';
    }
  }

  /// 获取消息类型描述
  String get typeDescription {
    // 内部直接调用我们新的静态方法，避免代码重复
    return Message.getTypeDescriptionFromInt(localType);
  }

  /// 获取格式化的创建时间
  String get formattedCreateTime {
    final date = DateTime.fromMillisecondsSinceEpoch(createTime * 1000);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
  }

  /// 是否为文本消息
  bool get isTextMessage => localType == 1;

  /// 是否为图片消息
  bool get isImageMessage => localType == 3;

  /// 是否为语音消息
  bool get isVoiceMessage => localType == 34;

  /// 是否为视频消息
  bool get isVideoMessage => localType == 43;

  /// 是否为系统消息
  bool get isSystemMessage => localType == 10000;

  /// 系统类消息（包括拍一拍等应居中显示的提示）
  bool get isSystemLike => localType == 10000 || localType == 266287972401;

  /// 是否为压缩内容
  bool get isCompressed => compressContent.isNotEmpty;

  /// 是否为图片消息
  bool get hasImage => isImageMessage;

  /// 从 packed_info_data 提取图片文件名（不含扩展名）
  /// 例如 packed_info_data 中包含 ...3848xxxx.dat，则返回 3848xxxx
  String? get imageDatName {
    if (localType != 3 || packedInfoData.isEmpty) return null;

    // 仅提取可打印字符，方便匹配
    final printable = StringBuffer();
    for (final b in packedInfoData) {
      if (b >= 0x20 && b <= 0x7E) {
        printable.writeCharCode(b);
      } else {
        printable.write(' ');
      }
    }
    final text = printable.toString();

    // 优先匹配形如 abc.t.dat / abc.dat
    final datMatch = RegExp(
      r'([0-9a-fA-F]{8,})(?:\\.t)?\\.dat',
    ).firstMatch(text);
    if (datMatch != null) {
      return datMatch.group(1)!.toLowerCase();
    }

    // 退化：匹配长的 hex 字符串
    final hexMatch = RegExp(r'([0-9a-fA-F]{16,})').firstMatch(text);
    if (hexMatch != null) {
      return hexMatch.group(1)!.toLowerCase();
    }

    return null;
  }

  /// 图片消息调试信息
  String get imageDebugInfo {
    if (localType != 3) return '';
    final xml = compressContent.isNotEmpty ? compressContent : messageContent;
    if (xml.isEmpty) return '';
    String attr(String name) {
      final match = RegExp('$name="([^"]+)"').firstMatch(xml);
      return match?.group(1) ?? '';
    }

    String short(String v, [int max = 80]) {
      if (v.isEmpty) return '';
      if (v.length <= max) return v;
      return '${v.substring(0, max)}...(${v.length})';
    }

    final items = <String>[];
    final aesKey = attr('aeskey');
    final thumbKey = attr('cdnthumbaeskey');
    final midUrl = attr('cdnmidimgurl');
    final bigUrl = attr('cdnbigimgurl');
    final length = attr('length');
    final hdLength = attr('hdlength');
    final hevcSize = attr('hevc_mid_size');

    if (aesKey.isNotEmpty) items.add('aeskey=${short(aesKey, 120)}');
    if (thumbKey.isNotEmpty) items.add('thumbKey=${short(thumbKey, 120)}');
    if (midUrl.isNotEmpty) items.add('midUrl=${short(midUrl)}');
    if (bigUrl.isNotEmpty) items.add('bigUrl=${short(bigUrl)}');
    if (length.isNotEmpty) items.add('len=$length');
    if (hdLength.isNotEmpty) items.add('hdlen=$hdLength');
    if (hevcSize.isNotEmpty) items.add('hevc=$hevcSize');

    return items.join(', ');
  }

  /// 获取显示内容 - 直接返回解析后的内容
  String get displayContent {
    // 强制修复包含XML的长消息
    // if (_parsedContent.contains('<') && _parsedContent.length > 50) {
    //   return '[不支持的消息类型]';
    // }

    return _parsedContent;
  }

  /// 获取引用内容
  String get quotedContent {
    if (localType != 244813135921) return '';

    final xml = compressContent.isNotEmpty ? compressContent : messageContent;
    if (xml.isEmpty) return '';

    try {
      // 正确解析引用消息：提取refermsg中的内容
      final referMsgStart = xml.indexOf('<refermsg>');
      final referMsgEnd = xml.indexOf('</refermsg>');

      if (referMsgStart != -1 && referMsgEnd != -1) {
        final referMsgXml = xml.substring(referMsgStart, referMsgEnd + 11);
        final referredContent = _extractValueFromXml(referMsgXml, 'content');
        final displayName = _extractValueFromXml(referMsgXml, 'displayname');
        final type = _extractValueFromXml(referMsgXml, 'type');

        // 按类型渲染引用消息，避免显示wxid/文件名等原始信息
        final rendered = _renderQuotedContentByType(referredContent, type);
        if (rendered.isEmpty) return '';

        final cleanDisplayName =
            displayName.isNotEmpty && !_looksLikeWxid(displayName)
            ? displayName
            : '';

        return cleanDisplayName.isNotEmpty
            ? '$cleanDisplayName: $rendered'
            : rendered;
      }
    } catch (e) {
      // 解析失败时静默处理
    }

    return '';
  }

  /// 判断字符串是否像wxid（用于隐藏引用消息中的原始wxid）
  static bool _looksLikeWxid(String text) {
    final trimmed = text.trim().toLowerCase();
    if (trimmed.isEmpty) return false;
    if (trimmed.startsWith('wxid_')) return true;
    return RegExp(r'^wx[a-z0-9_-]{4,}$').hasMatch(trimmed);
  }

  /// 清理引用消息内容中的wxid和多余分隔符
  static String _sanitizeQuotedContent(String content) {
    if (content.isEmpty) return '';
    var result = content;

    // 去掉所有 wxid_xxx 片段
    result = result.replaceAll(RegExp(r'wxid_[A-Za-z0-9_-]{3,}'), '');

    // 去掉开头的分隔符（冒号/空格等）
    result = result.replaceFirst(RegExp(r'^[\s:：\-]+'), '');

    // 折叠重复的分隔符
    result = result.replaceAll(RegExp(r'[:：]{2,}'), ':');
    result = result.replaceFirst(RegExp(r'^[\s:：\-]+'), '');

    // 标准化空白
    result = result.replaceAll(RegExp(r'\s+'), ' ').trim();
    return result;
  }

  /// 根据引用消息类型渲染文本，防止暴露wxid/文件名
  static String _renderQuotedContentByType(String rawContent, String type) {
    switch (type) {
      case '1': // 文本
      case '':
        return _sanitizeQuotedContent(rawContent);
      case '3':
        return '[图片]';
      case '34': // 语音
        return '[语音]';
      case '43': // 视频
        return '[视频]';
      case '47': // 动画表情
        return '[动画表情]';
      case '48': // 位置
        return '[位置]';
      case '49': // 链接或小程序
        return '[链接]';
      default:
        // 非文本类型不展示文件名，兜底使用已清理的文本
        return _sanitizeQuotedContent(rawContent);
    }
  }

  @override
  String toString() {
    return 'Message{localId: $localId, localType: $localType, createTime: $formattedCreateTime, content: $displayContent}';
  }
}
