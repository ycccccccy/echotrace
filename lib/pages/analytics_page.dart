import 'dart:io';
import 'package:flutter/material.dart';
import '../services/analytics_service.dart';
import '../services/database_service.dart';
import '../services/analytics_cache_service.dart';
import '../services/logger_service.dart';
import '../models/analytics_data.dart';
import 'annual_report_display_page.dart';

/// 数据分析页面
class AnalyticsPage extends StatefulWidget {
  final DatabaseService databaseService;

  const AnalyticsPage({super.key, required this.databaseService});

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> {
  late AnalyticsService _analyticsService;
  bool _isLoading = false;
  ChatStatistics? _overallStats;
  List<ContactRanking>? _contactRankings;
  List<ContactRanking>? _allContactRankings; // 保存所有排名
  Map<String, String> _avatarUrls = {}; // 排名联系人头像

  // 加载进度状态
  String _loadingStatus = '';
  int _processedCount = 0;
  int _totalCount = 0;

  // Top N 选择
  int _topN = 10;

  @override
  void initState() {
    super.initState();
    _analyticsService = AnalyticsService(widget.databaseService);
    // 延迟到下一帧执行，避免在 initState 中使用 context
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  Future<void> _loadData() async {
    await logger.debug('AnalyticsPage', '========== 开始加载数据分析 ==========');

    if (!widget.databaseService.isConnected) {
      await logger.warning('AnalyticsPage', '数据库未连接');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先连接数据库')));
      }
      return;
    }

    await logger.debug('AnalyticsPage', '数据库已连接，开始加载数据');

    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _loadingStatus = '正在检查缓存...';
      _processedCount = 0;
      _totalCount = 0;
    });

    try {
      final cacheService = AnalyticsCacheService.instance;

      // 获取数据库修改时间
      final dbPath = widget.databaseService.dbPath;
      await logger.debug('AnalyticsPage', '数据库路径: $dbPath');

      int? dbModifiedTime;
      if (dbPath != null) {
        final dbFile = File(dbPath);
        if (await dbFile.exists()) {
          final stat = await dbFile.stat();
          dbModifiedTime = stat.modified.millisecondsSinceEpoch;
          await logger.debug(
            'AnalyticsPage',
            '数据库修改时间: ${DateTime.fromMillisecondsSinceEpoch(dbModifiedTime)}',
          );
        } else {
          await logger.warning('AnalyticsPage', '数据库文件不存在');
        }
      }

      // 先尝试从缓存读取
      await logger.debug('AnalyticsPage', '开始检查缓存');
      final cachedData = await cacheService.loadBasicAnalytics();
      await logger.debug('AnalyticsPage', '缓存检查完成，有缓存: ${cachedData != null}');

      if (cachedData != null && dbModifiedTime != null) {
        // 有缓存，检查数据库是否变化
        await logger.debug('AnalyticsPage', '检查数据库是否变化');
        final dbChanged = await cacheService.isDatabaseChanged(dbModifiedTime);
        await logger.debug('AnalyticsPage', '数据库已变化: $dbChanged');

        if (dbChanged) {
          // 数据库已变化，询问用户
          await logger.info('AnalyticsPage', '数据库已变化，询问用户是否重新分析');
          if (!mounted) return;
          final shouldReanalyze = await _showDatabaseChangedDialog();

          if (shouldReanalyze == true) {
            // 用户选择重新分析
            await logger.info('AnalyticsPage', '用户选择重新分析');
            await _performAnalysis(dbModifiedTime);
          } else {
            // 用户选择使用旧数据
            await logger.info('AnalyticsPage', '用户选择使用旧数据');
            if (!mounted) return;
            setState(() {
              _overallStats = cachedData['overallStats'];
              _allContactRankings = cachedData['contactRankings'];
              _contactRankings = _allContactRankings?.take(_topN).toList();
              _loadingStatus = '完成（使用缓存数据）';
              _isLoading = false;
            });
            await logger.debug(
              'AnalyticsPage',
              '使用缓存数据完成，总消息数: ${_overallStats?.totalMessages}',
            );
          }
          return;
        }

        // 数据库未变化，直接使用缓存
        await logger.info('AnalyticsPage', '数据库未变化，使用缓存数据');
        if (!mounted) return;
        setState(() {
          _overallStats = cachedData['overallStats'];
          _allContactRankings = cachedData['contactRankings'];
          _contactRankings = _allContactRankings?.take(_topN).toList();
          _loadingStatus = '完成（从缓存加载）';
          _isLoading = false;
        });
        await logger.debug(
          'AnalyticsPage',
          '缓存加载完成，总消息数: ${_overallStats?.totalMessages}, 联系人数: ${_allContactRankings?.length}',
        );
        return;
      }

      // 没有缓存，重新分析
      await logger.info('AnalyticsPage', '没有缓存，开始重新分析');
      await _performAnalysis(
        dbModifiedTime ?? DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e, stackTrace) {
      await logger.error('AnalyticsPage', '加载数据失败: $e', e, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载数据失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      await logger.debug('AnalyticsPage', '========== 数据加载完成 ==========');
    }
  }

  Future<void> _performAnalysis(int dbModifiedTime) async {
    await logger.debug('AnalyticsPage', '========== 开始执行数据分析 ==========');
    final cacheService = AnalyticsCacheService.instance;

    if (!mounted) return;
    setState(() => _loadingStatus = '正在分析所有私聊数据...');

    await logger.debug('AnalyticsPage', '开始分析所有私聊数据');
    final startTime = DateTime.now();
    final stats = await _analyticsService.analyzeAllPrivateChats();
    final elapsed = DateTime.now().difference(startTime);

    await logger.info('AnalyticsPage', '私聊数据分析完成，耗时: ${elapsed.inSeconds}秒');
    await logger.debug('AnalyticsPage', '总消息数: ${stats.totalMessages}');
    await logger.debug('AnalyticsPage', '活跃天数: ${stats.activeDays}');
    await logger.debug('AnalyticsPage', '文本消息: ${stats.textMessages}');
    await logger.debug('AnalyticsPage', '图片消息: ${stats.imageMessages}');
    await logger.debug('AnalyticsPage', '语音消息: ${stats.voiceMessages}');
    await logger.debug('AnalyticsPage', '视频消息: ${stats.videoMessages}');
    await logger.debug('AnalyticsPage', '发送消息: ${stats.sentMessages}');
    await logger.debug('AnalyticsPage', '接收消息: ${stats.receivedMessages}');

    if (!mounted) return;
    setState(() {
      _overallStats = stats;
      _loadingStatus = '正在统计联系人排名...';
    });

    // 步骤2: 加载联系人排名（带进度）
    await logger.debug('AnalyticsPage', '开始加载联系人排名');
    final rankings = await _loadRankingsWithProgress();
    await logger.info('AnalyticsPage', '联系人排名加载完成，共 ${rankings.length} 个联系人');

    // 保存到缓存
    await logger.debug('AnalyticsPage', '开始保存缓存');
    await cacheService.saveBasicAnalytics(
      overallStats: _overallStats,
      contactRankings: rankings,
      dbModifiedTime: dbModifiedTime,
    );
    await logger.debug('AnalyticsPage', '缓存保存完成');

    if (!mounted) return;
    setState(() {
      _allContactRankings = rankings;
      _contactRankings = rankings.take(_topN).toList();
      _loadingStatus = '完成';
    });

    await logger.debug('AnalyticsPage', '========== 数据分析执行完成 ==========');
  }

  Future<bool?> _showDatabaseChangedDialog() async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.orange),
            SizedBox(width: 8),
            Text('数据库已更新'),
          ],
        ),
        content: const Text(
          '检测到数据库已发生变化，是否重新分析数据？\n\n'
          '• 重新分析：获取最新的统计结果（需要一些时间）\n'
          '• 使用旧数据：快速加载，但可能不包含最新消息',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('使用旧数据'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重新分析'),
          ),
        ],
      ),
    );
  }

  Future<List<ContactRanking>> _loadRankingsWithProgress() async {
    await logger.debug('AnalyticsPage', '开始加载联系人排名（带进度）');

    final sessions = await widget.databaseService.getSessions();
    final privateSessions = sessions.where((s) => !s.isGroup).toList();
    await logger.debug('AnalyticsPage', '获取到 ${privateSessions.length} 个私聊会话');

    if (!mounted) return [];
    setState(() {
      _totalCount = privateSessions.length;
      _processedCount = 0;
    });

    final rankings = <ContactRanking>[];
    final displayNames = await widget.databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );
    // 预取头像
    try {
      _avatarUrls = await widget.databaseService.getAvatarUrls(
        privateSessions.map((s) => s.username).toList(),
      );
    } catch (_) {}
    await logger.debug('AnalyticsPage', '获取到 ${displayNames.length} 个联系人显示名');

    int skippedCount = 0;
    int errorCount = 0;

    for (var i = 0; i < privateSessions.length; i++) {
      final session = privateSessions[i];

      if (!mounted) break;
      setState(() {
        _processedCount = i + 1;
        _loadingStatus =
            '正在分析: ${displayNames[session.username] ?? session.username}';
      });

      // 每处理100个联系人记录一次进度
      if ((i + 1) % 100 == 0) {
        await logger.debug(
          'AnalyticsPage',
          '已处理 ${i + 1}/${privateSessions.length} 个联系人',
        );
      }

      try {
        // 使用SQL直接统计，不加载所有消息
        final stats = await widget.databaseService.getSessionMessageStats(
          session.username,
        );
        final messageCount = stats['total'] as int;
        if (messageCount == 0) {
          skippedCount++;
          continue;
        }

        final sentCount = stats['sent'] as int;
        final receivedCount = stats['received'] as int;

        // 获取最后一条消息时间
        final timeRange = await widget.databaseService.getSessionTimeRange(
          session.username,
        );
        final lastMessageTime = timeRange['last'] != null
            ? DateTime.fromMillisecondsSinceEpoch(timeRange['last']! * 1000)
            : null;

        rankings.add(
          ContactRanking(
            username: session.username,
            displayName: displayNames[session.username] ?? session.username,
            messageCount: messageCount,
            sentCount: sentCount,
            receivedCount: receivedCount,
            lastMessageTime: lastMessageTime,
          ),
        );
      } catch (e, stackTrace) {
        // 读取失败，跳过
        errorCount++;
        await logger.warning(
          'AnalyticsPage',
          '读取联系人 ${session.username} 失败: $e\n$stackTrace',
        );
      }
    }

    await logger.debug(
      'AnalyticsPage',
      '联系人处理完成，有效: ${rankings.length}, 跳过: $skippedCount, 错误: $errorCount',
    );

    rankings.sort((a, b) => b.messageCount.compareTo(a.messageCount));
    final topRankings = rankings.take(50).toList();

    await logger.info('AnalyticsPage', '联系人排名完成，返回前 ${topRankings.length} 名');
    if (topRankings.isNotEmpty) {
      await logger.debug(
        'AnalyticsPage',
        '第1名: ${topRankings[0].displayName}, 消息数: ${topRankings[0].messageCount}',
      );
      if (topRankings.length >= 10) {
        await logger.debug(
          'AnalyticsPage',
          '第10名: ${topRankings[9].displayName}, 消息数: ${topRankings[9].messageCount}',
        );
      }
    }

    return topRankings;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          // 自定义标题栏
          _buildHeader(),
          // 内容区域
          Expanded(
            child: _isLoading
                ? _buildLoadingView()
                : _overallStats == null
                ? _buildEmptyView()
                : _buildContent(),
          ),
        ],
      ),
    );
  }

  /// 构建标题栏
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.1), width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.analytics_outlined,
            size: 28,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Text(
            '数据分析',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          if (!_isLoading)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadData,
              tooltip: '刷新数据',
            ),
        ],
      ),
    );
  }

  /// 构建加载视图（带详细进度）
  Widget _buildLoadingView() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 进度指示器
            SizedBox(
              width: 80,
              height: 80,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                value: _totalCount > 0 ? _processedCount / _totalCount : null,
              ),
            ),
            const SizedBox(height: 32),

            // 当前状态
            Text(
              _loadingStatus,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 16),

            // 进度数字
            if (_totalCount > 0)
              Text(
                '$_processedCount / $_totalCount',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),

            const SizedBox(height: 8),

            // 进度条
            if (_totalCount > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: LinearProgressIndicator(
                  value: _processedCount / _totalCount,
                  backgroundColor: Colors.grey[200],
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),

            const SizedBox(height: 24),

            // 提示文字
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '首次加载需要分析所有聊天数据，请耐心等待',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建空数据视图
  Widget _buildEmptyView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.analytics_outlined, size: 80, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            '暂无数据',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(color: Colors.grey[400]),
          ),
          const SizedBox(height: 8),
          Text(
            '请先连接数据库',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 年度报告入口（置顶）
        _buildAnnualReportEntry(),
        const SizedBox(height: 16),

        _buildOverallStatsCard(),
        const SizedBox(height: 16),
        _buildMessageTypeChart(),
        const SizedBox(height: 16),
        _buildSendReceiveChart(),
        const SizedBox(height: 16),
        _buildContactRankingCard(),
      ],
    );
  }

  /// 年度报告入口卡片
  Widget _buildAnnualReportEntry() {
    const wechatGreen = Color(0xFF07C160);

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: wechatGreen, width: 1),
      ),
      child: InkWell(
        onTap: _isLoading
            ? null
            : () async {
                // 显示加载状态
                setState(() {
                  _isLoading = true;
                  _loadingStatus = '正在准备年度报告...';
                });

                try {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => AnnualReportDisplayPage(
                        databaseService: widget.databaseService,
                      ),
                    ),
                  );
                } finally {
                  // 隐藏加载状态
                  if (mounted) {
                    setState(() {
                      _isLoading = false;
                      _loadingStatus = '';
                    });
                  }
                }
              },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '查看详细年度报告',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '深度分析你的聊天数据，发现更多有趣洞察',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              _isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(wechatGreen),
                      ),
                    )
                  : const Icon(
                      Icons.chevron_right,
                      color: Colors.grey,
                      size: 24,
                    ),
            ],
          ),
        ),
      ),
    );
  }

  /// 总体统计卡片
  Widget _buildOverallStatsCard() {
    final stats = _overallStats!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '私聊总体统计',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            _buildStatRow('总消息数', stats.totalMessages.toString()),
            _buildStatRow('活跃天数', stats.activeDays.toString()),
            _buildStatRow(
              '平均每天',
              stats.averageMessagesPerDay.toStringAsFixed(1),
            ),
            _buildStatRow('聊天时长', '${stats.chatDurationDays} 天'),
            if (stats.firstMessageTime != null)
              _buildStatRow('首条消息', _formatDateTime(stats.firstMessageTime!)),
            if (stats.lastMessageTime != null)
              _buildStatRow('最新消息', _formatDateTime(stats.lastMessageTime!)),
          ],
        ),
      ),
    );
  }

  /// 消息类型分布
  Widget _buildMessageTypeChart() {
    final stats = _overallStats!;
    final distribution = stats.messageTypeDistribution;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '消息类型分布',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ...distribution.entries.map((entry) {
              final percentage = stats.totalMessages > 0
                  ? (entry.value / stats.totalMessages * 100).toStringAsFixed(1)
                  : '0.0';

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(width: 60, child: Text(entry.key)),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: stats.totalMessages > 0
                            ? entry.value / stats.totalMessages
                            : 0,
                        backgroundColor: Colors.grey[200],
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 80,
                      child: Text(
                        '${entry.value} ($percentage%)',
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// 发送/接收比例
  Widget _buildSendReceiveChart() {
    final stats = _overallStats!;
    final ratio = stats.sendReceiveRatio;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '发送/接收比例',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ...ratio.entries.map((entry) {
              final percentage = stats.totalMessages > 0
                  ? (entry.value / stats.totalMessages * 100).toStringAsFixed(1)
                  : '0.0';

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(width: 60, child: Text(entry.key)),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: stats.totalMessages > 0
                            ? entry.value / stats.totalMessages
                            : 0,
                        backgroundColor: Colors.grey[200],
                        color: entry.key == '发送' ? Colors.blue : Colors.green,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 80,
                      child: Text(
                        '${entry.value} ($percentage%)',
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// 联系人排名卡片
  Widget _buildContactRankingCard() {
    if (_contactRankings == null || _contactRankings!.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  '聊天最多的联系人 Top $_topN',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment<int>(value: 10, label: Text('Top 10')),
                    ButtonSegment<int>(value: 20, label: Text('Top 20')),
                    ButtonSegment<int>(value: 50, label: Text('Top 50')),
                  ],
                  selected: {_topN},
                  onSelectionChanged: (Set<int> newSelection) {
                    final newTopN = newSelection.first;
                    setState(() {
                      _topN = newTopN;
                      _contactRankings = _allContactRankings
                          ?.take(_topN)
                          .toList();
                    });
                  },
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Builder(
              builder: (context) {
                return Column(
                  children: _contactRankings!.asMap().entries.map((entry) {
                    final index = entry.key;
                    final ranking = entry.value;

                    final avatarUrl = _avatarUrls[ranking.username];
                    return ListTile(
                      key: ValueKey('${ranking.username}_$index'),
                      leading: _AvatarWithRank(
                        avatarUrl: avatarUrl,
                        rank: index + 1,
                      ),
                      title: Text(ranking.displayName),
                      subtitle: Text(
                        '发送: ${ranking.sentCount} | 接收: ${ranking.receivedCount}',
                      ),
                      trailing: Text(
                        '${ranking.messageCount}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
  }
}

class _AvatarWithRank extends StatelessWidget {
  final String? avatarUrl;
  final int rank;

  const _AvatarWithRank({required this.avatarUrl, required this.rank});

  @override
  Widget build(BuildContext context) {
    final hasAvatar = avatarUrl != null && avatarUrl!.isNotEmpty;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 18,
          backgroundImage: hasAvatar ? NetworkImage(avatarUrl!) : null,
          child: !hasAvatar
              ? Text(
                  rank.toString(),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                )
              : null,
        ),
        Positioned(
          bottom: -2,
          right: -2,
          child: CircleAvatar(
            radius: 9,
            backgroundColor: Theme.of(context).colorScheme.primary,
            child: Text(
              '$rank',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
