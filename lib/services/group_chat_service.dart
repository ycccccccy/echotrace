import 'dart:core';
import 'package:intl/intl.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/message.dart';
import 'database_service.dart';

const Set<String> _chineseStopwords = {
  '的', '了', '我', '你', '他', '她', '它', '们', '是', '在', '也', '有', '就',
  '不', '都', '而', '及', '与', '且', '或', '个', '这', '那', '一', '!',
  '，', '。', '？', '、', '：', '；', '“', '”', '‘', '’', '（', '）', '《', '》',
  '【', '】', ' ', '...', '..', '.', ',', '?', '~', '～', '！',
  '啊', '哦', '嗯', '呢', '吧', '呀', '嘛', '哈', '嘿', '哼', '哎', '唉',
  '一个', '一些', '什么', '那个', '这个', '怎么', '我们', '你们', '他们',
  '然后', '但是', '所以', '因为', '知道', '觉得', '就是', '没有', '现在',
  '不是', '可以', '这么', '那么', '还有', '如果', '的话', '可能', '出来',
};

class GroupChatInfo {
  final String username;
  final String displayName;
  final int memberCount;
  GroupChatInfo({required this.username, required this.displayName, required this.memberCount});
}

class GroupMember {
  final String username;
  final String displayName;
  final String? avatarUrl;
  GroupMember({required this.username, required this.displayName, this.avatarUrl});
  Map<String, dynamic> toJson() => {'username': username, 'displayName': displayName, 'avatarUrl': avatarUrl};
}

class GroupMessageRank {
  final GroupMember member;
  final int messageCount;
  GroupMessageRank({required this.member, required this.messageCount});
}

class DailyMessageCount {
  final DateTime date;
  final int count;
  DailyMessageCount({required this.date, required this.count});
}

class GroupChatService {
  final DatabaseService _databaseService;
  
  GroupChatService(this._databaseService) {
    // 构造函数保持简单
  }

  // 将分词方法移到类级别
  List<String> _simpleTokenize(String text) {
    final words = <String>[];

    // 分离中英文
    final chinesePattern = RegExp(r'[\u4e00-\u9fa5]+');
    final englishPattern = RegExp(r'[a-zA-Z]+');

    // 提取中文词（双字组合）
    final chineseMatches = chinesePattern.allMatches(text);
    for (final match in chineseMatches) {
      final chinese = match.group(0)!;
      // 双字组合
      for (int i = 0; i < chinese.length - 1; i++) {
        words.add(chinese.substring(i, i + 2));
      }
    }

    // 提取英文词
    final englishMatches = englishPattern.allMatches(text);
    for (final match in englishMatches) {
      final word = match.group(0)!.toLowerCase();
      if (word.length >= 2) {
        words.add(word);
      }
    }

    return words;
  }

  // 确保方法只定义一次，并且所有路径都返回非null值
  Future<Map<String, int>> getMemberWordFrequency({
    required String chatroomId,
    required String memberUsername,
    required DateTime startDate,
    required DateTime endDate,
    int topN = 100,
  }) async {
    print('--- [词云] 开始分析词频 for $memberUsername ---');
    final endOfDay = DateTime(endDate.year, endDate.month, endDate.day, 23, 59, 59);
    
    try {
      // 获取消息
      final messages = await _databaseService.getMessagesByDate(
        chatroomId,
        startDate.millisecondsSinceEpoch ~/ 1000,
        endOfDay.millisecondsSinceEpoch ~/ 1000,
      );
      
      // 过滤并提取文本内容 - 使用displayContent而不是_parsedContent
      final textContent = messages
        .where((m) => 
            m.senderUsername == memberUsername &&
            (m.isTextMessage || m.localType == 244813135921) && // 使用isTextMessage属性
            m.displayContent.isNotEmpty && // 使用公开的displayContent属性
            !m.displayContent.startsWith('[') && // 排除[不支持的消息类型]等
            !m.displayContent.contains('tmp content') && // 排除临时内容
            !m.displayContent.contains('thumbwidth') && // 排除图片尺寸信息
            !m.displayContent.contains('cdnurl') && // 排除CDN链接
            !m.displayContent.contains('<msg>') && // 排除XML内容
            m.displayContent.length > 1 // 确保有足够内容
        )
        .map((m) => m.displayContent) // 使用displayContent
        .join(' ');
  
      // 检查文本是否为空
      if (textContent.isEmpty) {
        print('[词云] 未找到有效文本内容');
        return {}; // 返回空Map而不是null
      }
  
      // 使用自定义分词方法
      final List<String> segmentedWords = _simpleTokenize(textContent);
      
      // 过滤无效词
      final filteredWords = segmentedWords.where((word) {
        final trimmed = word.trim();
        return trimmed.length >= 2 && 
               !_chineseStopwords.contains(trimmed) && 
               double.tryParse(trimmed) == null &&
               !trimmed.contains('tmp') &&
               !trimmed.contains('content') &&
               !trimmed.contains('thumb') &&
               !trimmed.contains('width');
      }).toList();
  
      // 检查过滤后是否有有效词
      if (filteredWords.isEmpty) {
        print('[词云] 过滤后无有效词汇');
        return {}; // 返回空Map而不是null
      }
  
      // 统计词频
      final wordCounts = <String, int>{};
      for (final word in filteredWords) {
        wordCounts[word] = (wordCounts[word] ?? 0) + 1;
      }
  
      // 排序并取前N个
      final sortedEntries = wordCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final topEntries = sortedEntries.take(topN);
  
      print('[词云] 分析完成，有效高频词数量：${topEntries.length}');
      return Map.fromEntries(topEntries);
    } catch (e) {
      // 错误处理，确保即使出错也返回非null值
      print('[词云] 分析词频时出错: $e');
      return {};
    }
  }

  Future<List<GroupChatInfo>> getGroupChats() async {
    final sessions = await _databaseService.getSessions();
    final groupSessions = sessions.where((s) => s.isGroup).toList();
    final List<GroupChatInfo> result = [];
    final displayNames = await _databaseService.getDisplayNames(groupSessions.map((s) => s.username).toList());
    for (final session in groupSessions) {
      final memberCount = await _getGroupMemberCount(session.username);
      result.add(GroupChatInfo(
        username: session.username,
        displayName: displayNames[session.username] ?? session.username,
        memberCount: memberCount,
      ));
    }
    result.sort((a, b) => b.memberCount.compareTo(a.memberCount));
    return result;
  }

  Future<int> _getGroupMemberCount(String chatroomId) async {
    try {
      final contactDbPath = await _databaseService.getContactDatabasePath();
      if (contactDbPath == null) return 0;
      final db = await databaseFactoryFfi.openDatabase(contactDbPath, options: OpenDatabaseOptions(readOnly: true));
      try {
        final result = await db.rawQuery(
          '''
          SELECT COUNT(*) as count FROM chatroom_member 
          WHERE room_id = (SELECT rowid FROM name2id WHERE username = ?)
          ''',
          [chatroomId],
        );
        return (result.first['count'] as int?) ?? 0;
      } finally {
        await db.close();
      }
    } catch (e) {
      return 0;
    }
  }

  Future<List<GroupMember>> getGroupMembers(String chatroomId) async {
    final List<GroupMember> members = [];
    try {
      final contactDbPath = await _databaseService.getContactDatabasePath();
      if (contactDbPath == null) return [];

      final db = await databaseFactoryFfi.openDatabase(contactDbPath,
          options: OpenDatabaseOptions(readOnly: true));
      
      try {
        final memberRows = await db.rawQuery(
          '''
          SELECT n.username, c.small_head_url FROM chatroom_member m
          JOIN name2id n ON m.member_id = n.rowid
          LEFT JOIN contact c ON n.username = c.username
          WHERE m.room_id = (SELECT rowid FROM name2id WHERE username = ?)
          ''',
          [chatroomId],
        );

        if (memberRows.isEmpty) return [];
        
        final usernames = memberRows
          .where((row) => row['username'] != null)
          .map((row) => row['username'] as String)
          .toList();
        
        final displayNames = await _databaseService.getDisplayNames(usernames);

        final avatarMap = {
          for (var row in memberRows) 
            if (row['username'] != null) 
              row['username'] as String: row['small_head_url'] as String?
        };

        for (final username in usernames) {
           members.add(GroupMember(
             username: username, 
             displayName: displayNames[username] ?? username,
             avatarUrl: avatarMap[username],
           ));
        }
      } finally {
        await db.close();
      }
    } catch (e) {
      print('[调试] 获取群成员列表错误: $e');
    }
    return members;
  }

  Future<List<GroupMessageRank>> getGroupMessageRanking({
    required String chatroomId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final endOfDay = DateTime(endDate.year, endDate.month, endDate.day, 23, 59, 59);
    final messages = await _databaseService.getMessagesByDate(
        chatroomId, startDate.millisecondsSinceEpoch ~/ 1000, endOfDay.millisecondsSinceEpoch ~/ 1000);
    final Map<String, int> messageCounts = {};
    final Set<String> senderUsernames = {};
    for (final Message message in messages) {
      if (message.senderUsername != null && message.senderUsername!.isNotEmpty) {
        final username = message.senderUsername!;
        messageCounts[username] = (messageCounts[username] ?? 0) + 1;
        senderUsernames.add(username);
      }
    }
    if (senderUsernames.isEmpty) return [];

    final allMembers = await getGroupMembers(chatroomId);
    final memberMap = {for (var m in allMembers) m.username: m};

    final List<GroupMessageRank> ranking = [];
    messageCounts.forEach((username, count) {
      final member = memberMap[username] ?? GroupMember(username: username, displayName: username);
      ranking.add(GroupMessageRank(member: member, messageCount: count));
    });
    ranking.sort((a, b) => b.messageCount.compareTo(a.messageCount));
    return ranking;
  }
  
  Future<List<DailyMessageCount>> getMemberDailyMessageCount({
    required String chatroomId,
    required String memberUsername,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final endOfDay = DateTime(endDate.year, endDate.month, endDate.day, 23, 59, 59);
    final messages = await _databaseService.getMessagesByDate(
      chatroomId, startDate.millisecondsSinceEpoch ~/ 1000, endOfDay.millisecondsSinceEpoch ~/ 1000);
    final memberMessages = messages.where((m) => m.senderUsername == memberUsername);
    final Map<String, int> dailyCounts = {};
    final dateFormat = DateFormat('yyyy-MM-dd');
    for (final message in memberMessages) {
       final dateStr = dateFormat.format(DateTime.fromMillisecondsSinceEpoch(message.createTime * 1000));
       dailyCounts[dateStr] = (dailyCounts[dateStr] ?? 0) + 1;
    }
    final result = dailyCounts.entries.map((entry) {
        return DailyMessageCount(date: DateTime.parse(entry.key), count: entry.value);
    }).toList();
    result.sort((a,b) => a.date.compareTo(b.date));
    return result;
  }
}