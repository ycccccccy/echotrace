import '../services/database_service.dart';
import '../services/advanced_analytics_service.dart';
import '../services/analytics_service.dart';

/// 双人报告生成服务
class DualReportService {
  final DatabaseService _databaseService;
  final AdvancedAnalyticsService _advancedAnalyticsService;
  final AnalyticsService _analyticsService;

  DualReportService(this._databaseService)
    : _advancedAnalyticsService = AdvancedAnalyticsService(_databaseService),
      _analyticsService = AnalyticsService(_databaseService);

  /// 生成完整的双人报告
  Future<Map<String, dynamic>> generateDualReport({
    required String friendUsername,
    int? filterYear,
  }) async {
    // 更新过滤年份
    _advancedAnalyticsService.setYearFilter(filterYear);

    // 获取好友显示名
    final displayNames = await _databaseService.getDisplayNames([
      friendUsername,
    ]);
    final friendDisplayName = displayNames[friendUsername] ?? friendUsername;

    // 1. 亲密度日历
    final intimacyCalendar = await _advancedAnalyticsService
        .generateIntimacyCalendar(friendUsername);

    // 2. 对话天平
    final conversationBalance = await _advancedAnalyticsService
        .analyzeConversationBalance(friendUsername);

    // 3. 最长连聊记录
    final longestStreakRaw = await _advancedAnalyticsService.findLongestStreak(
      friendUsername,
    );

    // 转换DateTime为字符串
    final longestStreak = {
      'days': longestStreakRaw['days'],
      'startDate': longestStreakRaw['startDate'] != null
          ? (longestStreakRaw['startDate'] as DateTime).toIso8601String()
          : null,
      'endDate': longestStreakRaw['endDate'] != null
          ? (longestStreakRaw['endDate'] as DateTime).toIso8601String()
          : null,
    };

    // 4. 基础统计
    final messageStats = await _databaseService.getSessionMessageStats(
      friendUsername,
      filterYear: filterYear,
    );

    // 5. 第一次聊天时间
    final allMessages = await _analyticsService.getAllMessagesForSession(
      friendUsername,
    );
    DateTime? firstChatTime;
    DateTime? lastChatTime;
    if (allMessages.isNotEmpty) {
      // 按时间排序
      final sorted = List.from(allMessages)
        ..sort((a, b) => a.createTime.compareTo(b.createTime));
      firstChatTime = DateTime.fromMillisecondsSinceEpoch(
        sorted.first.createTime * 1000,
      );
      lastChatTime = DateTime.fromMillisecondsSinceEpoch(
        sorted.last.createTime * 1000,
      );
    }

    // 6. 聊天活跃天数
    final messageDates = await _databaseService.getSessionMessageDates(
      friendUsername,
      filterYear: filterYear,
    );

    // 7. 消息类型分析（只针对这个好友）
    final messagesByDate = await _databaseService.getSessionMessagesByDate(
      friendUsername,
      filterYear: filterYear,
    );

    // 计算主动性（谁先发消息的天数）
    int initiatedByMe = 0;
    int initiatedByFriend = 0;
    for (final data in messagesByDate.values) {
      if (data['firstIsSend'] == true) {
        initiatedByMe++;
      } else {
        initiatedByFriend++;
      }
    }

    return {
      'friendUsername': friendUsername,
      'friendDisplayName': friendDisplayName,
      'filterYear': filterYear,

      // 基础数据
      'totalMessages': messageStats['total'],
      'sentMessages': messageStats['sent'],
      'receivedMessages': messageStats['received'],
      'activeDays': messageDates.length,
      'firstChatTime': firstChatTime?.toIso8601String(),
      'lastChatTime': lastChatTime?.toIso8601String(),

      // 主动性
      'initiatedByMe': initiatedByMe,
      'initiatedByFriend': initiatedByFriend,

      // 详细分析
      'intimacyCalendar': intimacyCalendar.toJson(),
      'conversationBalance': conversationBalance.toJson(),
      'longestStreak': longestStreak,
    };
  }

  /// 获取推荐的好友列表（聊天最多的前N位）
  Future<List<Map<String, dynamic>>> getRecommendedFriends({
    int limit = 20,
    int? filterYear,
  }) async {
    final sessions = await _databaseService.getSessions();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .toList();

    final friendStats = <Map<String, dynamic>>[];
    final displayNames = await _databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );

    for (final session in privateSessions) {
      try {
        final stats = await _databaseService.getSessionMessageStats(
          session.username,
          filterYear: filterYear,
        );
        final total = stats['total'] as int;

        if (total > 0) {
          friendStats.add({
            'username': session.username,
            'displayName': displayNames[session.username] ?? session.username,
            'messageCount': total,
            'avatarUrl': null, // 可以后续添加头像支持
          });
        }
      } catch (e) {
        // 跳过错误
      }
    }

    // 按消息数排序
    friendStats.sort(
      (a, b) => (b['messageCount'] as int).compareTo(a['messageCount'] as int),
    );

    return friendStats.take(limit).toList();
  }

  bool _isSystemAccount(String username) {
    final lower = username.toLowerCase();
    if (lower.contains('filehelper') ||
        lower.contains('fmessage') ||
        lower.contains('medianote') ||
        lower.contains('newsapp') ||
        lower.contains('weixin') ||
        lower.contains('gh_') ||
        lower.contains('brandsession') ||
        lower.contains('brandservice') ||
        lower.contains('placeholder') ||
        lower.contains('holder') ||
        lower.contains('_foldgroup') ||
        lower.contains('qqmail')) {
      return true;
    }
    if (RegExp(r'^\d+$').hasMatch(username)) {
      return true;
    }
    return false;
  }
}
