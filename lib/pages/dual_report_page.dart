import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../services/dual_report_service.dart';
import '../services/dual_report_cache_service.dart';
import '../providers/app_state.dart';
import '../services/logger_service.dart';
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
    await logger.debug(
      'DualReportPage',
      'start isolate: friend=$friendUsername dbPath=$dbPath',
    );
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
      await logger.debug(
        'DualReportPage',
        'isolate spawned: friend=$friendUsername',
      );
    } catch (e, stackTrace) {
      await logger.error(
        'DualReportPage',
        'spawn isolate failed: $e',
        e,
        stackTrace,
      );
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
    await logger.debug(
      'DualReportPage',
      'progress: $taskName - $status ($progress%)',
    );
  }

  Future<void> _generateReport({required String friendUsername}) async {
    await logger.debug(
      'DualReportPage',
      '========== DUAL REPORT START ==========',
    );
    await logger.debug(
      'DualReportPage',
      'generate start: friend=$friendUsername',
    );
    final generateStart = DateTime.now();

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
      await logger.debug(
        'DualReportPage',
        'cache check: friend=$friendUsername hit=${cachedData != null}',
      );
      if (cachedData != null) {
        await logger.info('DualReportPage', 'cache hit: use cached report');
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

      final yearlyStats =
          (reportData['yearlyStats'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{};
      await logger.debug(
        'DualReportPage',
        'yearlyStats emoji keys: my=${yearlyStats['myTopEmojiMd5'] ?? 'null'} '
            'friend=${yearlyStats['friendTopEmojiMd5'] ?? 'null'}',
      );

      final hasTopEmoji =
          (yearlyStats['myTopEmojiMd5'] as String?)?.isNotEmpty == true ||
          (yearlyStats['friendTopEmojiMd5'] as String?)?.isNotEmpty == true;
      if (!hasTopEmoji) {
        try {
          final actualYear =
              (reportData['year'] as int?) ?? DateTime.now().year;
          await logger.debug(
            'DualReportPage',
            'top emoji missing, recompute in main isolate: friend=$friendUsername year=$actualYear',
          );
          final topEmoji =
              await appState.databaseService.getSessionYearlyTopEmojiMd5(
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

      await _updateProgress('下载表情包', '处理中', 94);
      await _cacheTopEmojiAssets(reportData);
      await _updateProgress('下载表情包', '已完成', 95);

      // 保存到缓存
      await _updateProgress('保存报告', '处理中', 96);
      final cacheData = _cloneForCache(reportData);
      _stripEmojiDataUrls(cacheData);
      await DualReportCacheService.saveReport(friendUsername, null, cacheData);
      await logger.debug('DualReportPage', 'cache saved');
      await _updateProgress('保存报告', '已完成', 100);

      if (!mounted) return;

      // 跳转到报告展示页面
      await logger.info(
        'DualReportPage',
        'DUAL REPORT done, elapsed: ${DateTime.now().difference(generateStart).inSeconds}s',
      );
      await logger.debug(
        'DualReportPage',
        '========== DUAL REPORT DONE ==========',
      );
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => DualReportDisplayPage(reportData: reportData),
        ),
      );
    } catch (e, stackTrace) {
      if (!mounted) return;
      await logger.error(
        'DualReportPage',
        'DUAL REPORT failed: $e',
        e,
        stackTrace,
      );

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
