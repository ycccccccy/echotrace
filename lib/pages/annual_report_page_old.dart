import 'package:flutter/material.dart';
import '../services/database_service.dart';
import '../services/analytics_background_service.dart';
import '../services/analytics_cache_service.dart';
import '../models/advanced_analytics_data.dart';
import '../models/chat_session.dart';
import '../widgets/analytics/heatmap_chart.dart';
import '../widgets/analytics/calendar_heatmap.dart';
import '../widgets/analytics/conversation_balance.dart';

/// 年度报告页面 - 调试模式
/// 这个文件用于测试最初的部分功能，新功能也将在此测试
/// 正式版本不使用此文件

class AnnualReportPage extends StatefulWidget {
  final DatabaseService databaseService;

  const AnnualReportPage({
    super.key,
    required this.databaseService,
  });

  @override
  State<AnnualReportPage> createState() => _AnnualReportPageState();
}

class _AnnualReportPageState extends State<AnnualReportPage> {
  late AnalyticsBackgroundService _backgroundService;
  final _cacheService = AnalyticsCacheService.instance;
  
  // 各功能模块的加载状态
  final Map<String, bool> _loadingStates = {};
  final Map<String, String> _errorMessages = {};
  
  // 后台分析进度
  int _currentProgress = 0;
  int _totalProgress = 100;
  
  // 数据
  ActivityHeatmap? _activityHeatmap;
  LinguisticStyle? _linguisticStyle;
  Map<String, dynamic>? _hahaReport;
  Map<String, dynamic>? _midnightKing;
  List<Map<String, dynamic>>? _whoRepliesFastest; // 谁回复我最快
  List<Map<String, dynamic>>? _myFastestReplies; // 我回复谁最快
  List<ChatSession> _privateSessions = [];
  String? _selectedFriend;
  IntimacyCalendar? _intimacyCalendar;
  ConversationBalance? _conversationBalance;
  
  // 新增功能数据
  int? _selectedYear; // null 表示历史以来
  List<int>? _availableYears; // 可用的年份列表
  bool _yearSelectionDone = false; // 是否已完成年份选择
  List<FriendshipRanking>? _absoluteCoreFriends;
  List<FriendshipRanking>? _confidantObjects;
  List<FriendshipRanking>? _bestListeners;
  List<FriendshipRanking>? _mutualFriends;
  SocialStyleData? _socialStyleData;
  ChatPeakDay? _chatPeakDay;
  Map<String, dynamic>? _longestCheckIn;
  List<MessageTypeStats>? _messageTypeStats;
  MessageLengthData? _messageLengthData;

  @override
  void initState() {
    super.initState();
    final dbPath = widget.databaseService.dbPath;
    if (dbPath != null) {
      _backgroundService = AnalyticsBackgroundService(dbPath);
    }
    _loadBasicData();
    
    // 延迟显示年份选择弹窗，让UI先完成渲染
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showYearSelectionDialog();
    });
  }

  Future<void> _loadBasicData() async {
    try {
      final sessions = await widget.databaseService.getSessions();
      
      // 按消息数量排序（需要从数据库获取每个会话的消息数）
      final sessionWithCounts = <ChatSession, int>{};
      final privateSessions = sessions.where((s) => !s.isGroup && !_isSystemAccount(s.username)).toList();
      
      for (int i = 0; i < privateSessions.length; i++) {
        final session = privateSessions[i];
        try {
          // 获取消息数量（高效的 COUNT 查询）
          final count = await widget.databaseService.getMessageCount(session.username);
          sessionWithCounts[session] = count;
        } catch (e) {
          sessionWithCounts[session] = 0;
        }
      }
      
      // 按消息数量降序排列
      final sortedSessions = sessionWithCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      
      setState(() {
        _privateSessions = sortedSessions.map((e) => e.key).toList();
      });
    } catch (e) {
    }
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

  Future<void> _loadFeature(String featureName, Future<void> Function() loader) async {
    setState(() {
      _loadingStates[featureName] = true;
      _errorMessages.remove(featureName);
      // 重置进度
      _currentProgress = 0;
      _totalProgress = 100;
    });

    try {
      await loader();
      } catch (e) {
      setState(() {
        _errorMessages[featureName] = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingStates[featureName] = false;
        });
      }
    }
  }

  void _updateProgress(
    String stage, 
    int current, 
    int total, {
    String? detail,
    int? elapsedSeconds,
    int? estimatedRemainingSeconds,
  }) {
    if (mounted) {
      setState(() {
        _currentProgress = current;
        _totalProgress = total;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          '年度报告' + (_yearSelectionDone ? (_selectedYear != null ? ' - ${_selectedYear}年' : ' - 历史以来') : ' - 加载中...')
        ),
        actions: [
          if (_yearSelectionDone)
            IconButton(
              icon: const Icon(Icons.calendar_today),
              onPressed: _showYearSelectionDialog,
              tooltip: '切换时间范围',
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _showClearCacheDialog,
            tooltip: '缓存管理',
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildDebugInfo(),
          const SizedBox(height: 16),
          _buildFeatureCard(
            '作息图谱',
            '分析24小时×7天的活动热力图',
            Icons.access_time,
            'activity',
            () async {
              final result = await _backgroundService.analyzeActivityPatternInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _activityHeatmap = result);
            },
            _activityHeatmap != null ? _buildActivityHeatmapContent() : null,
          ),
          const SizedBox(height: 16),
          _buildFeatureCard(
            '语言风格',
            '分析说话风格和表达习惯',
            Icons.format_quote,
            'linguistic',
            () async {
              final result = await _backgroundService.analyzeLinguisticStyleInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _linguisticStyle = result);
            },
            _linguisticStyle != null ? _buildLinguisticStyleContent() : null,
          ),
          const SizedBox(height: 16),
          _buildFeatureCard(
            '哈哈哈报告',
            '统计快乐指数',
            Icons.emoji_emotions,
            'haha',
            () async {
              final result = await _backgroundService.analyzeHahaReportInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _hahaReport = result);
            },
            _hahaReport != null ? _buildHahaReportContent() : null,
          ),
          const SizedBox(height: 16),
          _buildFeatureCard(
            '深夜密友',
            '找出深夜聊天最多的好友',
            Icons.nightlight_round,
            'midnight',
            () async {
              final result = await _backgroundService.findMidnightChatKingInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _midnightKing = result);
            },
            _midnightKing != null ? _buildMidnightKingContent() : null,
          ),
          const SizedBox(height: 16),
          _buildFeatureCard(
            '最快响应好友',
            '谁回复你的消息平均速度最快？',
            Icons.speed,
            'who_replies_fastest',
            () async {
              final result = await _backgroundService.analyzeWhoRepliesFastestInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _whoRepliesFastest = result);
            },
            _whoRepliesFastest != null ? _buildWhoRepliesFastestContent() : null,
          ),
          const SizedBox(height: 16),
          _buildFeatureCard(
            '我回复最快的好友',
            '我回复谁的消息最快？',
            Icons.reply,
            'my_fastest_replies',
            () async {
              final result = await _backgroundService.analyzeMyFastestRepliesInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _myFastestReplies = result);
            },
            _myFastestReplies != null ? _buildMyFastestRepliesContent() : null,
          ),
          const SizedBox(height: 16),
          _buildFriendSelector(),
          if (_selectedFriend != null) ...[
            const SizedBox(height: 16),
            _buildFeatureCard(
              '亲密度日历',
              '你们的聊天热度变化',
              Icons.calendar_today,
              'intimacy_$_selectedFriend',
              () async {
                final result = await _backgroundService.generateIntimacyCalendarInBackground(
                  _selectedFriend!,
                  _selectedYear,
                  _updateProgress,
                );
                setState(() => _intimacyCalendar = result);
              },
              _intimacyCalendar != null ? _buildIntimacyCalendarContent() : null,
            ),
            const SizedBox(height: 16),
            _buildFeatureCard(
              '对话天平',
              '谁更主动？',
              Icons.balance,
              'balance_$_selectedFriend',
              () async {
                final result = await _backgroundService.analyzeConversationBalanceInBackground(
                  _selectedFriend!,
                  _selectedYear,
                  _updateProgress,
                );
                setState(() => _conversationBalance = result);
              },
              _conversationBalance != null ? _buildConversationBalanceContent() : null,
            ),
          ],
        // 新增功能卡片（年度挚友榜和社交分析）
        if (_yearSelectionDone) ...[
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
          children: [
                Icon(Icons.info, color: Colors.amber[700], size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '时间范围: ' + (_selectedYear != null ? '${_selectedYear}年' : '历史以来'),
                    style: TextStyle(fontSize: 12, color: Colors.amber[700]),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '年度挚友榜',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _buildFeatureCard(
            '绝对核心好友',
            '你互动最频繁的人',
            Icons.favorite,
            'coreFriends',
            () async {
              final result = await _backgroundService.getAbsoluteCoreFriendsInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _absoluteCoreFriends = result as List<FriendshipRanking>?);
            },
            _absoluteCoreFriends != null ? _buildFriendshipRankingContent(_absoluteCoreFriends!, '总互动数') : null,
          ),
          const SizedBox(height: 12),
          _buildFeatureCard(
            '年度倾诉对象',
            '你最主要的输出对象',
            Icons.edit,
            'confidant',
            () async {
              final result = await _backgroundService.getConfidantObjectsInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _confidantObjects = result);
            },
            _confidantObjects != null ? _buildFriendshipRankingContent(_confidantObjects!, '你的消息数') : null,
          ),
          const SizedBox(height: 12),
          _buildFeatureCard(
            '年度最佳听众',
            '最关心你的人',
            Icons.hearing,
            'bestListeners',
            () async {
              final result = await _backgroundService.getBestListenersInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _bestListeners = result);
            },
            _bestListeners != null ? _buildFriendshipRankingContent(_bestListeners!, '对方消息数') : null,
          ),
          const SizedBox(height: 12),
          _buildFeatureCard(
            '双向奔赴好友',
            '互动最平等的人',
            Icons.sync,
            'mutual',
            () async {
              final result = await _backgroundService.getMutualFriendsRankingInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _mutualFriends = result);
            },
            _mutualFriends != null ? _buildMutualFriendContent(_mutualFriends!) : null,
          ),
          const SizedBox(height: 24),
          const Text(
            '社交行为分析',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _buildFeatureCard(
            '主动社交指数',
            '按好友统计你的主动率',
            Icons.trending_up,
            'socialInitiative',
            () async {
              final result = await _backgroundService.analyzeSocialInitiativeRateInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _socialStyleData = result);
            },
            _socialStyleData != null ? _buildSocialInitiativeContent(_socialStyleData!) : null,
          ),
          const SizedBox(height: 12),
          _buildFeatureCard(
            '聊天巅峰日',
            '消息最多的一天',
            Icons.calendar_today,
            'peakDay',
            () async {
              final result = await _backgroundService.analyzePeakChatDayInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _chatPeakDay = result);
            },
            _chatPeakDay != null ? _buildPeakChatDayContent(_chatPeakDay!) : null,
          ),
          const SizedBox(height: 12),
          _buildFeatureCard(
            '连续打卡记录',
            '最长连续聊天天数',
            Icons.calendar_month,
            'checkIn',
            () async {
              final result = await _backgroundService.findLongestCheckInRecordInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _longestCheckIn = result);
            },
            _longestCheckIn != null ? _buildCheckInContent(_longestCheckIn!) : null,
          ),
          const SizedBox(height: 24),
          const Text(
            '沟通方式分析',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _buildFeatureCard(
            '消息类型分布',
            '你最常用的沟通方式',
            Icons.pie_chart,
            'messageTypes',
            () async {
              final result = await _backgroundService.analyzeMessageTypeDistributionInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _messageTypeStats = result);
            },
            _messageTypeStats != null ? _buildMessageTypeContent(_messageTypeStats!) : null,
          ),
          const SizedBox(height: 12),
          _buildFeatureCard(
            '表达欲分析',
            '消息长度和详细程度',
            Icons.description,
            'messageLength',
            () async {
              final result = await _backgroundService.analyzeMessageLengthInBackground(
                _selectedYear,
                _updateProgress,
              );
              setState(() => _messageLengthData = result);
            },
            _messageLengthData != null ? _buildMessageLengthContent(_messageLengthData!) : null,
          ),
        ],
        ],
      ),
        ],
      ),
    );
  }

  Widget _buildDebugInfo() {
    return Card(
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
                children: [
                Icon(Icons.bug_report, color: Colors.blue),
                SizedBox(width: 8),
                  Text(
                  '调试模式',
                  style: TextStyle(
                    fontSize: 18,
                      fontWeight: FontWeight.bold,
                    color: Colors.blue,
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            Text('私聊会话数: ${_privateSessions.length}'),
            Text('数据库: ${widget.databaseService.dbPath ?? "未连接"}'),
            if (_yearSelectionDone) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.yellow.shade200,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '当前报告时间范围: ' + (_selectedYear != null ? '${_selectedYear}年' : '历史以来（全部数据）'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
            const SizedBox(height: 8),
            const Text(
              '点击下方卡片的"加载数据"按钮来测试各个功能，所有数据都将基于上述时间范围进行分析',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureCard(
    String title,
    String subtitle,
    IconData icon,
    String featureKey,
    Future<void> Function() loader,
    Widget? content,
  ) {
    final isLoading = _loadingStates[featureKey] ?? false;
    final error = _errorMessages[featureKey];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
            Text(
                        title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
            Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
                if (content == null)
                  ElevatedButton.icon(
                    onPressed: (!_yearSelectionDone || isLoading) ? null : () => _loadFeature(featureKey, loader),
                    icon: isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    label: isLoading 
                        ? Text('${_currentProgress}/${_totalProgress}')
                        : (!_yearSelectionDone ? const Text('等待年份...') : const Text('加载数据')),
                  )
                else
                  ElevatedButton.icon(
                    onPressed: !_yearSelectionDone ? null : () => _loadFeature(featureKey, loader),
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                    ),
                  ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
            Container(
                padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                children: [
                    const Icon(Icons.error, color: Colors.red),
                    const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        '错误: $error',
                        style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
            ],
            if (content != null) ...[
              const Divider(height: 24),
              content,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFriendSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            const Text(
              '选择好友进行分析',
              style: TextStyle(
                fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
            const SizedBox(height: 12),
            if (_privateSessions.isEmpty)
              const Text('暂无好友数据')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _privateSessions.take(10).map((session) {
                  final isSelected = _selectedFriend == session.username;
                  return ChoiceChip(
                    label: Text(session.displayName ?? session.username),
                    selected: isSelected,
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _selectedFriend = session.username;
                          _intimacyCalendar = null;
                          _conversationBalance = null;
                        } else {
                          _selectedFriend = null;
                        }
                      });
                    },
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivityHeatmapContent() {
    final heatmap = _activityHeatmap!;
    
    // 找出最活跃时段
    int maxHour = 0;
    int maxValue = 0;
    for (int hour = 0; hour < 24; hour++) {
      int hourTotal = 0;
      for (int day = 1; day <= 7; day++) {
        hourTotal += heatmap.getCount(hour, day);
      }
      if (hourTotal > maxValue) {
        maxValue = hourTotal;
        maxHour = hour;
      }
    }
    
    // 计算夜猫子指数（0:00-5:00）
    int nightCount = 0;
    int totalCount = 0;
    for (int hour = 0; hour < 24; hour++) {
      for (int day = 1; day <= 7; day++) {
        final count = heatmap.getCount(hour, day);
        totalCount += count;
        if (hour >= 0 && hour < 6) {
          nightCount += count;
        }
      }
    }
    final nightOwlIndex = totalCount > 0 ? (nightCount / totalCount * 100).toInt() : 0;
    
    return Column(
        children: [
        HeatmapChart(heatmap: heatmap),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  '最活跃时段',
                  '${maxHour.toString().padLeft(2, '0')}:00',
                  Icons.wb_sunny,
                  Colors.orange,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatCard(
                  '夜猫子指数',
                  '$nightOwlIndex%',
                  Icons.nightlight_round,
                  Colors.indigo,
                ),
              ),
            ],
          ),
        ],
    );
  }

  Widget _buildLinguisticStyleContent() {
    final style = _linguisticStyle!;
    
    return Column(
            children: [
              _buildStatRow('平均消息长度', '${style.avgMessageLength.toStringAsFixed(1)} 字'),
              const SizedBox(height: 12),
              _buildStatRow('说话风格', style.style),
              const SizedBox(height: 12),
              _buildStatRow('最常用标点', style.mostUsedPunctuation),
              const SizedBox(height: 12),
              _buildStatRow('撤回次数', '${style.revokedMessageCount} 次'),
      ],
    );
  }

  Widget _buildHahaReportContent() {
    final totalHaha = _hahaReport!['totalHaha'] as int;
    final longestHaha = _hahaReport!['longestHaha'] as int;
    final longestText = _hahaReport!['longestHahaText'] as String;
    
    return Column(
        children: [
                Row(
                  children: [
                    Expanded(
                      child: _buildStatCard(
                        '总"哈"数',
                        '$totalHaha',
                        Icons.sentiment_very_satisfied,
                        const Color(0xFFFFD54F),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildStatCard(
                        '最长记录',
                        '$longestHaha 个',
                        Icons.star,
                        const Color(0xFFFF7043),
                      ),
                    ),
                  ],
                ),
                if (longestText.isNotEmpty) ...[
          const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.amber.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.amber.withOpacity(0.3), width: 2),
                    ),
                          child: Column(
                            children: [
                const Icon(Icons.emoji_emotions_outlined, color: Colors.amber, size: 48),
                        const SizedBox(height: 12),
                              Text(
                          longestText,
                                style: const TextStyle(
                            fontSize: 28,
                                  fontWeight: FontWeight.bold,
                            color: Colors.amber,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '你的笑声传递着快乐',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
    );
  }

  Widget _buildMidnightKingContent() {
    final displayName = _midnightKing!['displayName'] as String?;
    final count = _midnightKing!['count'] as int;
    final percentage = _midnightKing!['percentage'] as String;
    final mostActiveHour = _midnightKing!['mostActiveHour'] as int;
    final totalMessages = _midnightKing!['totalMessages'] as int;
    
    if (count == 0) {
      return const Text('暂无深夜聊天数据');
    }
    
    return Column(
        children: [
          Text(
          displayName ?? '未知',
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
              child: _buildStatCard('深夜消息', '$count', Icons.chat_bubble, Colors.purple),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
              child: _buildStatCard('占比', '$percentage%', Icons.pie_chart, Colors.blue),
          ),
        ],
      ),
        const SizedBox(height: 12),
        Row(
        children: [
            Expanded(
              child: _buildStatCard('总消息数', '$totalMessages', Icons.message, Colors.teal),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
              child: _buildStatCard(
                '最活跃时段',
                '${mostActiveHour.toString().padLeft(2, '0')}:00',
                Icons.bedtime,
                Colors.deepPurple,
                          ),
                        ),
                      ],
        ),
        const SizedBox(height: 12),
                              Container(
          padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
            color: Colors.amber.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.amber.withOpacity(0.3)),
          ),
          child: Row(
                                  children: [
              Icon(Icons.info, color: Colors.amber[700], size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '深夜定义为 0:00-6:00（跨越午夜），全天数据统计到第二天6点前',
                                      style: TextStyle(
                                        fontSize: 12,
                    color: Colors.amber[700],
                  ),
                ),
                              ),
                            ],
                          ),
        ),
      ],
    );
  }

  Widget _buildWhoRepliesFastestContent() {
    if (_whoRepliesFastest == null || _whoRepliesFastest!.isEmpty) {
      return const Center(child: Text('暂无数据'));
    }

    // 只显示前5名
    final top5 = _whoRepliesFastest!.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Top 5 回复最快的好友',
                  style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        ...top5.asMap().entries.map((entry) {
          final index = entry.key;
          final data = entry.value;
          return _buildResponseTimeItem(
            index + 1,
            data['displayName'] as String,
            _formatResponseTime(data['avgResponseTimeMinutes'] as num),
            data['totalResponses'] as int,
              );
            }).toList(),
      ],
    );
  }

  Widget _buildMyFastestRepliesContent() {
    if (_myFastestReplies == null || _myFastestReplies!.isEmpty) {
      return const Center(child: Text('暂无数据'));
    }

    // 只显示前5名
    final top5 = _myFastestReplies!.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
          'Top 5 我回复最快的好友',
                          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        ...top5.asMap().entries.map((entry) {
          final index = entry.key;
          final data = entry.value;
          return _buildResponseTimeItem(
            index + 1,
            data['displayName'] as String,
            _formatResponseTime(data['avgResponseTimeMinutes'] as num),
            data['totalResponses'] as int,
          );
        }).toList(),
      ],
    );
  }

  Widget _buildResponseTimeItem(int rank, String name, String time, int count) {
    Color rankColor;
    if (rank == 1) {
      rankColor = const Color(0xFFFFD700); // 金色
    } else if (rank == 2) {
      rankColor = const Color(0xFFC0C0C0); // 银色
    } else if (rank == 3) {
      rankColor = const Color(0xFFCD7F32); // 铜色
    } else {
      rankColor = Colors.grey;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Row(
        children: [
                Container(
            width: 32,
            height: 32,
                  decoration: BoxDecoration(
              color: rankColor,
                    shape: BoxShape.circle,
                  ),
            child: Center(
              child: Text(
                '$rank',
                style: const TextStyle(
                  color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '平均响应: $time',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
          ),
                  Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
              color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(12),
                    ),
                          child: Text(
              '$count 次',
                            style: TextStyle(
                fontSize: 12,
                color: Colors.blue[700],
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatResponseTime(num minutes) {
    if (minutes < 1) {
      return '${(minutes * 60).toStringAsFixed(0)} 秒';
    } else if (minutes < 60) {
      return '${minutes.toStringAsFixed(1)} 分钟';
    } else {
      final hours = minutes / 60;
      return '${hours.toStringAsFixed(1)} 小时';
    }
  }

  Widget _buildIntimacyCalendarContent() {
    return CalendarHeatmap(calendar: _intimacyCalendar!);
  }

  Widget _buildConversationBalanceContent() {
    final balance = _conversationBalance!;
    final displayName = _privateSessions
        .firstWhere((s) => s.username == _selectedFriend, orElse: () => _privateSessions.first)
        .displayName ?? _selectedFriend!;

    return ConversationBalanceWidget(
      balance: balance,
      displayName: displayName,
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 32),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[700],
            fontSize: 16,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      ],
    );
  }

  Future<void> _showClearCacheDialog() async {
    final cacheInfo = await _cacheService.getCacheInfo();
    
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('缓存管理'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cacheInfo != null) ...[
              _buildInfoRow('基础分析缓存', cacheInfo['hasBasicAnalytics'] ? '✓ 已缓存' : '✗ 未缓存'),
              _buildInfoRow('年度报告缓存', cacheInfo['hasAnnualReport'] ? '✓ 已缓存' : '✗ 未缓存'),
              if (cacheInfo['cachedAt'] != null)
                _buildInfoRow('缓存时间', '${cacheInfo['age']} 分钟前'),
            ] else
              const Text('暂无缓存数据'),
          ],
        ),
        actions: [
          if (cacheInfo != null) ...[
            if (cacheInfo['hasBasicAnalytics'])
              TextButton(
                onPressed: () async {
                  await _cacheService.clearBasicCache();
                  if (mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('基础分析缓存已清除')),
                    );
                  }
                },
                child: const Text('清除基础分析'),
              ),
            if (cacheInfo['hasAnnualReport'])
              TextButton(
                onPressed: () async {
                  await _cacheService.clearAnnualReportCache();
                  if (mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('年度报告缓存已清除')),
                    );
                  }
                },
                child: const Text('清除年度报告'),
              ),
            TextButton(
              onPressed: () async {
                await _cacheService.clearAllCache();
                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('所有缓存已清除')),
                  );
                }
              },
              child: const Text('清除全部'),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  /// 检测可用的年份
  Future<void> _detectAvailableYears() async {
    try {
      // 从数据库获取所有消息的年份范围
      final sessions = await widget.databaseService.getSessions();
      final years = <int>{};
      
      for (final session in sessions) {
        try {
          final allMessages = await widget.databaseService.getMessages(session.username);
          for (final msg in allMessages) {
            final date = DateTime.fromMillisecondsSinceEpoch(msg.createTime * 1000);
            years.add(date.year);
          }
        } catch (e) {
          // 忽略错误
        }
      }
      
      if (mounted) {
        setState(() {
          _availableYears = years.toList()..sort((a, b) => b.compareTo(a));
        });
      }
    } catch (e) {
    }
  }

  /// 显示年份选择弹窗
  Future<void> _showYearSelectionDialog() async {
    // 先检测年份
    await _detectAvailableYears();
    
    if (!mounted) return;

    final selectedYear = await showDialog<int?>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('选择报告时间范围'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('请选择要查看的报告时间范围：'),
              const SizedBox(height: 16),
              // 历史以来选项
              ListTile(
                title: const Text('历史以来'),
                subtitle: _availableYears != null && _availableYears!.isNotEmpty
                    ? Text('${_availableYears!.last}-${_availableYears!.first}')
                    : const Text('查看全部数据'),
                onTap: () => Navigator.pop(context, 0), // 0 表示历史以来
              ),
              if (_availableYears != null && _availableYears!.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Divider(),
                const SizedBox(height: 8),
                const Text('或选择具体年份：'),
                const SizedBox(height: 8),
                ..._availableYears!.map((year) => ListTile(
                  title: Text('$year 年'),
                  onTap: () => Navigator.pop(context, year),
                )),
              ],
            ],
          ),
        ),
      ),
    );

    if (mounted) {
      setState(() {
        _selectedYear = selectedYear == 0 ? null : selectedYear;
        _yearSelectionDone = true;
      });
    }
  }

  Widget _buildFriendshipRankingContent(List<FriendshipRanking> rankings, String label) {
    if (rankings.isEmpty) {
      return const Center(child: Text('暂无数据'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Top 3 好友',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        ...rankings.take(3).toList().asMap().entries.map((entry) {
          final index = entry.key;
          final data = entry.value;
          return _buildResponseTimeItem(
            index + 1,
            data.displayName,
            '${data.count} 条',
            data.count,
          );
        }).toList(),
      ],
    );
  }

  Widget _buildMutualFriendContent(List<FriendshipRanking> mutualFriends) {
    if (mutualFriends.isEmpty) {
      return const Center(child: Text('暂无数据'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Top 3 双向奔赴好友',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        ...mutualFriends.take(3).toList().asMap().entries.map((entry) {
          final index = entry.key;
          final data = entry.value;
          final ratio = data.details?['ratio'] as String? ?? '1.0';
          return _buildResponseTimeItem(
            index + 1,
            data.displayName,
            '均衡度: $ratio',
            data.count,
          );
        }).toList(),
      ],
    );
  }

  Widget _buildSocialInitiativeContent(SocialStyleData socialStyleData) {
    if (socialStyleData.initiativeRanking.isEmpty) {
      return const Center(child: Text('暂无数据'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '主动发起率 Top 3',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        ...socialStyleData.initiativeRanking.take(3).toList().asMap().entries.map((entry) {
          final index = entry.key;
          final data = entry.value;
          return _buildResponseTimeItem(
            index + 1,
            data.displayName,
            '${(data.percentage * 100).toStringAsFixed(1)}%',
            data.count,
          );
        }).toList(),
      ],
    );
  }

  Widget _buildPeakChatDayContent(ChatPeakDay peakDay) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildStatRow('峰值日期', peakDay.formattedDate),
        const SizedBox(height: 12),
        _buildStatRow('峰值消息数', '${peakDay.messageCount} 条'),
        if (peakDay.topFriendDisplayName != null) ...[
          const SizedBox(height: 12),
          _buildStatRow('聊得最多的好友', peakDay.topFriendDisplayName!),
          const SizedBox(height: 12),
          _buildStatRow(
            '与TA的消息数', 
            '${peakDay.topFriendMessageCount} 条 (占${peakDay.topFriendPercentage?.toStringAsFixed(1)}%)',
          ),
        ],
      ],
    );
  }

  Widget _buildCheckInContent(Map<String, dynamic> checkInData) {
    final startDate = checkInData['startDate'] != null 
        ? DateTime.parse(checkInData['startDate'] as String) 
        : null;
    final endDate = checkInData['endDate'] != null 
        ? DateTime.parse(checkInData['endDate'] as String) 
        : null;
    final days = checkInData['days'] as int? ?? 0;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildStatRow('最长连续聊天天数', '$days 天'),
        const SizedBox(height: 12),
        _buildStatRow(
          '好友',
          checkInData['displayName'] as String? ?? '未知',
        ),
        if (startDate != null) ...[
          const SizedBox(height: 12),
          _buildStatRow(
            '开始日期',
            '${startDate.year}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}',
          ),
        ],
        if (endDate != null) ...[
          const SizedBox(height: 12),
          _buildStatRow(
            '结束日期',
            '${endDate.year}-${endDate.month.toString().padLeft(2, '0')}-${endDate.day.toString().padLeft(2, '0')}',
          ),
        ],
      ],
    );
  }

  Widget _buildMessageTypeContent(List<MessageTypeStats> messageTypeStats) {
    if (messageTypeStats.isEmpty) {
      return const Center(child: Text('暂无数据'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '消息类型分布 Top 5',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        ...messageTypeStats.take(5).map((stat) {
          return _buildStatRow(
            stat.typeName,
            '${stat.count} 条 (${(stat.percentage * 100).toStringAsFixed(1)}%)',
          );
        }).toList(),
      ],
    );
  }

  Widget _buildMessageLengthContent(MessageLengthData messageLengthData) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildStatRow(
          '平均消息长度',
          '${messageLengthData.averageLength.toStringAsFixed(1)} 字',
        ),
        const SizedBox(height: 12),
        _buildStatRow(
          '最长消息',
          '${messageLengthData.longestLength} 字',
        ),
        if (messageLengthData.longestSentToDisplayName != null) ...[
          const SizedBox(height: 12),
          _buildStatRow(
            '发送给',
            messageLengthData.longestSentToDisplayName!,
          ),
        ],
      ],
    );
  }
}
