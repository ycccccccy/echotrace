import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import '../models/advanced_analytics_data.dart';
import '../widgets/annual_report/animated_components.dart';
import '../widgets/annual_report/warm_theme.dart';
import '../widgets/annual_report/warm_decorations.dart';
import '../widgets/annual_report/elegant_page_transition.dart';
import '../config/annual_report_texts.dart';
import '../services/database_service.dart';
import '../services/analytics_background_service.dart';
import '../services/annual_report_cache_service.dart';
import '../services/logger_service.dart';
import '../widgets/annual_report/typography_system.dart';
import '../widgets/annual_report/rich_text_builder.dart';

/// 年度报告展示页面，支持翻页滑动查看各个分析模块
class AnnualReportDisplayPage extends StatefulWidget {
  final DatabaseService databaseService;
  final int? year;

  const AnnualReportDisplayPage({
    super.key,
    required this.databaseService,
    this.year,
  });

  @override
  State<AnnualReportDisplayPage> createState() => _AnnualReportDisplayPageState();
}

class _AnnualReportDisplayPageState extends State<AnnualReportDisplayPage> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  List<Widget>? _pages;
  final GlobalKey _pageViewKey = GlobalKey();
  
  // 导出相关
  bool _isExporting = false;
  String _nameHideMode = 'none'; // none, full, firstChar
  bool _exportAsSeparateImages = false; // false=合并, true=分开保存
  
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
    _initializeReport();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }
  
  Future<void> _initializeReport() async {
    final dbPath = widget.databaseService.dbPath;
    
    // 每次初始化时都重新创建后台服务，确保使用最新的数据库路径
    if (dbPath != null) {
      _backgroundService = AnalyticsBackgroundService(dbPath);
    } else {
    }
    
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
    await logger.info('AnnualReportPage', '检查缓存: year=${widget.year}, dbModifiedTime=${_dbModifiedTime}');
    final hasCache = await AnnualReportCacheService.hasReport(widget.year);

    if (hasCache && _dbModifiedTime != null) {
      final cachedData = await AnnualReportCacheService.loadReport(widget.year);
      if (cachedData != null) {
        await logger.info('AnnualReportPage', '找到缓存数据，检查时间戳');
        // 检查数据库是否有更新
        final cachedDbTime = cachedData['dbModifiedTime'] as int?;
        await logger.info('AnnualReportPage', '缓存数据库时间: $cachedDbTime, 当前数据库时间: $_dbModifiedTime');
        final dbChanged = cachedDbTime == null || cachedDbTime < _dbModifiedTime!;

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
            setState(() {
              _reportData = cachedData;
              _pages = null;
              try {
                _buildPages();
              } catch (e, stackTrace) {
                logger.error('AnnualReportPage', '缓存数据页面构建失败', e, stackTrace);
                // 页面构建失败时，重置状态并显示错误
                _reportData = null;
                _pages = null;
                rethrow;
              }
            });
          }
        } else {
          // 使用缓存
          await logger.info('AnnualReportPage', '使用缓存数据');
          if (!mounted) return;
          setState(() {
            _reportData = cachedData;
            _pages = null;
            try {
              _buildPages();
            } catch (e, stackTrace) {
              logger.error('AnnualReportPage', '缓存数据页面构建失败', e, stackTrace);
              // 页面构建失败时，重置状态并显示错误
              _reportData = null;
              _pages = null;
              rethrow;
            }
          });
        }
        return;
      }
    }

    await logger.info('AnnualReportPage', '没有缓存或缓存无效，自动开始生成: hasCache=$hasCache, dbModifiedTime=${_dbModifiedTime}');
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('服务未初始化，请检查数据库配置')),
        );
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
      await logger.debug('AnnualReportPage', '开始调用 generateFullAnnualReport，年份: ${widget.year}');
      final startTime = DateTime.now();
      final data = await _backgroundService!.generateFullAnnualReport(
        widget.year,
        (taskName, status, progress) async {
          await logger.debug('AnnualReportPage', '进度更新: $taskName - $status - $progress%');
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
      await logger.info('AnnualReportPage', 'generateFullAnnualReport 完成，耗时: ${elapsed.inSeconds}秒');
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
          _reportData = data;
          _isGenerating = false;
          _pages = null;
          try {
            _buildPages();
          } catch (e, stackTrace) {
            logger.error('AnnualReportPage', '新报告数据页面构建失败', e, stackTrace);
            // 页面构建失败时，重置状态并显示错误
            _reportData = null;
            _pages = null;
            rethrow;
          }
        });
        await logger.debug('AnnualReportPage', '页面构建完成');
        await logger.debug('AnnualReportPage', '========== 年度报告生成完成 ==========');
      }
    } catch (e, stackTrace) {
      await logger.error('AnnualReportPage', '生成报告失败: $e\n堆栈: $stackTrace');
      
      if (mounted) {
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
  }

  void _buildPages() {
    try {
      logger.debug('AnnualReportPage', '开始构建页面列表');
      logger.debug('AnnualReportPage', '_reportData 包含的键: ${_reportData?.keys.toList()}');

      // 检查关键数据
      if (_reportData != null) {
        final whoRepliesFastest = _reportData!['whoRepliesFastest'];
        final myFastestReplies = _reportData!['myFastestReplies'];
        logger.debug('AnnualReportPage', '构建页面前数据检查:');
        logger.debug('AnnualReportPage', '  whoRepliesFastest: ${whoRepliesFastest == null ? "null" : (whoRepliesFastest is List ? "List(${whoRepliesFastest.length})" : whoRepliesFastest.runtimeType)}');
        logger.debug('AnnualReportPage', '  myFastestReplies: ${myFastestReplies == null ? "null" : (myFastestReplies is List ? "List(${myFastestReplies.length})" : myFastestReplies.runtimeType)}');
      }

      _pages = [
        _buildCoverPage(),
        _buildIntroPage(),
        _buildComprehensiveFriendshipPage(),
        _buildMutualFriendsPage(),
        _buildSocialInitiativePage(),
        _buildPeakDayPage(),
        _buildCheckInPage(),
        _buildActivityPatternPage(),
        _buildMidnightKingPage(),
        _buildResponseSpeedPage(),
        _buildFormerFriendsPage(),
        _buildEndingPage(),
      ];
      logger.debug('AnnualReportPage', '页面列表构建完成，共${_pages!.length}页');
    } catch (e, stackTrace) {
      logger.error('AnnualReportPage', '页面构建失败', e, stackTrace);
      // 重新抛出异常，让上层处理
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    try {
      logger.debug('AnnualReportPage', 'build方法被调用: _reportData=${_reportData != null}, _isGenerating=$_isGenerating, _pages=${_pages != null ? _pages!.length : 'null'}');

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

      // 有报告数据，显示报告
      if (_pages == null) {
        // 页面正在构建中，显示加载状态
        logger.warning('AnnualReportPage', '报告数据存在但页面列表为null');
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
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF07C160)),
                ),
                const SizedBox(height: 16),
                Text(
                  '正在构建报告页面...',
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

    logger.info('AnnualReportPage', '显示年度报告，页面数量: ${_pages!.length}');
    return Theme(
      data: ThemeData(
        fontFamily: 'HarmonyOS Sans SC',
        textTheme: const TextTheme().apply(fontFamily: 'HarmonyOS Sans SC'),
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: RawKeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        autofocus: true,
        onKey: (event) {
          if (event is RawKeyDownEvent) {
            if (event.logicalKey.keyLabel == 'Arrow Right' ||
                event.logicalKey.keyLabel == 'Arrow Down' ||
                event.logicalKey.keyLabel == 'Page Down') {
              // 下一页
              if (_currentPage < _pages!.length - 1) {
                _pageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              }
            } else if (event.logicalKey.keyLabel == 'Arrow Left' ||
                       event.logicalKey.keyLabel == 'Arrow Up' ||
                       event.logicalKey.keyLabel == 'Page Up') {
              // 上一页
              if (_currentPage > 0) {
                _pageController.previousPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              }
            }
          }
        },
        child: Stack(
          children: [
            // 主内容区域，支持鼠标滚轮翻页
            RepaintBoundary(
              key: _pageViewKey,
              child: Listener(
                onPointerSignal: (pointerSignal) {
                if (pointerSignal is PointerScrollEvent) {
                  if (pointerSignal.scrollDelta.dy > 0) {
                    // 向下滚动 - 下一页
                    if (_currentPage < _pages!.length - 1) {
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    }
                  } else if (pointerSignal.scrollDelta.dy < 0) {
                    // 向上滚动 - 上一页
                    if (_currentPage > 0) {
                      _pageController.previousPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    }
                  }
                }
              },
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (index) {
                    setState(() => _currentPage = index);
                  },
                  children: _pages!.asMap().entries.map((entry) {
                    final index = entry.key;
                    final page = entry.value;
                    return ElegantPageTransition(
                      pageIndex: index,
                      currentPage: _currentPage,
                      pageController: _pageController,
                      transitionDuration: const Duration(milliseconds: 550),
                      child: page,
                    );
                  }).toList(),
                ),
              ),
            ),
          
          // 页面指示器
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pages!.length, (index) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _currentPage == index ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _currentPage == index
                        ? WarmTheme.primaryGreen
                        : Colors.grey[300]!.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: _currentPage == index
                        ? WarmTheme.getSoftShadow(
                            color: WarmTheme.primaryGreen,
                            blurRadius: 8,
                          )
                        : null,
                  ),
                );
              }),
            ),
          ),
          
          // 右上角按钮组
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            right: 16,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 分享按钮
                IconButton(
                  icon: const Icon(Icons.share, color: Colors.black87, size: 24),
                  onPressed: _isExporting ? null : _showExportDialog,
                  tooltip: '分享',
                ),
                const SizedBox(width: 8),
                // 关闭按钮
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.black87, size: 28),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '关闭',
                ),
              ],
            ),
          ),
        ],
        ),
      ),
      ),
    );
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
                const Icon(
                  Icons.error_outline,
                  size: 64,
                  color: Colors.red,
                ),
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
          style: const TextStyle(
            fontFamily: 'HarmonyOS Sans SC',
          ),
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
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
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
          style: const TextStyle(
            fontFamily: 'HarmonyOS Sans SC',
          ),
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
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF07C160)),
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
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0.0, 0.3),
                        end: Offset.zero,
                      ).animate(CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      )),
                      child: child,
                    ),
                  );
                },
                child: _currentTaskName.isNotEmpty
                    ? Column(
                        key: ValueKey<String>('$_currentTaskName-$_currentTaskStatus'),
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
                    : const SizedBox.shrink(
                        key: ValueKey<String>('empty'),
                      ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// 构建年度报告封面页
  Widget _buildCoverPage() {
    final yearText = widget.year != null ? '${widget.year}年' : '历史以来';
    final gradients = WarmTheme.getPageGradients();
    
    return Container(
      decoration: BoxDecoration(
        gradient: gradients[0], // 封面页渐变
      ),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FadeInText(
                text: AnnualReportTexts.coverTitle,
                style: TextStyle(
                  fontSize: 28,
                  color: Colors.grey[500],
                  letterSpacing: 8,
                  fontWeight: FontWeight.w300,
                  fontFamily: 'HarmonyOS Sans SC',
                ),
              ),
              const SizedBox(height: 48),
              SlideInCard(
                delay: const Duration(milliseconds: 400),
                child: Text(
                  yearText,
                  style: const TextStyle(
                    fontSize: 64,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF07C160),
                    letterSpacing: 6,
                    height: 1.2,
                    fontFamily: 'HarmonyOS Sans SC',
                  ),
                ),
              ),
              const SizedBox(height: 24),
              FadeInText(
                text: AnnualReportTexts.coverSubtitle,
                delay: const Duration(milliseconds: 700),
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w500,
                  color: Colors.black87,
                  letterSpacing: 4,
                  fontFamily: 'HarmonyOS Sans SC',
                ),
              ),
              const SizedBox(height: 64),
              Container(
                width: 80,
                height: 1,
                color: Colors.grey[300],
              ),
              const SizedBox(height: 32),
                  FadeInText(
                text: AnnualReportTexts.coverPoem1,
                delay: const Duration(milliseconds: 1000),
                style: TextStyle(
                  fontSize: 18,
                  color: Colors.grey[600],
                  letterSpacing: 2,
                  height: 1.8,
                  fontFamily: 'HarmonyOS Sans SC',
                ),
              ),
              FadeInText(
                text: AnnualReportTexts.coverPoem2,
                delay: const Duration(milliseconds: 1200),
                style: TextStyle(
                  fontSize: 18,
                  color: Colors.grey[600],
                  letterSpacing: 2,
                  height: 1.8,
                  fontFamily: 'HarmonyOS Sans SC',
                ),
              ),
              const SizedBox(height: 100),
              FadeInText(
                text: AnnualReportTexts.coverHint,
                delay: const Duration(milliseconds: 1500),
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[400],
                  letterSpacing: 1,
                  fontFamily: 'HarmonyOS Sans SC',
                ),
              ),
              const SizedBox(height: 12),
              FadeInText(
                text: AnnualReportTexts.coverArrows,
                delay: const Duration(milliseconds: 1700),
                style: TextStyle(
                  fontSize: 24,
                  color: Colors.grey[350],
                  fontWeight: FontWeight.w300,
                  fontFamily: 'HarmonyOS Sans SC',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 开场页 - 横屏居中流动设计
  Widget _buildIntroPage() {
    final totalMessages = _getTotalMessages();
    final totalFriends = _getTotalFriends();
    final yearText = widget.year != null ? '${widget.year}年' : '这段时光';
    final gradients = WarmTheme.getPageGradients();
    
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: gradients[1], // 开场页渐变
          ),
        ),
        // 添加浮动的装饰圆点
        const Positioned.fill(
          child: FloatingDots(
            dotCount: 20,
            color: WarmTheme.primaryGreen,
            minSize: 3.0,
            maxSize: 8.0,
          ),
        ),
        Container(
      child: SafeArea(
        child: Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = constraints.maxHeight;
              final width = constraints.maxWidth;
              final textSize = height * 0.04;
              final numberSize = height * 0.12;
              final smallSize = height * 0.028;
              
              return Center(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: width * 0.15, vertical: height * 0.1),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FadeInText(
                          text: '${AnnualReportTexts.introPrefix}$yearText${AnnualReportTexts.introSuffix}',
                          style: TextStyle(
                            fontSize: textSize,
                            color: Colors.grey[600],
                            letterSpacing: 2,
                          ),
                        ),
                        SizedBox(height: height * 0.05),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            FadeInText(
                              text: AnnualReportTexts.introWithFriends,
                              delay: const Duration(milliseconds: 300),
                              style: TextStyle(
                                fontSize: textSize,
                                color: Colors.black87,
                              ),
                            ),
                            SlideInCard(
                              delay: const Duration(milliseconds: 500),
                              child: AnimatedNumberDisplay(
                                value: totalFriends.toDouble(),
                                suffix: '',
                                style: TextStyle(
                                  fontSize: numberSize,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF07C160),
                                  height: 1.0,
                                ),
                              ),
                            ),
                            FadeInText(
                              text: AnnualReportTexts.introFriendsUnit,
                              delay: const Duration(milliseconds: 700),
                              style: TextStyle(
                                fontSize: textSize,
                                color: Colors.black87,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: height * 0.04),
                        FadeInText(
                          text: AnnualReportTexts.introExchanged,
                          delay: const Duration(milliseconds: 900),
                          style: TextStyle(
                            fontSize: textSize,
                            color: Colors.grey[600],
                          ),
                        ),
                        SizedBox(height: height * 0.04),
                        SlideInCard(
                          delay: const Duration(milliseconds: 1100),
                          child: AnimatedNumberDisplay(
                            value: totalMessages.toDouble(),
                            suffix: AnnualReportTexts.introMessagesUnit,
                            style: TextStyle(
                              fontSize: numberSize * 0.8,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF07C160),
                              height: 1.0,
                            ),
                          ),
                        ),
                        SizedBox(height: height * 0.08),
                        FadeInText(
                          text: _getOpeningComment(totalMessages),
                          delay: const Duration(milliseconds: 1400),
                          style: TextStyle(
                            fontSize: smallSize,
                            color: Colors.grey[500],
                            fontStyle: FontStyle.italic,
                            height: 2.0,
                            letterSpacing: 0.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
      ],
    );
  }

  // 获取总消息数（从报告的总统计字段读取）
  int _getTotalMessages() {
    return (_reportData!['totalMessages'] as int?) ?? 0;
  }

  // 获取好友总数（从报告的总统计字段读取）
  int _getTotalFriends() {
    return (_reportData!['totalFriends'] as int?) ?? 0;
  }

  // 根据消息数生成开场评语
  String _getOpeningComment(int messages) {
    return AnnualReportTexts.getOpeningComment(messages);
  }

  // 综合好友页 - 合并年度挚友、倾诉对象、最佳听众
  Widget _buildComprehensiveFriendshipPage() {
    // 获取数据
    final List<dynamic> coreFriendsJson = _reportData!['coreFriends'] ?? [];
    final coreFriends = coreFriendsJson.map((e) => FriendshipRanking.fromJson(e)).toList();
    
    final List<dynamic> confidantJson = _reportData!['confidant'] ?? [];
    final confidants = confidantJson.map((e) => FriendshipRanking.fromJson(e)).toList();
    
    final List<dynamic> listenersJson = _reportData!['listeners'] ?? [];
    final listeners = listenersJson.map((e) => FriendshipRanking.fromJson(e)).toList();
    
    if (coreFriends.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          gradient: WarmTheme.getPageGradients()[2],
        ),
        child: const Center(
          child: Text('暂无数据', style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    final topFriend = coreFriends[0];
    final topConfidant = confidants.isNotEmpty ? confidants[0] : null;
    final topListener = listeners.isNotEmpty ? listeners[0] : null;
    final gradients = WarmTheme.getPageGradients();
    
    return Container(
      decoration: BoxDecoration(
        gradient: gradients[2], // 年度挚友页渐变
      ),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = constraints.maxHeight;
            final width = constraints.maxWidth;
            // 统一字体系统：只用两种尺寸
            final emphasisSize = height * 0.045;  // 强调字体：标题、名字、数字
            final normalSize = height * 0.024;    // 正常字体：所有其他文本
            
            return Center(
                child: Padding(
                padding: EdgeInsets.symmetric(horizontal: width * 0.1, vertical: height * 0.06),
                  child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                    children: [
                    // 标题
                      FadeInText(
                      text: AnnualReportTexts.friendshipTitle,
                        style: TextStyle(
                        fontSize: emphasisSize,
                        fontWeight: FontWeight.w600,
                          color: const Color(0xFF07C160),
                        letterSpacing: 2,
                        ),
                      ),
                    SizedBox(height: height * 0.03),
                    
                    // 主要内容
                      FadeInText(
                      text: AnnualReportTexts.friendshipIntro,
                        delay: const Duration(milliseconds: 200),
                        style: TextStyle(
                        fontSize: normalSize,
                        color: Colors.grey[600],
                      ),
                    ),
                    SizedBox(height: height * 0.025),
                    
                    // 挚友名字
                    SlideInCard(
                                delay: const Duration(milliseconds: 400),
                      child: Container(
                        constraints: BoxConstraints(maxWidth: width * 0.6),
            child: _buildNameWithBlur(
                          topFriend.displayName,
              TextStyle(
                            fontSize: emphasisSize,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF07C160),
              height: 1.3,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
          ),
        ),
                    ),
                    SizedBox(height: height * 0.02),
                    
                    FadeInText(
                      text: AnnualReportTexts.friendshipMostChats,
                      delay: const Duration(milliseconds: 600),
          style: TextStyle(
                        fontSize: normalSize,
                        color: Colors.grey[600],
                      ),
                    ),
                    SizedBox(height: height * 0.015),
                    
                    // 总消息数
                    SlideInCard(
                      delay: const Duration(milliseconds: 800),
                      child: AnimatedNumberDisplay(
                        value: topFriend.count.toDouble(),
                        suffix: AnnualReportTexts.friendshipMessagesCount,
          style: TextStyle(
                          fontSize: emphasisSize,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF07C160),
                        ),
                      ),
                    ),
                    
                    SizedBox(height: height * 0.04),
                    
                    // 分隔线
                    Container(
                      width: width * 0.2,
                      height: 1,
                      color: Colors.grey[300],
                    ),
                    
                    SizedBox(height: height * 0.035),
                    
                    // 倾诉和听众信息
                    if (topConfidant != null && topListener != null) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          // 你最爱给谁发
                          Expanded(
                  child: Column(
                              mainAxisSize: MainAxisSize.min,
                    children: [
                      FadeInText(
                                  text: AnnualReportTexts.friendshipYouSendTo,
                                  delay: const Duration(milliseconds: 1000),
                        style: TextStyle(
                                    fontSize: normalSize * 0.9,
                                    color: Colors.grey[500],
                                  ),
                                ),
                                SizedBox(height: height * 0.015),
                       SlideInCard(
                                  delay: const Duration(milliseconds: 1200),
                                  child: _buildNameWithBlur(
                                    topConfidant.displayName,
                        TextStyle(
                                    fontSize: normalSize,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black87,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                          ),
                                ),
                                SizedBox(height: height * 0.012),
                      FadeInText(
                                  text: '${topConfidant.count}${AnnualReportTexts.friendshipMessagesCount}',
                                  delay: const Duration(milliseconds: 1400),
                        style: TextStyle(
                                    fontSize: emphasisSize * 0.8,
                                    color: const Color(0xFF07C160),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (topConfidant.details != null && 
                                    topConfidant.details!['receivedCount'] != null) ...[
                                  SizedBox(height: height * 0.01),
                      FadeInText(
                                    text: '${AnnualReportTexts.friendshipTheyReply}${topConfidant.details!['receivedCount']}${AnnualReportTexts.friendshipMessagesCount}',
                        delay: const Duration(milliseconds: 1500),
                        style: TextStyle(
                                      fontSize: normalSize * 0.85,
                          color: Colors.grey[500],
                        ),
                      ),
                                ],
                    ],
                  ),
                ),
                          
                          Container(
                            width: 1,
                            height: height * 0.12,
                            color: Colors.grey[300],
                          ),
                          
                          // 谁最爱给你发
                          Expanded(
                  child: Column(
                              mainAxisSize: MainAxisSize.min,
                    children: [
                      FadeInText(
                                  text: AnnualReportTexts.friendshipWhoSendsYou,
                                  delay: const Duration(milliseconds: 1000),
                        style: TextStyle(
                                    fontSize: normalSize * 0.9,
                                    color: Colors.grey[500],
                                  ),
                                ),
                                SizedBox(height: height * 0.015),
                                SlideInCard(
                                  delay: const Duration(milliseconds: 1200),
                                  child: _buildNameWithBlur(
                                    topListener.displayName,
                            TextStyle(
                                    fontSize: normalSize,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black87,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                          ),
                                ),
                                SizedBox(height: height * 0.012),
                      FadeInText(
                                  text: '${topListener.count}${AnnualReportTexts.friendshipMessagesCount}',
                                  delay: const Duration(milliseconds: 1400),
                        style: TextStyle(
                                    fontSize: emphasisSize * 0.8,
                                    color: const Color(0xFF07C160),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (topListener.details != null && 
                                    topListener.details!['sentCount'] != null) ...[
                                  SizedBox(height: height * 0.01),
                      FadeInText(
                                    text: '${AnnualReportTexts.friendshipYouReply}${topListener.details!['sentCount']}${AnnualReportTexts.friendshipMessagesCount}',
                                    delay: const Duration(milliseconds: 1500),
                        style: TextStyle(
                                      fontSize: normalSize * 0.85,
                          color: Colors.grey[500],
                        ),
                      ),
                                ],
                              ],
                          ),
                        ),
                      ],
                      ),
                      
                      SizedBox(height: height * 0.035),
                      
                      // 底部寄语
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: width * 0.08),
                        child: FadeInText(
                          text: AnnualReportTexts.friendshipClosing,
                          delay: const Duration(milliseconds: 1800),
                        style: TextStyle(
                            fontSize: normalSize * 0.9,
                          color: Colors.grey[500],
                          fontStyle: FontStyle.italic,
                            height: 1.8,
                          letterSpacing: 0.5,
                        ),
                        textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                    ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // 双向奔赴页 - 横屏水平对称设计
  Widget _buildMutualFriendsPage() {
    final List<dynamic> friendsJson = _reportData!['mutualFriends'] ?? [];
    final friends = friendsJson.map((e) => FriendshipRanking.fromJson(e)).toList();
    final gradients = WarmTheme.getPageGradients();
    
    if (friends.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          gradient: gradients[3],
        ),
        child: const Center(
          child: Text('暂无数据', style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    final friend1 = friends[0];
    final ratio = friend1.details?['ratio'] as String? ?? '1.0';
    final sent = friend1.details?['sentCount'] as int? ?? 0;
    final received = friend1.details?['receivedCount'] as int? ?? 0;
    
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: gradients[3], // 双向奔赴页渐变
          ),
        ),
        // 添加装饰圆点
        const Positioned.fill(
          child: FloatingDots(
            dotCount: 15,
            color: WarmTheme.warmBlue,
            minSize: 2.0,
            maxSize: 6.0,
          ),
        ),
        Container(
      child: SafeArea(
        child: Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = constraints.maxHeight;
              final width = constraints.maxWidth;
              final titleSize = height * 0.05;
              final nameSize = height * 0.065;
              final numberSize = height * 0.1;
              final textSize = height * 0.03;
              final smallSize = height * 0.026;
              
              return Center(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: width * 0.08, vertical: height * 0.1),
                    child: Column(
                      children: [
                        FadeInText(
                          text: AnnualReportTexts.mutualTitle,
                          style: TextStyle(
                            fontSize: titleSize,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF07C160),
                            letterSpacing: 3,
                          ),
                        ),
                        SizedBox(height: height * 0.015),
                        FadeInText(
                          text: AnnualReportTexts.mutualSubtitle,
                          delay: const Duration(milliseconds: 200),
                          style: TextStyle(
                            fontSize: smallSize,
                            color: Colors.grey[500],
                            letterSpacing: 0.5,
                          ),
                        ),
                        SizedBox(height: height * 0.06),
                        SlideInCard(
                          delay: const Duration(milliseconds: 400),
                          child: Container(
                            constraints: BoxConstraints(maxWidth: width * 0.5),
                            child: _buildNameWithBlur(
                              friend1.displayName,
                              TextStyle(
                                fontSize: nameSize,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                                height: 1.2,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                            ),
                          ),
                        ),
                        SizedBox(height: height * 0.08),
                        
                        // 水平排列数据
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // 你发
                            Column(
                              children: [
                                FadeInText(
                                  text: AnnualReportTexts.mutualYouSent,
                                  delay: const Duration(milliseconds: 600),
                                  style: TextStyle(
                                    fontSize: textSize,
                                    color: Colors.grey[500],
                                  ),
                                ),
                                SizedBox(height: height * 0.02),
                                FadeInText(
                                  text: '$sent',
                                  delay: const Duration(milliseconds: 800),
                                  style: TextStyle(
                                    fontSize: numberSize,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF07C160),
                                    height: 1.0,
                                  ),
                                ),
                                SizedBox(height: 4),
                                FadeInText(
                                  text: AnnualReportTexts.mutualMessagesUnit,
                                  delay: const Duration(milliseconds: 900),
                                  style: TextStyle(
                                    fontSize: smallSize,
                                    color: Colors.grey[500],
                                  ),
                                ),
                              ],
                            ),
                            
                            SizedBox(width: width * 0.15),
                            
                            // 箭头
                            FadeInText(
                              text: '⇄',
                              delay: const Duration(milliseconds: 1000),
                              style: TextStyle(
                                fontSize: numberSize * 0.4,
                                color: Colors.grey[300],
                              ),
                            ),
                            
                            SizedBox(width: width * 0.15),
                            
                            // TA回
                            Column(
                              children: [
                                FadeInText(
                                  text: AnnualReportTexts.mutualTheySent,
                                  delay: const Duration(milliseconds: 600),
                                  style: TextStyle(
                                    fontSize: textSize,
                                    color: Colors.grey[500],
                                  ),
                                ),
                                SizedBox(height: height * 0.02),
                                FadeInText(
                                  text: '$received',
                                  delay: const Duration(milliseconds: 800),
                                  style: TextStyle(
                                    fontSize: numberSize,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF07C160),
                                    height: 1.0,
                                  ),
                                ),
                                SizedBox(height: 4),
                                FadeInText(
                                  text: AnnualReportTexts.mutualMessagesUnit,
                                  delay: const Duration(milliseconds: 900),
                                  style: TextStyle(
                                    fontSize: smallSize,
                                    color: Colors.grey[500],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        
                        SizedBox(height: height * 0.08),
                        
                        FadeInText(
                          text: '${AnnualReportTexts.mutualRatioPrefix}$ratio',
                          delay: const Duration(milliseconds: 1100),
                          style: TextStyle(
                            fontSize: textSize,
                            color: const Color(0xFF07C160),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: height * 0.04),
                        FadeInText(
                          text: AnnualReportTexts.mutualClosing,
                          delay: const Duration(milliseconds: 1300),
                          style: TextStyle(
                            fontSize: smallSize * 0.9,
                            color: Colors.grey[500],
                            fontStyle: FontStyle.italic,
                            height: 2.0,
                            letterSpacing: 0.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
      ],
    );
  }

  // 主动社交指数页
  Widget _buildSocialInitiativePage() {
    final socialData = SocialStyleData.fromJson(_reportData!['socialInitiative']);
    
    if (socialData.initiativeRanking.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          gradient: WarmTheme.getPageGradients()[4],
        ),
        child: const Center(
          child: Text('暂无数据', style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    final friend1 = socialData.initiativeRanking.first;
    final rate = friend1.percentage;
    final gradients = WarmTheme.getPageGradients();
    
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: gradients[4], // 主动社交指数页渐变
          ),
        ),
        // 添加装饰圆点
        const Positioned.fill(
          child: FloatingDots(
            dotCount: 18,
            color: WarmTheme.warmOrange,
            minSize: 3.0,
            maxSize: 7.0,
          ),
        ),
        Container(
      child: SafeArea(
        child: Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = constraints.maxHeight;
              final width = constraints.maxWidth;
              final titleSize = height > 700 ? 32.0 : 26.0;
              final nameSize = height > 700 ? 38.0 : 32.0;
              final descSize = height > 700 ? 18.0 : 16.0;
              
              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: width * 0.1, 
                  vertical: height * 0.05,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    FadeInText(
                      text: AnnualReportTexts.socialTitle,
                      style: TextStyle(
                        fontSize: titleSize,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF07C160),
                        letterSpacing: 2,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: height * 0.06),
                    
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: width * 0.05),
                      child: SlideInCard(
                        delay: const Duration(milliseconds: 300),
                        child: Column(
                          children: [
                            Text(
                              '在与',
                              style: TextStyle(
                                fontSize: descSize - 1,
                                color: Colors.grey[700],
                                height: 1.9,
                                letterSpacing: 0.5,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            _buildNameWithBlur(
                              friend1.displayName,
                              TextStyle(
                                fontSize: descSize - 1,
                                color: Colors.grey[700],
                                fontWeight: FontWeight.w600,
                                height: 1.9,
                                letterSpacing: 0.5,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                            ),
                            Text(
                              '的聊天中，你发起了 ${(rate * 100).toStringAsFixed(1)}% 的对话',
                              style: TextStyle(
                                fontSize: descSize - 1,
                                color: Colors.grey[700],
                                height: 1.9,
                                letterSpacing: 0.5,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: height * 0.06),
                    SlideInCard(
                      delay: const Duration(milliseconds: 600),
                      child: Text(
                        '${(rate * 100).toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: nameSize,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF07C160),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    SizedBox(height: height * 0.02),
                    FadeInText(
                      text: AnnualReportTexts.socialInitiatedUnit,
                      delay: const Duration(milliseconds: 800),
                      style: TextStyle(
                        fontSize: descSize - 2,
                        color: Colors.grey[600],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
      ],
    );
  }

  // 聊天巅峰日页
  Widget _buildPeakDayPage() {
    final peakDay = ChatPeakDay.fromJson(_reportData!['peakDay']);
    final gradients = WarmTheme.getPageGradients();
    
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: gradients[5],
          ),
        ),
        const Positioned.fill(
          child: FloatingDots(
            dotCount: 20,
            color: WarmTheme.warmPink,
            minSize: 3.0,
            maxSize: 8.0,
          ),
        ),
        Container(
          child: SafeArea(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final height = constraints.maxHeight;
                  final width = constraints.maxWidth;
                  
                  final titleSize = height > 700 ? 36.0 : 32.0;
                  final bodySize = height > 700 ? 24.0 : 22.0;
                  
                  return Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: width * 0.08, 
                      vertical: height * 0.1,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // 标题
                          FadeInText(
                            text: AnnualReportTexts.peakDayTitle,
                            style: TextStyle(
                              fontSize: titleSize,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF07C160),
                              letterSpacing: 1,
                              fontFamily: 'HarmonyOS Sans SC',
                            ),
                          ),
                          SizedBox(height: height * 0.08),
                          
                          // 第一句：日期
                          FadeInRichText(
                            text: peakDay.formattedDate,
                            baseStyle: TextStyle(
                              fontSize: bodySize,
                              color: Colors.black87,
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                              fontWeight: FontWeight.bold,
                            ),
                            highlights: {
                              peakDay.formattedDate: TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF07C160),
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 200),
                          ),
                          SizedBox(height: height * 0.05),
                          
                          // 第二句：消息总数
                          FadeInRichText(
                            text: '${AnnualReportTexts.peakDayYouChatted}${peakDay.messageCount}${AnnualReportTexts.peakDayMessagesCount}',
                            baseStyle: TextStyle(
                              fontSize: bodySize,
                              color: Colors.black87,
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                            highlights: {
                              peakDay.messageCount.toString(): TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF07C160),
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 400),
                          ),
                          
                          if (peakDay.topFriendDisplayName != null) ...[
                            SizedBox(height: height * 0.06),
                            
                            // 第三句：好友信息
                            FadeInRichText(
                              text: '${AnnualReportTexts.peakDayWithFriendPrefix}${peakDay.topFriendDisplayName}${AnnualReportTexts.peakDayWithFriendSuffix}${peakDay.topFriendMessageCount}${AnnualReportTexts.peakDayWithFriendMessagesUnit}',
                              baseStyle: TextStyle(
                                fontSize: bodySize,
                                color: Colors.black87,
                                fontFamily: 'HarmonyOS Sans SC',
                                height: 1.6,
                                fontWeight: FontWeight.w500,
                              ),
                              highlights: {
                                peakDay.topFriendDisplayName ?? '': TextStyle(
                                  fontSize: bodySize,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF5C6BC0),
                                  fontFamily: 'HarmonyOS Sans SC',
                                ),
                                peakDay.topFriendMessageCount.toString(): TextStyle(
                                  fontSize: bodySize,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF07C160),
                                  fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 600),
                          ),
                        ],
                        
                        SizedBox(height: height * 0.08),
                          
                          // 第四部分：情感总结
                          FadeInText(
                            text: AnnualReportTexts.getPeakDayComment(peakDay.messageCount),
                            delay: const Duration(milliseconds: 900),
                            style: TextStyle(
                              fontSize: bodySize - 2,
                              color: Colors.black87,
                              fontStyle: FontStyle.italic,
                              height: 1.9,
                              fontFamily: 'HarmonyOS Sans SC',
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }


// 连续打卡页
  Widget _buildCheckInPage() {
    final checkIn = _reportData!['checkIn'] as Map<String, dynamic>;
    final days = checkIn['days'] ?? 0;
    final displayName = checkIn['displayName'] ?? '未知';
    final startDateStr = checkIn['startDate'] as String?;
    final endDateStr = checkIn['endDate'] as String?;
    
    // 格式化日期，只保留年月日
    String? startDate;
    String? endDate;
    if (startDateStr != null) {
      startDate = startDateStr.split('T').first;
    }
    if (endDateStr != null) {
      endDate = endDateStr.split('T').first;
    }
    
    final gradients = WarmTheme.getPageGradients();

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: gradients[6],
          ),
        ),
        const Positioned.fill(
          child: FloatingDots(
            dotCount: 16,
            color: WarmTheme.warmOrange,
            minSize: 2.5,
            maxSize: 6.5,
          ),
        ),
        Container(
          child: SafeArea(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final height = constraints.maxHeight;
                  final width = constraints.maxWidth;
                  
                  final titleSize = height > 700 ? 36.0 : 32.0;
                  final bodySize = height > 700 ? 24.0 : 22.0;

                  return Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: width * 0.08,
                      vertical: height * 0.08,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // 标题
                          FadeInText(
                            text: AnnualReportTexts.checkInTitle,
                            style: TextStyle(
                              fontSize: titleSize,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF07C160),
                              letterSpacing: 1,
                              fontFamily: 'HarmonyOS Sans SC',
                            ),
                            textAlign: TextAlign.center,
                          ),
                          SizedBox(height: height * 0.06),

                          // 副标题
                          FadeInText(
                            text: AnnualReportTexts.checkInSubtitle,
                            delay: const Duration(milliseconds: 200),
                            style: TextStyle(
                              fontSize: bodySize - 4,
                              color: Colors.grey[500],
                              height: 1.6,
                              fontFamily: 'HarmonyOS Sans SC',
                            ),
                            textAlign: TextAlign.center,
                          ),
                          SizedBox(height: height * 0.08),

                          // 第一句：和XXX聊了
                          FadeInRichText(
                            text: '你和 $displayName 连续聊了',
                            baseStyle: TextStyle(
                              fontSize: bodySize,
                              color: Colors.black87,
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                            highlights: {
                              displayName: TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF5C6BC0),
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 300),
                          ),
                          SizedBox(height: height * 0.05),

                          // 第二句：天数
                          FadeInRichText(
                            text: '$days${AnnualReportTexts.checkInDaysUnit}',
                            baseStyle: TextStyle(
                              fontSize: bodySize,
                              color: Colors.black87,
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                            highlights: {
                              days.toString(): TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF07C160),
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 500),
                          ),

                          if (startDate != null && endDate != null) ...[
                            SizedBox(height: height * 0.06),

                            // 第三句：时间范围
                            FadeInRichText(
                              text: '$startDate ${AnnualReportTexts.checkInDateRange} $endDate',
                              baseStyle: TextStyle(
                                fontSize: bodySize - 2,
                                color: Colors.grey[600],
                                fontFamily: 'HarmonyOS Sans SC',
                                height: 1.6,
                                fontWeight: FontWeight.w500,
                              ),
                              highlights: {
                                startDate: TextStyle(
                                  fontSize: bodySize - 2,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF07C160),
                                  fontFamily: 'HarmonyOS Sans SC',
                                ),
                                endDate: TextStyle(
                                  fontSize: bodySize - 2,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF07C160),
                                  fontFamily: 'HarmonyOS Sans SC',
                                ),
                              },
                              delay: const Duration(milliseconds: 700),
                            ),
                          ],

                          SizedBox(height: height * 0.08),

                          // 结束语
                          FadeInText(
                            text: AnnualReportTexts.checkInClosing,
                            delay: const Duration(milliseconds: 900),
                            style: TextStyle(
                              fontSize: bodySize - 2,
                              color: Colors.black87,
                              fontStyle: FontStyle.italic,
                              height: 1.9,
                              fontFamily: 'HarmonyOS Sans SC',
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  // 作息图谱页
  Widget _buildActivityPatternPage() {
    final activityJson = _reportData!['activityPattern'];
    final gradients = WarmTheme.getPageGradients();

    if (activityJson == null) {
      return Container(
        decoration: BoxDecoration(
          gradient: gradients[7],
        ),
        child: const Center(child: Text('暂无数据')),
      );
    }

    final activity = ActivityHeatmap.fromJson(activityJson);

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: gradients[7], // 作息图谱页渐变
          ),
        ),
        // 添加装饰圆点
        const Positioned.fill(
          child: FloatingDots(
            dotCount: 14,
            color: WarmTheme.warmBlue,
            minSize: 2.0,
            maxSize: 6.0,
          ),
        ),
        Container(
          child: SafeArea(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final height = constraints.maxHeight;
                  final width = constraints.maxWidth;
                  final titleSize = height > 700 ? 36.0 : 32.0;
                  final textSize = height > 700 ? 22.0 : 20.0;
                  final numberSize = height > 700 ? 48.0 : 42.0;

                  // 找出最活跃时段
                  int maxHour = 0;
                  int maxValue = 0;
                  for (int hour = 0; hour < 24; hour++) {
                    int hourTotal = 0;
                    for (int day = 1; day <= 7; day++) {
                      hourTotal += activity.getCount(hour, day);
                    }
                    if (hourTotal > maxValue) {
                      maxValue = hourTotal;
                      maxHour = hour;
                    }
                  }

                  return Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: width * 0.1,
                      vertical: height * 0.08,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        FadeInText(
                          text: AnnualReportTexts.activityTitle,
                          style: TextStyle(
                            fontSize: titleSize,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF07C160),
                            letterSpacing: 1,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: height * 0.02),
                        FadeInText(
                          text: AnnualReportTexts.activitySubtitle,
                          delay: const Duration(milliseconds: 200),
                          style: TextStyle(
                            fontSize: titleSize - 12,
                            color: Colors.grey[500],
                            letterSpacing: 0.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: height * 0.06),
                        FadeInText(
                          text: AnnualReportTexts.activityEveryday,
                          delay: const Duration(milliseconds: 300),
                          style: TextStyle(
                            fontSize: textSize,
                            color: Colors.grey[600],
                          ),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: height * 0.04),
                        SlideInCard(
                          delay: const Duration(milliseconds: 600),
                          child: Text(
                            '${maxHour.toString().padLeft(2, '0')}:00',
                            style: TextStyle(
                              fontSize: numberSize,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF07C160),
                            ),
                          ),
                        ),
                        SizedBox(height: height * 0.05),
                        Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: width * 0.08),
                          child: FadeInText(
                            text: AnnualReportTexts.activityClosing,
                            delay: const Duration(milliseconds: 900),
                            style: TextStyle(
                              fontSize: textSize - 2,
                              color: Colors.grey[600],
                              fontStyle: FontStyle.italic,
                              height: 1.9,
                              letterSpacing: 0.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ), 
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  // 深夜长谈页
  Widget _buildMidnightKingPage() {
    final midnightKing = _reportData!['midnightKing'];
    final gradients = WarmTheme.getPageGradients();
    
    if (midnightKing == null || midnightKing['count'] == 0) {
      return Container(
        decoration: BoxDecoration(
          gradient: gradients[8],
        ),
        child: const Center(child: Text('暂无深夜聊天数据')),
      );
    }
    
    final displayName = midnightKing['displayName'] as String? ?? '未知';
    final count = midnightKing['count'] as int;
    final percentage = midnightKing['percentage'] as String? ?? '0';
    
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: gradients[8],
          ),
        ),
        const Positioned.fill(
          child: FloatingDots(
            dotCount: 12,
            color: WarmTheme.warmPink,
            minSize: 2.0,
            maxSize: 7.0,
          ),
        ),
        Container(
          child: SafeArea(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final height = constraints.maxHeight;
                  final width = constraints.maxWidth;
                  
                  final titleSize = height > 700 ? 36.0 : 32.0;
                  final bodySize = height > 700 ? 24.0 : 22.0;

                  return Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: width * 0.08,
                      vertical: height * 0.08,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // 标题
                          FadeInText(
                            text: AnnualReportTexts.midnightTitle,
                            style: TextStyle(
                              fontSize: titleSize,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF5C6BC0),
                              letterSpacing: 1,
                              fontFamily: 'HarmonyOS Sans SC',
                            ),
                            textAlign: TextAlign.center,
                          ),
                          SizedBox(height: height * 0.06),

                          // 副标题
                          FadeInText(
                            text: AnnualReportTexts.midnightSubtitle,
                            delay: const Duration(milliseconds: 200),
                            style: TextStyle(
                              fontSize: bodySize - 4,
                              color: Colors.grey[500],
                              height: 1.6,
                              fontFamily: 'HarmonyOS Sans SC',
                            ),
                            textAlign: TextAlign.center,
                          ),
                          SizedBox(height: height * 0.08),

                          // 第一句：时间范围
                          FadeInText(
                            text: AnnualReportTexts.midnightTimeRange,
                            delay: const Duration(milliseconds: 300),
                            style: TextStyle(
                              fontSize: bodySize - 2,
                              color: Colors.grey[600],
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          SizedBox(height: height * 0.06),

                          // 第二句：和XXX聊了
                          FadeInRichText(
                            text: '${AnnualReportTexts.midnightChattedWith} $displayName ${AnnualReportTexts.midnightChattedPrefix}',
                            baseStyle: TextStyle(
                              fontSize: bodySize,
                              color: Colors.black87,
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                            highlights: {
                              displayName: TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF5C6BC0),
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 500),
                          ),
                          SizedBox(height: height * 0.05),

                          // 第三句：消息数
                          FadeInRichText(
                            text: '$count${AnnualReportTexts.midnightMessagesUnit}',
                            baseStyle: TextStyle(
                              fontSize: bodySize,
                              color: Colors.black87,
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                            highlights: {
                              count.toString(): TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF5C6BC0),
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 700),
                          ),
                          SizedBox(height: height * 0.04),

                          // 第四句：占比
                          FadeInRichText(
                            text: '${AnnualReportTexts.midnightPercentagePrefix}$percentage${AnnualReportTexts.midnightPercentageSuffix}',
                            baseStyle: TextStyle(
                              fontSize: bodySize - 2,
                              color: Colors.grey[600],
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                            highlights: {
                              percentage: TextStyle(
                                fontSize: bodySize - 2,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF5C6BC0),
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 900),
                          ),

                          SizedBox(height: height * 0.08),

                          // 结束语
                          FadeInText(
                            text: AnnualReportTexts.midnightClosing,
                            delay: const Duration(milliseconds: 1100),
                            style: TextStyle(
                              fontSize: bodySize - 2,
                              color: Colors.black87,
                              fontStyle: FontStyle.italic,
                              height: 1.9,
                              fontFamily: 'HarmonyOS Sans SC',
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  // 响应速度页（合并最快响应和我回复最快）
  Widget _buildResponseSpeedPage() {
    logger.debug('AnnualReportPage', '========== 构建响应速度页面 ==========');
    logger.debug('AnnualReportPage', '_reportData 是否为 null: ${_reportData == null}');

    if (_reportData == null) {
      logger.error('AnnualReportPage', ' _reportData 为 null！');
      return Container(
        decoration: BoxDecoration(
          gradient: WarmTheme.getPageGradients()[9],
        ),
        child: const Center(child: Text('数据错误：报告数据为空')),
      );
    }

    logger.debug('AnnualReportPage', '_reportData 包含的键: ${_reportData!.keys.toList()}');

    final whoRepliesFastest = _reportData!['whoRepliesFastest'] as List?;
    final myFastestReplies = _reportData!['myFastestReplies'] as List?;

    logger.info('AnnualReportPage', '响应速度数据检查:');
    logger.info('AnnualReportPage', '  whoRepliesFastest: ${whoRepliesFastest == null ? "null" : "List(${whoRepliesFastest.length})"}');
    logger.info('AnnualReportPage', '  myFastestReplies: ${myFastestReplies == null ? "null" : "List(${myFastestReplies.length})"}');

    if (whoRepliesFastest != null && whoRepliesFastest.isNotEmpty) {
      logger.debug('AnnualReportPage', '  whoRepliesFastest 前3条数据:');
      for (int i = 0; i < whoRepliesFastest.length && i < 3; i++) {
        final item = whoRepliesFastest[i];
        logger.debug('AnnualReportPage', '    [$i]: $item');
      }
    }

    if (myFastestReplies != null && myFastestReplies.isNotEmpty) {
      logger.debug('AnnualReportPage', '  myFastestReplies 前3条数据:');
      for (int i = 0; i < myFastestReplies.length && i < 3; i++) {
        final item = myFastestReplies[i];
        logger.debug('AnnualReportPage', '    [$i]: $item');
      }
    }

    if ((whoRepliesFastest == null || whoRepliesFastest.isEmpty) &&
        (myFastestReplies == null || myFastestReplies.isEmpty)) {
      logger.warning('AnnualReportPage', '命中"暂无数据"判定逻辑！');
      logger.warning('AnnualReportPage', '  原因: whoRepliesFastest=${whoRepliesFastest == null ? "null" : "empty"}, myFastestReplies=${myFastestReplies == null ? "null" : "empty"}');
      return Container(
        decoration: BoxDecoration(
          gradient: WarmTheme.getPageGradients()[9],
        ),
        child: const Center(child: Text('暂无数据')),
      );
    }

    logger.info('AnnualReportPage', ' 数据检查通过，开始构建响应速度页面');
    final gradients = WarmTheme.getPageGradients();
    
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: gradients[9], // 响应速度页渐变
          ),
        ),
        // 添加装饰圆点
        const Positioned.fill(
          child: FloatingDots(
            dotCount: 16,
            color: WarmTheme.warmBlue,
            minSize: 2.5,
            maxSize: 6.5,
          ),
        ),
        Container(
      child: SafeArea(
        child: Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = constraints.maxHeight;
              final width = constraints.maxWidth;
              final titleSize = height > 700 ? 36.0 : 32.0;
              final nameSize = height > 700 ? 38.0 : 34.0;
              final textSize = height > 700 ? 22.0 : 20.0;
              
              // 获取第一名
              final fastestPerson = whoRepliesFastest != null && whoRepliesFastest.isNotEmpty
                  ? whoRepliesFastest.first
                  : null;
              final myFastest = myFastestReplies != null && myFastestReplies.isNotEmpty
                  ? myFastestReplies.first
                  : null;
              
              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: width * 0.1,
                  vertical: height * 0.05,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    FadeInText(
                      text: AnnualReportTexts.responseTitle,
                      style: TextStyle(
                        fontSize: titleSize,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF07C160),
                        letterSpacing: 1,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: height * 0.015),
                    FadeInText(
                      text: AnnualReportTexts.responseSubtitle,
                      delay: const Duration(milliseconds: 200),
                      style: TextStyle(
                        fontSize: titleSize - 14,
                        color: Colors.grey[500],
                        letterSpacing: 0.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: height * 0.04),
                    
                    // 谁回复我最快
                    if (fastestPerson != null) ...[
                      FadeInText(
                        text: AnnualReportTexts.responseWhoRepliesYou,
                        delay: const Duration(milliseconds: 300),
                        style: TextStyle(
                          fontSize: textSize - 2,
                          color: Colors.grey[600],
                        ),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: height * 0.02),
                      SlideInCard(
                        delay: const Duration(milliseconds: 600),
                        child: _buildNameWithBlur(
                          fastestPerson['displayName'] as String,
                          TextStyle(
                            fontSize: nameSize,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF07C160),
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                        ),
                      ),
                      SizedBox(height: height * 0.015),
                      FadeInText(
                        text: _formatResponseTime(fastestPerson['avgResponseTimeMinutes'] as num),
                        delay: const Duration(milliseconds: 800),
                        style: TextStyle(
                          fontSize: textSize - 4,
                          color: const Color(0xFF07C160),
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: height * 0.012),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: width * 0.08),
                        child: FadeInText(
                          text: AnnualReportTexts.responseClosing1,
                          delay: const Duration(milliseconds: 900),
                          style: TextStyle(
                            fontSize: textSize - 6,
                            color: Colors.grey[600],
                            fontStyle: FontStyle.italic,
                            height: 1.6,
                            letterSpacing: 0.3,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                    
                    if (fastestPerson != null && myFastest != null)
                      SizedBox(height: height * 0.05),
                    
                    // 我回复最快的人
                    if (myFastest != null) ...[
                      FadeInText(
                        text: AnnualReportTexts.responseYouReplyWho,
                        delay: const Duration(milliseconds: 1000),
                        style: TextStyle(
                          fontSize: textSize - 2,
                          color: Colors.grey[600],
                        ),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: height * 0.02),
                      SlideInCard(
                        delay: const Duration(milliseconds: 1300),
                        child: _buildNameWithBlur(
                          myFastest['displayName'] as String,
                          TextStyle(
                            fontSize: nameSize,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF07C160),
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                        ),
                      ),
                      SizedBox(height: height * 0.015),
                      FadeInText(
                        text: _formatResponseTime(myFastest['avgResponseTimeMinutes'] as num),
                        delay: const Duration(milliseconds: 1500),
                        style: TextStyle(
                          fontSize: textSize - 4,
                          color: const Color(0xFF07C160),
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: height * 0.012),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: width * 0.08),
                        child: FadeInText(
                          text: AnnualReportTexts.responseClosing2,
                          delay: const Duration(milliseconds: 1600),
                          style: TextStyle(
                            fontSize: textSize - 6,
                            color: Colors.grey[600],
                            fontStyle: FontStyle.italic,
                            height: 1.6,
                            letterSpacing: 0.3,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
      ],
    );
  }

  String _formatResponseTime(num minutes) {
    if (minutes < 1) {
      return '${AnnualReportTexts.responseAvgPrefix}${(minutes * 60).toStringAsFixed(0)} 秒';
    } else if (minutes < 60) {
      return '${AnnualReportTexts.responseAvgPrefix}${minutes.toStringAsFixed(1)} 分钟';
    } else {
      final hours = minutes / 60;
      return '${AnnualReportTexts.responseAvgPrefix}${hours.toStringAsFixed(1)} 小时';
    }
  }

  // 曾经的好朋友页
  Widget _buildFormerFriendsPage() {
    final List<dynamic>? formerFriendsJson = _reportData?['formerFriends'];
    final Map<String, dynamic>? stats = _reportData?['formerFriendsStats'] as Map<String, dynamic>?;

    // 检查是否有数据
    if (formerFriendsJson == null || formerFriendsJson.isEmpty) {
      // 检查统计信息，判断是否因为聊天记录不足14天
      String message = AnnualReportTexts.formerFriendNoData;
      String? subtitle;

      if (stats != null) {
        final totalSessions = stats['totalSessions'] as int? ?? 0;
        final sessionsWithMessages = stats['sessionsWithMessages'] as int? ?? 0;
        final sessionsUnder14Days = stats['sessionsUnder14Days'] as int? ?? 0;

        if (totalSessions > 0 && sessionsWithMessages > 0) {
          if (sessionsUnder14Days == sessionsWithMessages) {
            message = AnnualReportTexts.formerFriendInsufficientData;
            subtitle = AnnualReportTexts.formerFriendInsufficientDataDetail;
          } else if (sessionsUnder14Days > 0) {
            message = AnnualReportTexts.formerFriendNoQualified;
            subtitle = '有 $sessionsUnder14Days 个好友聊天记录不足14天\n其他好友未符合"曾经的好朋友"条件';
          } else {
            message = AnnualReportTexts.formerFriendNoQualified;
            subtitle = AnnualReportTexts.formerFriendAllGoodRelations;
          }
        }
      }

      return Container(
        decoration: BoxDecoration(
          gradient: WarmTheme.getPageGradients()[10],
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.people_outline,
                    size: 60,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    message,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        color: Colors.grey[600],
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    // 只显示第一个曾经的好朋友
    final formerFriendData = formerFriendsJson.first as Map<String, dynamic>;
    final displayName = formerFriendData['displayName'] as String;
    final activeStartDate = DateTime.parse(formerFriendData['activeStartDate'] as String);
    final activeEndDate = DateTime.parse(formerFriendData['activeEndDate'] as String);
    final activeDays = formerFriendData['activeDays'] as int;
    final activeDaysCount = formerFriendData['activeDaysCount'] as int;
    final activeMessageCount = formerFriendData['activeMessageCount'] as int;
    final daysSinceActive = formerFriendData['daysSinceActive'] as int;
    const primaryColor = Color(0xFF34C759);
    final gradients = WarmTheme.getPageGradients();

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: gradients[10],
          ),
        ),
        const Positioned.fill(
          child: FloatingDots(
            dotCount: 18,
            color: WarmTheme.warmOrange,
            minSize: 2.5,
            maxSize: 7.0,
          ),
        ),
        Container(
          child: SafeArea(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final height = constraints.maxHeight;
                  final width = constraints.maxWidth;

                  final titleSize = height > 700 ? 36.0 : 32.0;
                  final bodySize = height > 700 ? 24.0 : 22.0;

                  return SingleChildScrollView(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: width * 0.08,
                        vertical: height * 0.08,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // 标题
                          FadeInText(
                            text: AnnualReportTexts.formerFriendTitle,
                            style: TextStyle(
                              fontSize: titleSize,
                              fontWeight: FontWeight.bold,
                              color: primaryColor,
                              letterSpacing: 1,
                              fontFamily: 'HarmonyOS Sans SC',
                            ),
                            textAlign: TextAlign.center,
                          ),
                          SizedBox(height: height * 0.06),

                          // 第一句：还记得XXX吗
                          FadeInRichText(
                            text: '${AnnualReportTexts.formerFriendRemember} $displayName 聊天的时候吗',
                            baseStyle: TextStyle(
                              fontSize: bodySize,
                              color: Colors.black87,
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                            highlights: {
                              displayName: TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF5C6BC0),
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 200),
                          ),
                          SizedBox(height: height * 0.06),

                          // 第二句：时间范围
                          FadeInRichText(
                            text: '从 ${_formatDate(activeStartDate)}${AnnualReportTexts.formerFriendToDate}${_formatDate(activeEndDate)}',
                            baseStyle: TextStyle(
                              fontSize: bodySize,
                              color: Colors.black87,
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                            highlights: {
                              _formatDate(activeStartDate): TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: primaryColor,
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                              _formatDate(activeEndDate): TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: primaryColor,
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 400),
                          ),
                          SizedBox(height: height * 0.04),

                          // 第三句：那XX天里，你们聊了XX天
                          FadeInRichText(
                            text: '${AnnualReportTexts.formerFriendInDaysPrefix}$activeDays${AnnualReportTexts.formerFriendInDaysSuffix}$activeDaysCount${AnnualReportTexts.formerFriendInDaysCount}',
                            baseStyle: TextStyle(
                              fontSize: bodySize,
                              color: Colors.black87,
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                            highlights: {
                              activeDays.toString(): TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: primaryColor,
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                              activeDaysCount.toString(): TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: primaryColor,
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 600),
                          ),
                          SizedBox(height: height * 0.04),

                          // 第四句：一共XX条消息
                          FadeInRichText(
                            text: '${AnnualReportTexts.formerFriendTotalPrefix}$activeMessageCount${AnnualReportTexts.formerFriendTotalSuffix}',
                            baseStyle: TextStyle(
                              fontSize: bodySize,
                              color: Colors.black87,
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                            highlights: {
                              activeMessageCount.toString(): TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: primaryColor,
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 800),
                          ),
                          SizedBox(height: height * 0.08),

                          // 第五句：但现在已经XX天没有联系了
                          FadeInRichText(
                            text: '${AnnualReportTexts.formerFriendButNow}${AnnualReportTexts.formerFriendNoContactPrefix}$daysSinceActive${AnnualReportTexts.formerFriendNoContactSuffix}',
                            baseStyle: TextStyle(
                              fontSize: bodySize,
                              color: Colors.black87,
                              fontFamily: 'HarmonyOS Sans SC',
                              height: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                            highlights: {
                              daysSinceActive.toString(): TextStyle(
                                fontSize: bodySize,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFFFF6B6B),
                                fontFamily: 'HarmonyOS Sans SC',
                              ),
                            },
                            delay: const Duration(milliseconds: 1000),
                          ),
                          SizedBox(height: height * 0.08),

                          // 感悟文字
                          FadeInText(
                            text: AnnualReportTexts.formerFriendClosing,
                            delay: const Duration(milliseconds: 1200),
                            style: TextStyle(
                              fontSize: bodySize - 2,
                              color: Colors.black87,
                              fontStyle: FontStyle.italic,
                              height: 1.9,
                              fontFamily: 'HarmonyOS Sans SC',
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  // 辅助方法：格式化日期
  String _formatDate(DateTime date) {
    return '${date.year}/${date.month}/${date.day}';
  }

  // 结束页 - 简约排版，修复溢出
  Widget _buildEndingPage() {
    final yearText = widget.year != null ? '${widget.year}年' : '这段时光';
    final totalMessages = _getTotalMessages();
    final totalFriends = _getTotalFriends();
    final gradients = WarmTheme.getPageGradients();
    
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: gradients[11], // 结束页渐变
          ),
        ),
        // 添加装饰圆点
        const Positioned.fill(
          child: FloatingDots(
            dotCount: 25,
            color: WarmTheme.primaryGreen,
            minSize: 3.0,
            maxSize: 8.0,
          ),
        ),
        Container(
      child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = constraints.maxHeight;
              final width = constraints.maxWidth;
              final titleSize = height > 700 ? 32.0 : 28.0;
            final numberSize = height > 700 ? 56.0 : 48.0;
            final textSize = height > 700 ? 17.0 : 15.0;
            final smallSize = height > 700 ? 14.0 : 13.0;
            
            return Stack(
              children: [
                // 顶部标题
                Positioned(
                  left: width * 0.08,
                  top: height * 0.1,
                  right: width * 0.08,
          child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FadeInText(
                      text: '$yearText${AnnualReportTexts.endingTitleSuffix}',
                      style: TextStyle(
                        fontSize: titleSize,
                  fontWeight: FontWeight.bold,
                        color: const Color(0xFF07C160),
                        letterSpacing: 2,
                ),
              ),
                      SizedBox(height: 8),
              FadeInText(
                        text: AnnualReportTexts.endingSubtitle,
                      delay: const Duration(milliseconds: 300),
                      style: TextStyle(
                        fontSize: textSize,
                          color: Colors.grey[500],
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                
                // 中间数据区域
                Positioned(
                  left: width * 0.12,
                  top: height * 0.32,
                  child: SlideInCard(
                    delay: const Duration(milliseconds: 600),
                        child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        AnimatedNumberDisplay(
                          value: totalMessages.toDouble(),
                          suffix: '',
                              style: TextStyle(
                            fontSize: numberSize,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF07C160),
                            height: 1.0,
                          ),
                        ),
                        SizedBox(height: 4),
                            Text(
                          AnnualReportTexts.endingMessagesUnit,
                              style: TextStyle(
                            fontSize: textSize - 2,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                
                Positioned(
                  right: width * 0.12,
                  top: height * 0.48,
                  child: SlideInCard(
                    delay: const Duration(milliseconds: 800),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        AnimatedNumberDisplay(
                          value: totalFriends.toDouble(),
                          suffix: '',
                          style: TextStyle(
                            fontSize: numberSize * 0.7,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF07C160),
                            height: 1.0,
                          ),
                        ),
                        SizedBox(height: 4),
                            Text(
                          AnnualReportTexts.endingFriendsUnit,
                              style: TextStyle(
                            fontSize: textSize - 3,
                            color: Colors.grey[600],
                          ),
                            ),
                          ],
                        ),
                      ),
                    ),
                
                // 中间分隔线
                Positioned(
                  left: width * 0.3,
                  right: width * 0.3,
                  top: height * 0.58,
                  child: SlideInCard(
                    delay: const Duration(milliseconds: 1000),
                    child: Container(
                      height: 1,
                      color: Colors.grey[300],
                    ),
                  ),
                ),
                
                // 底部温暖寄语
                Positioned(
                  left: width * 0.1,
                  right: width * 0.1,
                  bottom: height * 0.08,
                  child: Column(
                    children: [
                    FadeInText(
                        text: AnnualReportTexts.endingPoem1,
                        delay: const Duration(milliseconds: 1200),
                      style: TextStyle(
                          fontSize: textSize,
                          color: Colors.grey[700],
                          height: 1.9,
                          letterSpacing: 0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: height * 0.04),
                    FadeInText(
                        text: AnnualReportTexts.endingPoem2,
                        delay: const Duration(milliseconds: 1400),
                      style: TextStyle(
                          fontSize: smallSize,
                          color: Colors.grey[500],
                          fontStyle: FontStyle.italic,
                          height: 2.0,
                          letterSpacing: 0.3,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: height * 0.02),
                    ],
                  ),
                ),
              ],
              );
            },
        ),
      ),
    ),
      ],
    );
  }

  // 显示导出对话框
  void _showExportDialog() {
    String tempHideMode = _nameHideMode;
    bool tempSeparateImages = _exportAsSeparateImages;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('导出年度报告'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('导出格式：', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                RadioListTile<bool>(
                  title: const Text('合并为一张长图'),
                  subtitle: const Text('所有页面拼接成一张图片'),
                  value: false,
                  groupValue: tempSeparateImages,
                  onChanged: (value) {
                    setState(() => tempSeparateImages = value!);
                  },
                ),
                RadioListTile<bool>(
                  title: const Text('分开保存'),
                  subtitle: const Text('每页单独保存为一张图片'),
                  value: true,
                  groupValue: tempSeparateImages,
                  onChanged: (value) {
                    setState(() => tempSeparateImages = value!);
                  },
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 16),
                const Text('联系人信息显示：', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                RadioListTile<String>(
                  title: const Text('显示完整信息'),
                  value: 'none',
                  groupValue: tempHideMode,
                  onChanged: (value) {
                    setState(() => tempHideMode = value!);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('仅保留姓氏'),
                  value: 'firstChar',
                  groupValue: tempHideMode,
                  onChanged: (value) {
                    setState(() => tempHideMode = value!);
                  },
                ),
                RadioListTile<String>(
                  title: const Text('完全隐藏'),
                  value: 'full',
                  groupValue: tempHideMode,
                  onChanged: (value) {
                    setState(() => tempHideMode = value!);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                this.setState(() {
                  _nameHideMode = tempHideMode;
                  _exportAsSeparateImages = tempSeparateImages;
                });
                Navigator.pop(context);
                _exportReport();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF07C160),
                foregroundColor: Colors.white,
              ),
              child: const Text('开始导出'),
            ),
          ],
        ),
      ),
    );
  }

  // 导出报告
  Future<void> _exportReport() async {
    if (_isExporting) return;

    setState(() => _isExporting = true);

    // 显示进度对话框
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => WillPopScope(
          onWillPop: () async => false,
          child: const AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('正在生成图片，请稍候...'),
              ],
            ),
          ),
        ),
      );
    }

    try {
      // 获取保存目录
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final yearText = widget.year != null ? '${widget.year}年' : '全部';

      // 创建专门的导出文件夹：EchoTrace/年度报告_YYYY_timestamp
      final exportDirName = '年度报告_${yearText}_$timestamp';
      final exportDir = Directory('${directory.path}/EchoTrace/$exportDirName');

      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }

      final images = <Uint8List>[];

      // 记录当前页面
      final originalPage = _currentPage;

      // 通过翻页截图的方式获取所有页面
      for (int i = 0; i < _pages!.length; i++) {
        // 跳转到指定页面
        _pageController.jumpToPage(i);

        // 等待页面切换动画完成
        await Future.delayed(const Duration(milliseconds: 500));

        // 等待所有帧完成渲染（包括文本和emoji）
        await SchedulerBinding.instance.endOfFrame;
        await Future.delayed(const Duration(milliseconds: 100));

        // 再等待确保emoji字体加载完成
        await Future.delayed(const Duration(milliseconds: 2000));

        // 再次等待一帧，确保所有内容都已完全绘制
        await SchedulerBinding.instance.endOfFrame;

        // 截取当前页面
        try {
          final boundary = _pageViewKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
          if (boundary != null) {
            // 标记需要重绘
            boundary.markNeedsPaint();

            // 等待重绘完成
            await Future.delayed(const Duration(milliseconds: 200));
            await SchedulerBinding.instance.endOfFrame;

            // 执行截图
            final image = await boundary.toImage(pixelRatio: 3.0);
            final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
            if (byteData != null) {
              images.add(byteData.buffer.asUint8List());
            }
          }
        } catch (e) {
        }
      }

      // 恢复到原始页面
      _pageController.jumpToPage(originalPage);

      if (images.isEmpty) {
        throw Exception('生成图片失败：所有页面截图都失败了');
      }

      String resultMessage;

      if (_exportAsSeparateImages) {
        // 分开保存每一页
        for (int i = 0; i < images.length; i++) {
          final filePath = '${exportDir.path}/page_${i + 1}.png';
          final file = File(filePath);
          await file.writeAsBytes(images[i]);
        }
        resultMessage = '导出成功！\n保存位置：${exportDir.path}\n共生成 ${images.length} 张图片';
      } else {
        // 合并为一张长图
        final combinedImage = await compute(_combineImagesInBackground, images);
        final filePath = '${exportDir.path}/年度报告_合并.png';
        final file = File(filePath);
        await file.writeAsBytes(combinedImage);
        resultMessage = '导出成功！\n保存位置：$filePath\n共合并 ${images.length} 页';
      }

      // 关闭进度对话框
      if (mounted) {
        Navigator.of(context).pop();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(resultMessage),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      // 关闭进度对话框
      if (mounted) {
        Navigator.of(context).pop();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
          _nameHideMode = 'none'; // 恢复显示
          _exportAsSeparateImages = false; // 恢复默认
        });
      }
    }
  }


  // 拼接多张图片为一张长图（后台线程执行）
  static Future<Uint8List> _combineImagesInBackground(List<Uint8List> images) async {
    final decodedImages = <img.Image>[];
    int totalHeight = 0;
    int maxWidth = 0;

    // 解码所有图片并计算总高度
    for (final imageBytes in images) {
      final decodedImage = img.decodeImage(imageBytes);
      if (decodedImage != null) {
        decodedImages.add(decodedImage);
        totalHeight += decodedImage.height;
        if (decodedImage.width > maxWidth) {
          maxWidth = decodedImage.width;
        }
      }
    }

    // 创建新图片
    final combined = img.Image(width: maxWidth, height: totalHeight);
    
    // 填充白色背景
    img.fill(combined, color: img.ColorRgb8(255, 255, 255));

    // 拼接图片
    int currentY = 0;
    for (final image in decodedImages) {
      img.compositeImage(combined, image, dstY: currentY);
      currentY += image.height;
    }

    // 编码为PNG
    return Uint8List.fromList(img.encodePng(combined));
  }


  // 处理名字隐藏 - 使用高斯模糊覆盖
  Widget _buildNameWithBlur(String name, TextStyle style, {TextAlign? textAlign, int? maxLines}) {
    if (_nameHideMode == 'none') {
      return Text(
        name,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: maxLines != null ? TextOverflow.ellipsis : null,
      );
    }

    // 保留首字模式：只模糊后面的字
    if (_nameHideMode == 'firstChar' && name.isNotEmpty) {
      // 使用 characters 正确处理 emoji 等复杂字符
      final characters = name.characters;
      if (characters.isEmpty) {
        return Text('', style: style);
      }
      
      final firstChar = characters.first;
      final restChars = characters.length > 1 
          ? characters.skip(1).toString() 
          : '';
      
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 第一个字符不模糊
          Text(
            firstChar,
            style: style,
          ),
          // 后面的字模糊
          if (restChars.isNotEmpty)
            Stack(
              children: [
                Text(
                  restChars,
                  style: style,
                ),
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(
                        sigmaX: 15.0,
                        sigmaY: 15.0,
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
        ],
      );
    }

    // 完全隐藏模式：全部模糊
    return Stack(
      children: [
        Text(
          name,
          style: style,
          textAlign: textAlign,
          maxLines: maxLines,
          overflow: maxLines != null ? TextOverflow.ellipsis : null,
        ),
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: 15.0,
                sigmaY: 15.0,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
