import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/app_state.dart';
import '../services/analytics_service.dart';
import '../services/database_service.dart';
import '../services/analytics_cache_service.dart';
import '../services/dual_report_cache_service.dart';
import '../services/dual_report_service.dart';
import '../services/logger_service.dart';
import '../models/analytics_data.dart';
import '../utils/string_utils.dart';
import '../widgets/annual_report/dual_report_html_renderer.dart';
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
  final GlobalKey<_DualReportSubPageState> _dualReportKey =
      GlobalKey<_DualReportSubPageState>();

  // 加载进度状态
  String _loadingStatus = '';
  int _processedCount = 0;
  int _totalCount = 0;

  // Top N 选择
  int _topN = 10;
  bool _showAnnualReportSubPage = false;
  bool _showDualReportSubPage = false;

  bool get _isSubPage => _showAnnualReportSubPage || _showDualReportSubPage;

  String get _currentTitle {
    if (_showAnnualReportSubPage) return '年度报告';
    if (_showDualReportSubPage) return '双人报告';
    return '数据分析';
  }

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

    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadingStatus = '正在连接数据库...';
        _processedCount = 0;
        _totalCount = 0;
      });
    }

    if (!widget.databaseService.isConnected) {
      await logger.warning('AnalyticsPage', '数据库未连接，尝试自动连接');
      final appState = context.read<AppState>();
      try {
        await appState.reconnectDatabase();
      } catch (e) {
        await logger.error('AnalyticsPage', '自动连接失败', e);
      }
    }

    if (!widget.databaseService.isConnected) {
      await logger.warning('AnalyticsPage', '数据库仍未连接');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadingStatus = '数据库未连接';
        });
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
    // 预取头像（使用全局缓存）
    try {
      final appState = context.read<AppState>();
      await appState.fetchAndCacheAvatars(
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
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _isLoading
                  ? _buildLoadingView()
                  : _showAnnualReportSubPage
                      ? _AnnualReportSubPage(
                          databaseService: widget.databaseService,
                          onClose: () {
                            setState(() => _showAnnualReportSubPage = false);
                          },
                        )
                      : _showDualReportSubPage
                      ? _DualReportSubPage(
                          key: _dualReportKey,
                          databaseService: widget.databaseService,
                          rankings: _allContactRankings ?? const <ContactRanking>[],
                          onClose: () {
                            setState(() => _showDualReportSubPage = false);
                          },
                        )
                      : _overallStats == null
                          ? _buildEmptyView()
                          : _buildContent(),
            ),
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
          bottom: BorderSide(
            color: Colors.grey.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          if (_isSubPage)
            IconButton(
              onPressed: () {
                if (_showDualReportSubPage) {
                  final handler = _dualReportKey.currentState;
                  if (handler != null) {
                    handler.handleHeaderBack();
                    return;
                  }
                }
                setState(() {
                  _showAnnualReportSubPage = false;
                  _showDualReportSubPage = false;
                });
              },
              icon: const Icon(Icons.arrow_back),
              tooltip: '返回数据分析',
            )
          else
            Icon(
              Icons.analytics_outlined,
              size: 28,
              color: Theme.of(context).colorScheme.primary,
            ),
          SizedBox(width: _isSubPage ? 4 : 12),
          Text(
            _currentTitle,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          if (!_isSubPage && !_isLoading)
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

        // 双人报告入口
        _buildDualReportEntry(),
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
                setState(() => _showAnnualReportSubPage = true);
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

  /// 双人报告入口卡片
  Widget _buildDualReportEntry() {
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
                setState(() => _showDualReportSubPage = true);
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
                      '查看双人报告',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '选择一位好友，生成专属的双人聊天报告',
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
                    final appState = Provider.of<AppState>(context);
                    final avatarUrl = appState.getAvatarUrl(ranking.username);
                    return ListTile(
                      key: ValueKey('${ranking.username}_$index'),
                      leading: _AvatarWithRank(
                        avatarUrl: avatarUrl,
                        rank: index + 1,
                        displayName: ranking.displayName,
                      ),
                      title: Text(
                        StringUtils.cleanOrDefault(
                          ranking.displayName,
                          ranking.username,
                        ),
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        '发送: ${ranking.sentCount} | 接收: ${ranking.receivedCount}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      trailing: Text(
                        '${ranking.messageCount}',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
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
  final String displayName;

  const _AvatarWithRank({
    required this.avatarUrl,
    required this.rank,
    required this.displayName,
  });

  @override
  Widget build(BuildContext context) {
    final hasAvatar = avatarUrl != null && avatarUrl!.isNotEmpty;
    final fallbackText = StringUtils.getFirstChar(
      displayName,
      defaultChar: '聊',
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (hasAvatar)
          CachedNetworkImage(
            imageUrl: avatarUrl!,
            imageBuilder: (context, imageProvider) => CircleAvatar(
              radius: 22,
              backgroundColor: Colors.transparent,
              backgroundImage: imageProvider,
            ),
            placeholder: (context, url) => CircleAvatar(
              radius: 22,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.12),
              child: Text(
                fallbackText,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            errorWidget: (context, url, error) => CircleAvatar(
              radius: 22,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.12),
              child: Text(
                fallbackText,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          )
        else
          CircleAvatar(
            radius: 22,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.12),
            child: Text(
              fallbackText,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        Positioned(
          bottom: -4,
          right: -4,
          child: CircleAvatar(
            radius: 10,
            backgroundColor: Colors.white,
            child: CircleAvatar(
              radius: 8,
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
        ),
      ],
    );
  }
}

class _AnnualReportSubPage extends StatelessWidget {
  final DatabaseService databaseService;
  final VoidCallback onClose;

  const _AnnualReportSubPage({
    required this.databaseService,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return AnnualReportDisplayPage(
      databaseService: databaseService,
      showAppBar: false,
      onClose: onClose,
    );
  }
}

class _DualReportSubPage extends StatefulWidget {
  final DatabaseService databaseService;
  final List<ContactRanking> rankings;
  final VoidCallback onClose;

  const _DualReportSubPage({
    super.key,
    required this.databaseService,
    required this.rankings,
    required this.onClose,
  });

  @override
  State<_DualReportSubPage> createState() => _DualReportSubPageState();
}

class _DualReportSubPageState extends State<_DualReportSubPage> {
  static const _wechatGreen = Color(0xFF07C160);

  int _topN = 10;
  ContactRanking? _selectedFriend;
  Map<String, dynamic>? _reportData;
  String? _reportHtml;
  String? _reportUrl;
  HttpServer? _reportServer;

  bool _isGenerating = false;
  bool _isHtmlLoading = false;
  bool _isOpeningBrowser = false;
  bool _didAutoOpen = false;
  String? _errorMessage;
  String _currentTaskName = '';
  String _currentTaskStatus = '';
  int _totalProgress = 0;
  bool _cancelRequested = false;

  Isolate? _reportIsolate;
  ReceivePort? _reportPort;
  ReceivePort? _reportExitPort;
  ReceivePort? _reportErrorPort;
  StreamSubscription? _reportSubscription;
  StreamSubscription? _reportExitSubscription;
  StreamSubscription? _reportErrorSubscription;
  Completer<Map<String, dynamic>>? _reportCompleter;

  @override
  void dispose() {
    _disposeReportIsolate(canceled: true);
    _stopReportServer();
    super.dispose();
  }

  void _disposeReportIsolate({bool canceled = false}) {
    if (canceled && _reportCompleter != null && !_reportCompleter!.isCompleted) {
      _reportCompleter!.completeError(StateError('report canceled'));
    }
    _reportSubscription?.cancel();
    _reportSubscription = null;
    _reportExitSubscription?.cancel();
    _reportExitSubscription = null;
    _reportErrorSubscription?.cancel();
    _reportErrorSubscription = null;
    _reportPort?.close();
    _reportPort = null;
    _reportExitPort?.close();
    _reportExitPort = null;
    _reportErrorPort?.close();
    _reportErrorPort = null;
    _reportIsolate?.kill(priority: Isolate.immediate);
    _reportIsolate = null;
    _reportCompleter = null;
  }

  Future<Map<String, dynamic>> _generateReportInIsolate(
    ContactRanking ranking,
  ) async {
    final dbPath = widget.databaseService.dbPath;
    if (dbPath == null || dbPath.isEmpty) {
      throw StateError('database path missing');
    }
    final appState = context.read<AppState>();
    final manualWxid = await appState.configService.getManualWxid();
    await logger.debug(
      'DualReportPage',
      'start isolate: friend=${ranking.username} dbPath=$dbPath',
    );

    _disposeReportIsolate();
    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();
    _reportPort = receivePort;
    _reportExitPort = exitPort;
    _reportErrorPort = errorPort;
    final completer = Completer<Map<String, dynamic>>();
    _reportCompleter = completer;
    _reportSubscription = receivePort.listen(
      (message) {
        if (message is! Map) return;
        final type = message['type'];
        if (type == 'progress') {
          _updateProgress(
            message['taskName']?.toString() ?? '',
            message['status']?.toString() ?? '',
            (message['progress'] as int?) ?? 0,
          );
        } else if (type == 'done') {
          if (!completer.isCompleted) {
            completer.complete(
              (message['data'] as Map?)?.cast<String, dynamic>() ??
                  <String, dynamic>{},
            );
          }
          _disposeReportIsolate();
        } else if (type == 'error') {
          if (!completer.isCompleted) {
            completer.completeError(
              StateError(message['message']?.toString() ?? 'unknown error'),
            );
          }
          _disposeReportIsolate();
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(StateError('report isolate closed'));
        }
        _disposeReportIsolate();
      },
    );
    _reportExitSubscription = exitPort.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('report isolate exited'));
      }
      _disposeReportIsolate();
    });
    _reportErrorSubscription = errorPort.listen((message) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('report isolate error: ${message.toString()}'),
        );
      }
      _disposeReportIsolate();
    });

    try {
      _reportIsolate = await Isolate.spawn(
        dualReportIsolateEntry,
        {
          'sendPort': receivePort.sendPort,
          'dbPath': dbPath,
          'friendUsername': ranking.username,
          'filterYear': null,
          'manualWxid': manualWxid,
        },
        onExit: exitPort.sendPort,
        onError: errorPort.sendPort,
        debugName: 'dual-report',
      );
      await logger.debug(
        'DualReportPage',
        'isolate spawned: friend=${ranking.username}',
      );
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
      _disposeReportIsolate();
    }

    return completer.future;
  }

  Future<void> _generateReportFor(ContactRanking ranking) async {
    if (_isGenerating) return;
    _cancelRequested = false;
    await logger.debug(
      'DualReportPage',
      '========== DUAL REPORT START ==========',
    );
    final generateStart = DateTime.now();
    await logger.debug(
      'DualReportPage',
      'generate start: friend=${ranking.username}',
    );
    setState(() {
      _isGenerating = true;
      _isHtmlLoading = false;
      _errorMessage = null;
      _selectedFriend = ranking;
      _currentTaskName = '准备生成双人报告';
      _currentTaskStatus = '处理中';
      _totalProgress = 0;
    });

    try {
      await _updateProgress('检查缓存', '处理中', 10);
      final cached = await DualReportCacheService.loadReport(
        ranking.username,
        null,
      );
      await logger.debug(
        'DualReportPage',
        'cache check: friend=${ranking.username} hit=${cached != null}',
      );
      Map<String, dynamic> reportData;
      if (cached != null) {
        await _updateProgress('检查缓存', '已完成', 100);
        reportData = cached;
        await logger.info('DualReportPage', 'cache hit: use cached report');
      } else {
        await _updateProgress('检查缓存', '已完成', 12);
        reportData = await _generateReportInIsolate(ranking);
        final cacheData = _cloneForCache(reportData);
        _stripEmojiDataUrls(cacheData);
        await DualReportCacheService.saveReport(
          ranking.username,
          null,
          cacheData,
        );
        await logger.debug('DualReportPage', 'cache saved');
      }

      final yearlyStats =
          (reportData['yearlyStats'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{};
      await logger.debug(
        'DualReportPage',
        'yearlyStats emoji: my=${yearlyStats['myTopEmojiMd5'] ?? 'null'} '
            'friend=${yearlyStats['friendTopEmojiMd5'] ?? 'null'} '
            'myUrl=${yearlyStats['myTopEmojiUrl'] != null} '
            'friendUrl=${yearlyStats['friendTopEmojiUrl'] != null}',
      );

      final hasTopEmoji =
          (yearlyStats['myTopEmojiMd5'] as String?)?.isNotEmpty == true ||
          (yearlyStats['friendTopEmojiMd5'] as String?)?.isNotEmpty == true;
      if (!hasTopEmoji) {
        try {
          final actualYear =
              (reportData['year'] as int?) ?? DateTime.now().year;
          final friendUsername =
              reportData['friendUsername']?.toString() ?? ranking.username;
          await logger.debug(
            'DualReportPage',
            'top emoji missing, recompute in main isolate: friend=$friendUsername year=$actualYear',
          );
          final topEmoji =
              await widget.databaseService.getSessionYearlyTopEmojiMd5(
            friendUsername,
            actualYear,
          );
          yearlyStats['myTopEmojiMd5'] = topEmoji['myTopEmojiMd5'];
          yearlyStats['friendTopEmojiMd5'] = topEmoji['friendTopEmojiMd5'];
          yearlyStats['myTopEmojiUrl'] = topEmoji['myTopEmojiUrl'];
          yearlyStats['friendTopEmojiUrl'] = topEmoji['friendTopEmojiUrl'];
          yearlyStats['myEmojiRankings'] = topEmoji['myEmojiRankings'];
          yearlyStats['friendEmojiRankings'] = topEmoji['friendEmojiRankings'];
          reportData['yearlyStats'] = yearlyStats;
          await logger.debug(
            'DualReportPage',
            'top emoji recomputed: my=${yearlyStats['myTopEmojiMd5'] ?? 'null'} '
                'friend=${yearlyStats['friendTopEmojiMd5'] ?? 'null'}',
          );
        } catch (e) {
          await logger.debug(
            'DualReportPage',
            'top emoji recompute failed: $e',
          );
        }
      }

      await _cacheTopEmojiAssets(reportData);
      await _buildReportHtml(reportData);
      await logger.info(
        'DualReportPage',
        'DUAL REPORT done, elapsed: ${DateTime.now().difference(generateStart).inSeconds}s',
      );
      await logger.debug(
        'DualReportPage',
        '========== DUAL REPORT DONE ==========',
      );
      await _startReportServer();
      if (!_didAutoOpen) {
        _didAutoOpen = true;
        await _openReportInBrowser();
      }
    } catch (e) {
      if (_cancelRequested) return;
      if (!mounted) return;
      await logger.error('DualReportPage', 'DUAL REPORT failed: $e');
      setState(() => _errorMessage = '生成双人报告失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  Future<void> _updateProgress(
    String taskName,
    String status,
    int progress,
  ) async {
    if (!mounted) return;
    if (progress < _totalProgress) {
      return;
    }
    setState(() {
      _currentTaskName = taskName;
      _currentTaskStatus = status;
      _totalProgress = progress;
    });
    await logger.debug(
      'DualReportPage',
      'progress: $taskName - $status ($progress%)',
    );
  }

  Future<void> _buildReportHtml(Map<String, dynamic> reportData) async {
    if (!mounted) return;
    setState(() => _isHtmlLoading = true);
    try {
      const myName = '我';
      await logger.debug('DualReportPage', 'build html start');
      final friendName =
          reportData['friendName']?.toString() ??
          _selectedFriend?.displayName ??
          '';
      final html = await DualReportHtmlRenderer.build(
        reportData: reportData,
        myName: myName,
        friendName: friendName,
      );
      if (!mounted) return;
      setState(() {
        _reportData = reportData;
        _reportHtml = html;
      });
      await logger.debug('DualReportPage', 'build html done');
    } finally {
      if (mounted) {
        setState(() => _isHtmlLoading = false);
      }
    }
  }

  Future<void> _openReportInBrowser() async {
    if (_reportHtml == null || _isOpeningBrowser) return;
    setState(() => _isOpeningBrowser = true);
    try {
      await _startReportServer();
      if (_reportUrl == null) {
        throw StateError('报告服务未启动');
      }
      final uri = Uri.parse(_reportUrl!);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开浏览器，请检查默认浏览器设置')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开浏览器失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isOpeningBrowser = false);
      }
    }
  }

  Future<void> _refreshPreview() async {
    if (_reportData == null) return;
    await _buildReportHtml(_reportData!);
    await _startReportServer();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('预览已刷新，请在浏览器中刷新页面')),
      );
    }
  }

  Future<void> _startReportServer() async {
    if (_reportHtml == null) return;
    if (_reportServer != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _reportServer = server;
    _reportUrl = 'http://127.0.0.1:${server.port}/';
    await logger.debug(
      'DualReportPage',
      'report server started: $_reportUrl',
    );
    server.listen((request) async {
      if (request.uri.path == '/favicon.ico') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      if (request.uri.path != '/' && request.uri.path != '/index.html') {
        request.response
          ..statusCode = HttpStatus.notFound
          ..headers.contentType = ContentType.text
          ..write('Not Found');
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.html;
      request.response.write(_reportHtml);
      await request.response.close();
    });
  }

  void _stopReportServer() {
    _reportServer?.close(force: true);
    _reportServer = null;
    _reportUrl = null;
  }

  void _resetToSelection() {
    _cancelRequested = true;
    logger.debug('DualReportPage', 'reset selection');
    _disposeReportIsolate(canceled: true);
    _stopReportServer();
    setState(() {
      _selectedFriend = null;
      _reportData = null;
      _reportHtml = null;
      _errorMessage = null;
      _isGenerating = false;
      _isHtmlLoading = false;
      _isOpeningBrowser = false;
      _didAutoOpen = false;
    });
  }

  void _handleBack() {
    if (_selectedFriend != null ||
        _reportHtml != null ||
        _errorMessage != null ||
        _isGenerating ||
        _isHtmlLoading) {
      logger.debug('DualReportPage', 'handle back: reset');
      _resetToSelection();
      return;
    }
    widget.onClose();
  }

  void handleHeaderBack() {
    _handleBack();
  }

  
  Map<String, dynamic> _cloneForCache(Map<String, dynamic> data) {
    try {
      return jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
    } catch (_) {
      return Map<String, dynamic>.from(data);
    }
  }

  void _stripEmojiDataUrls(Map<String, dynamic> reportData) {
    final yearlyStats =
        (reportData['yearlyStats'] as Map?)?.cast<String, dynamic>();
    if (yearlyStats == null || yearlyStats.isEmpty) return;
    yearlyStats.remove('myTopEmojiDataUrl');
    yearlyStats.remove('friendTopEmojiDataUrl');
    reportData['yearlyStats'] = yearlyStats;
  }

  Future<void> _cacheTopEmojiAssets(Map<String, dynamic> reportData) async {
    try {
      final yearlyStats =
          (reportData['yearlyStats'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{};
      if (yearlyStats.isEmpty) return;

      await logger.debug(
        'DualReportPage',
        'cache top emoji start: my=${yearlyStats['myTopEmojiMd5'] ?? 'null'} '
            'friend=${yearlyStats['friendTopEmojiMd5'] ?? 'null'}',
      );

      final docs = await getApplicationDocumentsDirectory();
      final emojiDir = Directory(p.join(docs.path, 'EchoTrace', 'Emojis'));
      if (!await emojiDir.exists()) {
        await emojiDir.create(recursive: true);
      }

      final myMd5 = yearlyStats['myTopEmojiMd5'] as String?;
      final myUrl = yearlyStats['myTopEmojiUrl'] as String?;
      final friendMd5 = yearlyStats['friendTopEmojiMd5'] as String?;
      final friendUrl = yearlyStats['friendTopEmojiUrl'] as String?;
      final hasMy = (myMd5 != null && myMd5.isNotEmpty) ||
          (myUrl != null && myUrl.isNotEmpty);
      final hasFriend = (friendMd5 != null && friendMd5.isNotEmpty) ||
          (friendUrl != null && friendUrl.isNotEmpty);
      if (!hasMy && !hasFriend) {
        await logger.debug(
          'DualReportPage',
          'top emoji missing in report data, skip cache',
        );
        return;
      }

      final myPath =
          await _ensureEmojiCached(emojiDir, myMd5, myUrl ?? '');
      final friendPath =
          await _ensureEmojiCached(emojiDir, friendMd5, friendUrl ?? '');

      await logger.debug(
        'DualReportPage',
        'cache top emoji paths: my=${myPath ?? 'null'} friend=${friendPath ?? 'null'}',
      );

      final myDataUrl = await _emojiDataUrlFromPath(myPath);
      final friendDataUrl = await _emojiDataUrlFromPath(friendPath);
      if (myDataUrl != null) {
        yearlyStats['myTopEmojiDataUrl'] = myDataUrl;
      }
      if (friendDataUrl != null) {
        yearlyStats['friendTopEmojiDataUrl'] = friendDataUrl;
      }
      reportData['yearlyStats'] = yearlyStats;
    } catch (_) {
      // 缓存失败不影响报告生成
    }
  }

  Future<String?> _ensureEmojiCached(
    Directory dir,
    String? md5,
    String url,
  ) async {
    final existing = await _findExistingEmojiCache(dir, md5, url);
    if (existing != null) return existing;
    if (url.isEmpty) return null;
    return _downloadAndCacheEmoji(dir, url, md5);
  }

  Future<String?> _emojiDataUrlFromPath(String? path) async {
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    final ext = p.extension(path).toLowerCase();
    final mime = _emojiMimeFromExtension(ext);
    if (mime == null) return null;
    final base64Data = base64Encode(bytes);
    return 'data:$mime;base64,$base64Data';
  }

  String? _emojiMimeFromExtension(String ext) {
    switch (ext) {
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      default:
        return null;
    }
  }

  String _emojiCacheKey(String url, String? md5) {
    if (md5 != null && md5.isNotEmpty) return md5;
    return url.hashCode.toUnsigned(32).toString();
  }

  Future<String?> _findExistingEmojiCache(
    Directory dir,
    String? md5,
    String url,
  ) async {
    final base = _emojiCacheKey(url, md5);
    for (final ext in const ['.gif', '.png', '.webp', '.jpg', '.jpeg']) {
      final candidate = File(p.join(dir.path, '$base$ext'));
      if (await candidate.exists()) {
        return candidate.path;
      }
    }
    return null;
  }

  Future<String?> _downloadAndCacheEmoji(
    Directory dir,
    String url,
    String? md5,
  ) async {
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      final bytes = response.bodyBytes;
      if (response.statusCode != 200 || bytes.isEmpty) {
        return null;
      }

      final contentType = response.headers['content-type'] ?? '';
      final sniffedExt = _detectImageExtension(bytes);
      final ext = sniffedExt ?? _pickEmojiExtension(url, contentType);
      final base = _emojiCacheKey(url, md5);
      final outPath = p.join(dir.path, '$base$ext');
      final file = File(outPath);
      await file.writeAsBytes(bytes, flush: true);
      return outPath;
    } catch (_) {
      return null;
    }
  }

  String _pickEmojiExtension(String url, String contentType) {
    final uriExt = p.extension(Uri.parse(url).path);
    if (uriExt.isNotEmpty && uriExt.length <= 5) {
      return uriExt;
    }
    final lower = contentType.toLowerCase();
    if (lower.contains('png')) return '.png';
    if (lower.contains('webp')) return '.webp';
    if (lower.contains('jpeg') || lower.contains('jpg')) return '.jpg';
    return '.gif';
  }

  String? _detectImageExtension(List<int> bytes) {
    if (bytes.length < 12) return null;
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      return '.gif';
    }
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return '.png';
    }
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return '.jpg';
    }
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: _isGenerating || _isHtmlLoading
          ? _buildGeneratingView()
          : _errorMessage != null
          ? _buildErrorView()
          : _reportHtml != null
          ? _buildReportReadyView()
          : _buildSelectionView(),
    );
  }

  Widget _buildSelectionView() {
    return ListView(
      key: const ValueKey('dual_report_selection'),
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Theme.of(context).primaryColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '从聊天排行中选择一位好友生成双人报告',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildRankingCard(),
      ],
    );
  }

  Widget _buildRankingCard() {
    if (widget.rankings.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('暂无聊天排行数据')),
        ),
      );
    }

    final visibleRankings = widget.rankings.take(_topN).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '聊天排行 Top $_topN',
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
                    setState(() {
                      _topN = newSelection.first;
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
            Column(
              children: visibleRankings.asMap().entries.map((entry) {
                final index = entry.key;
                final ranking = entry.value;
                final appState = Provider.of<AppState>(context);
                final avatarUrl = appState.getAvatarUrl(ranking.username);
                return ListTile(
                  key: ValueKey('${ranking.username}_dual_$index'),
                  leading: _AvatarWithRank(
                    avatarUrl: avatarUrl,
                    rank: index + 1,
                    displayName: ranking.displayName,
                  ),
                  title: Text(
                    StringUtils.cleanOrDefault(
                      ranking.displayName,
                      ranking.username,
                    ),
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '发送 ${ranking.sentCount} | 接收 ${ranking.receivedCount}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  trailing: Text(
                    '${ranking.messageCount}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  onTap: () => _generateReportFor(ranking),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGeneratingView() {
    return Center(
      key: const ValueKey('dual_report_generating'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 200,
              height: 200,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 200,
                    height: 200,
                    child: TweenAnimationBuilder<double>(
                      duration: const Duration(milliseconds: 600),
                      curve: Curves.easeInOut,
                      tween: Tween<double>(
                        begin: 0,
                        end: _totalProgress / 100,
                      ),
                      builder: (context, value, child) {
                        return CircularProgressIndicator(
                          value: value,
                          strokeWidth: 12,
                          backgroundColor: Colors.grey[200],
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            _wechatGreen,
                          ),
                        );
                      },
                    ),
                  ),
                  TweenAnimationBuilder<double>(
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeInOut,
                    tween: Tween<double>(
                      begin: 0,
                      end: _totalProgress.toDouble(),
                    ),
                    builder: (context, value, child) {
                      return Text(
                        '${value.toInt()}%',
                        style: const TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          color: _wechatGreen,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (currentChild, previousChildren) {
                return Stack(
                  alignment: Alignment.center,
                  children: [...previousChildren, if (currentChild != null) currentChild],
                );
              },
              transitionBuilder: (Widget child, Animation<double> animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: _currentTaskName.isNotEmpty
                  ? Column(
                      key: ValueKey<String>(
                        '$_currentTaskName-$_currentTaskStatus',
                      ),
                      children: [
                        Text(
                          _currentTaskName,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 300),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: _currentTaskStatus == '已完成'
                                    ? _wechatGreen
                                    : Colors.grey[600],
                              ) ??
                              TextStyle(
                                fontWeight: FontWeight.w600,
                                color: _currentTaskStatus == '已完成'
                                    ? _wechatGreen
                                    : Colors.grey[600],
                              ),
                          child: Text(
                            _currentTaskStatus,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(key: ValueKey<String>('empty')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      key: const ValueKey('dual_report_error'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 64, color: Colors.red),
          const SizedBox(height: 16),
          Text(
            _errorMessage ?? '生成失败',
            style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _errorMessage = null;
                _reportHtml = null;
                _reportData = null;
                _selectedFriend = null;
              });
            },
            child: const Text('返回选择'),
          ),
        ],
      ),
    );
  }

  Widget _buildReportReadyView() {
    if (!Platform.isWindows) {
      return Center(
        key: const ValueKey('dual_report_platform'),
        child: Text(
          '双人报告 HTML 仅支持 Windows 平台',
          style: TextStyle(color: Colors.grey[700]),
        ),
      );
    }

    return Container(
      key: const ValueKey('dual_report_ready'),
      color: const Color(0xFFF7F7F5),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                constraints: const BoxConstraints(maxWidth: 560),
                padding: const EdgeInsets.symmetric(
                  horizontal: 36,
                  vertical: 32,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 30,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE6F6EE),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Icon(
                        Icons.public,
                        size: 32,
                        color: _wechatGreen,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '双人报告已生成',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[900],
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '前往浏览器预览',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF6F6F4),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '本地预览地址',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            _reportUrl ?? '尚未启动（点击打开或刷新预览）',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[800],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '提示：建议使用 Chrome 或 Edge 浏览器以获得最佳预览效果',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed:
                              _isOpeningBrowser ? null : _openReportInBrowser,
                          icon: _isOpeningBrowser
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.open_in_new),
                          label: const Text('打开浏览器'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _wechatGreen,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: _isHtmlLoading ? null : _refreshPreview,
                          icon: const Icon(Icons.refresh),
                          label: const Text('刷新预览'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _wechatGreen,
                            side: const BorderSide(color: _wechatGreen),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _handleBack,
                      style: TextButton.styleFrom(foregroundColor: Colors.grey),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
