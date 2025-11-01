import 'package:xml/xml.dart';

/// XML消息解析工具，处理微信消息中的特殊格式
class XmlMessageParser {
  /// 解析撤回消息
  static String? parseRevokeMessage(
    String xmlContent,
    String? myWxid,
    String? senderUsername,
    String? senderDisplayName,
  ) {
    try {
      // 根据消息发送者判断是谁撤回了消息
      if (senderUsername != null) {
        if (senderUsername == myWxid) {
          return '你撤回了一条消息';
        }
        return '"${senderDisplayName ?? senderUsername}" 撤回了一条消息';
      }

      return '撤回了一条消息';
    } catch (e) {
      return '[撤回消息]';
    }
  }

  /// 解析拍一拍消息，提取wxid列表
  static Map<String, dynamic>? parsePatMessageInfo(String xmlContent) {
    try {
      final document = XmlDocument.parse(xmlContent);
      final template = document.findAllElements('template').first.text;

      // 提取模板中的所有wxid
      final wxidRegex = RegExp(r'\$\{(wxid_[a-zA-Z0-9_]+)\}');
      final matches = wxidRegex.allMatches(template);
      final wxids = matches.map((m) => m.group(1)!).toSet().toList();

      return {'template': template, 'wxids': wxids};
    } catch (e) {
      return null;
    }
  }

  /// 渲染拍一拍消息（用真实姓名替换wxid）
  static String renderPatMessage(
    String template,
    Map<String, String> wxidToName,
  ) {
    var result = template;

    // 替换所有 ${wxid_xxx} 为真实姓名
    wxidToName.forEach((wxid, name) {
      result = result.replaceAll('\${$wxid}', name);
    });

    return result;
  }

  /// 解析引用消息
  static Map<String, String>? parseQuoteMessage(String xmlContent) {
    try {
      final document = XmlDocument.parse(xmlContent);
      final appmsg = document.findAllElements('appmsg').first;
      final refermsg = appmsg.findAllElements('refermsg').first;

      final displayname = refermsg.findElements('displayname').first.text;
      final content = refermsg.findElements('content').first.text;
      final type = refermsg.findElements('type').first.text;

      String displayContent = content;

      // 根据类型转换为更友好的提示
      switch (type) {
        case '1': // 文本
          displayContent = content;
          break;
        case '3': // 图片
          displayContent = '[图片]';
          break;
        case '47': // 动画表情
          displayContent = '[动画表情]';
          break;
        case '49': // 链接
          displayContent = '[链接] $content';
          break;
        default:
          displayContent = '[消息]';
      }

      return {'displayName': displayname, 'content': displayContent};
    } catch (e) {
      return null;
    }
  }
}
