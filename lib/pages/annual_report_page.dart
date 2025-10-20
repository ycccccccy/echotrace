import 'package:flutter/material.dart';
import '../services/database_service.dart';
import '../services/analytics_background_service.dart';
import '../services/annual_report_cache_service.dart';
import '../widgets/annual_report/year_selector_widget.dart';
import '../widgets/annual_report/generation_progress_page.dart';
import 'annual_report_display_page.dart';

/// 页面状态枚举
enum ReportPageState {
  selectYear,   // 选择年份
  generating,   // 生成中
  display,      // 展示报告
}

/// 年度报告主页面
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
  AnalyticsBackgroundService? _backgroundService;
  
  // 状态管理
  ReportPageState _currentState = ReportPageState.selectYear;
  
  // 年份数据
  final List<int> _availableYears = []; // 不再自动检测，留空即可
  int? _selectedYear; // null表示"历史以来"（默认选中）
  bool _isLoadingYears = false; // 不需要扫描
  
  // 报告数据
  Map<String, dynamic>? _reportData;
  
  // 进度数据
  final Map<String, String> _taskStatus = {};
  int _totalProgress = 0;

  @override
  void initState() {
    super.initState();
    // 默认选中"历史以来"（null表示历史以来）
    _selectedYear = null;
      final dbPath = widget.databaseService.dbPath;
      if (dbPath != null) {
      _backgroundService = AnalyticsBackgroundService(dbPath);
    }
    // 不再自动检测年份，避免数据库锁定问题
  }


  /// 开始生成报告
  Future<void> _startGenerateReport() async {
    // 检查服务是否已初始化
    if (_backgroundService == null) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('服务未初始化，请检查数据库配置')),
              );
          }
          return;
        }
        
    // 检查是否有缓存
    final hasCache = await AnnualReportCacheService.hasReport(_selectedYear);
    
    if (hasCache) {
      // 有缓存，直接加载
      final cachedData = await AnnualReportCacheService.loadReport(_selectedYear);
      if (cachedData != null && mounted) {
        setState(() {
          _reportData = cachedData;
          _currentState = ReportPageState.display;
        });
        return;
      }
    }
    
    // 没有缓存，开始生成
    setState(() {
      _currentState = ReportPageState.generating;
      _taskStatus.clear();
      _totalProgress = 0;
    });
    
    try {
      
      // 并行生成报告
      final data = await _backgroundService!.generateFullAnnualReport(
        _selectedYear,
        (taskName, status, progress) {
          if (mounted) {
      setState(() {
              _taskStatus[taskName] = status;
              _totalProgress = progress;
            });
          }
        },
      );
      
      
      // 保存缓存
      await AnnualReportCacheService.saveReport(_selectedYear, data);
      
      
      // 进入展示模式
      if (mounted) {
      setState(() {
          _reportData = data;
          _currentState = ReportPageState.display;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('生成报告失败: ${e.toString()}'),
            duration: const Duration(seconds: 5),
          ),
        );
        setState(() {
          _currentState = ReportPageState.selectYear;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: _buildBody(),
    );
  }

  PreferredSizeWidget? _buildAppBar() {
    if (_currentState == ReportPageState.display) {
      return null; // 展示模式下不显示AppBar
    }
    
    return AppBar(
      title: Text(_getTitle()),
      backgroundColor: Colors.white,
      foregroundColor: Colors.black,
      elevation: 0,
    );
  }

  String _getTitle() {
    switch (_currentState) {
      case ReportPageState.selectYear:
        return '年度报告';
      case ReportPageState.generating:
        return '生成报告中';
      case ReportPageState.display:
        return '';
    }
  }

  Widget _buildBody() {
    switch (_currentState) {
      case ReportPageState.selectYear:
        if (_isLoadingYears) {
          return const Center(
      child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
        children: [
                CircularProgressIndicator(
                  color: Color(0xFF07C160),
                ),
                SizedBox(height: 24),
                              Text(
                  '正在扫描可用年份...',
                  style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
        ],
      ),
    );
  }
  
        return YearSelectorWidget(
          availableYears: _availableYears,
          selectedYear: _selectedYear,
          onYearSelected: (year) {
            setState(() => _selectedYear = year);
          },
          onConfirm: _startGenerateReport,
        );
        
      case ReportPageState.generating:
        return GenerationProgressPage(
          taskStatus: _taskStatus,
          totalProgress: _totalProgress,
        );
        
      case ReportPageState.display:
        if (_reportData == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return AnnualReportDisplayPage(
          reportData: _reportData!,
          year: _selectedYear,
        );
    }
  }
}
