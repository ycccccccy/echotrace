import 'dart:async';
import 'dart:isolate';
import 'package:flutter/material.dart';
import '../services/dual_report_service.dart';
import '../services/dual_report_cache_service.dart';
import '../providers/app_state.dart';
import 'package:provider/provider.dart';
import 'friend_selector_page.dart';
import 'dual_report_display_page.dart';

/// 双人报告主页面
class DualReportPage extends StatefulWidget {
  const DualReportPage({super.key});

  @override
  State<DualReportPage> createState() => _DualReportPageState();
}

class _DualReportPageState extends State<DualReportPage> {
  bool _isGenerating = false;
  String _currentTaskName = '';
  String _currentTaskStatus = '';
  int _totalProgress = 0;
  String _friendDisplayName = '好友';
  Isolate? _reportIsolate;
  ReceivePort? _reportPort;
  ReceivePort? _reportExitPort;
  ReceivePort? _reportErrorPort;
  StreamSubscription? _reportSubscription;
  StreamSubscription? _reportExitSubscription;
  StreamSubscription? _reportErrorSubscription;
  Completer<Map<String, dynamic>>? _reportCompleter;

  @override
  void initState() {
    super.initState();
    // 在frame渲染完成后直接显示好友列表
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectFriend();
    });
  }

  @override
  void dispose() {
    _disposeReportIsolate(canceled: true);
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

  Future<Map<String, dynamic>> _generateReportInIsolate({
    required String dbPath,
    required String friendUsername,
    required String? manualWxid,
  }) async {
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
          'friendUsername': friendUsername,
          'filterYear': null,
          'manualWxid': manualWxid,
        },
        onExit: exitPort.sendPort,
        onError: errorPort.sendPort,
        debugName: 'dual-report',
      );
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
      _disposeReportIsolate();
    }

    return completer.future;
  }

  Future<void> _selectFriend() async {
    final appState = Provider.of<AppState>(context, listen: false);
    final databaseService = appState.databaseService;
    final dualReportService = DualReportService(databaseService);

    if (!mounted) return;

    // 打开好友选择页面
    final selectedFriend = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => FriendSelectorPage(
          dualReportService: dualReportService,
          year: null, // 不限年份
        ),
      ),
    );

    if (selectedFriend == null) {
      // 用户取消选择，返回上一页
      if (mounted) Navigator.pop(context);
      return;
    }

    setState(() {
      _friendDisplayName =
          selectedFriend['displayName'] as String? ?? '好友';
    });

    // 生成完整的双人报告
    if (!mounted) return;
    await _generateReport(friendUsername: selectedFriend['username'] as String);
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
  }

  Future<void> _generateReport({required String friendUsername}) async {
    try {
      if (mounted) {
        setState(() {
          _isGenerating = true;
          _currentTaskName = '准备生成双人报告';
          _currentTaskStatus = '处理中';
          _totalProgress = 0;
        });
      }

      final appState = Provider.of<AppState>(context, listen: false);
      final dbPath = appState.databaseService.dbPath;
      if (dbPath == null || dbPath.isEmpty) {
        throw StateError('database path missing');
      }
      final manualWxid = await appState.configService.getManualWxid();

      // 首先检查缓存
      await _updateProgress('检查缓存', '处理中', 10);
      final cachedData = await DualReportCacheService.loadReport(
        friendUsername,
        null,
      );
      if (cachedData != null) {
        await _updateProgress('检查缓存', '已完成', 100);
        // 使用缓存数据
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => DualReportDisplayPage(reportData: cachedData),
          ),
        );
        return;
      }

      await _updateProgress('检查缓存', '已完成', 12);

      // 生成完整的双人报告数据
      final reportData = await _generateReportInIsolate(
        dbPath: dbPath,
        friendUsername: friendUsername,
        manualWxid: manualWxid,
      );

      // 保存到缓存
      await _updateProgress('保存报告', '处理中', 96);
      await DualReportCacheService.saveReport(friendUsername, null, reportData);
      await _updateProgress('保存报告', '已完成', 100);

      if (!mounted) return;

      // 跳转到报告展示页面
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => DualReportDisplayPage(reportData: reportData),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      // 显示错误信息
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('生成报告失败: $e')));
      Navigator.pop(context);
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isGenerating) {
      return _buildGeneratingScreen();
    }

    return const Scaffold(
      backgroundColor: Color(0xFF07C160),
      body: Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
        ),
      ),
    );
  }

  Widget _buildGeneratingScreen() {
    return Theme(
      data: ThemeData(
        fontFamily: 'HarmonyOS Sans SC',
        textTheme: const TextTheme().apply(fontFamily: 'HarmonyOS Sans SC'),
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: const Text(
            '生成双人报告',
            style: TextStyle(fontFamily: 'HarmonyOS Sans SC'),
          ),
          backgroundColor: Colors.white,
          elevation: 0,
          foregroundColor: Colors.black87,
        ),
        body: Center(
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
                                Color(0xFF07C160),
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
                              color: Color(0xFF07C160),
                              fontFamily: 'HarmonyOS Sans SC',
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  '正在生成 $_friendDisplayName 的双人报告',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                    fontFamily: 'HarmonyOS Sans SC',
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (currentChild, previousChildren) {
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        ...previousChildren,
                        if (currentChild != null) currentChild,
                      ],
                    );
                  },
                  transitionBuilder:
                      (Widget child, Animation<double> animation) {
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
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                color: Colors.black87,
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 300),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: _currentTaskStatus == '已完成'
                                    ? const Color(0xFF07C160)
                                    : Colors.grey[600],
                                fontFamily: 'HarmonyOS Sans SC',
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
        ),
      ),
    );
  }
}
