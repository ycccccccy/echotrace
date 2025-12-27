import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/annual_report/annual_report_html_renderer.dart';
import '../services/database_service.dart';
import '../services/analytics_background_service.dart';
import '../services/annual_report_cache_service.dart';
import '../services/logger_service.dart';

/// 年度报告展示页面
class AnnualReportDisplayPage extends StatefulWidget {
  final DatabaseService databaseService;
  final int? year;

  const AnnualReportDisplayPage({
    super.key,
    required this.databaseService,
    this.year,
  });

  @override
  State<AnnualReportDisplayPage> createState() =>
      _AnnualReportDisplayPageState();
}

class _AnnualReportDisplayPageState extends State<AnnualReportDisplayPage> {
  final PageController _pageController = PageController();
  List<Widget>? _pages;
  late final FocusNode _keyboardFocusNode;
  bool _isHtmlLoading = false;
  String? _reportHtml;
  bool _isOpeningBrowser = false;
  bool _didAutoOpen = false;
  HttpServer? _reportServer;
  String? _reportUrl;

  // 报告生成相关
  AnalyticsBackgroundService? _backgroundService;
  Map<String, dynamic>? _reportData;
  bool _isGenerating = false;
  String _currentTaskName = '';
  String _currentTaskStatus = '';
  int _totalProgress = 0;
  int? _dbModifiedTime;

  @override
  void initState() {
    super.initState();
    _keyboardFocusNode = FocusNode();
    _keyboardFocusNode.requestFocus();
    _initializeReport();
  }

  @override
  void dispose() {
    _keyboardFocusNode.dispose();
    _pageController.dispose();
    _stopReportServer();
    super.dispose();
  }

  Future<void> _initializeReport() async {
    final dbPath = widget.databaseService.dbPath;

    // 每次初始化时都重新创建后台服务，确保使用最新的数据库路径
    if (dbPath != null) {
      _backgroundService = AnalyticsBackgroundService(dbPath);
    } else {}

    // 获取数据库修改时间
    if (dbPath != null) {
      try {
        final dbFile = File(dbPath);
        if (await dbFile.exists()) {
          final stat = await dbFile.stat();
          _dbModifiedTime = stat.modified.millisecondsSinceEpoch;
        }
      } catch (e) {
        // 无法获取文件状态，继续执行
      }
    }

    // 检查缓存
    await logger.info(
      'AnnualReportPage',
      '检查缓存: year=${widget.year}, dbModifiedTime=$_dbModifiedTime',
    );
    final hasCache = await AnnualReportCacheService.hasReport(widget.year);

    if (hasCache && _dbModifiedTime != null) {
      final cachedData = await AnnualReportCacheService.loadReport(widget.year);
      if (cachedData != null) {
        await logger.info('AnnualReportPage', '找到缓存数据，检查时间戳');
        // 检查数据库是否有更新
        final cachedDbTime = cachedData['dbModifiedTime'] as int?;
        await logger.info(
          'AnnualReportPage',
          '缓存数据库时间: $cachedDbTime, 当前数据库时间: $_dbModifiedTime',
        );
        final dbChanged =
            cachedDbTime == null || cachedDbTime < _dbModifiedTime!;

        if (dbChanged) {
          // 数据库已更新，询问用户
          await logger.info('AnnualReportPage', '数据库已更新，显示确认对话框');
          if (!mounted) return;
          final shouldRegenerate = await _showDatabaseChangedDialog();

          if (shouldRegenerate == true) {
            // 重新生成
            await logger.info('AnnualReportPage', '用户选择重新生成');
            await _startGenerateReport();
          } else {
            // 使用旧数据
            await logger.info('AnnualReportPage', '用户选择使用旧数据');
            if (!mounted) return;
            await _applyReportData(cachedData);
          }
        } else {
          // 使用缓存
          await logger.info('AnnualReportPage', '使用缓存数据');
          if (!mounted) return;
          await _applyReportData(cachedData);
        }
        return;
      }
    }

    await logger.info(
      'AnnualReportPage',
      '没有缓存或缓存无效，自动开始生成: hasCache=$hasCache, dbModifiedTime=$_dbModifiedTime',
    );
    // 自动生成缓存
    await _startGenerateReport();
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
          '检测到数据库已发生变化，是否重新生成年度报告？\n\n'
          '• 重新生成：获取最新的数据（需要一些时间）\n'
          '• 使用旧数据：快速加载，但可能不包含最新消息',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('使用旧数据'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重新生成'),
          ),
        ],
      ),
    );
  }

  Future<void> _startGenerateReport() async {
    await logger.debug('AnnualReportPage', '========== 开始生成年度报告 ==========');
    await logger.info('AnnualReportPage', '_startGenerateReport 被调用');

    // 防止重复生成
    if (_isGenerating) {
      await logger.warning('AnnualReportPage', '已经在生成中，忽略重复调用');
      return;
    }

    if (_backgroundService == null) {
      await logger.error('AnnualReportPage', '背景服务未初始化');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('服务未初始化，请检查数据库配置')));
      }
      return;
    }

    await logger.debug('AnnualReportPage', '设置生成状态为 true');
    setState(() {
      _isGenerating = true;
      _currentTaskName = '';
      _currentTaskStatus = '';
      _totalProgress = 0;
    });

    try {
      await logger.debug(
        'AnnualReportPage',
        '开始调用 generateFullAnnualReport，年份: ${widget.year}',
      );
      final startTime = DateTime.now();
      final data = await _backgroundService!.generateFullAnnualReport(
        widget.year,
        (taskName, status, progress) async {
          await logger.debug(
            'AnnualReportPage',
            '进度更新: $taskName - $status - $progress%',
          );
          if (mounted) {
            setState(() {
              _currentTaskName = taskName;
              _currentTaskStatus = status;
              _totalProgress = progress;
            });
          }
        },
      );

      final elapsed = DateTime.now().difference(startTime);
      await logger.info(
        'AnnualReportPage',
        'generateFullAnnualReport 完成，耗时: ${elapsed.inSeconds}秒',
      );
      await logger.debug('AnnualReportPage', '报告数据包含 ${data.keys.length} 个字段');

      // 保存数据库修改时间
      data['dbModifiedTime'] = _dbModifiedTime;
      await logger.debug('AnnualReportPage', '保存数据库修改时间: $_dbModifiedTime');

      // 保存到缓存
      await logger.debug('AnnualReportPage', '开始保存缓存');
      await AnnualReportCacheService.saveReport(widget.year, data);
      await logger.debug('AnnualReportPage', '缓存保存完成');

      if (mounted) {
        await logger.debug('AnnualReportPage', '更新UI状态');
        setState(() {
          _isGenerating = false;
        });
        await _applyReportData(data);
        await logger.debug('AnnualReportPage', '页面构建完成');
        await logger.debug(
          'AnnualReportPage',
          '========== 年度报告生成完成 ==========',
        );
      }
    } catch (e, stackTrace) {
      await logger.error('AnnualReportPage', '生成报告失败: $e\n堆栈: $stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _isGenerating = false;
        _currentTaskName = '';
        _currentTaskStatus = '';
        _totalProgress = 0;
      });

      // 显示详细的错误信息
      String errorMsg = '生成报告失败';
      if (e.toString().contains('TimeoutException')) {
        errorMsg = '生成报告超时，请稍后重试';
      } else if (e.toString().contains('database')) {
        errorMsg = '数据库访问失败，请检查数据库连接';
      }

      await logger.error('AnnualReportPage', '显示错误消息: $errorMsg');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$errorMsg\n\n详细信息：$e'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: '重试',
            onPressed: _startGenerateReport,
          ),
        ),
      );
    }
  }

  Future<void> _applyReportData(Map<String, dynamic> data) async {
    if (!mounted) return;
    setState(() {
      _reportData = data;
      _reportHtml = null;
    });

    try {
      await _buildReportHtml();
    } catch (e, stackTrace) {
      logger.error('AnnualReportPage', 'HTML 渲染构建失败', e, stackTrace);
      if (!mounted) return;
      setState(() {
        _reportData = null;
        _reportHtml = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('报告渲染失败: $e')),
      );
    }
  }

  Future<void> _buildReportHtml({bool autoOpen = true}) async {
    if (_reportData == null) return;
    if (!mounted) return;
    setState(() {
      _isHtmlLoading = true;
    });

    final html = await AnnualReportHtmlRenderer.build(
      reportData: _reportData!,
      year: widget.year,
    );

    _reportHtml = html;
    if (!mounted) return;
    setState(() {
      _isHtmlLoading = false;
    });
    if (autoOpen && !_didAutoOpen) {
      _didAutoOpen = true;
      await _openReportInBrowser();
    }
  }



  @override
  Widget build(BuildContext context) {
    try {
      logger.debug(
        'AnnualReportPage',
        'build方法被调用: _reportData=${_reportData != null}, _isGenerating=$_isGenerating, _pages=${_pages != null ? _pages!.length : 'null'}',
      );

      // 如果没有报告数据且不在生成中，显示初始界面
      if (_reportData == null && !_isGenerating) {
        logger.info('AnnualReportPage', '显示初始界面');
        return _buildInitialScreen();
      }

      // 如果正在生成，显示进度界面
      if (_isGenerating) {
        logger.info('AnnualReportPage', '显示生成进度界面');
        return _buildGeneratingScreen();
      }

      return _buildReportScreen();
    } catch (e, stackTrace) {
      logger.error('AnnualReportPage', 'build方法执行失败', e, stackTrace);
      // 发生异常时，显示错误界面
      return Theme(
        data: ThemeData(
          fontFamily: 'HarmonyOS Sans SC',
          textTheme: const TextTheme().apply(fontFamily: 'HarmonyOS Sans SC'),
        ),
        child: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  '报告显示出错',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800],
                    fontFamily: 'HarmonyOS Sans SC',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '请尝试重新生成报告',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                    fontFamily: 'HarmonyOS Sans SC',
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _reportData = null;
                      _pages = null;
                      _isGenerating = false;
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF07C160),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('重新生成'),
                ),
              ],
            ),
          ),
        ),
      );
    }
  }

  Widget _buildReportScreen() {
    if (!Platform.isWindows) {
      return Theme(
        data: ThemeData(
          fontFamily: 'HarmonyOS Sans SC',
          textTheme: const TextTheme().apply(fontFamily: 'HarmonyOS Sans SC'),
        ),
        child: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: Text(
              '年度报告 HTML 仅支持 Windows 平台',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey[700],
                fontFamily: 'HarmonyOS Sans SC',
              ),
            ),
          ),
        ),
      );
    }

    if (_isHtmlLoading || _reportHtml == null) {
      return Theme(
        data: ThemeData(
          fontFamily: 'HarmonyOS Sans SC',
          textTheme: const TextTheme().apply(fontFamily: 'HarmonyOS Sans SC'),
        ),
        child: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Color(0xFF07C160),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '正在渲染年度报告...',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontFamily: 'HarmonyOS Sans SC',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    logger.info('AnnualReportPage', '显示年度报告（外部浏览器）');
    return Theme(
      data: ThemeData(
        fontFamily: 'HarmonyOS Sans SC',
        textTheme: const TextTheme().apply(fontFamily: 'HarmonyOS Sans SC'),
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F7F5),
        body: Center(
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
                          color: Color(0xFF07C160),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '年度报告已生成',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[900],
                          letterSpacing: 0.5,
                          fontFamily: 'HarmonyOS Sans SC',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '前往浏览器以预览',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                          fontFamily: 'HarmonyOS Sans SC',
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
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            ),
                            const SizedBox(height: 6),
                            SelectableText(
                              _reportUrl ?? '尚未启动（点击打开或刷新预览）',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey[800],
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '提示：建议使用Chrome或Edge浏览器以获得最佳预览效果',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[500],
                                fontFamily: 'HarmonyOS Sans SC',
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
                              backgroundColor: const Color(0xFF07C160),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 12,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed:
                                _isHtmlLoading ? null : _refreshPreview,
                            icon: const Icon(Icons.refresh),
                            label: const Text('刷新预览'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF07C160),
                              side: const BorderSide(
                                color: Color(0xFF07C160),
                              ),
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
                        onPressed: () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.grey,
                        ),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _refreshPreview() async {
    if (_reportData == null) return;
    await _buildReportHtml(autoOpen: false);
    await _startReportServer();
    if (mounted) {
      setState(() {});
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('预览已刷新，请在浏览器中刷新页面')),
      );
    }
  }

  Future<void> _openReportInBrowser() async {
    if (_reportHtml == null || _isOpeningBrowser) return;
    setState(() {
      _isOpeningBrowser = true;
    });

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
        setState(() {
          _isOpeningBrowser = false;
        });
      }
    }
  }

  Future<void> _startReportServer() async {
    if (_reportHtml == null) return;
    if (_reportServer != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _reportServer = server;
    _reportUrl = 'http://127.0.0.1:${server.port}/';
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

  Widget _buildInitialScreen() {
    final yearText = widget.year != null ? '${widget.year}年' : '历史以来';

    return Theme(
      data: ThemeData(
        fontFamily: 'HarmonyOS Sans SC',
        textTheme: const TextTheme().apply(fontFamily: 'HarmonyOS Sans SC'),
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: Text(
            '$yearText年度报告',
            style: const TextStyle(fontFamily: 'HarmonyOS Sans SC'),
          ),
          backgroundColor: Colors.white,
          elevation: 0,
          foregroundColor: Colors.black87,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.analytics_outlined,
                size: 80,
                color: Color(0xFF07C160),
              ),
              const SizedBox(height: 24),
              Text(
                '$yearText年度报告',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                  fontFamily: 'HarmonyOS Sans SC',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '点击下方按钮开始分析',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                  fontFamily: 'HarmonyOS Sans SC',
                ),
              ),
              const SizedBox(height: 48),
              ElevatedButton.icon(
                onPressed: _startGenerateReport,
                icon: const Icon(Icons.play_arrow),
                label: const Text('开始生成报告'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF07C160),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 48,
                    vertical: 16,
                  ),
                  textStyle: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'HarmonyOS Sans SC',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGeneratingScreen() {
    final yearText = widget.year != null ? '${widget.year}年' : '历史以来';

    return Theme(
      data: ThemeData(
        fontFamily: 'HarmonyOS Sans SC',
        textTheme: const TextTheme().apply(fontFamily: 'HarmonyOS Sans SC'),
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: Text(
            '生成$yearText年度报告',
            style: const TextStyle(fontFamily: 'HarmonyOS Sans SC'),
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
                const SizedBox(height: 48),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  transitionBuilder:
                      (Widget child, Animation<double> animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position:
                                Tween<Offset>(
                                  begin: const Offset(0.0, 0.3),
                                  end: Offset.zero,
                                ).animate(
                                  CurvedAnimation(
                                    parent: animation,
                                    curve: Curves.easeOutCubic,
                                  ),
                                ),
                            child: child,
                          ),
                        );
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
                                fontSize: 24,
                                fontWeight: FontWeight.w900,
                                color: Colors.black87,
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 300),
                              style: TextStyle(
                                fontSize: 18,
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
