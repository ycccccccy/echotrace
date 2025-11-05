/// 联系人数据模型
class Contact {
  final int id;
  final String username;
  final int localType;
  final String alias;
  final String encryptUsername;
  final int flag;
  final int deleteFlag;
  final int verifyFlag;
  final String remark;
  final String remarkQuanPin;
  final String remarkPinYinInitial;
  final String nickName;
  final String pinYinInitial;
  final String quanPin;
  final String bigHeadUrl;
  final String smallHeadUrl;
  final String headImgMd5;
  final int chatRoomNotify;
  final int isInChatRoom;
  final String description;
  final List<int> extraBuffer;
  final int chatRoomType;
  final int type;
  final int chatroomFlag;

  Contact({
    required this.id,
    required this.username,
    required this.localType,
    required this.alias,
    required this.encryptUsername,
    required this.flag,
    required this.deleteFlag,
    required this.verifyFlag,
    required this.remark,
    required this.remarkQuanPin,
    required this.remarkPinYinInitial,
    required this.nickName,
    required this.pinYinInitial,
    required this.quanPin,
    required this.bigHeadUrl,
    required this.smallHeadUrl,
    required this.headImgMd5,
    required this.chatRoomNotify,
    required this.isInChatRoom,
    required this.description,
    required this.extraBuffer,
    required this.chatRoomType,
    this.type = 0,
    this.chatroomFlag = 0,
  });

  /// 从数据库Map创建Contact对象
  factory Contact.fromMap(Map<String, dynamic> map) {
    return Contact(
      id: map['id'] ?? 0,
      username: map['username'] ?? '',
      localType: map['local_type'] ?? 0,
      alias: map['alias'] ?? '',
      encryptUsername: map['encrypt_username'] ?? '',
      flag: map['flag'] ?? 0,
      deleteFlag: map['delete_flag'] ?? 0,
      verifyFlag: map['verify_flag'] ?? 0,
      remark: map['remark'] ?? '',
      remarkQuanPin: map['remark_quan_pin'] ?? '',
      remarkPinYinInitial: map['remark_pin_yin_initial'] ?? '',
      nickName: map['nick_name'] ?? '',
      pinYinInitial: map['pin_yin_initial'] ?? '',
      quanPin: map['quan_pin'] ?? '',
      bigHeadUrl: map['big_head_url'] ?? '',
      smallHeadUrl: map['small_head_url'] ?? '',
      headImgMd5: map['head_img_md5'] ?? '',
      chatRoomNotify: map['chat_room_notify'] ?? 0,
      isInChatRoom: map['is_in_chat_room'] ?? 0,
      description: map['description'] ?? '',
      extraBuffer: map['extra_buffer'] != null
          ? List<int>.from(map['extra_buffer'])
          : [],
      chatRoomType: map['chat_room_type'] ?? 0,
      type: map['type'] ?? 0,
      chatroomFlag: map['chatroom_flag'] ?? 0,
    );
  }

  /// 获取显示名称
  String get displayName {
    if (remark.isNotEmpty) {
      return remark;
    } else if (nickName.isNotEmpty) {
      return nickName;
    } else if (alias.isNotEmpty) {
      return alias;
    } else {
      return username;
    }
  }

  /// 获取联系人类型描述
  String get typeDescription {
    switch (localType) {
      case 0:
        return '普通联系人';
      case 1:
        return '群聊';
      case 2:
        return '公众号';
      case 3:
        return '企业微信联系人';
      default:
        return '未知类型($localType)';
    }
  }

  /// 是否为群聊
  bool get isGroup => localType == 1;

  /// 是否为公众号
  bool get isOfficialAccount => localType == 2;

  /// 是否具备好友标记（基于 type 字段）
  bool get hasFriendFlag {
    if (type == 0) return false;
    // 参考已知的 rcontact.type 位标志：
    // 0x1 -> 普通联系人，0x8 -> 已通过验证的好友/联系人
    // 0x200/0x400 -> 企业或双向好友扩展位
    return (type & 0x1) != 0 ||
        (type & 0x8) != 0 ||
        (type & 0x200) != 0 ||
        (type & 0x400) != 0;
  }

  /// 是否已删除
  bool get isDeleted => deleteFlag == 1;

  /// 是否已验证
  bool get isVerified => verifyFlag == 1;

  /// 获取头像URL
  String get avatarUrl {
    if (bigHeadUrl.isNotEmpty) {
      return bigHeadUrl;
    } else if (smallHeadUrl.isNotEmpty) {
      return smallHeadUrl;
    }
    return '';
  }

  /// 获取拼音首字母
  String get pinyinInitial {
    if (remarkPinYinInitial.isNotEmpty) {
      return remarkPinYinInitial;
    } else if (pinYinInitial.isNotEmpty) {
      return pinYinInitial;
    }
    return '';
  }

  @override
  String toString() {
    return 'Contact{id: $id, username: $username, displayName: $displayName, type: $typeDescription}';
  }
}
