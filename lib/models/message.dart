import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:zstd/zstd.dart';
import '../utils/xml_message_parser.dart';

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
  // 我的wxid
  final String? myWxid;
  // 拍一拍消息的解析信息（模板和需要查询的wxid列表）
  final Map<String, dynamic>? patInfo;
  // 解析后的显示内容
  final String _parsedContent;

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
    this.myWxid,
    this.patInfo,
    required String parsedContent,
  }) : _parsedContent = parsedContent;

  /// 从数据库Map创建Message对象
  factory Message.fromMap(Map<String, dynamic> map, {String? myWxid}) {
    final localType = map['local_type'] ?? 0;
    final messageContent = _safeStringFromMap(map, 'message_content');

    // 步骤1：处理compress_content - 检查是否为blob格式
    String actualContent = '';
    final compressContentRaw = map['compress_content'];

    if (compressContentRaw is Uint8List) {
      // 是blob格式，需要解压
      actualContent = _decodeBinaryContent(compressContentRaw);
    } else if (compressContentRaw is String && compressContentRaw.isNotEmpty) {
      // 是字符串格式，直接使用
      actualContent = compressContentRaw;
    } else if (messageContent.isNotEmpty) {
      // compress_content为空，使用message_content
      actualContent = messageContent;
    }

    // 步骤2：根据localType解析内容
    final parsedContent = _parseMessageContent(
      actualContent,
      localType,
      messageContent,
      myWxid,
    );

    // 提取图片MD5（如果是图片消息）
    String? imageMd5;
    if (localType == 3 && actualContent.isNotEmpty) {
      imageMd5 = _extractImageMd5(actualContent);
    }

    // 提取拍一拍消息信息
    Map<String, dynamic>? patInfo;
    if (localType == 266287972401 && actualContent.isNotEmpty) {
      patInfo = XmlMessageParser.parsePatMessageInfo(actualContent);
    }

    return Message(
      localId: map['local_id'] ?? 0,
      serverId: map['server_id'] ?? 0,
      localType: localType,
      sortSeq: map['sort_seq'] ?? 0,
      realSenderId: map['real_sender_id'] ?? 0,
      createTime: map['create_time'] ?? 0,
      status: map['status'] ?? 0,
      uploadStatus: map['upload_status'] ?? 0,
      downloadStatus: map['download_status'] ?? 0,
      serverSeq: map['server_seq'] ?? 0,
      originSource: map['origin_source'] ?? 0,
      source: _safeStringFromMap(map, 'source'),
      messageContent: messageContent,
      compressContent: actualContent, // 存储解压后的内容
      packedInfoData: map['packed_info_data'] != null
          ? (map['packed_info_data'] is Uint8List
                ? map['packed_info_data'].cast<int>()
                : List<int>.from(map['packed_info_data']))
          : [],
      isSend: _readIsSend(map),
      senderUsername: _safeStringFromMap(map, 'sender_username').isEmpty
          ? null
          : _safeStringFromMap(map, 'sender_username'),
      imageMd5: imageMd5,
      myWxid: myWxid,
      patInfo: patInfo,
      parsedContent: parsedContent,
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
    String? myWxid,
  ) {
    // 调试输出 - 特别关注74614
    final isTargetMessage =
        kDebugMode && (localType == 244813135921 || content.length > 10000);
    if (isTargetMessage) {}

    // 首先进行URL解码，处理&amp;、&lt;、&gt;等编码
    String decodedContent = _decodeHtmlEntities(content);

    if (isTargetMessage) {}

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

        // 普通文本消息，移除wxid前缀
        final wxidPattern = RegExp(r'^wxid_[a-zA-Z0-9]+:\s*');
        return textContent.replaceFirst(wxidPattern, '');

      case 3: // 图片消息
        return '[图片]';

      case 34: // 语音消息
        final duration = _extractDurationFromXml(decodedContent, 'voicelength');
        return duration.isNotEmpty ? '[语音 ${duration}秒]' : '[语音消息]';

      case 42: // 名片消息
        final nickname = _extractValueFromXml(decodedContent, 'nickname');
        return nickname.isNotEmpty ? '[名片] $nickname' : '[名片]';

      case 43: // 视频消息
        final duration = _extractDurationFromXml(decodedContent, 'playlength');
        return duration.isNotEmpty ? '[视频 ${duration}秒]' : '[视频消息]';

      case 47: // 动画表情
        return '[动画表情]';

      case 48: // 位置消息
        final location = _extractValueFromXml(decodedContent, 'label');
        return location.isNotEmpty ? '[位置] $location' : '[位置消息]';

      case 10000: // 系统消息
        if (decodedContent.contains('revokemsg')) {
          // 处理撤回消息
          return _parseRevokeMessage(decodedContent, myWxid);
        }
        return decodedContent.isNotEmpty ? decodedContent : '[系统消息]';

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
      // 移除可能的wxid前缀
      final wxidPattern = RegExp(r'^wxid_[a-zA-Z0-9]+:\s*');
      final cleanContent = decodedContent.replaceFirst(wxidPattern, '');
      final result = cleanContent.isNotEmpty
          ? cleanContent
          : '[未知消息类型($localType)]';
      return _checkParseResult(result, localType, '非XML内容处理');
    }

    return '[未知消息类型($localType)]';
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
      final pattern = RegExp(
        '$attributeName["\s]*=["\s]*(\\d+)',
        caseSensitive: false,
      );
      final match = pattern.firstMatch(xml);
      return match?.group(1) ?? '';
    } catch (e) {
      return '';
    }
  }

  /// 解析撤回消息
  static String _parseRevokeMessage(String xml, String? myWxid) {
    try {
      return XmlMessageParser.parseRevokeMessage(xml, myWxid, null, null) ??
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
        r'md5\s*=\s*["\047]([a-fA-F0-9]+)["\047]',
        caseSensitive: false,
      );
      final match = pattern.firstMatch(xml);
      return match?.group(1);
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
            // zstd解压失败
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

  /// 获取消息类型描述
  String get typeDescription {
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
      default:
        return '未知消息类型($localType)';
    }
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

  /// 是否为压缩内容
  bool get isCompressed => compressContent.isNotEmpty;

  /// 是否为图片消息（暂时禁用图片显示，改为文本）
  bool get hasImage => false;

  /// 获取显示内容 - 直接返回解析后的内容
  String get displayContent {
    // 强制修复包含XML的长消息
    if (_parsedContent.contains('<') && _parsedContent.length > 50) {
      return '[不支持的消息类型]';
    }

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

        // 只显示简短的纯文本引用内容，过滤XML和过长内容
        if (referredContent.isNotEmpty &&
            referredContent.length < 200 &&
            !referredContent.contains('<')) {
          return displayName.isNotEmpty
              ? '$displayName: $referredContent'
              : referredContent;
        }
      }
    } catch (e) {
      // 解析失败时静默处理
    }

    return '';
  }

  @override
  String toString() {
    return 'Message{localId: $localId, localType: $localType, createTime: $formattedCreateTime, content: $displayContent}';
  }
}
