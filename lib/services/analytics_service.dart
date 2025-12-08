// 数据分析服务：封装会话/全局统计、时间分布、词频与联系人排名等逻辑
import '../models/message.dart';
import '../models/analytics_data.dart';
import 'database_service.dart';
import 'logger_service.dart';

/// 数据分析服务
class AnalyticsService {
  final DatabaseService _databaseService;

  AnalyticsService(this._databaseService);

  /// 分析私聊数据
  ///
  /// [sessionId] 会话ID（username）
  /// [includeWordFrequency] 是否包含词频分析（可能比较耗时）
  Future<PrivateChatAnalytics> analyzePrivateChat(
    String sessionId, {
    bool includeWordFrequency = false,
  }) async {
    // 过滤出私聊消息（排除群聊）
    if (sessionId.contains('@chatroom')) {
      throw Exception('此功能仅支持私聊分析');
    }

    // 使用SQL直接统计基础数据
    final stats = await _databaseService.getSessionMessageStats(sessionId);
    final typeStats = await _databaseService.getSessionTypeDistribution(
      sessionId,
    );
    final timeRange = await _databaseService.getSessionTimeRange(sessionId);
    final dates = await _databaseService.getSessionMessageDates(sessionId);

    // 计算基础统计
    final statistics = ChatStatistics(
      totalMessages: stats['total'] as int,
      textMessages: typeStats['text'] ?? 0,
      imageMessages: typeStats['image'] ?? 0,
      voiceMessages: typeStats['voice'] ?? 0,
      videoMessages: typeStats['video'] ?? 0,
      otherMessages: typeStats['other'] ?? 0,
      sentMessages: stats['sent'] as int,
      receivedMessages: stats['received'] as int,
      firstMessageTime: timeRange['first'] != null
          ? DateTime.fromMillisecondsSinceEpoch(timeRange['first']! * 1000)
          : null,
      lastMessageTime: timeRange['last'] != null
          ? DateTime.fromMillisecondsSinceEpoch(timeRange['last']! * 1000)
          : null,
      activeDays: dates.length,
    );

    // 使用SQL获取时间分布
    final timeDistData = await _databaseService.getSessionTimeDistribution(
      sessionId,
    );
    final timeDistribution = TimeDistribution(
      hourlyDistribution: Map<int, int>.from(timeDistData['hourly'] ?? {}),
      weekdayDistribution: Map<int, int>.from(timeDistData['weekday'] ?? {}),
      monthlyDistribution: Map<String, int>.from(timeDistData['monthly'] ?? {}),
    );

    // 词频分析（需要加载消息内容，但可选）
    WordFrequency? wordFrequency;
    if (includeWordFrequency) {
      final messages = await getAllMessagesForSession(sessionId);
      wordFrequency = _analyzeWordFrequency(messages);
    }

    // 联系人排名
    final contactRankings = await _getContactRankings([sessionId]);

    return PrivateChatAnalytics(
      statistics: statistics,
      timeDistribution: timeDistribution,
      wordFrequency: wordFrequency,
      contactRankings: contactRankings,
    );
  }

  /// 获取所有私聊联系人的排名
  Future<List<ContactRanking>> getAllPrivateChatsRanking({
    int limit = 20,
  }) async {
    // 1. 获取所有会话
    final sessions = await _databaseService.getSessions();

    // 2. 过滤出私聊会话
    final privateSessions = sessions.where((s) => !s.isGroup).toList();

    // 3. 获取排名
    final rankings = await _getContactRankings(
      privateSessions.map((s) => s.username).toList(),
    );

    // 4. 排序并限制数量
    rankings.sort((a, b) => b.messageCount.compareTo(a.messageCount));

    return rankings.take(limit).toList();
  }

  /// 分析全部私聊的总体统计
  Future<ChatStatistics> analyzeAllPrivateChats() async {
    await logger.debug('AnalyticsService', '========== 开始分析全部私聊统计 ==========');

    // 1. 获取所有私聊会话
    await logger.debug('AnalyticsService', '获取所有会话列表');
    final sessions = await _databaseService.getSessions();
    final privateSessions = sessions.where((s) => !s.isGroup).toList();
    await logger.info(
      'AnalyticsService',
      '找到 ${privateSessions.length} 个私聊会话（总会话数: ${sessions.length}）',
    );

    // 2. 批量获取所有会话的统计数据（一次性查询）
    await logger.debug('AnalyticsService', '开始批量查询会话统计数据');
    final startTime = DateTime.now();
    final batchStats = await _databaseService.getBatchSessionStats(
      privateSessions.map((s) => s.username).toList(),
    );
    final elapsed = DateTime.now().difference(startTime);
    await logger.info(
      'AnalyticsService',
      '批量查询完成，耗时: ${elapsed.inMilliseconds}ms，获得 ${batchStats.length} 个会话的统计',
    );

    // 3. 累加统计结果
    await logger.debug('AnalyticsService', '开始累加统计结果');
    int totalMessages = 0;
    int textMessages = 0;
    int imageMessages = 0;
    int voiceMessages = 0;
    int videoMessages = 0;
    int otherMessages = 0;
    int sentMessages = 0;
    int receivedMessages = 0;
    DateTime? firstMessageTime;
    DateTime? lastMessageTime;
    final activeDaysSet = <String>{};

    int processedCount = 0;
    int zeroActiveDaysCount = 0;
    final activeDaysDistribution = <int, int>{}; // 活跃天数分布统计

    for (final entry in batchStats.entries) {
      final sessionId = entry.key;
      final stats = entry.value;

      final sessionTotal = stats['total'] as int;
      final sessionActiveDays = stats['activeDays'] as int;

      totalMessages += sessionTotal;
      sentMessages += stats['sent'] as int;
      receivedMessages += stats['received'] as int;
      textMessages += stats['text'] as int;
      imageMessages += stats['image'] as int;
      voiceMessages += stats['voice'] as int;
      videoMessages += stats['video'] as int;
      otherMessages += stats['other'] as int;

      // 时间范围
      if (stats['first'] != null) {
        final firstTime = DateTime.fromMillisecondsSinceEpoch(
          (stats['first'] as int) * 1000,
        );
        if (firstMessageTime == null || firstTime.isBefore(firstMessageTime)) {
          firstMessageTime = firstTime;
        }
      }
      if (stats['last'] != null) {
        final lastTime = DateTime.fromMillisecondsSinceEpoch(
          (stats['last'] as int) * 1000,
        );
        if (lastMessageTime == null || lastTime.isAfter(lastMessageTime)) {
          lastMessageTime = lastTime;
        }
      }

      // 活跃天数已经在批量查询中计算好了
      activeDaysSet.add(sessionActiveDays.toString());

      // 统计活跃天数分布
      activeDaysDistribution[sessionActiveDays] =
          (activeDaysDistribution[sessionActiveDays] ?? 0) + 1;

      // 记录活跃天数为0的会话
      if (sessionActiveDays == 0 && sessionTotal > 0) {
        zeroActiveDaysCount++;
        await logger.warning(
          'AnalyticsService',
          '会话 $sessionId 有 $sessionTotal 条消息但活跃天数为0',
        );
      }

      processedCount++;
      // 每处理100个会话记录一次进度
      if (processedCount % 100 == 0) {
        await logger.debug(
          'AnalyticsService',
          '已累加 $processedCount/${batchStats.length} 个会话的统计（活跃天数为0: $zeroActiveDaysCount）',
        );
      }
    }

    // 活跃天数需要重新计算总数（因为不同会话可能有相同日期）
    int totalActiveDays = batchStats.values.fold(
      0,
      (sum, stats) => sum + (stats['activeDays'] as int),
    );

    await logger.debug(
      'AnalyticsService',
      '活跃天数统计: 总计=$totalActiveDays, 为0的会话数=$zeroActiveDaysCount',
    );
    await logger.debug(
      'AnalyticsService',
      '活跃天数分布（前10）: ${activeDaysDistribution.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value))
        ..take(10).toList()}',
    );

    await logger.info('AnalyticsService', '统计累加完成');
    await logger.debug('AnalyticsService', '总消息数: $totalMessages');
    await logger.debug('AnalyticsService', '文本消息: $textMessages');
    await logger.debug('AnalyticsService', '图片消息: $imageMessages');
    await logger.debug('AnalyticsService', '语音消息: $voiceMessages');
    await logger.debug('AnalyticsService', '视频消息: $videoMessages');
    await logger.debug('AnalyticsService', '其他消息: $otherMessages');
    await logger.debug('AnalyticsService', '发送消息: $sentMessages');
    await logger.debug('AnalyticsService', '接收消息: $receivedMessages');
    await logger.debug('AnalyticsService', '活跃天数: $totalActiveDays');
    await logger.debug('AnalyticsService', '首条消息时间: $firstMessageTime');
    await logger.debug('AnalyticsService', '最后消息时间: $lastMessageTime');
    await logger.debug('AnalyticsService', '========== 全部私聊统计分析完成 ==========');

    return ChatStatistics(
      totalMessages: totalMessages,
      textMessages: textMessages,
      imageMessages: imageMessages,
      voiceMessages: voiceMessages,
      videoMessages: videoMessages,
      otherMessages: otherMessages,
      sentMessages: sentMessages,
      receivedMessages: receivedMessages,
      firstMessageTime: firstMessageTime,
      lastMessageTime: lastMessageTime,
      activeDays: totalActiveDays,
    );
  }

  /// 获取指定时间范围内的消息
  Future<List<Message>> getMessagesByDateRange(
    String sessionId,
    DateTime startDate,
    DateTime endDate,
  ) async {
    final messages = await getAllMessagesForSession(sessionId);

    final startTimestamp = startDate.millisecondsSinceEpoch ~/ 1000;
    final endTimestamp = endDate.millisecondsSinceEpoch ~/ 1000;

    return messages.where((msg) {
      return msg.createTime >= startTimestamp && msg.createTime <= endTimestamp;
    }).toList();
  }

  /// 搜索包含特定关键词的消息
  Future<List<Message>> searchKeywordInSession(
    String sessionId,
    String keyword,
  ) async {
    final messages = await getAllMessagesForSession(sessionId);

    return messages.where((msg) {
      return msg.displayContent.contains(keyword);
    }).toList();
  }

  // ==================== 公开方法 ====================

  /// 获取会话的所有消息（分批加载）
  Future<List<Message>> getAllMessagesForSession(String sessionId) async {
    final allMessages = <Message>[];
    const batchSize = 500;
    int offset = 0;

    while (true) {
      final batch = await _databaseService.getMessages(
        sessionId,
        limit: batchSize,
        offset: offset,
      );

      if (batch.isEmpty) break;

      allMessages.addAll(batch);
      offset += batchSize;

      // 安全限制：最多加载10万条消息
      if (offset >= 100000) break;
    }

    return allMessages;
  }

  /// 分析词频（简单的分词统计）
  WordFrequency _analyzeWordFrequency(List<Message> messages) {
    final wordCount = <String, int>{};
    int totalWords = 0;

    for (final msg in messages) {
      // 只分析文本消息
      if (!msg.isTextMessage && msg.localType != 244813135921) continue;

      final content = msg.displayContent;
      if (content.isEmpty || content.startsWith('[')) continue;

      // 简单分词：按字符分割（中文按字分，英文按词分）
      final words = _simpleTokenize(content);

      for (final word in words) {
        if (word.isEmpty || word.length < 2) continue; // 过滤单字和空字符

        wordCount[word] = (wordCount[word] ?? 0) + 1;
        totalWords++;
      }
    }

    return WordFrequency(wordCount: wordCount, totalWords: totalWords);
  }

  /// 简单分词（中文按双字分，英文按空格分）
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

  /// 获取联系人排名
  Future<List<ContactRanking>> _getContactRankings(
    List<String> usernames,
  ) async {
    final rankings = <ContactRanking>[];

    // 批量获取显示名称
    final displayNames = await _databaseService.getDisplayNames(usernames);

    for (final username in usernames) {
      try {
        // 使用SQL直接统计，不加载所有消息
        final stats = await _databaseService.getSessionMessageStats(username);
        final messageCount = stats['total'] as int;
        if (messageCount == 0) continue;

        final sentCount = stats['sent'] as int;
        final receivedCount = stats['received'] as int;

        // 获取最后一条消息时间
        final timeRange = await _databaseService.getSessionTimeRange(username);
        final lastMessageTime = timeRange['last'] != null
            ? DateTime.fromMillisecondsSinceEpoch(timeRange['last']! * 1000)
            : null;

        rankings.add(
          ContactRanking(
            username: username,
            displayName: displayNames[username] ?? username,
            messageCount: messageCount,
            sentCount: sentCount,
            receivedCount: receivedCount,
            lastMessageTime: lastMessageTime,
          ),
        );
      } catch (e) {
        // 读取失败，跳过
      }
    }

    return rankings;
  }

  /// 导出聊天数据为文本格式
  Future<String> exportChatAsText(String sessionId) async {
    final messages = await getAllMessagesForSession(sessionId);
    final displayNames = await _databaseService.getDisplayNames([sessionId]);
    final contactName = displayNames[sessionId] ?? sessionId;

    final buffer = StringBuffer();
    buffer.writeln('========================================');
    buffer.writeln('聊天记录导出');
    buffer.writeln('联系人: $contactName');
    buffer.writeln('消息数量: ${messages.length}');
    buffer.writeln('导出时间: ${DateTime.now()}');
    buffer.writeln('========================================\n');

    // 按时间正序排列
    messages.sort((a, b) => a.createTime.compareTo(b.createTime));

    for (final msg in messages) {
      final time = DateTime.fromMillisecondsSinceEpoch(msg.createTime * 1000);
      final sender = msg.isSend == 1 ? '我' : contactName;
      final timeStr =
          '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

      buffer.writeln('[$timeStr] $sender');
      buffer.writeln('  ${msg.displayContent}');
      buffer.writeln();
    }

    return buffer.toString();
  }
}
