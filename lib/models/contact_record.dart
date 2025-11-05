import 'contact.dart';

/// 联系人识别来源
enum ContactRecognitionSource {
  friend,
  chatroomParticipant,
  stranger,
  officialAccount,
  system,
}

/// 联系人数据来源表
enum ContactDataOrigin {
  contact,
  stranger,
  unknown,
}

extension ContactRecognitionSourceLabel on ContactRecognitionSource {
  String get label {
    switch (this) {
      case ContactRecognitionSource.friend:
        return '好友';
      case ContactRecognitionSource.chatroomParticipant:
        return '群聊成员';
      case ContactRecognitionSource.stranger:
        return '陌生人';
      case ContactRecognitionSource.officialAccount:
        return '公众号/服务号';
      case ContactRecognitionSource.system:
        return '系统账号';
    }
  }
}

extension ContactDataOriginLabel on ContactDataOrigin {
  String get label {
    switch (this) {
      case ContactDataOrigin.contact:
        return '联系人表';
      case ContactDataOrigin.stranger:
        return '陌生人表';
      case ContactDataOrigin.unknown:
        return '未知来源';
    }
  }
}

/// 带有识别信息的联系人记录
class ContactRecord {
  final Contact contact;
  final ContactRecognitionSource source;
  final ContactDataOrigin origin;

  ContactRecord({
    required this.contact,
    required this.source,
    required this.origin,
  });

  bool get isFriend => source == ContactRecognitionSource.friend;

  bool get isSystem => source == ContactRecognitionSource.system;

  String get friendLabel => isFriend ? '是' : '否';
}
