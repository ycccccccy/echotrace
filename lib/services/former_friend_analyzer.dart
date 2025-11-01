import 'database_service.dart';

/// 曾经的好朋友分析结果
class FormerFriendResult {
  final String username;
  final String displayName;
  final DateTime activeStartDate; // 活跃期开始日期
  final DateTime activeEndDate; // 活跃期结束日期
  final int activeDays; // 活跃期天数
  final int activeDaysCount; // 活跃期内有聊天的天数
  final int activeMessageCount; // 活跃期内的消息总数
  final DateTime? lastMessageDate; // 最后一条消息的日期
  final int daysSinceActive; // 距离活跃期结束的天数
  final int messagesAfterActive; // 活跃期后的消息数
  final double afterFrequency; // 活跃期后的聊天频率（消息数/天）

  FormerFriendResult({
    required this.username,
    required this.displayName,
    required this.activeStartDate,
    required this.activeEndDate,
    required this.activeDays,
    required this.activeDaysCount,
    required this.activeMessageCount,
    this.lastMessageDate,
    required this.daysSinceActive,
    required this.messagesAfterActive,
    required this.afterFrequency,
  });

  Map<String, dynamic> toJson() => {
    'username': username,
    'displayName': displayName,
    'activeStartDate': activeStartDate.toIso8601String(),
    'activeEndDate': activeEndDate.toIso8601String(),
    'activeDays': activeDays,
    'activeDaysCount': activeDaysCount,
    'activeMessageCount': activeMessageCount,
    'lastMessageDate': lastMessageDate?.toIso8601String(),
    'daysSinceActive': daysSinceActive,
    'messagesAfterActive': messagesAfterActive,
    'afterFrequency': afterFrequency,
  };

  factory FormerFriendResult.fromJson(Map<String, dynamic> json) {
    return FormerFriendResult(
      username: json['username'] as String,
      displayName: json['displayName'] as String,
      activeStartDate: DateTime.parse(json['activeStartDate'] as String),
      activeEndDate: DateTime.parse(json['activeEndDate'] as String),
      activeDays: json['activeDays'] as int,
      activeDaysCount: json['activeDaysCount'] as int,
      activeMessageCount: json['activeMessageCount'] as int,
      lastMessageDate: json['lastMessageDate'] != null
          ? DateTime.parse(json['lastMessageDate'] as String)
          : null,
      daysSinceActive: json['daysSinceActive'] as int,
      messagesAfterActive: json['messagesAfterActive'] as int,
      afterFrequency: (json['afterFrequency'] as num).toDouble(),
    );
  }
}

/// 曾经的好朋友分析器
class FormerFriendAnalyzer {
  final DatabaseService _databaseService;
  int? _filterYear;

  FormerFriendAnalyzer(this._databaseService);

  void setYearFilter(int? year) {
    _filterYear = year;
  }

  /// 查找数据库中最新的消息日期（直接查询MAX(create_time)）
  Future<DateTime?> _findLatestMessageDate() async {
    return await _databaseService.getLatestMessageDate();
  }

  /// 分析曾经的好朋友
  /// [onProgress] 进度回调 (current, total, currentUsername)
  /// [onLog] 日志回调 (message, level)
  ///
  /// 返回值包含：
  /// - results: 符合条件的曾经的好朋友列表（只返回连续天数最多的那个人）
  /// - stats: 统计信息 {totalSessions, sessionsWithMessages, sessionsUnder14Days}
  Future<Map<String, dynamic>> analyzeFormerFriends({
    Function(int current, int total, String currentUser)? onProgress,
    Function(String message, {String level})? onLog,
  }) async {
    onProgress?.call(0, 1, '正在分析曾经的好朋友...');
    onLog?.call('========== 开始分析曾经的好朋友 ==========', level: 'debug');

    // 1. 首先找到数据库中最新的消息日期
    final latestMessageDate = await _findLatestMessageDate();
    if (latestMessageDate == null) {
      onLog?.call('未找到任何消息记录', level: 'warning');
      return {
        'results': <FormerFriendResult>[],
        'stats': {
          'totalSessions': 0,
          'sessionsWithMessages': 0,
          'sessionsUnder14Days': 0,
        },
      };
    }

    onLog?.call(
      '数据库最新消息日期: ${latestMessageDate.toString().split(' ')[0]}',
      level: 'info',
    );

    // 定义"近期"为最新消息日期往前30天
    final recentPeriodStart = latestMessageDate.subtract(
      const Duration(days: 30),
    );
    onLog?.call(
      '近期定义: ${recentPeriodStart.toString().split(' ')[0]} 至 ${latestMessageDate.toString().split(' ')[0]}',
      level: 'info',
    );

    // 2. 获取所有私聊会话
    final sessions = await _databaseService.getSessions();
    final privateSessions = sessions.where((s) => !s.isGroup).toList();

    onLog?.call('找到 ${privateSessions.length} 个私聊会话', level: 'info');

    final displayNames = await _databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );

    // 统计信息
    int totalSessions = privateSessions.length;
    int sessionsWithMessages = 0;
    int sessionsUnder14Days = 0;

    // 用于存储每个人的最长连续聊天期
    FormerFriendResult? bestCandidate;
    int maxConsecutiveDays = 0;

    for (int i = 0; i < privateSessions.length; i++) {
      final session = privateSessions[i];
      final displayName = displayNames[session.username] ?? session.username;

      onProgress?.call(i + 1, privateSessions.length, displayName);

      try {
        // 获取该会话的所有消息日期
        final messagesByDate = await _databaseService.getSessionMessagesByDate(
          session.username,
          filterYear: _filterYear,
        );

        if (messagesByDate.isEmpty) {
          continue;
        }

        sessionsWithMessages++;

        // 按日期排序
        final sortedDates = messagesByDate.keys.toList()..sort();

        if (sortedDates.length < 14) {
          sessionsUnder14Days++;
          continue;
        }

        // 查找最长的连续聊天期（间隔不超过3天）
        final longestPeriod = _findLongestConsecutivePeriod(
          sortedDates,
          messagesByDate,
        );

        if (longestPeriod == null || longestPeriod['consecutiveDays'] < 14) {
          continue;
        }

        final consecutiveDays = longestPeriod['consecutiveDays'] as int;
        final activeStartDate = DateTime.parse(
          longestPeriod['startDate'] as String,
        );
        final activeEndDate = DateTime.parse(
          longestPeriod['endDate'] as String,
        );

        // 检查是否近期还在频繁聊天
        // 计算近期（最新消息日期往前30天）的消息数量
        final recentMessages = sortedDates.where((date) {
          final d = DateTime.parse(date);
          return d.isAfter(recentPeriodStart) &&
              d.isBefore(latestMessageDate.add(const Duration(days: 1)));
        }).toList();

        int recentMessageCount = 0;
        for (final date in recentMessages) {
          recentMessageCount += messagesByDate[date]!['count'] as int;
        }

        final recentDays = latestMessageDate
            .difference(recentPeriodStart)
            .inDays;
        final recentFrequency = recentDays > 0
            ? recentMessageCount / recentDays
            : 0.0;

        // 如果近期频率还很高（比如 > 5条/天），则不算"曾经的好朋友"
        if (recentFrequency > 5.0) {
          onLog?.call(
            '✗ $displayName 近期频率过高 (${recentFrequency.toStringAsFixed(2)}条/天)，跳过',
            level: 'debug',
          );
          continue;
        }

        // 如果这个人的连续天数更多，更新最佳候选人
        if (consecutiveDays > maxConsecutiveDays) {
          maxConsecutiveDays = consecutiveDays;

          // 计算活跃期的统计数据
          final activeDays =
              activeEndDate.difference(activeStartDate).inDays + 1;
          final activeDaysCount = longestPeriod['daysCount'] as int;
          final activeMessageCount = longestPeriod['messageCount'] as int;

          // 计算活跃期后的统计数据
          final afterDates = sortedDates.where((date) {
            final d = DateTime.parse(date);
            return d.isAfter(activeEndDate);
          }).toList();

          final lastMessageDate = sortedDates.isNotEmpty
              ? DateTime.parse(sortedDates.last)
              : null;
          final daysSinceActive = lastMessageDate != null
              ? lastMessageDate.difference(activeEndDate).inDays
              : latestMessageDate.difference(activeEndDate).inDays;

          int messagesAfterActive = 0;
          for (final date in afterDates) {
            messagesAfterActive += messagesByDate[date]!['count'] as int;
          }

          final afterFrequency = daysSinceActive > 0
              ? messagesAfterActive / daysSinceActive
              : 0.0;

          bestCandidate = FormerFriendResult(
            username: session.username,
            displayName: displayName,
            activeStartDate: activeStartDate,
            activeEndDate: activeEndDate,
            activeDays: activeDays,
            activeDaysCount: activeDaysCount,
            activeMessageCount: activeMessageCount,
            lastMessageDate: lastMessageDate,
            daysSinceActive: daysSinceActive,
            messagesAfterActive: messagesAfterActive,
            afterFrequency: afterFrequency,
          );

          onLog?.call(
            '新的最佳候选: $displayName, 连续聊天$consecutiveDays天, 近期频率${recentFrequency.toStringAsFixed(2)}条/天',
            level: 'info',
          );
        }
      } catch (e) {
        onLog?.call('处理会话 $displayName 时出错: $e', level: 'warning');
      }
    }

    onLog?.call('========== 曾经的好朋友分析完成 ==========', level: 'info');
    onLog?.call('最长连续聊天: $maxConsecutiveDays 天', level: 'info');
    onLog?.call(
      '统计: 总会话=$totalSessions, 有消息=$sessionsWithMessages, 不足14天=$sessionsUnder14Days',
      level: 'info',
    );

    final results = bestCandidate != null
        ? [bestCandidate]
        : <FormerFriendResult>[];

    return {
      'results': results,
      'stats': {
        'totalSessions': totalSessions,
        'sessionsWithMessages': sessionsWithMessages,
        'sessionsUnder14Days': sessionsUnder14Days,
      },
    };
  }

  /// 查找最长的连续聊天期（间隔不超过3天）
  /// 返回最长连续期的详细信息
  Map<String, dynamic>? _findLongestConsecutivePeriod(
    List<String> sortedDates,
    Map<String, Map<String, dynamic>> messagesByDate,
  ) {
    if (sortedDates.isEmpty) return null;

    // 查找连续聊天的最长区间（间隔不超过3天）
    int maxConsecutiveDays = 0;
    int maxStartIndex = 0;
    int maxEndIndex = 0;

    int currentStart = 0;
    for (int i = 1; i < sortedDates.length; i++) {
      final prevDate = DateTime.parse(sortedDates[i - 1]);
      final currDate = DateTime.parse(sortedDates[i]);
      final daysDiff = currDate.difference(prevDate).inDays;

      // 如果间隔超过3天，认为是断开了
      if (daysDiff > 3) {
        // 计算当前区间的连续天数（从开始日期到结束日期的天数）
        final startDate = DateTime.parse(sortedDates[currentStart]);
        final endDate = DateTime.parse(sortedDates[i - 1]);
        final consecutiveDays = endDate.difference(startDate).inDays + 1;

        if (consecutiveDays > maxConsecutiveDays) {
          maxConsecutiveDays = consecutiveDays;
          maxStartIndex = currentStart;
          maxEndIndex = i - 1;
        }
        currentStart = i;
      }
    }

    // 检查最后一段
    final startDate = DateTime.parse(sortedDates[currentStart]);
    final endDate = DateTime.parse(sortedDates.last);
    final lastConsecutiveDays = endDate.difference(startDate).inDays + 1;

    if (lastConsecutiveDays > maxConsecutiveDays) {
      maxConsecutiveDays = lastConsecutiveDays;
      maxStartIndex = currentStart;
      maxEndIndex = sortedDates.length - 1;
    }

    // 计算这个区间的统计数据
    int daysCount = 0;
    int messageCount = 0;

    for (int i = maxStartIndex; i <= maxEndIndex; i++) {
      daysCount++;
      messageCount += messagesByDate[sortedDates[i]]!['count'] as int;
    }

    return {
      'startDate': sortedDates[maxStartIndex],
      'endDate': sortedDates[maxEndIndex],
      'consecutiveDays': maxConsecutiveDays,
      'daysCount': daysCount,
      'messageCount': messageCount,
    };
  }
}
