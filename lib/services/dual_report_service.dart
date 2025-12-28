import 'dart:isolate';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database_service.dart';
import '../models/contact_record.dart';
import '../models/contact.dart';

typedef DualReportProgressCallback =
    Future<void> Function(String taskName, String status, int progress);

@pragma('vm:entry-point')
void dualReportIsolateEntry(Map<String, dynamic> message) async {
  final sendPort = message['sendPort'] as SendPort;
  DatabaseService? databaseService;
  try {
    final dbPath = message['dbPath'] as String?;
    final friendUsername = message['friendUsername'] as String?;
    final filterYear = message['filterYear'] as int?;
    final manualWxid = message['manualWxid'] as String?;
    if (dbPath == null || dbPath.isEmpty || friendUsername == null) {
      throw StateError('invalid isolate params');
    }

    databaseService = DatabaseService();
    await databaseService.initialize(factory: databaseFactoryFfi);
    if (manualWxid != null && manualWxid.isNotEmpty) {
      databaseService.setManualWxid(manualWxid);
    }
    await databaseService.connectDecryptedDatabase(
      dbPath,
      factory: databaseFactoryFfi,
    );

    final service = DualReportService(databaseService);
    final reportData = await service.generateDualReport(
      friendUsername: friendUsername,
      filterYear: filterYear,
      onProgress: (taskName, status, progress) async {
        sendPort.send({
          'type': 'progress',
          'taskName': taskName,
          'status': status,
          'progress': progress,
        });
      },
    );

    sendPort.send({'type': 'done', 'data': reportData});
  } catch (e) {
    sendPort.send({'type': 'error', 'message': e.toString()});
  } finally {
    try {
      await databaseService?.close();
    } catch (_) {}
  }
}

/// 双人报告数据服务
class DualReportService {
  final DatabaseService _databaseService;

  DualReportService(this._databaseService);

  Future<void> _reportProgress(
    DualReportProgressCallback? onProgress,
    String taskName,
    String status,
    int progress,
  ) async {
    if (onProgress == null) return;
    await onProgress(taskName, status, progress);
  }

  /// 生成双人报告数据
  Future<Map<String, dynamic>> generateDualReportData({
    required String friendUsername,
    required String friendName,
    required String myName,
    int? year,
    DualReportProgressCallback? onProgress,
  }) async {
    await _reportProgress(onProgress, '准备双人报告数据', '处理中', 35);
    // 获取第一次聊天信息
    await _reportProgress(onProgress, '获取首次聊天记录', '处理中', 45);
    final firstChat = await _getFirstChatInfo(friendUsername);
    await _reportProgress(onProgress, '获取首次聊天记录', '已完成', 52);

    // 获取今年第一次聊天信息
    await _reportProgress(onProgress, '获取今年首次聊天', '处理中', 60);
    final thisYearFirstChat = await _getThisYearFirstChatInfo(
      friendUsername,
      friendName,
      year ?? DateTime.now().year,
    );
    await _reportProgress(onProgress, '获取今年首次聊天', '已完成', 68);

    // 获取我的微信显示名称
    await _reportProgress(onProgress, '获取我的显示名', '处理中', 75);
    final myDisplayName = await _getMyDisplayName(myName);
    await _reportProgress(onProgress, '获取我的显示名', '已完成', 80);

    // 获取年度统计数据
    final actualYear = year ?? DateTime.now().year;
    await _reportProgress(onProgress, '统计年度聊天数据', '处理中', 85);
    final yearlyStats =
        Map<String, dynamic>.from(await _getYearlyStats(friendUsername, actualYear));
    final topEmoji = await _databaseService.getSessionYearlyTopEmojiMd5(
      friendUsername,
      actualYear,
    );
    yearlyStats['myTopEmojiMd5'] = topEmoji['myTopEmojiMd5'];
    yearlyStats['friendTopEmojiMd5'] = topEmoji['friendTopEmojiMd5'];
    yearlyStats['myTopEmojiUrl'] = topEmoji['myTopEmojiUrl'];
    yearlyStats['friendTopEmojiUrl'] = topEmoji['friendTopEmojiUrl'];
    yearlyStats['myEmojiRankings'] = topEmoji['myEmojiRankings'];
    yearlyStats['friendEmojiRankings'] = topEmoji['friendEmojiRankings'];
    await _reportProgress(onProgress, '统计年度聊天数据', '已完成', 92);

    final reportData = {
      'myName': myDisplayName,
      'friendUsername': friendUsername,
      'friendName': friendName,
      'year': year,
      'firstChat': firstChat,
      'thisYearFirstChat': thisYearFirstChat,
      'yearlyStats': yearlyStats,
    };
    await _reportProgress(onProgress, '整理报告数据', '已完成', 100);
    return reportData;
  }

  /// 获取我的微信显示名称
  Future<String> _getMyDisplayName(String myWxid) async {
    try {
      // 检查myWxid是否为空
      if (myWxid.isEmpty) {
        return myWxid;
      }

      // 从 contact 数据库获取所有联系人，找到自己的记录
      final contacts = await _databaseService.getAllContacts();

      // 构建username到ContactRecord的映射，提高查找效率
      final contactMap = <String, ContactRecord>{};
      for (final contactRecord in contacts) {
        final username = contactRecord.contact.username;
        if (username.isNotEmpty) {
          contactMap[username] = contactRecord;
        }
      }

      // 精确查找联系人
      ContactRecord myContactRecord;
      if (contactMap.containsKey(myWxid)) {
        myContactRecord = contactMap[myWxid]!;
      } else {
        // 找不到精确匹配，创建默认ContactRecord
        myContactRecord = ContactRecord(
          contact: Contact(
            id: 0,
            username: myWxid,
            localType: 0,
            alias: '',
            encryptUsername: '',
            flag: 0,
            deleteFlag: 0,
            verifyFlag: 0,
            remark: '',
            remarkQuanPin: '',
            remarkPinYinInitial: '',
            nickName: '',
            pinYinInitial: '',
            quanPin: '',
            bigHeadUrl: '',
            smallHeadUrl: '',
            headImgMd5: '',
            chatRoomNotify: 0,
            isInChatRoom: 0,
            description: '',
            extraBuffer: [],
            chatRoomType: 0,
          ),
          source: ContactRecognitionSource.friend,
          origin: ContactDataOrigin.unknown,
        );
      }

      // 使用 Contact 的 displayName getter（已处理 remark/nickName/alias 优先级）
      return myContactRecord.contact.displayName;
    } catch (e) {
      return myWxid;
    }
  }

  /// 获取第一次聊天信息
  Future<Map<String, dynamic>?> _getFirstChatInfo(String username) async {
    try {
      // 使用 SQL 快速获取最早消息，避免加载全部历史
      final now = DateTime.now();
      final startTimestamp = 0; // 1970年1月1日
      final endTimestamp = now.millisecondsSinceEpoch ~/ 1000; // 当前时间

      final allMessages = await _databaseService.getEarliestMessages(
        username,
        startTimestamp,
        endTimestamp,
        1,
      );

      if (allMessages.isEmpty) {
        return null;
      }

      final firstMessage = allMessages.first;
      // createTime 是秒级时间戳，需要转换为毫秒
      final createTimeMs = firstMessage.createTime * 1000;

      return {
        'createTime': createTimeMs,  // 毫秒时间戳
        'createTimeStr': _formatDateTime(createTimeMs), // 格式化的时间字符串
        'content': firstMessage.displayContent,
        'isSentByMe': firstMessage.isSend == 1,
        'senderUsername': firstMessage.senderUsername,
      };
    } catch (e) {
      return null;
    }
  }

  /// 获取今年第一次聊天信息（包括前三句对话）
  Future<Map<String, dynamic>?> _getThisYearFirstChatInfo(
    String username,
    String friendName,
    int year,
  ) async {
    try {
      // 定义今年的时间范围
      final startOfYear = DateTime(year, 1, 1);
      final endOfYear = DateTime(year, 12, 31, 23, 59, 59);

      final startTimestamp = startOfYear.millisecondsSinceEpoch ~/ 1000;
      final endTimestamp = endOfYear.millisecondsSinceEpoch ~/ 1000;

      final thisYearMessages = await _databaseService.getEarliestMessages(
        username,
        startTimestamp,
        endTimestamp,
        3,
      );

      if (thisYearMessages.isEmpty) {
        return null;
      }

      final firstMessage = thisYearMessages.first;
      final createTimeMs = firstMessage.createTime * 1000; // 转换为毫秒

      // 获取前三条消息（包含时间）
      final firstThreeMessages = thisYearMessages.take(3).map((msg) {
        final msgTimeMs = msg.createTime * 1000;
        return {
          'content': msg.displayContent,
          'isSentByMe': msg.isSend == 1,
          'createTime': msg.createTime,
          'createTimeStr': _formatDateTime(msgTimeMs),
        };
      }).toList();

      return {
        'createTime': createTimeMs,
        'createTimeStr': _formatDateTime(createTimeMs),
        'content': firstMessage.displayContent,
        'isSentByMe': firstMessage.isSend == 1,
        'friendName': friendName,
        'firstThreeMessages': firstThreeMessages,
      };
    } catch (e) {
      return null;
    }
  }

  /// 格式化时间（显示日期和时间）
  String _formatDateTime(int millisecondsSinceEpoch) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$month/$day $hour:$minute';
  }

  /// 获取年度统计数据
  Future<Map<String, dynamic>> _getYearlyStats(
    String username,
    int year,
  ) async {
    try {
      return await _databaseService.getSessionYearlyStats(username, year);
    } catch (e) {
      return {
        'totalMessages': 0,
        'totalWords': 0,
        'imageCount': 0,
        'voiceCount': 0,
        'emojiCount': 0,
      };
    }
  }

  /// 生成完整的双人报告（外部接口）
  Future<Map<String, dynamic>> generateDualReport({
    required String friendUsername,
    int? filterYear,
    DualReportProgressCallback? onProgress,
  }) async {
    try {
      await _reportProgress(onProgress, '准备双人报告', '处理中', 20);
      // 获取当前用户wxid
      final myWxid = _databaseService.currentAccountWxid;
      if (myWxid == null || myWxid.isEmpty) {
        throw Exception('无法获取当前用户信息');
      }

      // 检查friendUsername是否为空
      if (friendUsername.isEmpty) {
        throw Exception('好友用户名不能为空');
      }

      // 获取好友显示名称
      await _reportProgress(onProgress, '读取好友信息', '处理中', 28);
      final contacts = await _databaseService.getAllContacts();

      // 构建username到ContactRecord的映射，提高查找效率
      final contactMap = <String, ContactRecord>{};
      for (final contactRecord in contacts) {
        final username = contactRecord.contact.username;
        if (username.isNotEmpty) {
          contactMap[username] = contactRecord;
        }
      }

      // 精确查找联系人
      ContactRecord friendContact;
      if (contactMap.containsKey(friendUsername)) {
        friendContact = contactMap[friendUsername]!;
      } else {
        // 找不到精确匹配，创建默认ContactRecord
        friendContact = ContactRecord(
          contact: Contact(
            id: 0,
            username: friendUsername,
            localType: 0,
            alias: '',
            encryptUsername: '',
            flag: 0,
            deleteFlag: 0,
            verifyFlag: 0,
            remark: '',
            remarkQuanPin: '',
            remarkPinYinInitial: '',
            nickName: '',
            pinYinInitial: '',
            quanPin: '',
            bigHeadUrl: '',
            smallHeadUrl: '',
            headImgMd5: '',
            chatRoomNotify: 0,
            isInChatRoom: 0,
            description: '',
            extraBuffer: [],
            chatRoomType: 0,
          ),
          source: ContactRecognitionSource.friend,
          origin: ContactDataOrigin.unknown,
        );
      }

      final friendName = friendContact.contact.displayName;
      await _reportProgress(onProgress, '读取好友信息', '已完成', 32);

      // 生成报告数据
      return await generateDualReportData(
        friendUsername: friendUsername,
        friendName: friendName,
        myName: myWxid,
        year: filterYear,
        onProgress: onProgress,
      );
    } catch (e) {
      rethrow;
    }
  }

  /// 获取推荐好友列表（按消息数量排序）
  Future<List<Map<String, dynamic>>> getRecommendedFriends({
    required int limit,
    int? filterYear,
  }) async {
    try {
      // 获取按消息数量排序的联系人数据
      final topContacts = await _databaseService.getTopContactsData(
        limit: limit,
        year: filterYear,
      );

      // 获取所有联系人信息以获取显示名称
      final allContacts = await _databaseService.getAllContacts();

      // 构建username到ContactRecord的映射，提高查找效率
      final contactMap = <String, ContactRecord>{};
      for (final contactRecord in allContacts) {
        final username = contactRecord.contact.username;
        if (username.isNotEmpty) {
          contactMap[username] = contactRecord;
        }
      }

      // 映射结果，添加显示名称
      final result = <Map<String, dynamic>>[];
      for (final contactData in topContacts) {
        final username = contactData['username'] as String? ?? '';

        String displayName;
        if (username.isEmpty) {
          // 空username，显示为"未知"
          displayName = '未知';
        } else {
          // 精确查找联系人
          final contactRecord = contactMap[username];
          if (contactRecord != null) {
            displayName = contactRecord.contact.displayName;
          } else {
            // 找不到精确匹配，使用username作为显示名称
            displayName = username;
          }
        }

        result.add({
          'username': username,
          'displayName': displayName,
          'messageCount': contactData['total'] as int? ?? 0,
        });
      }

      return result;
    } catch (e) {
      rethrow;
    }
  }
}
