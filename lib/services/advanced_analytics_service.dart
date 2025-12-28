import '../models/message.dart';
import '../models/advanced_analytics_data.dart';
import 'database_service.dart';
import 'analytics_service.dart';

/// 高级分析服务
///
/// 核心分析维度：
///
/// 1. 年度挚友榜 - 总互动数排名
///    衡量指标：总消息数（我发+对方发）
///    含义：互动最频繁的关系
///    排序：总消息数 ↓
///
/// 2. 年度倾诉对象 - 倾诉指数排名（我话最多）
///    衡量指标：我的发送数 / 对方的发送数
///    含义：最想向TA倾诉的人，代表你对TA最信任最有话说
///    排序：发送比例 ↓（比值越大越靠前）
///    示例：如果某朋友是 我发100条：对方发50条，比例=2.0
///
/// 3. 年度最佳听众 - 倾听指数排名（TA话最多）
///    衡量指标：对方的发送数 / 我的发送数
///    含义：最无私的倾听者，代表TA最愿意向你分享
///    排序：接收比例 ↓（比值越大越靠前）
///    示例：如果某朋友是 对方发100条：我发50条，比例=2.0
///
/// 这三个维度形成了关系的完整画像：
/// - 挚友：互动总量高
/// - 倾诉对象：你主动倾诉
/// - 最佳听众：TA主动分享
///
/// 因此这三个排名通常会不同，避免了重复和重叠的问题。
class AdvancedAnalyticsService {
  final DatabaseService _databaseService;
  final AnalyticsService _analyticsService;

  int? _filterYear; // 年份过滤器，null表示显示全部年份

  // 系统账号和无效账号的黑名单，避免分析时包含无关数据
  static const _systemAccounts = {
    'filehelper',
    'fmessage',
    'medianote',
    'newsapp',
    'weixin',
    'gh_',
    'brandsessionholder',
    'brandservice',
    'brandsession',
    'placeholder',
    'qqmail',
    'tmessage',
  };

  AdvancedAnalyticsService(this._databaseService)
    : _analyticsService = AnalyticsService(_databaseService);

  /// 设置年份过滤器，用于限定分析的数据范围
  void setYearFilter(int? year) {
    _filterYear = year;
  }

  /// 根据年份过滤消息
  List<Message> _filterMessagesByYear(List<Message> messages) {
    if (_filterYear == null) return messages;

    return messages.where((msg) {
      final date = DateTime.fromMillisecondsSinceEpoch(msg.createTime * 1000);
      return date.year == _filterYear;
    }).toList();
  }

  /// 检查是否为系统账号或无效账号，避免纳入统计分析
  bool _isSystemAccount(String username) {
    if (username.isEmpty) return true;

    final lower = username.toLowerCase();

    // 检查是否在黑名单中
    for (final account in _systemAccounts) {
      if (lower.contains(account)) return true;
    }

    // 过滤纯数字账号
    if (RegExp(r'^\d+$').hasMatch(username)) return true;

    // 过滤包含特定关键词的异常账号
    if (lower.contains('holder') ||
        lower.contains('session') ||
        lower.contains('placeholder') ||
        lower.contains('_foldgroup')) {
      return true;
    }

    return false;
  }

  /// 分析作息规律（24小时×7天热力图）
  Future<ActivityHeatmap> analyzeActivityPattern() async {
    // 使用SQL直接统计，避免加载所有消息到内存
    final data = await _databaseService.getActivityHeatmapData(
      year: _filterYear,
    );

    // 计算最大值
    int maxCount = 0;
    for (final hourData in data.values) {
      for (final count in hourData.values) {
        if (count > maxCount) {
          maxCount = count;
        }
      }
    }

    return ActivityHeatmap(data: data, maxCount: maxCount);
  }

  /// 分析语言风格和表达习惯
  Future<LinguisticStyle> analyzeLinguisticStyle() async {
    final sessions = await _databaseService.getSessions();
    final myWxid = _databaseService.currentAccountWxid;
    final normalizedMyWxid = myWxid?.toLowerCase();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .where((s) {
          final username = s.username.toLowerCase();
          if (username == 'filehelper') return false;
          if (normalizedMyWxid != null &&
              normalizedMyWxid.isNotEmpty &&
              username == normalizedMyWxid) {
            return false;
          }
          return true;
        })
        .toList();

    int totalLength = 0;
    int messageCount = 0;
    final punctuationCount = <String, int>{};
    int revokedCount = 0;

    final punctuations = ['。', '！', '？', '，', '、', '；', '：', '…', '~'];

    for (final session in privateSessions) {
      try {
        final messages = await _analyticsService.getAllMessagesForSession(
          session.username,
        );

        for (final msg in messages) {
          // 统计撤回消息数量
          if (msg.localType == 10000 && msg.displayContent.contains('撤回')) {
            revokedCount++;
            continue;
          }

          // 只分析自己发送的文本消息，跳过接收的消息和其他类型
          if (msg.isSend != 1 || !msg.isTextMessage) continue;

          final content = msg.displayContent;
          if (content.isEmpty || content.startsWith('[')) continue;

          totalLength += content.length;
          messageCount++;

          // 统计标点符号使用情况
          for (final punct in punctuations) {
            final count = punct.allMatches(content).length;
            punctuationCount[punct] = (punctuationCount[punct] ?? 0) + count;
          }
        }
      } catch (e) {
        // 遇到错误时跳过这个会话，继续处理下一个
      }
    }

    final avgLength = messageCount > 0 ? totalLength / messageCount : 0.0;

    return LinguisticStyle(
      avgMessageLength: avgLength,
      punctuationUsage: punctuationCount,
      revokedMessageCount: revokedCount,
    );
  }

  /// 生成亲密度日历
  Future<IntimacyCalendar> generateIntimacyCalendar(String username) async {
    final allMessages = await _analyticsService.getAllMessagesForSession(
      username,
    );
    final messages = _filterMessagesByYear(allMessages);

    if (messages.isEmpty) {
      return IntimacyCalendar(
        username: username,
        dailyMessages: {},
        startDate: DateTime.now(),
        endDate: DateTime.now(),
        maxDailyCount: 0,
      );
    }

    final dailyMessages = <DateTime, int>{};
    DateTime? startDate;
    DateTime? endDate;
    int maxCount = 0;

    for (final msg in messages) {
      final time = DateTime.fromMillisecondsSinceEpoch(msg.createTime * 1000);
      final dateKey = DateTime(time.year, time.month, time.day);

      dailyMessages[dateKey] = (dailyMessages[dateKey] ?? 0) + 1;

      if (dailyMessages[dateKey]! > maxCount) {
        maxCount = dailyMessages[dateKey]!;
      }

      if (startDate == null || time.isBefore(startDate)) {
        startDate = dateKey;
      }
      if (endDate == null || time.isAfter(endDate)) {
        endDate = dateKey;
      }
    }

    return IntimacyCalendar(
      username: username,
      dailyMessages: dailyMessages,
      startDate: startDate ?? DateTime.now(),
      endDate: endDate ?? DateTime.now(),
      maxDailyCount: maxCount,
    );
  }

  /// 分析对话平衡性，包括消息数量、字数和主动发起情况
  Future<ConversationBalance> analyzeConversationBalance(
    String username,
  ) async {
    final allMessages = await _analyticsService.getAllMessagesForSession(
      username,
    );
    final messages = _filterMessagesByYear(allMessages);

    int sentCount = 0;
    int receivedCount = 0;
    int sentWords = 0;
    int receivedWords = 0;
    int conversationSegments = 0;
    int segmentsInitiatedByMe = 0;
    int segmentsInitiatedByOther = 0;

    Message? lastMsg;
    bool isNewSegment = true;

    // 按时间正序排列，确保对话段落判断正确
    final sortedMessages = List<Message>.from(messages);
    sortedMessages.sort((a, b) => a.createTime.compareTo(b.createTime));

    for (final msg in sortedMessages) {
      if (msg.isSend == 1) {
        sentCount++;
        sentWords += msg.displayContent.length;
      } else {
        receivedCount++;
        receivedWords += msg.displayContent.length;
      }

      // 检查是否为新对话段（相邻消息间隔超过20分钟）
      if (lastMsg != null && (msg.createTime - lastMsg.createTime) > 1200) {
        isNewSegment = true;
      }

      // 统计新对话段的发起者
      if (isNewSegment) {
        conversationSegments++;
        if (msg.isSend == 1) {
          segmentsInitiatedByMe++;
        } else {
          segmentsInitiatedByOther++;
        }
        isNewSegment = false;
      }

      lastMsg = msg;
    }

    return ConversationBalance(
      username: username,
      sentCount: sentCount,
      receivedCount: receivedCount,
      sentWords: sentWords,
      receivedWords: receivedWords,
      initiatedByMe: sentCount > 0 ? 1 : 0, // 保留兼容性
      initiatedByOther: receivedCount > 0 ? 1 : 0,
      conversationSegments: conversationSegments,
      segmentsInitiatedByMe: segmentsInitiatedByMe,
      segmentsInitiatedByOther: segmentsInitiatedByOther,
    );
  }

  /// 寻找关键词的"第一次"出现记录，记录重要时刻
  Future<List<FirstTimeRecord>> findFirstTimes(
    String username,
    List<String> keywords,
  ) async {
    final allMessages = await _analyticsService.getAllMessagesForSession(
      username,
    );
    final messages = _filterMessagesByYear(allMessages);
    final records = <FirstTimeRecord>[];

    // 按时间正序排列，确保能找到每个关键词的第一次出现
    messages.sort((a, b) => a.createTime.compareTo(b.createTime));

    final foundKeywords = <String>{};

    for (final msg in messages) {
      if (!msg.isTextMessage) continue;

      final content = msg.displayContent.toLowerCase();

      for (final keyword in keywords) {
        if (!foundKeywords.contains(keyword) &&
            content.contains(keyword.toLowerCase())) {
          records.add(
            FirstTimeRecord(
              keyword: keyword,
              time: DateTime.fromMillisecondsSinceEpoch(msg.createTime * 1000),
              messageContent: msg.displayContent,
              isSentByMe: msg.isSend == 1,
            ),
          );
          foundKeywords.add(keyword);
        }
      }

      if (foundKeywords.length == keywords.length) break;
    }

    return records;
  }

  /// "哈哈哈"报告
  Future<Map<String, dynamic>> analyzeHahaReport() async {
    final sessions = await _databaseService.getSessions();
    final myWxid = _databaseService.currentAccountWxid;
    final normalizedMyWxid = myWxid?.toLowerCase();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .where((s) {
          final username = s.username.toLowerCase();
          if (username == 'filehelper') return false;
          if (normalizedMyWxid != null &&
              normalizedMyWxid.isNotEmpty &&
              username == normalizedMyWxid) {
            return false;
          }
          return true;
        })
        .toList();

    int totalHaha = 0;
    int longestHaha = 0;
    String longestHahaText = '';

    final hahaPattern = RegExp(r'哈+');

    for (final session in privateSessions) {
      try {
        final allMessages = await _analyticsService.getAllMessagesForSession(
          session.username,
        );
        final messages = _filterMessagesByYear(allMessages);

        for (final msg in messages) {
          if (msg.isSend != 1 || !msg.isTextMessage) continue;

          final content = msg.displayContent;
          final matches = hahaPattern.allMatches(content);

          for (final match in matches) {
            final hahaText = match.group(0)!;
            final count = hahaText.length;
            totalHaha += count;

            if (count > longestHaha) {
              longestHaha = count;
              longestHahaText = hahaText;
            }
          }
        }
      } catch (e) {
        // 跳过错误
      }
    }

    return {
      'totalHaha': totalHaha,
      'longestHaha': longestHaha,
      'longestHahaText': longestHahaText,
    };
  }

  /// 深夜密友
  Future<Map<String, dynamic>> findMidnightChatKing() async {
    final sessions = await _databaseService.getSessions();
    final myWxid = _databaseService.currentAccountWxid;
    final normalizedMyWxid = myWxid?.toLowerCase();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .where((s) {
          final username = s.username.toLowerCase();
          if (username == 'filehelper') return false;
          if (normalizedMyWxid != null &&
              normalizedMyWxid.isNotEmpty &&
              username == normalizedMyWxid) {
            return false;
          }
          return true;
        })
        .toList();

    final midnightStats = <String, Map<String, dynamic>>{};
    final displayNames = await _databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );

    int totalMidnightMessages = 0; // 所有人的深夜消息总数

    for (final session in privateSessions) {
      try {
        // 使用数据库直接统计，避免加载所有消息到内存
        final stats = await _databaseService.getMidnightMessageStats(
          session.username,
          filterYear: _filterYear,
        );

        final midnightCount = stats['midnightCount'] as int;

        if (midnightCount > 0) {
          midnightStats[session.username] = {
            'count': midnightCount,
            'hourlyData': stats['hourlyData'] as Map<int, int>,
          };
          totalMidnightMessages += midnightCount;
        }
      } catch (e) {
        // 跳过错误
      }
    }

    if (midnightStats.isEmpty) {
      return {
        'username': null,
        'displayName': null,
        'count': 0,
        'totalMessages': 0,
        'percentage': '0.0',
        'mostActiveHour': 0,
      };
    }

    // 找出深夜消息最多的好友
    final king = midnightStats.entries.reduce(
      (a, b) => (a.value['count'] as int) > (b.value['count'] as int) ? a : b,
    );

    final kingCount = king.value['count'] as int;

    // 计算占比（这个好友的深夜消息数 / 所有深夜消息总数）
    final percentage = totalMidnightMessages > 0
        ? (kingCount / totalMidnightMessages * 100).toStringAsFixed(1)
        : '0.0';

    // 找出最活跃的深夜时段（0-5点中哪个时段最活跃）
    final hourlyData = king.value['hourlyData'] as Map<int, int>;
    int mostActiveHour = 0;
    if (hourlyData.isNotEmpty) {
      mostActiveHour = hourlyData.entries
          .reduce((a, b) => a.value > b.value ? a : b)
          .key;
    }

    return {
      'username': king.key,
      'displayName': displayNames[king.key] ?? king.key,
      'count': kingCount, // 深夜消息数
      'totalMessages': totalMidnightMessages, // 所有深夜消息总数
      'percentage': percentage,
      'mostActiveHour': mostActiveHour,
    };
  }

  /// 最长连聊记录
  Future<Map<String, dynamic>> findLongestStreak(String username) async {
    final allMessages = await _analyticsService.getAllMessagesForSession(
      username,
    );
    final messages = _filterMessagesByYear(allMessages);

    if (messages.isEmpty) {
      return {'days': 0, 'startDate': null, 'endDate': null};
    }

    // 按日期分组
    final dateSet = <String>{};
    for (final msg in messages) {
      final time = DateTime.fromMillisecondsSinceEpoch(msg.createTime * 1000);
      final dateKey = '${time.year}-${time.month}-${time.day}';
      dateSet.add(dateKey);
    }

    // 转换为日期列表并排序
    final dates = dateSet.map((dateStr) {
      final parts = dateStr.split('-');
      return DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    }).toList()..sort();

    // 计算最长连续天数
    int maxStreak = 1;
    int currentStreak = 1;
    DateTime? maxStart = dates.first;
    DateTime? maxEnd = dates.first;
    DateTime currentStart = dates.first;

    for (int i = 1; i < dates.length; i++) {
      if (dates[i].difference(dates[i - 1]).inDays == 1) {
        currentStreak++;
      } else {
        if (currentStreak > maxStreak) {
          maxStreak = currentStreak;
          maxStart = currentStart;
          maxEnd = dates[i - 1];
        }
        currentStreak = 1;
        currentStart = dates[i];
      }
    }

    if (currentStreak > maxStreak) {
      maxStreak = currentStreak;
      maxStart = currentStart;
      maxEnd = dates.last;
    }

    return {'days': maxStreak, 'startDate': maxStart, 'endDate': maxEnd};
  }

  /// 绝对核心好友（总互动数排名）
  Future<List<FriendshipRanking>> getAbsoluteCoreFriends(int limit) async {
    final sessions = await _databaseService.getSessions();
    final myWxid = _databaseService.currentAccountWxid;
    final normalizedMyWxid = myWxid?.toLowerCase();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .where((s) {
          final username = s.username.toLowerCase();
          if (username == 'filehelper') return false;
          if (normalizedMyWxid != null &&
              normalizedMyWxid.isNotEmpty &&
              username == normalizedMyWxid) {
            return false;
          }
          return true;
        })
        .toList();

    final friendshipStats = <String, Map<String, dynamic>>{};
    final displayNames = await _databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );

    int totalMessages = 0;
    for (final session in privateSessions) {
      try {
        final stats = await _databaseService.getSessionMessageStats(
          session.username,
          filterYear: _filterYear,
        );
        final count = stats['total'] as int;

        if (count > 0) {
          friendshipStats[session.username] = {
            'count': count,
            'sent': stats['sent'],
            'received': stats['received'],
            'displayName': displayNames[session.username] ?? session.username,
          };
          totalMessages += count;
        }
      } catch (e) {
        // 跳过错误
      }
    }

    if (friendshipStats.isEmpty) return [];

    // 按总消息数排序
    final sorted = friendshipStats.entries.toList()
      ..sort((a, b) => b.value['count'].compareTo(a.value['count']));

    // 生成排名列表
    return sorted.take(limit).map((e) {
      final percentage = totalMessages > 0
          ? (e.value['count'] / totalMessages * 100)
          : 0.0;
      return FriendshipRanking(
        username: e.key,
        displayName: e.value['displayName'],
        count: e.value['count'],
        percentage: percentage,
        details: {'sent': e.value['sent'], 'received': e.value['received']},
      );
    }).toList();
  }

  /// 年度倾诉对象（我的发送数 / 对方发送数 的比值排名）
  /// 找出"我话最多但对方话较少"的关系 - 代表最想向TA倾诉的人
  Future<List<FriendshipRanking>> getConfidantObjects(int limit) async {
    final sessions = await _databaseService.getSessions();
    final myWxid = _databaseService.currentAccountWxid;
    final normalizedMyWxid = myWxid?.toLowerCase();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .where((s) {
          final username = s.username.toLowerCase();
          if (username == 'filehelper') return false;
          if (normalizedMyWxid != null &&
              normalizedMyWxid.isNotEmpty &&
              username == normalizedMyWxid) {
            return false;
          }
          return true;
        })
        .toList();

    final confidentStats = <String, Map<String, dynamic>>{};
    final displayNames = await _databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );

    for (final session in privateSessions) {
      try {
        final stats = await _databaseService.getSessionMessageStats(
          session.username,
          filterYear: _filterYear,
        );
        final sentCount = stats['sent'] as int;
        final receivedCount = stats['received'] as int;
        final totalMessages = sentCount + receivedCount;

        // 过滤：消息数少于50条的不计算（关系需要一定深度）
        if (totalMessages < 50) continue;

        // 只计算对方有回应的（接收数 > 0）
        if (receivedCount > 0) {
          // 计算倾诉指数：我发送数 / 对方发送数
          // 比值越大，说明我越想向TA倾诉
          final confidentIndex = sentCount / receivedCount;

          confidentStats[session.username] = {
            'count': sentCount, // 显示我发送的消息数
            'receivedCount': receivedCount,
            'index': confidentIndex,
            'displayName': displayNames[session.username] ?? session.username,
          };
        }
      } catch (e) {
        // 跳过错误
      }
    }

    if (confidentStats.isEmpty) return [];

    // 按倾诉指数从高到低排序（我话最多的优先）
    final sorted = confidentStats.entries.toList()
      ..sort((a, b) => b.value['index'].compareTo(a.value['index']));

    return sorted.take(limit).map((e) {
      final percentage = (e.value['index'] as double) * 10; // 指数转换为显示百分比
      return FriendshipRanking(
        username: e.key,
        displayName: e.value['displayName'],
        count: e.value['count'],
        percentage: (percentage).clamp(0, 100).toDouble(), // 限制在0-100
        details: {
          'receivedCount': e.value['receivedCount'],
          'confidentIndex': (e.value['index'] as double).toStringAsFixed(2),
        },
      );
    }).toList();
  }

  /// 年度最佳听众（对方发送数 / 我的发送数 的比值排名）
  /// 找出"对方话最多但我话较少"的关系 - 代表最无私的倾听者
  Future<List<FriendshipRanking>> getBestListeners(int limit) async {
    final sessions = await _databaseService.getSessions();
    final myWxid = _databaseService.currentAccountWxid;
    final normalizedMyWxid = myWxid?.toLowerCase();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .where((s) {
          final username = s.username.toLowerCase();
          if (username == 'filehelper') return false;
          if (normalizedMyWxid != null &&
              normalizedMyWxid.isNotEmpty &&
              username == normalizedMyWxid) {
            return false;
          }
          return true;
        })
        .toList();

    final listenerStats = <String, Map<String, dynamic>>{};
    final displayNames = await _databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );

    for (final session in privateSessions) {
      try {
        final stats = await _databaseService.getSessionMessageStats(
          session.username,
          filterYear: _filterYear,
        );
        final sentCount = stats['sent'] as int;
        final receivedCount = stats['received'] as int;
        final totalMessages = sentCount + receivedCount;

        // 过滤：消息数少于50条的不计算
        if (totalMessages < 50) continue;

        // 只计算我有发送消息的（发送数 > 0）
        if (sentCount > 0) {
          // 计算倾听指数：对方发送数 / 我发送数
          // 比值越大，说明TA越无私地倾听我
          final listenerIndex = receivedCount / sentCount;

          listenerStats[session.username] = {
            'count': receivedCount, // 显示对方发送的消息数
            'sentCount': sentCount,
            'index': listenerIndex,
            'displayName': displayNames[session.username] ?? session.username,
          };
        }
      } catch (e) {
        // 跳过错误
      }
    }

    if (listenerStats.isEmpty) return [];

    // 按倾听指数从高到低排序（对方话最多的优先）
    final sorted = listenerStats.entries.toList()
      ..sort((a, b) => b.value['index'].compareTo(a.value['index']));

    return sorted.take(limit).map((e) {
      final percentage = (e.value['index'] as double) * 10; // 指数转换为显示百分比
      return FriendshipRanking(
        username: e.key,
        displayName: e.value['displayName'],
        count: e.value['count'],
        percentage: (percentage).clamp(0, 100).toDouble(), // 限制在0-100
        details: {
          'sentCount': e.value['sentCount'],
          'listenerIndex': (e.value['index'] as double).toStringAsFixed(2),
        },
      );
    }).toList();
  }

  /// 双向奔赴好友（互动均衡度排名）
  Future<List<FriendshipRanking>> getMutualFriendsRanking(int limit) async {
    final sessions = await _databaseService.getSessions();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .toList();

    final balanceList = <Map<String, dynamic>>[];

    // 获取所有好友的显示名（包括备注名）
    final displayNames = await _databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );

    for (final session in privateSessions) {
      try {
        final stats = await _databaseService.getSessionMessageStats(
          session.username,
          filterYear: _filterYear,
        );
        final sentCount = stats['sent'] as int;
        final receivedCount = stats['received'] as int;
        final totalMessages = sentCount + receivedCount;

        // 过滤：消息数少于100条的好友不统计
        if (totalMessages < 100) continue;

        if (sentCount > 0 && receivedCount > 0) {
          final ratio = sentCount / receivedCount;
          // 均衡度：1.0最平衡，偏离1.0越远越不平衡
          final balanceness = 1.0 - (ratio - 1.0).abs().clamp(0, 10) / 10;

          balanceList.add({
            'username': session.username,
            'displayName':
                displayNames[session.username] ??
                session.displayName ??
                session.username,
            'ratio': ratio,
            'balanceness': balanceness,
            'sentCount': sentCount,
            'receivedCount': receivedCount,
          });
        }
      } catch (e) {
        // 跳过错误
      }
    }

    if (balanceList.isEmpty) return [];

    // 按均衡度从高到低排序（最接近1.0）
    balanceList.sort((a, b) => b['balanceness'].compareTo(a['balanceness']));

    return balanceList.take(limit).map((item) {
      final ratio = item['ratio'] as double;
      return FriendshipRanking(
        username: item['username'],
        displayName: item['displayName'],
        count: (item['sentCount'] as int) + (item['receivedCount'] as int),
        percentage: item['balanceness'],
        details: {
          'ratio': ratio.toStringAsFixed(2),
          'sentCount': item['sentCount'],
          'receivedCount': item['receivedCount'],
        },
      );
    }).toList();
  }

  /// 主动社交指数（按好友统计每天第一条消息由我发起的比例）
  Future<SocialStyleData> analyzeSocialInitiativeRate() async {
    final sessions = await _databaseService.getSessions();
    final myWxid = _databaseService.currentAccountWxid;
    final normalizedMyWxid = myWxid?.toLowerCase();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .where((s) {
          final username = s.username.toLowerCase();
          if (username == 'filehelper') return false;
          if (normalizedMyWxid != null &&
              normalizedMyWxid.isNotEmpty &&
              username == normalizedMyWxid) {
            return false;
          }
          return true;
        })
        .toList();

    final initiativeStats = <String, Map<String, dynamic>>{};
    final displayNames = await _databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );

    for (final session in privateSessions) {
      try {
        // 使用的 SQL 查询方法
        final messagesByDate = await _databaseService.getSessionMessagesByDate(
          session.username,
          filterYear: _filterYear,
        );

        // 计算总消息数
        final totalCount = messagesByDate.values.fold(
          0,
          (sum, data) => sum + (data['count'] as int),
        );

        // 过滤：消息数少于100条的好友不统计
        if (totalCount < 100) continue;

        // 统计每天的第一条消息是否由我发起
        int daysWithMessages = messagesByDate.length;
        int daysInitiatedByMe = 0;

        for (final dateData in messagesByDate.values) {
          if (dateData['firstIsSend'] == true) {
            daysInitiatedByMe++;
          }
        }

        if (daysWithMessages > 0) {
          final rate = (daysInitiatedByMe / daysWithMessages * 100);
          initiativeStats[session.username] = {
            'displayName': displayNames[session.username] ?? session.username,
            'rate': rate,
            'daysInitiated': daysInitiatedByMe,
            'totalDays': daysWithMessages,
          };
        }
      } catch (e) {
        // 跳过错误
      }
    }

    if (initiativeStats.isEmpty) {
      return SocialStyleData(initiativeRanking: []);
    }

    // 按主动率从高到低排序
    final sorted = initiativeStats.entries.toList()
      ..sort((a, b) => b.value['rate'].compareTo(a.value['rate']));

    final ranking = sorted.map((e) {
      return FriendshipRanking(
        username: e.key,
        displayName: e.value['displayName'],
        count: e.value['daysInitiated'],
        percentage: e.value['rate'] / 100,
        details: {'totalDays': e.value['totalDays']},
      );
    }).toList();

    return SocialStyleData(initiativeRanking: ranking);
  }

  /// 年度聊天巅峰日
  Future<ChatPeakDay> analyzePeakChatDay() async {
    final sessions = await _databaseService.getSessions();
    final myWxid = _databaseService.currentAccountWxid;
    final normalizedMyWxid = myWxid?.toLowerCase();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .where((s) {
          final username = s.username.toLowerCase();
          if (username == 'filehelper') return false;
          if (normalizedMyWxid != null &&
              normalizedMyWxid.isNotEmpty &&
              username == normalizedMyWxid) {
            return false;
          }
          return true;
        })
        .toList();

    // 获取所有好友的显示名（包括备注名）
    final displayNames = await _databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );

    final messagesByDate = <String, int>{};
    // 按日期和好友分组统计消息数：dateKey -> {username -> {count, displayName}}
    final messagesByDateAndFriend =
        <String, Map<String, Map<String, dynamic>>>{};

    for (final session in privateSessions) {
      try {
        final sessionMessagesByDate = await _databaseService
            .getSessionMessagesByDate(
              session.username,
              filterYear: _filterYear,
            );

        for (final entry in sessionMessagesByDate.entries) {
          final dateKey = entry.key;
          final count = entry.value['count'] as int;

          messagesByDate[dateKey] = (messagesByDate[dateKey] ?? 0) + count;

          // 记录每天和每个好友的消息数
          messagesByDateAndFriend[dateKey] ??= {};
          messagesByDateAndFriend[dateKey]![session.username] = {
            'count': count,
            'displayName':
                displayNames[session.username] ??
                session.displayName ??
                session.username,
          };
        }
      } catch (e) {
        // 跳过错误
      }
    }

    if (messagesByDate.isEmpty) {
      return ChatPeakDay(date: DateTime.now(), messageCount: 0);
    }

    // 找出消息数最多的一天
    final peakEntry = messagesByDate.entries.reduce(
      (a, b) => a.value > b.value ? a : b,
    );

    final dateParts = peakEntry.key.split('-');
    final peakDate = DateTime(
      int.parse(dateParts[0]),
      int.parse(dateParts[1]),
      int.parse(dateParts[2]),
    );

    // 找出那天聊得最多的好友
    String? topFriendUsername;
    String? topFriendDisplayName;
    int topFriendMessageCount = 0;
    double topFriendPercentage = 0.0;

    final friendsOnPeakDay = messagesByDateAndFriend[peakEntry.key];
    if (friendsOnPeakDay != null && friendsOnPeakDay.isNotEmpty) {
      // 找出消息数最多的好友
      var topFriendEntry = friendsOnPeakDay.entries.reduce(
        (a, b) => (a.value['count'] as int) > (b.value['count'] as int) ? a : b,
      );

      topFriendUsername = topFriendEntry.key;
      topFriendDisplayName = topFriendEntry.value['displayName'] as String;
      topFriendMessageCount = topFriendEntry.value['count'] as int;
      topFriendPercentage = (topFriendMessageCount / peakEntry.value * 100);
    }

    return ChatPeakDay(
      date: peakDate,
      messageCount: peakEntry.value,
      topFriendUsername: topFriendUsername,
      topFriendDisplayName: topFriendDisplayName,
      topFriendMessageCount: topFriendMessageCount,
      topFriendPercentage: topFriendPercentage,
    );
  }

  /// 连续打卡记录（最长连续聊天天数和好友）
  Future<Map<String, dynamic>> findLongestCheckInRecord() async {
    final sessions = await _databaseService.getSessions();
    final myWxid = _databaseService.currentAccountWxid;
    final normalizedMyWxid = myWxid?.toLowerCase();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .where((s) {
          final username = s.username.toLowerCase();
          if (username == 'filehelper') return false;
          if (normalizedMyWxid != null &&
              normalizedMyWxid.isNotEmpty &&
              username == normalizedMyWxid) {
            return false;
          }
          return true;
        })
        .toList();

    // 获取所有好友的显示名（包括备注名）
    final displayNames = await _databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );

    // 批量获取所有会话的消息日期
    final allSessionsDates = await _databaseService
        .getAllPrivateSessionsMessageDates(filterYear: _filterYear);

    int globalMaxStreak = 0;
    String? bestFriendUsername;
    String? bestFriendDisplayName;
    DateTime? streakStart;
    DateTime? streakEnd;

    for (final session in privateSessions) {
      try {
        final dateSet = allSessionsDates[session.username];
        if (dateSet == null || dateSet.isEmpty) continue;

        // 转换为日期列表并排序
        final dates = dateSet.map((dateStr) {
          final parts = dateStr.split('-');
          return DateTime(
            int.parse(parts[0]),
            int.parse(parts[1]),
            int.parse(parts[2]),
          );
        }).toList()..sort();

        // 计算最长连续天数
        int maxStreak = 1;
        int currentStreak = 1;
        DateTime? maxStart = dates.first;
        DateTime? maxEnd = dates.first;

        for (int i = 1; i < dates.length; i++) {
          final dayDiff = dates[i].difference(dates[i - 1]).inDays;
          if (dayDiff == 1) {
            currentStreak++;
            if (currentStreak > maxStreak) {
              maxStreak = currentStreak;
              maxStart = dates[i - currentStreak + 1];
              maxEnd = dates[i];
            }
          } else {
            currentStreak = 1;
          }
        }

        if (maxStreak > globalMaxStreak) {
          globalMaxStreak = maxStreak;
          bestFriendUsername = session.username;
          bestFriendDisplayName =
              displayNames[session.username] ??
              session.displayName ??
              session.username;
          streakStart = maxStart;
          streakEnd = maxEnd;
        }
      } catch (e) {
        // 跳过错误
      }
    }

    return {
      'username': bestFriendUsername,
      'displayName': bestFriendDisplayName,
      'days': globalMaxStreak,
      'startDate': streakStart,
      'endDate': streakEnd,
    };
  }

  /// 消息类型分布
  Future<List<MessageTypeStats>> analyzeMessageTypeDistribution() async {
    final typeCount = await _databaseService.getAllMessageTypeDistribution(
      filterYear: _filterYear,
    );

    if (typeCount.isEmpty) return [];

    final totalMessages = typeCount.values.fold(0, (sum, count) => sum + count);
    if (totalMessages == 0) return [];

    // 映射消息类型
    final typeMapping = {
      1: '文本消息',
      3: '图片',
      34: '语音',
      43: '视频',
      8594229559345: '红包',
      8589934592049: '转账',
      42: '名片',
      47: '动画表情',
      48: '位置',
      17179869233: '链接',
      21474836529: '图文',
      154618822705: '小程序',
      12884901937: '音乐',
      81604378673: '聊天记录',
      266287972401: '拍一拍',
      270582939697: '视频号',
      25769803825: '文件',
      10000: '系统消息',
    };

    // 生成统计列表
    final stats = <MessageTypeStats>[];
    final otherCount = typeCount.entries
        .where((e) => !typeMapping.containsKey(e.key))
        .fold<int>(0, (sum, e) => sum + e.value);

    for (final entry in typeCount.entries) {
      final typeName = typeMapping[entry.key] ?? '其他消息';
      if (typeMapping.containsKey(entry.key)) {
        stats.add(
          MessageTypeStats(
            typeName: typeName,
            count: entry.value,
            percentage: entry.value / totalMessages,
          ),
        );
      }
    }

    if (otherCount > 0) {
      stats.add(
        MessageTypeStats(
          typeName: '其他消息',
          count: otherCount,
          percentage: otherCount / totalMessages,
        ),
      );
    }

    // 按数量从高到低排序
    stats.sort((a, b) => b.count.compareTo(a.count));

    return stats;
  }

  /// 消息长度分析
  Future<MessageLengthData> analyzeMessageLength() async {
    final stats = await _databaseService.getTextMessageLengthStats(
      year: _filterYear,
    );

    final averageLength = stats['averageLength'] as double;
    final longestLength = stats['longestLength'] as int;
    final textMessageCount = stats['textMessageCount'] as int;
    final longestMsg = stats['longestMessage'] as Map<String, dynamic>?;

    String longestContent = '';
    String? longestSentTo;
    String? longestSentToDisplayName;
    DateTime? longestMessageTime;

    if (longestMsg != null) {
      final content = longestMsg['content'] as String;
      longestContent = content.length > 100
          ? '${content.substring(0, 100)}...'
          : content;
      longestMessageTime = DateTime.fromMillisecondsSinceEpoch(
        (longestMsg['createTime'] as int) * 1000,
      );

      // 从表名推断会话ID（简化处理，实际可能需要反查）
      final tableName = longestMsg['tableName'] as String;
      longestSentTo = tableName; // 临时使用表名
      longestSentToDisplayName = tableName; // 临时使用表名
    }

    return MessageLengthData(
      averageLength: averageLength,
      longestLength: longestLength,
      longestContent: longestContent,
      longestSentTo: longestSentTo,
      longestSentToDisplayName: longestSentToDisplayName,
      longestMessageTime: longestMessageTime,
      totalTextMessages: textMessageCount,
    );
  }
}
