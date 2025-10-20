import 'package:flutter/material.dart';
import '../services/dual_report_service.dart';
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
  @override
  void initState() {
    super.initState();
    // 在frame渲染完成后直接显示好友列表
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectFriend();
    });
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
    
    // 生成完整的双人报告
    if (!mounted) return;
    await _generateReport(
      dualReportService: dualReportService,
      friendUsername: selectedFriend['username'] as String,
    );
  }

  Future<void> _generateReport({
    required DualReportService dualReportService,
    required String friendUsername,
  }) async {
    try {
      // 生成完整的双人报告数据
      final reportData = await dualReportService.generateDualReport(
        friendUsername: friendUsername,
        filterYear: null,
      );
      
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('生成报告失败: $e')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF07C160),
      body: Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
        ),
      ),
    );
  }
}

