import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/database_service.dart';
import '../services/dual_report_service.dart';
import '../services/dual_report_cache_service.dart';
import '../widgets/annual_report/dual_report_html_renderer.dart';

/// 双人报告浏览器展示页面（类似年度报告）
class DualReportBrowserPage extends StatefulWidget {
  final String friendUsername;
  final String friendName;
  final DatabaseService databaseService;
  final int? year;

  const DualReportBrowserPage({
    super.key,
    required this.friendUsername,
    required this.friendName,
    required this.databaseService,
    this.year,
  });

  @override
  State<DualReportBrowserPage> createState() => _DualReportBrowserPageState();
}

class _DualReportBrowserPageState extends State<DualReportBrowserPage> {
  bool _isGenerating = true;
  String? _reportHtml;
  String? _reportUrl;
  HttpServer? _server;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _generateReport();
  }

  @override
  void dispose() {
    _server?.close();
    super.dispose();
  }

  /// 生成报告
  Future<void> _generateReport() async {
    setState(() {
      _isGenerating = true;
      _errorMessage = null;
    });

    try {
      // 首先检查缓存
      final cachedData = await DualReportCacheService.loadReport(widget.friendUsername, widget.year);
      if (cachedData != null) {
        // 使用缓存数据生成HTML
        final html = await DualReportHtmlRenderer.build(
          reportData: cachedData,
          myName: '我',
          friendName: widget.friendName,
        );

        if (!mounted) return;
        setState(() {
          _reportHtml = html;
        });

        // 启动服务器并打开浏览器
        if (!mounted) return;
        await _startReportServer();
        return;
      }

      // 获取当前用户wxid
      final myWxid = widget.databaseService.currentAccountWxid ?? '我';

      // 生成数据
      final service = DualReportService(widget.databaseService);
      final reportData = await service.generateDualReportData(
        friendUsername: widget.friendUsername,
        friendName: widget.friendName,
        myName: myWxid,
        year: widget.year,
      );

      // 保存到缓存
      await DualReportCacheService.saveReport(widget.friendUsername, widget.year, reportData);

      // 生成HTML
      final html = await DualReportHtmlRenderer.build(
        reportData: reportData,
        myName: '我',
        friendName: widget.friendName,
      );

      if (!mounted) return;
      setState(() {
        _reportHtml = html;
      });

      // 启动服务器并打开浏览器
      if (!mounted) return;
      await _startReportServer();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '生成报告失败: $e';
        _isGenerating = false;
      });
    }
  }

  /// 启动HTTP服务器
  Future<void> _startReportServer() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _reportUrl = 'http://127.0.0.1:${server.port}/';
    _server = server;

    // 监听请求
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write(_reportHtml);
      await request.response.close();
    });

    setState(() {
      _isGenerating = false;
    });

    // 打开浏览器
    final uri = Uri.parse(_reportUrl!);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.friendName} 的双人报告'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isGenerating) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在生成报告...'),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
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
              _errorMessage!,
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('返回'),
            ),
          ],
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 64,
            color: Colors.green,
          ),
          const SizedBox(height: 16),
          const Text('报告已在浏览器中打开'),
          const SizedBox(height: 8),
          Text(
            '如果浏览器未自动打开，请访问：\n$_reportUrl',
            style: TextStyle(color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }
}
