import 'dart:async';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../services/database_service.dart';
import '../services/advanced_analytics_service.dart';
import '../services/response_time_analyzer.dart';
import '../services/former_friend_analyzer.dart';
import '../services/logger_service.dart';
import '../models/advanced_analytics_data.dart';

/// Isolate 通信消息
class _AnalyticsMessage {
  final String type; // 'progress' | 'error' | 'done' | 'log'
  final String? stage; // 当前分析阶段
  final int? current;
  final int? total;
  final String? detail; // 详细信息
  final int? elapsedSeconds; // 已用时间（秒）
  final int? estimatedRemainingSeconds; // 预估剩余时间（秒）
  final dynamic result;
  final String? error;
  final String? logMessage; // 日志消息
  final String? logLevel; // 日志级别: 'info' | 'warning' | 'error' | 'debug'

  _AnalyticsMessage({
    required this.type,
    this.stage,
    this.current,
    this.total,
    this.detail,
    this.elapsedSeconds,
    this.estimatedRemainingSeconds,
    this.result,
    this.error,
    this.logMessage,
    this.logLevel,
  });
}

/// 分析任务参数
class _AnalyticsTask {
  final String dbPath;
  final String? filterUsername; // 如果指定，只分析特定用户
  final int? filterYear;
  final String analysisType;
  final SendPort sendPort;
  final RootIsolateToken rootIsolateToken;

  _AnalyticsTask({
    required this.dbPath,
    this.filterUsername,
    this.filterYear,
    required this.analysisType,
    required this.sendPort,
    required this.rootIsolateToken,
  });
}

/// 分析进度回调函数类型
/// 用来实时报告分析进度和状态信息
///
/// 参数说明：
/// - [stage]: 当前分析阶段的描述（如"加载数据"、"处理用户"等）
/// - [current]: 当前进度值
/// - [total]: 总进度值
/// - [detail]: 详细信息，比如当前正在处理哪个用户
/// - [elapsedSeconds]: 已经用去的时间（秒）
/// - [estimatedRemainingSeconds]: 预计还需的时间（秒）
typedef AnalyticsProgressCallback =
    void Function(
      String stage,
      int current,
      int total, {
      String? detail,
      int? elapsedSeconds,
      int? estimatedRemainingSeconds,
    });

/// 后台分析服务（使用独立Isolate）
/// 通过独立的Isolate执行数据库操作，避免阻塞主线程
/// 所有分析任务都在后台运行，只返回最终结果
class AnalyticsBackgroundService {
  final String dbPath;

  AnalyticsBackgroundService(this.dbPath);

  /// 在后台分析作息规律
  Future<ActivityHeatmap> analyzeActivityPatternInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'activity',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return ActivityHeatmap.fromJson(result);
  }

  /// 在后台分析语言风格
  Future<LinguisticStyle> analyzeLinguisticStyleInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'linguistic',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return LinguisticStyle.fromJson(result);
  }

  /// 在后台分析哈哈哈报告
  Future<Map<String, dynamic>> analyzeHahaReportInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    return await _runAnalysisInIsolate(
      analysisType: 'haha',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
  }

  /// 在后台查找深夜密谈之王
  Future<Map<String, dynamic>> findMidnightChatKingInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    return await _runAnalysisInIsolate(
      analysisType: 'midnight',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
  }

  /// 在后台生成亲密度日历
  Future<IntimacyCalendar> generateIntimacyCalendarInBackground(
    String username,
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'intimacy',
      filterUsername: username,
      filterYear: filterYear,
      progressCallback: progressCallback,
    );

    // 反序列化 DateTime
    final dailyMessages = <DateTime, int>{};
    final dailyMessagesRaw = result['dailyMessages'] as Map<String, dynamic>;
    dailyMessagesRaw.forEach((key, value) {
      dailyMessages[DateTime.parse(key)] = value as int;
    });

    return IntimacyCalendar(
      username: result['username'] as String,
      dailyMessages: dailyMessages,
      startDate: DateTime.parse(result['startDate'] as String),
      endDate: DateTime.parse(result['endDate'] as String),
      maxDailyCount: result['maxDailyCount'] as int,
    );
  }

  /// 在后台分析对话天平
  Future<ConversationBalance> analyzeConversationBalanceInBackground(
    String username,
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'balance',
      filterUsername: username,
      filterYear: filterYear,
      progressCallback: progressCallback,
    );

    return ConversationBalance(
      username: result['username'] as String,
      sentCount: result['sentCount'] as int,
      receivedCount: result['receivedCount'] as int,
      sentWords: result['sentWords'] as int,
      receivedWords: result['receivedWords'] as int,
      initiatedByMe: result['initiatedByMe'] as int,
      initiatedByOther: result['initiatedByOther'] as int,
      conversationSegments: result['conversationSegments'] as int,
      segmentsInitiatedByMe: result['segmentsInitiatedByMe'] as int,
      segmentsInitiatedByOther: result['segmentsInitiatedByOther'] as int,
    );
  }

  /// 在后台分析谁回复我最快
  Future<List<Map<String, dynamic>>> analyzeWhoRepliesFastestInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'who_replies_fastest',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );

    return (result['results'] as List).cast<Map<String, dynamic>>();
  }

  /// 在后台分析我回复谁最快
  Future<List<Map<String, dynamic>>> analyzeMyFastestRepliesInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'my_fastest_replies',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );

    return (result['results'] as List).cast<Map<String, dynamic>>();
  }

  /// 通用 Isolate 分析执行器
  Future<dynamic> _runAnalysisInIsolate({
    required String analysisType,
    String? filterUsername,
    int? filterYear,
    required AnalyticsProgressCallback progressCallback,
  }) async {
    ReceivePort? receivePort;
    try {
      await logger.debug('RunAnalysis', '========== 开始分析任务 ==========');
      await logger.debug('RunAnalysis', '任务类型: $analysisType');
      await logger.debug('RunAnalysis', '过滤年份: ${filterYear ?? "全部"}');
      await logger.debug('RunAnalysis', '过滤用户: ${filterUsername ?? "全部"}');
      await logger.debug('RunAnalysis', '数据库路径: $dbPath');

      receivePort = ReceivePort();
      final task = _AnalyticsTask(
        dbPath: dbPath,
        filterUsername: filterUsername,
        filterYear: filterYear,
        analysisType: analysisType,
        sendPort: receivePort.sendPort,
        rootIsolateToken: ServicesBinding.rootIsolateToken!,
      );

      await logger.debug('RunAnalysis', '准备启动Isolate: $analysisType');

      // 添加错误和退出监听
      final errorPort = ReceivePort();
      final exitPort = ReceivePort();

      // 启动 Isolate
      final startTime = DateTime.now();
      final isolate = await Isolate.spawn(
        _analyzeInIsolate,
        task,
        debugName: 'Analytics-$analysisType',
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
      );

      await logger.debug(
        'RunAnalysis',
        'Isolate已启动: $analysisType, ID: ${isolate.debugName}',
      );

      // 监听错误
      errorPort.listen((errorData) async {
        await logger.error(
          'RunAnalysis',
          'Isolate错误: $analysisType',
          errorData,
        );
      });

      // 监听退出
      exitPort.listen((exitData) async {
        await logger.debug(
          'RunAnalysis',
          'Isolate退出: $analysisType, 退出数据: $exitData',
        );
      });

      await logger.debug('RunAnalysis', '开始监听消息: $analysisType');

      // 监听进度消息
      dynamic result;
      int messageCount = 0;
      await for (final message in receivePort) {
        messageCount++;
        await logger.debug(
          'RunAnalysis',
          '收到消息 #$messageCount: $analysisType, 类型: ${message.runtimeType}',
        );

        if (message is _AnalyticsMessage) {
          if (message.type == 'log') {
            final logMsg = message.logMessage ?? '';
            final level = message.logLevel ?? 'info';
            switch (level) {
              case 'error':
                await logger.error('Isolate-$analysisType', logMsg);
                break;
              case 'warning':
                await logger.warning('Isolate-$analysisType', logMsg);
                break;
              case 'debug':
                await logger.debug('Isolate-$analysisType', logMsg);
                break;
              default:
                await logger.info('Isolate-$analysisType', logMsg);
            }
          } else if (message.type == 'progress') {
            await logger.debug(
              'RunAnalysis',
              '进度更新: $analysisType - ${message.stage} (${message.current}/${message.total})',
            );
            progressCallback(
              message.stage ?? '',
              message.current ?? 0,
              message.total ?? 100,
              detail: message.detail,
              elapsedSeconds: message.elapsedSeconds,
              estimatedRemainingSeconds: message.estimatedRemainingSeconds,
            );
          } else if (message.type == 'done') {
            final elapsed = DateTime.now().difference(startTime);
            await logger.info(
              'RunAnalysis',
              '任务完成: $analysisType, 耗时: ${elapsed.inSeconds}秒',
            );
            await logger.debug(
              'RunAnalysis',
              '结果数据类型: ${message.result.runtimeType}',
            );
            result = message.result;
            receivePort.close();
            break;
          } else if (message.type == 'error') {
            await logger.error(
              'RunAnalysis',
              '任务失败: $analysisType, 错误: ${message.error}',
            );
            receivePort.close();
            throw Exception(message.error);
          }
        } else {
          await logger.warning(
            'RunAnalysis',
            '收到未知类型的消息: ${message.runtimeType}',
          );
        }
      }

      await logger.debug(
        'RunAnalysis',
        '消息监听结束: $analysisType, 共收到 $messageCount 条消息',
      );
      await logger.debug('RunAnalysis', '========== 任务完成 ==========');

      // 清理监听
      errorPort.close();
      exitPort.close();

      return result;
    } catch (e) {
      await logger.error('RunAnalysis', '捕获异常: $analysisType, 错误: $e');
      // 确保receivePort被关闭
      receivePort?.close();
      rethrow;
    }
  }

  /// 后台 Isolate 分析入口函数
  static Future<void> _analyzeInIsolate(_AnalyticsTask task) async {
    if (!logger.isInIsolateMode) {
      logger.enableIsolateMode();
    }

    runZonedGuarded(
      () async {
        // 辅助函数：发送日志到主线程
        void sendLog(String message, {String level = 'info'}) {
          if (message.isEmpty) return;
          task.sendPort.send(
            _AnalyticsMessage(
              type: 'log',
              logMessage: message,
              logLevel: level,
            ),
          );
        }

        DatabaseService? dbService;
        try {
          sendLog('========== Isolate任务开始 ==========', level: 'debug');
          sendLog('任务类型: ${task.analysisType}', level: 'debug');
          sendLog('过滤年份: ${task.filterYear ?? "全部"}', level: 'debug');
          sendLog('数据库路径: ${task.dbPath}', level: 'debug');

          // 不需要初始化 BackgroundIsolateBinaryMessenger，因为我们不使用平台通道
          // 避免在release模式下stdout写入导致的错误
          sendLog(
            '跳过 BackgroundIsolateBinaryMessenger 初始化（Isolate中不需要）',
            level: 'debug',
          );

          sqfliteFfiInit();
          sendLog('sqflite_ffi 初始化完成', level: 'debug');

          final startTime = DateTime.now();

          task.sendPort.send(
            _AnalyticsMessage(
              type: 'progress',
              stage: '正在打开数据库...',
              current: 0,
              total: 100,
              elapsedSeconds: 0,
              estimatedRemainingSeconds: 60,
            ),
          );

          sendLog('创建 DatabaseService', level: 'debug');
          dbService = DatabaseService();

          sendLog('初始化 DatabaseService', level: 'debug');
          await dbService
              .initialize(factory: databaseFactoryFfi)
              .timeout(
                const Duration(seconds: 30),
                onTimeout: () {
                  sendLog('初始化 DatabaseService 超时', level: 'error');
                  throw TimeoutException('初始化 DatabaseService 超时');
                },
              );
          sendLog('DatabaseService 初始化完成', level: 'debug');

          sendLog('开始连接数据库: ${task.dbPath}', level: 'debug');
          try {
            await dbService
                .connectDecryptedDatabase(
                  task.dbPath,
                  factory: databaseFactoryFfi,
                )
                .timeout(
                  const Duration(seconds: 30),
                  onTimeout: () {
                    sendLog('连接数据库超时', level: 'error');
                    throw TimeoutException('连接数据库超时，可能数据库文件被占用');
                  },
                );
            sendLog('数据库连接成功', level: 'debug');
          } catch (e) {
            sendLog('数据库连接失败: $e', level: 'error');
            rethrow;
          }

          task.sendPort.send(
            _AnalyticsMessage(
              type: 'progress',
              stage: '正在分析数据...',
              current: 30,
              total: 100,
              elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
              estimatedRemainingSeconds: _estimateRemainingTime(
                30,
                100,
                startTime,
              ),
            ),
          );

          sendLog('创建 AdvancedAnalyticsService', level: 'debug');
          final analyticsService = AdvancedAnalyticsService(dbService);
          if (task.filterYear != null) {
            analyticsService.setYearFilter(task.filterYear);
            sendLog('设置年份过滤: ${task.filterYear}', level: 'debug');
          }

          dynamic result;
          sendLog('开始执行分析: ${task.analysisType}', level: 'debug');

          switch (task.analysisType) {
            case 'activity':
              sendLog('开始分析作息规律', level: 'debug');
              task.sendPort.send(
                _AnalyticsMessage(
                  type: 'progress',
                  stage: '正在分析作息规律...',
                  current: 50,
                  total: 100,
                  elapsedSeconds: DateTime.now()
                      .difference(startTime)
                      .inSeconds,
                  estimatedRemainingSeconds: _estimateRemainingTime(
                    50,
                    100,
                    startTime,
                  ),
                ),
              );
              final data = await analyticsService.analyzeActivityPattern();
              sendLog('作息规律分析完成，最大值: ${data.maxCount}', level: 'debug');
              result = data.toJson();
              break;

            case 'midnight':
              sendLog('开始寻找深夜密谈之王', level: 'debug');
              task.sendPort.send(
                _AnalyticsMessage(
                  type: 'progress',
                  stage: '正在寻找深夜密谈之王...',
                  current: 50,
                  total: 100,
                  elapsedSeconds: DateTime.now()
                      .difference(startTime)
                      .inSeconds,
                  estimatedRemainingSeconds: _estimateRemainingTime(
                    50,
                    100,
                    startTime,
                  ),
                ),
              );
              result = await analyticsService.findMidnightChatKing();
              sendLog('深夜密谈之王分析完成', level: 'debug');
              break;

            case 'who_replies_fastest':
              sendLog('========== 开始分析谁回复最快 ==========', level: 'debug');
              sendLog('创建 ResponseTimeAnalyzer', level: 'debug');
              final analyzer = ResponseTimeAnalyzer(dbService);
              if (task.filterYear != null) {
                analyzer.setYearFilter(task.filterYear);
                sendLog('设置年份过滤: ${task.filterYear}', level: 'debug');
              }

              sendLog('调用 analyzeWhoRepliesFastest', level: 'debug');
              final analysisStartTime = DateTime.now();
              final results = await analyzer.analyzeWhoRepliesFastest(
                onProgress: (current, total, username) {
                  final elapsed = DateTime.now()
                      .difference(startTime)
                      .inSeconds;
                  sendLog(
                    '分析进度: $current/$total, 当前用户: $username',
                    level: 'debug',
                  );
                  task.sendPort.send(
                    _AnalyticsMessage(
                      type: 'progress',
                      stage: '正在分析响应速度...',
                      current: current,
                      total: total,
                      detail: username,
                      elapsedSeconds: elapsed,
                      estimatedRemainingSeconds: _estimateRemainingTime(
                        current,
                        total,
                        startTime,
                      ),
                    ),
                  );
                },
                onLog: (message, {String level = 'info'}) {
                  sendLog(message, level: level);
                },
              );
              final analysisElapsed = DateTime.now().difference(
                analysisStartTime,
              );
              sendLog(
                'analyzeWhoRepliesFastest 完成，耗时: ${analysisElapsed.inSeconds}秒',
                level: 'debug',
              );

              sendLog('谁回复最快分析完成，找到 ${results.length} 个结果', level: 'info');
              if (results.isNotEmpty) {
                sendLog('前3名结果:', level: 'info');
                for (int i = 0; i < results.length && i < 3; i++) {
                  final r = results[i];
                  sendLog(
                    '  ${i + 1}. ${r.displayName}: 平均${r.avgResponseTimeMinutes.toStringAsFixed(1)}分钟 (${r.totalResponses}次)',
                    level: 'info',
                  );
                }
              } else {
                sendLog('警告：分析完成但没有找到任何结果！', level: 'warning');
                sendLog('可能原因：', level: 'warning');
                sendLog('  1. 没有私聊会话', level: 'warning');
                sendLog('  2. 所有会话都没有找到响应模式', level: 'warning');
                sendLog('  3. 所有响应时间都超过24小时', level: 'warning');
              }

              sendLog('转换结果为 JSON', level: 'debug');
              final jsonResults = results.map((r) => r.toJson()).toList();
              sendLog('JSON 结果数量: ${jsonResults.length}', level: 'debug');

              result = {'results': jsonResults};
              sendLog('========== 谁回复最快分析完成 ==========', level: 'debug');
              break;

            case 'my_fastest_replies':
              sendLog('========== 开始分析我回复最快 ==========', level: 'debug');
              sendLog('创建 ResponseTimeAnalyzer', level: 'debug');
              final analyzer2 = ResponseTimeAnalyzer(dbService);
              if (task.filterYear != null) {
                analyzer2.setYearFilter(task.filterYear);
                sendLog('设置年份过滤: ${task.filterYear}', level: 'debug');
              }

              sendLog('调用 analyzeMyFastestReplies', level: 'debug');
              final analysisStartTime2 = DateTime.now();
              final results2 = await analyzer2.analyzeMyFastestReplies(
                onProgress: (current, total, username) {
                  final elapsed = DateTime.now()
                      .difference(startTime)
                      .inSeconds;
                  sendLog(
                    '分析进度: $current/$total, 当前用户: $username',
                    level: 'debug',
                  );
                  task.sendPort.send(
                    _AnalyticsMessage(
                      type: 'progress',
                      stage: '正在分析我的响应速度...',
                      current: current,
                      total: total,
                      detail: username,
                      elapsedSeconds: elapsed,
                      estimatedRemainingSeconds: _estimateRemainingTime(
                        current,
                        total,
                        startTime,
                      ),
                    ),
                  );
                },
                onLog: (message, {String level = 'info'}) {
                  sendLog(message, level: level);
                },
              );
              final analysisElapsed2 = DateTime.now().difference(
                analysisStartTime2,
              );
              sendLog(
                'analyzeMyFastestReplies 完成，耗时: ${analysisElapsed2.inSeconds}秒',
                level: 'debug',
              );

              sendLog('我回复最快分析完成，找到 ${results2.length} 个结果', level: 'info');
              if (results2.isNotEmpty) {
                sendLog('前3名结果:', level: 'info');
                for (int i = 0; i < results2.length && i < 3; i++) {
                  final r = results2[i];
                  sendLog(
                    '  ${i + 1}. ${r.displayName}: 平均${r.avgResponseTimeMinutes.toStringAsFixed(1)}分钟 (${r.totalResponses}次)',
                    level: 'info',
                  );
                }
              } else {
                sendLog('警告：分析完成但没有找到任何结果！', level: 'warning');
                sendLog('可能原因：', level: 'warning');
                sendLog('  1. 没有私聊会话', level: 'warning');
                sendLog('  2. 所有会话都没有找到响应模式', level: 'warning');
                sendLog('  3. 所有响应时间都超过24小时', level: 'warning');
              }

              sendLog('转换结果为 JSON', level: 'debug');
              final jsonResults2 = results2.map((r) => r.toJson()).toList();
              sendLog('JSON 结果数量: ${jsonResults2.length}', level: 'debug');

              result = {'results': jsonResults2};
              sendLog('========== 我回复最快分析完成 ==========', level: 'debug');
              break;

            case 'former_friends':
              sendLog('========== 开始分析曾经的好朋友 ==========', level: 'debug');
              sendLog('创建 FormerFriendAnalyzer', level: 'debug');
              final formerFriendAnalyzer = FormerFriendAnalyzer(dbService);
              if (task.filterYear != null) {
                formerFriendAnalyzer.setYearFilter(task.filterYear);
                sendLog('设置年份过滤: ${task.filterYear}', level: 'debug');
              }

              sendLog('调用 analyzeFormerFriends', level: 'debug');
              final formerFriendsStartTime = DateTime.now();
              final formerFriendsData = await formerFriendAnalyzer
                  .analyzeFormerFriends(
                    onProgress: (current, total, username) {
                      final elapsed = DateTime.now()
                          .difference(startTime)
                          .inSeconds;
                      sendLog(
                        '分析进度: $current/$total, 当前用户: $username',
                        level: 'debug',
                      );
                      task.sendPort.send(
                        _AnalyticsMessage(
                          type: 'progress',
                          stage: '正在分析曾经的好朋友...',
                          current: current,
                          total: total,
                          detail: username,
                          elapsedSeconds: elapsed,
                          estimatedRemainingSeconds: _estimateRemainingTime(
                            current,
                            total,
                            startTime,
                          ),
                        ),
                      );
                    },
                    onLog: (message, {String level = 'info'}) {
                      sendLog(message, level: level);
                    },
                  );
              final formerFriendsElapsed = DateTime.now().difference(
                formerFriendsStartTime,
              );
              sendLog(
                'analyzeFormerFriends 完成，耗时: ${formerFriendsElapsed.inSeconds}秒',
                level: 'debug',
              );

              final formerFriendsResults =
                  formerFriendsData['results'] as List<FormerFriendResult>;
              final stats = formerFriendsData['stats'] as Map<String, dynamic>;

              sendLog(
                '曾经的好朋友分析完成，找到 ${formerFriendsResults.length} 个结果',
                level: 'info',
              );
              sendLog('统计: ${stats.toString()}', level: 'info');

              if (formerFriendsResults.isNotEmpty) {
                sendLog('前3名结果:', level: 'info');
                for (int i = 0; i < formerFriendsResults.length && i < 3; i++) {
                  final r = formerFriendsResults[i];
                  sendLog(
                    '  ${i + 1}. ${r.displayName}: 活跃期${r.activeDays}天, 已${r.daysSinceActive}天未联系',
                    level: 'info',
                  );
                }
              } else {
                sendLog('警告：分析完成但没有找到任何结果！', level: 'warning');
              }

              sendLog('转换结果为 JSON', level: 'debug');
              final formerFriendsJson = formerFriendsResults
                  .map((r) => r.toJson())
                  .toList();
              sendLog('JSON 结果数量: ${formerFriendsJson.length}', level: 'debug');

              result = {'results': formerFriendsJson, 'stats': stats};
              sendLog('========== 曾经的好朋友分析完成 ==========', level: 'debug');
              break;

            case 'absoluteCoreFriends':
              sendLog('开始统计绝对核心好友', level: 'debug');
              task.sendPort.send(
                _AnalyticsMessage(
                  type: 'progress',
                  stage: '正在统计绝对核心好友...',
                  current: 50,
                  total: 100,
                  elapsedSeconds: DateTime.now()
                      .difference(startTime)
                      .inSeconds,
                  estimatedRemainingSeconds: _estimateRemainingTime(
                    50,
                    100,
                    startTime,
                  ),
                ),
              );
              // 获取所有好友统计以计算总数
              final allCoreFriends = await analyticsService
                  .getAbsoluteCoreFriends(999999);
              sendLog('获取到 ${allCoreFriends.length} 个好友', level: 'debug');
              // 只取前3名用于展示
              final top3 = allCoreFriends.take(3).toList();
              // 计算总消息数和总好友数
              int totalMessages = 0;
              for (var friend in allCoreFriends) {
                totalMessages += friend.count;
              }
              sendLog('绝对核心好友统计完成，总消息数: $totalMessages', level: 'debug');
              result = {
                'top3': top3.map((e) => e.toJson()).toList(),
                'totalMessages': totalMessages,
                'totalFriends': allCoreFriends.length,
              };
              break;

            case 'confidantObjects':
              sendLog('开始统计年度倾诉对象', level: 'debug');
              task.sendPort.send(
                _AnalyticsMessage(
                  type: 'progress',
                  stage: '正在统计年度倾诉对象...',
                  current: 50,
                  total: 100,
                  elapsedSeconds: DateTime.now()
                      .difference(startTime)
                      .inSeconds,
                  estimatedRemainingSeconds: _estimateRemainingTime(
                    50,
                    100,
                    startTime,
                  ),
                ),
              );
              final confidants = await analyticsService.getConfidantObjects(3);
              sendLog('年度倾诉对象统计完成，找到 ${confidants.length} 个', level: 'debug');
              result = confidants.map((e) => e.toJson()).toList();
              break;

            case 'bestListeners':
              sendLog('开始统计年度最佳听众', level: 'debug');
              task.sendPort.send(
                _AnalyticsMessage(
                  type: 'progress',
                  stage: '正在统计年度最佳听众...',
                  current: 50,
                  total: 100,
                  elapsedSeconds: DateTime.now()
                      .difference(startTime)
                      .inSeconds,
                  estimatedRemainingSeconds: _estimateRemainingTime(
                    50,
                    100,
                    startTime,
                  ),
                ),
              );
              final listeners = await analyticsService.getBestListeners(3);
              sendLog('年度最佳听众统计完成，找到 ${listeners.length} 个', level: 'debug');
              result = listeners.map((e) => e.toJson()).toList();
              break;

            case 'monthlyTopFriends':
              sendLog('开始统计月度好友', level: 'debug');
              task.sendPort.send(
                _AnalyticsMessage(
                  type: 'progress',
                  stage: '正在统计月度好友...',
                  current: 50,
                  total: 100,
                  elapsedSeconds: DateTime.now()
                      .difference(startTime)
                      .inSeconds,
                  estimatedRemainingSeconds: _estimateRemainingTime(
                    50,
                    100,
                    startTime,
                  ),
                ),
              );
              final monthlyTop = await analyticsService.getMonthlyTopFriends();
              sendLog('月度好友统计完成', level: 'debug');
              result = monthlyTop;
              break;

            case 'mutualFriends':
              sendLog('开始统计双向奔赴好友', level: 'debug');
              task.sendPort.send(
                _AnalyticsMessage(
                  type: 'progress',
                  stage: '正在统计双向奔赴好友...',
                  current: 50,
                  total: 100,
                  elapsedSeconds: DateTime.now()
                      .difference(startTime)
                      .inSeconds,
                  estimatedRemainingSeconds: _estimateRemainingTime(
                    50,
                    100,
                    startTime,
                  ),
                ),
              );
              final mutual = await analyticsService.getMutualFriendsRanking(3);
              sendLog('双向奔赴好友统计完成，找到 ${mutual.length} 个', level: 'debug');
              result = mutual.map((e) => e.toJson()).toList();
              break;

            case 'socialInitiative':
              sendLog('开始分析主动社交指数', level: 'debug');
              task.sendPort.send(
                _AnalyticsMessage(
                  type: 'progress',
                  stage: '正在分析主动社交指数...',
                  current: 50,
                  total: 100,
                  elapsedSeconds: DateTime.now()
                      .difference(startTime)
                      .inSeconds,
                  estimatedRemainingSeconds: _estimateRemainingTime(
                    50,
                    100,
                    startTime,
                  ),
                ),
              );
              final socialStyle = await analyticsService
                  .analyzeSocialInitiativeRate();
              sendLog('主动社交指数分析完成', level: 'debug');
              result = socialStyle.toJson();
              break;

            case 'peakChatDay':
              sendLog('开始统计聊天巅峰日', level: 'debug');
              task.sendPort.send(
                _AnalyticsMessage(
                  type: 'progress',
                  stage: '正在统计聊天巅峰日...',
                  current: 50,
                  total: 100,
                  elapsedSeconds: DateTime.now()
                      .difference(startTime)
                      .inSeconds,
                  estimatedRemainingSeconds: _estimateRemainingTime(
                    50,
                    100,
                    startTime,
                  ),
                ),
              );
              final peakDay = await analyticsService.analyzePeakChatDay();
              sendLog('聊天巅峰日统计完成', level: 'debug');
              result = peakDay.toJson();
              break;

            case 'longestCheckIn':
              sendLog('开始统计连续打卡记录', level: 'debug');
              task.sendPort.send(
                _AnalyticsMessage(
                  type: 'progress',
                  stage: '正在统计连续打卡记录...',
                  current: 50,
                  total: 100,
                  elapsedSeconds: DateTime.now()
                      .difference(startTime)
                      .inSeconds,
                  estimatedRemainingSeconds: _estimateRemainingTime(
                    50,
                    100,
                    startTime,
                  ),
                ),
              );
              final checkIn = await analyticsService.findLongestCheckInRecord();
              sendLog('连续打卡记录统计完成，最长: ${checkIn['days']} 天', level: 'debug');
              result = {
                'username': checkIn['username'],
                'displayName': checkIn['displayName'],
                'days': checkIn['days'],
                'startDate': (checkIn['startDate'] as DateTime?)
                    ?.toIso8601String(),
                'endDate': (checkIn['endDate'] as DateTime?)?.toIso8601String(),
              };
              break;

            default:
              sendLog('未知的分析类型: ${task.analysisType}', level: 'error');
              throw Exception('未知的分析类型: ${task.analysisType}');
          }

          final elapsed = DateTime.now().difference(startTime);
          sendLog('分析完成，总耗时: ${elapsed.inSeconds}秒', level: 'debug');
          task.sendPort.send(
            _AnalyticsMessage(
              type: 'progress',
              stage: '分析完成',
              current: 100,
              total: 100,
              elapsedSeconds: elapsed.inSeconds,
              estimatedRemainingSeconds: 0,
            ),
          );

          sendLog('发送完成消息', level: 'debug');
          task.sendPort.send(_AnalyticsMessage(type: 'done', result: result));
          sendLog('========== Isolate任务完成 ==========', level: 'debug');
        } catch (e, stackTrace) {
          task.sendPort.send(
            _AnalyticsMessage(type: 'error', error: e.toString()),
          );
          sendLog('任务失败: ${task.analysisType}, 错误: $e', level: 'error');
          sendLog('堆栈: $stackTrace', level: 'error');
        } finally {
          sendLog('开始清理资源', level: 'debug');
          if (dbService != null) {
            try {
              sendLog('关闭数据库连接', level: 'debug');
              await dbService.close();
              sendLog('数据库连接已关闭', level: 'debug');
            } catch (e) {
              sendLog('关闭数据库失败: $e', level: 'error');
            }
          }
          sendLog('Isolate 退出: ${task.analysisType}', level: 'debug');
        }
      },
      (error, stackTrace) {
        task.sendPort.send(
          _AnalyticsMessage(type: 'error', error: error.toString()),
        );
        task.sendPort.send(
          _AnalyticsMessage(
            type: 'log',
            logMessage: 'runZonedGuarded 捕获错误: $error',
            logLevel: 'error',
          ),
        );
        task.sendPort.send(
          _AnalyticsMessage(
            type: 'log',
            logMessage: '堆栈: $stackTrace',
            logLevel: 'error',
          ),
        );
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          task.sendPort.send(
            _AnalyticsMessage(type: 'log', logMessage: line, logLevel: 'debug'),
          );
        },
      ),
    );
  }

  /// 估计剩余时间（秒）
  static int _estimateRemainingTime(
    int current,
    int total,
    DateTime startTime,
  ) {
    if (current == 0) return 60;
    final elapsed = DateTime.now().difference(startTime).inSeconds;
    if (elapsed == 0) return 60;
    final totalEstimated = (elapsed * total) ~/ current;
    final remaining = totalEstimated - elapsed;
    return remaining.clamp(1, 3600); // 最少1秒，最多1小时
  }

  /// 绝对核心好友（后台版本）
  Future<Map<String, dynamic>> getAbsoluteCoreFriendsInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result =
        await _runAnalysisInIsolate(
              analysisType: 'absoluteCoreFriends',
              filterYear: filterYear,
              progressCallback: progressCallback,
            )
            as Map<String, dynamic>;

    return {
      'top3': (result['top3'] as List)
          .cast<Map<String, dynamic>>()
          .map((e) => FriendshipRanking.fromJson(e))
          .toList(),
      'totalMessages': result['totalMessages'],
      'totalFriends': result['totalFriends'],
    };
  }

  /// 年度倾诉对象（后台版本）
  Future<List<FriendshipRanking>> getConfidantObjectsInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'confidantObjects',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return (result as List)
        .cast<Map<String, dynamic>>()
        .map((e) => FriendshipRanking.fromJson(e))
        .toList();
  }

  /// 年度最佳听众（后台版本）
  Future<List<FriendshipRanking>> getBestListenersInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'bestListeners',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return (result as List)
        .cast<Map<String, dynamic>>()
        .map((e) => FriendshipRanking.fromJson(e))
        .toList();
  }

  /// 月度好友（后台版本）
  Future<Map<String, dynamic>> getMonthlyTopFriendsInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'monthlyTopFriends',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return result as Map<String, dynamic>;
  }

  /// 双向奔赴好友（后台版本）
  Future<List<FriendshipRanking>> getMutualFriendsRankingInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'mutualFriends',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return (result as List)
        .cast<Map<String, dynamic>>()
        .map((e) => FriendshipRanking.fromJson(e))
        .toList();
  }

  /// 主动社交指数（后台版本）
  Future<SocialStyleData> analyzeSocialInitiativeRateInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'socialInitiative',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return SocialStyleData.fromJson(result);
  }

  /// 年度聊天巅峰日（后台版本）
  Future<ChatPeakDay> analyzePeakChatDayInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'peakChatDay',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return ChatPeakDay.fromJson(result);
  }

  /// 连续打卡记录（后台版本）
  Future<Map<String, dynamic>> findLongestCheckInRecordInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'longestCheckIn',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return result;
  }

  /// 消息类型分布（后台版本）
  Future<List<MessageTypeStats>> analyzeMessageTypeDistributionInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'messageTypes',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return (result as List)
        .cast<Map<String, dynamic>>()
        .map((e) => MessageTypeStats.fromJson(e))
        .toList();
  }

  /// 消息长度分析（后台版本）
  Future<MessageLengthData> analyzeMessageLengthInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'messageLength',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return MessageLengthData.fromJson(result);
  }

  /// 曾经的好朋友分析（后台版本）
  Future<Map<String, dynamic>> analyzeFormerFriendsInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'former_friends',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return {
      'results': (result['results'] as List).cast<Map<String, dynamic>>(),
      'stats': result['stats'] as Map<String, dynamic>,
    };
  }

  /// 生成完整年度报告（并行执行所有任务）
  Future<Map<String, dynamic>> generateFullAnnualReport(
    int? filterYear,
    void Function(String taskName, String status, int progress)
    progressCallback,
  ) async {
    await logger.debug('AnnualReport', '========== 开始生成年度报告 ==========');
    await logger.info(
      'AnnualReport',
      '开始生成年度报告, filterYear: $filterYear, dbPath: $dbPath',
    );

    final taskProgress = <String, int>{};
    final taskStatus = <String, String>{};
    final includeFormerFriends = filterYear == null;


    // 初始化任务状态
    final taskNames = [
      '绝对核心好友',
      '年度倾诉对象',
      '年度最佳听众',
      '月度好友',
      '双向奔赴好友',
      '主动社交指数',
      '聊天巅峰日',
      '连续打卡记录',
      '作息图谱',
      '深夜密友',
      '最快响应好友',
      '我回复最快',
      if (includeFormerFriends) '曾经的好朋友',
    ];

    await logger.debug('AnnualReport', '初始化 ${taskNames.length} 个任务');
    for (final name in taskNames) {
      taskProgress[name] = 0;
      taskStatus[name] = '等待中';
    }
    await logger.debug('AnnualReport', '任务列表: ${taskNames.join(", ")}');

    // 创建进度回调包装器
    AnalyticsProgressCallback createProgressCallback(String taskName) {
      return (
        String stage,
        int current,
        int total, {
        String? detail,
        int? elapsedSeconds,
        int? estimatedRemainingSeconds,
      }) {
        taskProgress[taskName] = (current / total * 100).toInt();
        taskStatus[taskName] = current >= total ? '已完成' : '进行中';

        // 计算总体进度
        final totalProgress =
            taskProgress.values.reduce((a, b) => a + b) ~/ taskNames.length;
        logger.debug(
          'AnnualReport',
          '任务进度: $taskName - $stage ($current/$total), 总进度: $totalProgress%',
        );
        progressCallback(taskName, taskStatus[taskName]!, totalProgress);
      };
    }

    // 串行执行所有任务，避免数据库锁定（一次只执行一个Isolate）
    // 每个任务都有5分钟超时保护
    final timeout = const Duration(minutes: 5);
    await logger.debug('AnnualReport', '任务超时设置: ${timeout.inMinutes} 分钟');

    await logger.info('AnnualReport', '开始任务 1/13: 绝对核心好友');
    final coreFriendsData =
        await getAbsoluteCoreFriendsInBackground(
          filterYear,
          createProgressCallback('绝对核心好友'),
        ).timeout(
          timeout,
          onTimeout: () {
            logger.error('AnnualReport', '任务超时: 绝对核心好友');
            throw TimeoutException('分析绝对核心好友超时，数据量可能过大');
          },
        );
    await logger.info('AnnualReport', '完成任务 1/13: 绝对核心好友');

    await logger.info('AnnualReport', '开始任务 2/13: 年度倾诉对象');
    final confidant =
        await getConfidantObjectsInBackground(
          filterYear,
          createProgressCallback('年度倾诉对象'),
        ).timeout(
          timeout,
          onTimeout: () {
            logger.error('AnnualReport', '任务超时: 年度倾诉对象');
            throw TimeoutException('分析年度倾诉对象超时');
          },
        );
    await logger.info('AnnualReport', '完成任务 2/13: 年度倾诉对象');

    await logger.info('AnnualReport', '开始任务 3/13: 年度最佳听众');
    final listeners =
        await getBestListenersInBackground(
          filterYear,
          createProgressCallback('年度最佳听众'),
        ).timeout(
          timeout,
          onTimeout: () {
            logger.error('AnnualReport', '任务超时: 年度最佳听众');
            throw TimeoutException('分析年度最佳听众超时');
          },
        );
    await logger.info('AnnualReport', '完成任务 3/13: 年度最佳听众');

    await logger.info('AnnualReport', '开始任务 4/13: 月度好友');
    final monthlyTopFriendsData =
        await getMonthlyTopFriendsInBackground(
          filterYear,
          createProgressCallback('月度好友'),
        ).timeout(
          timeout,
          onTimeout: () {
            logger.error('AnnualReport', '任务超时: 月度好友');
            throw TimeoutException('分析月度好友超时');
          },
        );
    await logger.info('AnnualReport', '完成任务 4/13: 月度好友');

    await logger.info('AnnualReport', '开始任务 5/13: 双向奔赴好友');
    final mutualFriends =
        await getMutualFriendsRankingInBackground(
          filterYear,
          createProgressCallback('双向奔赴好友'),
        ).timeout(
          timeout,
          onTimeout: () {
            logger.error('AnnualReport', '任务超时: 双向奔赴好友');
            throw TimeoutException('分析双向奔赴好友超时');
          },
        );
    await logger.info('AnnualReport', '完成任务 5/13: 双向奔赴好友');

    await logger.info('AnnualReport', '开始任务 6/13: 主动社交指数');
    final socialInitiative =
        await analyzeSocialInitiativeRateInBackground(
          filterYear,
          createProgressCallback('主动社交指数'),
        ).timeout(
          timeout,
          onTimeout: () {
            logger.error('AnnualReport', '任务超时: 主动社交指数');
            throw TimeoutException('分析主动社交指数超时');
          },
        );
    await logger.info('AnnualReport', '完成任务 6/13: 主动社交指数');

    await logger.info('AnnualReport', '开始任务 7/13: 聊天巅峰日');
    final peakDay =
        await analyzePeakChatDayInBackground(
          filterYear,
          createProgressCallback('聊天巅峰日'),
        ).timeout(
          timeout,
          onTimeout: () {
            logger.error('AnnualReport', '任务超时: 聊天巅峰日');
            throw TimeoutException('分析聊天巅峰日超时');
          },
        );
    await logger.info('AnnualReport', '完成任务 7/13: 聊天巅峰日');

    await logger.info('AnnualReport', '开始任务 8/13: 连续打卡记录');
    final checkIn =
        await findLongestCheckInRecordInBackground(
          filterYear,
          createProgressCallback('连续打卡记录'),
        ).timeout(
          timeout,
          onTimeout: () {
            logger.error('AnnualReport', '任务超时: 连续打卡记录');
            throw TimeoutException('分析连续打卡记录超时');
          },
        );
    await logger.info('AnnualReport', '完成任务 8/13: 连续打卡记录');

    await logger.info('AnnualReport', '开始任务 9/13: 作息图谱');
    final activityPattern =
        await analyzeActivityPatternInBackground(
          filterYear,
          createProgressCallback('作息图谱'),
        ).timeout(
          timeout,
          onTimeout: () {
            logger.error('AnnualReport', '任务超时: 作息图谱');
            throw TimeoutException('分析作息图谱超时');
          },
        );
    await logger.info('AnnualReport', '完成任务 9/13: 作息图谱');

    await logger.info('AnnualReport', '开始任务 10/13: 深夜密友');
    final midnightKing =
        await findMidnightChatKingInBackground(
          filterYear,
          createProgressCallback('深夜密友'),
        ).timeout(
          timeout,
          onTimeout: () {
            logger.error('AnnualReport', '任务超时: 深夜密友');
            throw TimeoutException('分析深夜密友超时');
          },
        );
    await logger.info('AnnualReport', '完成任务 10/13: 深夜密友');

    await logger.info('AnnualReport', '开始任务 11/13: 最快响应好友');
    final whoRepliesFastest =
        await analyzeWhoRepliesFastestInBackground(
          filterYear,
          createProgressCallback('最快响应好友'),
        ).timeout(
          timeout,
          onTimeout: () {
            logger.error('AnnualReport', '任务超时: 最快响应好友');
            throw TimeoutException('分析最快响应好友超时，可能因为好友数量过多');
          },
        );
    await logger.info('AnnualReport', '完成任务 11/13: 最快响应好友');

    await logger.info('AnnualReport', '开始任务 12/13: 我回复最快');
    final myFastestReplies =
        await analyzeMyFastestRepliesInBackground(
          filterYear,
          createProgressCallback('我回复最快'),
        ).timeout(
          timeout,
          onTimeout: () {
            logger.error('AnnualReport', '任务超时: 我回复最快');
            throw TimeoutException('分析我回复最快超时，可能因为好友数量过多');
          },
        );
    await logger.info('AnnualReport', '完成任务 12/13: 我回复最快');

    List<Map<String, dynamic>> formerFriends = [];
    Map<String, dynamic>? formerFriendsStats;

    if (includeFormerFriends) {
      await logger.info('AnnualReport', '开始任务 13/13: 曾经的好朋友');
      final formerFriendsData =
          await analyzeFormerFriendsInBackground(
            filterYear,
            createProgressCallback('曾经的好朋友'),
          ).timeout(
            timeout,
            onTimeout: () {
              logger.error('AnnualReport', '任务超时: 曾经的好朋友');
              throw TimeoutException('分析曾经的好朋友超时');
            },
          );
      await logger.info('AnnualReport', '完成任务 13/13: 曾经的好朋友');

      formerFriends =
          formerFriendsData['results'] as List<Map<String, dynamic>>;
      formerFriendsStats =
          formerFriendsData['stats'] as Map<String, dynamic>;
    }

    // 组装结果
    await logger.debug('AnnualReport', '所有任务完成，开始组装结果');
    await logger.debug(
      'AnnualReport',
      '核心好友数: ${(coreFriendsData['top3'] as List).length}',
    );
    await logger.debug(
      'AnnualReport',
      '总消息数: ${coreFriendsData['totalMessages']}',
    );
    await logger.debug(
      'AnnualReport',
      '总好友数: ${coreFriendsData['totalFriends']}',
    );
    await logger.debug('AnnualReport', '倾诉对象数: ${confidant.length}');
    await logger.debug('AnnualReport', '最佳听众数: ${listeners.length}');
    await logger.debug(
      'AnnualReport',
      '月度好友数: ${(monthlyTopFriendsData['monthlyTopFriends'] as List).length}',
    );
    await logger.debug('AnnualReport', '双向奔赴好友数: ${mutualFriends.length}');
    await logger.debug('AnnualReport', '最快响应好友数: ${whoRepliesFastest.length}');
    await logger.debug('AnnualReport', '我回复最快好友数: ${myFastestReplies.length}');

    // 响应速度数据已经是 List<Map<String, dynamic>> 格式
    await logger.debug('AnnualReport', '响应速度数据类型检查:');
    await logger.debug(
      'AnnualReport',
      '  whoRepliesFastest: ${whoRepliesFastest.runtimeType}, 长度: ${whoRepliesFastest.length}',
    );
    await logger.debug(
      'AnnualReport',
      '  myFastestReplies: ${myFastestReplies.runtimeType}, 长度: ${myFastestReplies.length}',
    );

    if (whoRepliesFastest.isNotEmpty) {
      await logger.debug(
        'AnnualReport',
        '  whoRepliesFastest[0]: ${whoRepliesFastest[0]}',
      );
    }
    if (myFastestReplies.isNotEmpty) {
      await logger.debug(
        'AnnualReport',
        '  myFastestReplies[0]: ${myFastestReplies[0]}',
      );
    }

    final result = {
      'coreFriends': (coreFriendsData['top3'] as List<FriendshipRanking>)
          .map((e) => e.toJson())
          .toList(),
      'totalMessages': coreFriendsData['totalMessages'],
      'totalFriends': coreFriendsData['totalFriends'],
      'confidant': confidant.map((e) => e.toJson()).toList(),
      'listeners': listeners.map((e) => e.toJson()).toList(),
      'monthlyTopFriends': monthlyTopFriendsData['monthlyTopFriends'],
      'selfAvatarUrl': monthlyTopFriendsData['selfAvatarUrl'],
      'mutualFriends': mutualFriends.map((e) => e.toJson()).toList(),
      'socialInitiative': socialInitiative.toJson(),
      'peakDay': peakDay.toJson(),
      'checkIn': checkIn,
      'activityPattern': activityPattern.toJson(),
      'midnightKing': midnightKing,
      'whoRepliesFastest': whoRepliesFastest,
      'myFastestReplies': myFastestReplies,
      'formerFriends': formerFriends,
      'formerFriendsStats': formerFriendsStats,
    };

    await logger.debug(
      'AnnualReport',
      '最终 result 包含的键: ${result.keys.toList()}',
    );
    await logger.debug(
      'AnnualReport',
      '最终 result[whoRepliesFastest]: ${result['whoRepliesFastest'].runtimeType}, 长度: ${(result['whoRepliesFastest'] as List).length}',
    );
    await logger.debug(
      'AnnualReport',
      '最终 result[myFastestReplies]: ${result['myFastestReplies'].runtimeType}, 长度: ${(result['myFastestReplies'] as List).length}',
    );

    await logger.info('AnnualReport', '年度报告生成完成');
    await logger.debug('AnnualReport', '========== 年度报告生成完成 ==========');
    return result;
  }
}
