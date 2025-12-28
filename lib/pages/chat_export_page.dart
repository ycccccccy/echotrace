import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_state.dart';
import '../models/chat_session.dart';
import '../models/contact_record.dart';
import '../models/message.dart';
import '../services/chat_export_service.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import '../widgets/common/shimmer_loading.dart';
import '../widgets/toast_overlay.dart';
import '../utils/string_utils.dart';

/// 聊天记录导出页面
class ChatExportPage extends StatefulWidget {
  const ChatExportPage({super.key});

  @override
  State<ChatExportPage> createState() => _ChatExportPageState();
}

class _ChatExportPageState extends State<ChatExportPage>
    with TickerProviderStateMixin {
  late final ToastOverlay _toast;
  List<ChatSession> _allSessions = [];
  Set<String> _selectedSessions = {};
  bool _isLoadingSessions = false;
  bool _selectAll = false;
  String _searchQuery = '';
  String _selectedFormat = 'json';
  DateTimeRange? _selectedRange;
  String? _exportFolder;
  bool _isAutoConnecting = false;
  bool _autoLoadScheduled = false;
  bool _hasAttemptedRefreshAfterConnect = false;
  bool _useAllTime = false;
  bool _isExportingContacts = false;
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;

  // 添加静态缓存变量，用于存储会话列表
  static List<ChatSession>? _cachedSessions;

  @override
  void initState() {
    super.initState();
    _toast = ToastOverlay(this);
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
    _searchController.addListener(_handleSearchQueryChanged);
    _searchFocusNode.addListener(_handleSearchFocusChange);
    _loadSessions();
    _loadExportFolder();
    // 默认选择最近7天
    _selectedRange = DateTimeRange(
      start: DateTime.now().subtract(const Duration(days: 7)),
      end: DateTime.now(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureConnected();
    });
  }

  @override
  void dispose() {
    _toast.dispose();
    _searchController.removeListener(_handleSearchQueryChanged);
    _searchController.dispose();
    _searchFocusNode.removeListener(_handleSearchFocusChange);
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _handleSearchFocusChange() {
    if (_searchFocusNode.hasFocus) {
      // ignore: invalid_use_of_visible_for_testing_member
      HardwareKeyboard.instance.clearState();
    }
  }

  void _handleSearchQueryChanged() {
    final value = _searchController.text;
    if (value == _searchQuery) return;
    setState(() {
      _searchQuery = value;
      _selectAll = false;
    });
  }

  Future<void> _loadExportFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final folder = prefs.getString('export_folder');
    if (!mounted || folder == null) return;

    setState(() {
      _exportFolder = folder;
    });
  }

  Future<void> _selectExportFolder() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择导出文件夹',
    );

    if (!mounted || result == null) {
      return;
    }

    setState(() {
      _exportFolder = result;
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('export_folder', result);

    if (!mounted) return;

    _toast.show(context, '已设置导出文件夹: $result');
  }

  Future<void> _exportContacts() async {
    final appState = context.read<AppState>();
    if (!appState.databaseService.isConnected) {
      if (mounted) {
        _toast.show(context, '请先连接数据库后再导出通讯录', success: false);
      }
      return;
    }

    setState(() {
      _isExportingContacts = true;
    });

    try {
      final databaseService = appState.databaseService;
      final allRecords = await databaseService.getAllContacts(
        includeStrangers: true,
        includeChatroomParticipants: true,
      );

      final friendRecords = allRecords
          .where(
            (record) =>
                record.source == ContactRecognitionSource.friend &&
                record.contact.localType == 1,
          )
          .toList();
      final groupOnlyRecords = allRecords
          .where(
            (record) =>
                record.source == ContactRecognitionSource.chatroomParticipant,
          )
          .toList();
      final strangerRecords = allRecords
          .where((record) => record.source == ContactRecognitionSource.stranger)
          .toList();

      final exportService = ChatExportService(databaseService);
      final success = await exportService.exportContactsToExcel(
        directoryPath: _exportFolder,
        contacts: friendRecords,
      );

      if (!mounted) return;

      final summary = StringBuffer(success ? '通讯录导出成功' : '没有可导出的联系人或导出被取消')
        ..write('（好友 ')
        ..write(friendRecords.length)
        ..write(' 人');

      if (groupOnlyRecords.isNotEmpty) {
        summary
          ..write('，群聊成员未导出 ')
          ..write(groupOnlyRecords.length)
          ..write(' 人');
      }

      if (strangerRecords.isNotEmpty) {
        summary
          ..write('，陌生人未导出 ')
          ..write(strangerRecords.length)
          ..write(' 人');
      }

      summary.write('）');

      _toast.show(context, summary.toString());
    } catch (e) {
      if (mounted) {
        _toast.show(context, '导出通讯录失败: $e', success: false);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isExportingContacts = false;
        });
      }
    }
  }

  Future<void> _ensureConnected() async {
    final appState = context.read<AppState>();
    if (!appState.isConfigured) return;
    if (appState.databaseService.isConnected || appState.isLoading) return;
    if (_isAutoConnecting) return;

    setState(() {
      _isAutoConnecting = true;
      _hasAttemptedRefreshAfterConnect = false;
    });
    try {
      await appState.reconnectDatabase();
      if (mounted) {
        await _loadSessions();
        _hasAttemptedRefreshAfterConnect = true;
      }
    } catch (_) {
      // 失败交给 UI 提示
    } finally {
      if (mounted) {
        setState(() {
          _isAutoConnecting = false;
        });
        // 若仍未连接，再尝试一次刷新会话列表以防遗漏
        if (!_hasAttemptedRefreshAfterConnect &&
            appState.databaseService.isConnected) {
          _hasAttemptedRefreshAfterConnect = true;
          unawaited(_loadSessions());
        }
      }
    }
  }

  Future<void> _loadSessions() async {
    // 首先检查缓存是否存在
    if (_cachedSessions != null) {
      setState(() {
        _allSessions = _cachedSessions!;
        _isLoadingSessions = false;
      });
      return;
    }

    setState(() {
      _isLoadingSessions = true;
    });

    try {
      final appState = context.read<AppState>();

      if (!appState.databaseService.isConnected) {
        if (mounted) {
          setState(() {
            _isLoadingSessions = false;
          });
        }
        return;
      }

      final sessions = await appState.databaseService.getSessions();

      // 过滤掉公众号/服务号
      final filteredSessions = sessions.where((session) {
        return ChatSession.shouldKeep(session.username);
      }).toList(); // 保存到缓存
      _cachedSessions = filteredSessions;

      if (mounted) {
        setState(() {
          _allSessions = filteredSessions;
          _isLoadingSessions = false;
        });
      }

      // 异步加载头像（使用全局缓存）
      try {
        await appState.fetchAndCacheAvatars(
          filteredSessions.map((s) => s.username).toList(),
        );
      } catch (_) {}
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingSessions = false;
        });
        _toast.show(context, '加载会话列表失败: $e', success: false);
      }
    }
  }

  // 修改刷新方法，清除缓存后重新加载
  Future<void> _refreshSessions() async {
    // 清除缓存
    _cachedSessions = null;
    // 清除已选会话，避免刷新后选中状态与新列表不匹配
    setState(() {
      _selectedSessions.clear();
      _selectAll = false;
    });
    // 重新加载数据
    await _loadSessions();

    if (mounted) {
      _toast.show(context, '会话列表已刷新');
    }
  }

  List<ChatSession> get _filteredSessions {
    if (_searchQuery.isEmpty) return _allSessions;

    return _allSessions.where((session) {
      final displayName = session.displayName ?? session.username;
      return displayName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          session.username.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();
  }

  void _toggleSelectAll() {
    setState(() {
      _selectAll = !_selectAll;
      if (_selectAll) {
        _selectedSessions = _filteredSessions.map((s) => s.username).toSet();
      } else {
        _selectedSessions.clear();
      }
    });
  }

  void _toggleSession(String username) {
    setState(() {
      if (_selectedSessions.contains(username)) {
        _selectedSessions.remove(username);
        _selectAll = false;
      } else {
        _selectedSessions.add(username);
        if (_selectedSessions.length == _filteredSessions.length) {
          _selectAll = true;
        }
      }
    });
  }

  Future<void> _selectDateRange() async {
    if (_useAllTime) {
      _toast.show(context, '已选择全部时间，无需设置日期范围');
      return;
    }

    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _selectedRange,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: Theme.of(context).colorScheme.primary,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedRange = picked;
      });
    }
  }

  Future<void> _startExport() async {
    if (_selectedSessions.isEmpty) {
      _toast.show(context, '请至少选择一个会话', success: false);
      return;
    }

    if (_exportFolder == null) {
      _toast.show(context, '请先选择导出文件夹', success: false);
      return;
    }

    // 显示确认对话框
    final dateRangeText = _useAllTime
        ? '全部时间'
        : '${_selectedRange!.start.toLocal().toString().split(' ')[0]} 至 ${_selectedRange!.end.toLocal().toString().split(' ')[0]}';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认导出'),
        content: Text(
          '将导出 ${_selectedSessions.length} 个会话的聊天记录\n'
          '日期范围: $dateRangeText\n'
          '导出格式: ${_getFormatName(_selectedFormat)}\n'
          '导出位置: $_exportFolder\n\n'
          '此操作可能需要一些时间，请耐心等待。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始导出'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // 显示进度对话框
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ExportProgressDialog(
        sessions: _selectedSessions.toList(),
        allSessions: _allSessions,
        format: _selectedFormat,
        dateRange: _selectedRange!,
        exportFolder: _exportFolder!,
        useAllTime: _useAllTime,
      ),
    );
  }

  String _getFormatName(String format) {
    switch (format) {
      case 'json':
        return 'JSON';
      case 'html':
        return 'HTML';
      case 'xlsx':
        return 'Excel';
      case 'sql':
        return 'SQL';
      default:
        return format.toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final hasError = appState.errorMessage != null;
    final isConnecting =
        appState.isLoading ||
        _isAutoConnecting ||
        (!appState.databaseService.isConnected && !hasError);
    final showErrorOverlay =
        !appState.isLoading &&
        !appState.databaseService.isConnected &&
        hasError;

    if (!isConnecting &&
        !_isLoadingSessions &&
        _allSessions.isEmpty &&
        !_autoLoadScheduled &&
        appState.databaseService.isConnected) {
      _autoLoadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        _autoLoadScheduled = false;
        await _loadSessions();
      });
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: AnimatedPageWrapper(
        child: Stack(
          children: [
            Column(
              children: [
                _buildHeader(),
                _buildFilterBar(),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(flex: 2, child: _buildSessionList()),
                      Container(
                        width: 1,
                        color: Colors.grey.withValues(alpha: 0.2),
                      ),
                      Expanded(flex: 1, child: _buildExportSettings()),
                    ],
                  ),
                ),
              ],
            ),

            // 遮罩层 (加载/错误)
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                switchInCurve: Curves.easeInOutCubic,
                switchOutCurve: Curves.easeInOutCubic,
                transitionBuilder: (child, animation) {
                  // 出入场动画
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: animation.drive(
                        Tween<double>(
                          begin: 0.96,
                          end: 1.0,
                        ).chain(CurveTween(curve: Curves.easeOutCubic)),
                      ),
                      child: child,
                    ),
                  );
                },
                child: showErrorOverlay
                    ? Container(
                        key: const ValueKey('error_overlay'),
                        color: Colors.white,
                        child: Center(
                          child: _buildErrorOverlay(
                            context,
                            appState,
                            appState.errorMessage ?? '未能连接数据库',
                          ),
                        ),
                      )
                    : isConnecting
                    ? Container(
                        key: const ValueKey('loading_overlay'),
                        color: Colors.white.withValues(alpha: 0.98),
                        child: Center(child: _buildFancyLoader(context)),
                      )
                    : const SizedBox.shrink(key: ValueKey('none')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFancyLoader(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 800),
      curve: Curves.elasticOut,
      builder: (context, value, child) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 80,
              height: 40,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(4, (index) {
                  return _AnimatedBar(
                    index: index,
                    color: color,
                    baseHeight: 12,
                    maxExtraHeight: 24,
                  );
                }),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '正在建立连接...',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildErrorOverlay(
    BuildContext context,
    AppState appState,
    String message,
  ) {
    final theme = Theme.of(context);
    final lower = message.toLowerCase();
    bool isMissingDb =
        lower.contains('未找到') ||
        lower.contains('不存在') ||
        lower.contains('no such file') ||
        lower.contains('not found');

    return Container(
      constraints: const BoxConstraints(maxWidth: 400),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.error.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.error_outline_rounded,
              size: 40,
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            isMissingDb ? '未找到数据库文件' : '数据库连接异常',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isMissingDb ? '请先在「数据管理」页面解密对应账号的数据库。' : message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () =>
                    context.read<AppState>().setCurrentPage('data_management'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('前往管理'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: _ensureConnected,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('重试'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
            color: Colors.grey.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.file_download_outlined,
              size: 24,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '导出聊天记录',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontSize: 22,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '选择会话并配置导出参数',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey.shade500,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refreshSessions,
            tooltip: '刷新列表',
            style: IconButton.styleFrom(
              backgroundColor: Colors.grey.shade50,
              padding: const EdgeInsets.all(12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
            color: Colors.grey.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                decoration: InputDecoration(
                  hintText: '搜索联系人或群组...',
                  hintStyle: TextStyle(
                    color: Colors.grey.shade400,
                    fontSize: 14,
                  ),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: Colors.grey.shade400,
                    size: 20,
                  ),
                  filled: true,
                  fillColor: Colors.grey.shade50,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade200),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.5),
                      width: 1.5,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            _searchFocusNode.requestFocus();
                          },
                        )
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(width: 24),
          OutlinedButton.icon(
            onPressed: _toggleSelectAll,
            label: Text(_selectAll ? '重置选择' : '快速全选'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(width: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '已选 ${_selectedSessions.length}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionList() {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        if (!appState.databaseService.isConnected) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.storage_rounded,
                  size: 64,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  '数据库未连接',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.7),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '请先在「数据管理」页面解密数据库文件',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          );
        }

        if (_isLoadingSessions) {
          return ShimmerLoading(
            isLoading: true,
            child: ListView.builder(
              itemCount: 6,
              physics: const NeverScrollableScrollPhysics(),
              itemBuilder: (context, index) => const ListItemShimmer(),
            ),
          );
        }

        final sessions = _filteredSessions;

        if (sessions.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  size: 64,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  _searchQuery.isEmpty ? '暂无会话' : '未找到匹配的会话',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          itemCount: sessions.length,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          separatorBuilder: (context, index) =>
              const Divider(height: 1, indent: 72),
          itemBuilder: (context, index) {
            final session = sessions[index];
            final isSelected = _selectedSessions.contains(session.username);
            final avatarUrl = appState.getAvatarUrl(session.username);

            return InkWell(
              onTap: () => _toggleSession(session.username),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 8,
                ),
                child: Row(
                  children: [
                    // 头像部分
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: (avatarUrl != null && avatarUrl.isNotEmpty)
                                ? CachedNetworkImage(
                                    imageUrl: avatarUrl,
                                    imageBuilder: (context, imageProvider) =>
                                        Container(
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            image: DecorationImage(
                                              image: imageProvider,
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                        ),
                                    placeholder: (context, url) =>
                                        _buildAvatarPlaceholder(
                                          context,
                                          session,
                                          isSelected,
                                        ),
                                    errorWidget: (context, url, error) =>
                                        _buildAvatarPlaceholder(
                                          context,
                                          session,
                                          isSelected,
                                        ),
                                  )
                                : _buildAvatarPlaceholder(
                                    context,
                                    session,
                                    isSelected,
                                  ),
                          ),
                          if (isSelected)
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.check_circle_rounded,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    // 会话信息
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            session.displayName ?? session.username,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            session.typeDescription,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 选择框
                    Checkbox(
                      value: isSelected,
                      onChanged: (value) => _toggleSession(session.username),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      activeColor: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAvatarPlaceholder(
    BuildContext context,
    ChatSession session,
    bool isSelected,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: isSelected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Text(
          StringUtils.getFirstChar(session.displayName ?? session.username),
          style: TextStyle(
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade600,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      ),
    );
  }

  Widget _buildExportSettings() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(
          left: BorderSide(
            color: Colors.grey.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 24),
            child: Text(
              '导出配置',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                fontSize: 20,
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSettingSection(
                    title: '存储位置',
                    child: OutlinedButton.icon(
                      onPressed: _selectExportFolder,
                      icon: Icon(
                        Icons.folder_open_rounded,
                        size: 18,
                        color: Colors.grey.shade600,
                      ),
                      label: Text(
                        _exportFolder ?? '选择导出目录',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _exportFolder != null
                              ? Colors.black87
                              : Colors.grey.shade400,
                          fontSize: 13,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        alignment: Alignment.centerLeft,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        backgroundColor: Colors.white,
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildSettingSection(
                    title: '通讯录备份',
                    subtitle: '将联系人列表导出为 Excel',
                    child: OutlinedButton.icon(
                      onPressed: _isExportingContacts ? null : _exportContacts,
                      icon: _isExportingContacts
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.contact_page_outlined, size: 18),
                      label: Text(_isExportingContacts ? '处理中...' : '立即导出通讯录'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        backgroundColor: Colors.white,
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildSettingSection(
                    title: '时间范围',
                    subtitle: _useAllTime ? '导出所有时间的消息' : '仅导出选定日期的消息',
                    child: Column(
                      children: [
                        SwitchListTile(
                          value: _useAllTime,
                          onChanged: (v) => setState(() => _useAllTime = v),
                          title: const Text(
                            '全部时间',
                            style: TextStyle(fontSize: 14),
                          ),
                          contentPadding: EdgeInsets.zero,
                          activeColor: Theme.of(context).colorScheme.primary,
                        ),
                        if (!_useAllTime)
                          InkWell(
                            onTap: _selectDateRange,
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                border: Border.all(color: Colors.grey.shade200),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.calendar_today_rounded,
                                    size: 16,
                                    color: Colors.grey.shade600,
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    _selectedRange == null
                                        ? '选择日期范围'
                                        : '${_selectedRange!.start.toString().split(' ')[0]} 至 ${_selectedRange!.end.toString().split(' ')[0]}',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildSettingSection(
                    title: '导出格式',
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Column(
                        children: [
                          _buildFormatOption('json', 'JSON', '结构化数据，适合导入/分析'),
                          Divider(
                            height: 1,
                            indent: 16,
                            color: Colors.grey.shade100,
                          ),
                          _buildFormatOption('html', 'HTML', '网页格式，适合直接阅读'),
                          Divider(
                            height: 1,
                            indent: 16,
                            color: Colors.grey.shade100,
                          ),
                          _buildFormatOption('xlsx', 'Excel', '电子表格，适合统计分析'),
                          Divider(
                            height: 1,
                            indent: 16,
                            color: Colors.grey.shade100,
                          ),
                          _buildFormatOption(
                            'sql',
                            'PostgreSQL',
                            '数据库脚本，便于导入到数据库',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Colors.grey.shade100)),
            ),
            child: SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: _startExport,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  '开始处理',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingSection({
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: child),
      ],
    );
  }

  Widget _buildFormatOption(String value, String label, String desc) {
    final isSelected = _selectedFormat == value;
    return InkWell(
      onTap: () => setState(() => _selectedFormat = value),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  Text(
                    desc,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}

// 导出状态枚举
enum _ExportStatus { idle, initializing, exporting, completed, error }

class _ExportProgressDialog extends StatefulWidget {
  final List<String> sessions;
  final List<ChatSession> allSessions;
  final String format;
  final DateTimeRange dateRange;
  final String exportFolder;
  final bool useAllTime;

  const _ExportProgressDialog({
    required this.sessions,
    required this.allSessions,
    required this.format,
    required this.dateRange,
    required this.exportFolder,
    required this.useAllTime,
  });

  @override
  State<_ExportProgressDialog> createState() => _ExportProgressDialogState();
}

class _ExportProgressDialogState extends State<_ExportProgressDialog> {
  int _successCount = 0;
  int _failedCount = 0;
  int _totalMessagesProcessed = 0;
  String _currentSessionName = '';
  String _currentStage = ''; // 当前处理阶段
  double _progress = 0.0;
  _ExportStatus _status = _ExportStatus.idle;
  String? _errorMessage;
  late int _totalSessions;

  // 使用 ValueNotifier 来局部更新条数，避免重建整个 widget 导致进度条卡顿
  final ValueNotifier<int> _exportedCountNotifier = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _totalSessions = widget.sessions.length;
    _startExport();
  }

  @override
  void dispose() {
    _exportedCountNotifier.dispose();
    super.dispose();
  }

  Future<void> _startExport() async {
    try {
      final appState = context.read<AppState>();
      final dbService = appState.databaseService;
      final exportService = ChatExportService(dbService);

      if (dbService.mode == DatabaseMode.realtime) {
        throw Exception('实时模式暂不支持导出功能，切换至备份模式后重试。');
      }

      setState(() {
        _status = _ExportStatus.initializing;
      });

      final startTime = widget.useAllTime
          ? null
          : widget.dateRange.start.millisecondsSinceEpoch ~/ 1000;
      final endTime = widget.useAllTime
          ? null
          : widget.dateRange.end.millisecondsSinceEpoch ~/ 1000;

      // 提前获取所有会话，避免循环中重复调用
      final sessions = await dbService.getSessions();

      for (int i = 0; i < _totalSessions; i++) {
        final username = widget.sessions[i];

        // 尝试获取显示名称
        final sFromAll = widget.allSessions
            .where((s) => s.username == username)
            .firstOrNull;
        String displayName = sFromAll?.displayName ?? username;

        try {
          final contact = await dbService.getContact(username);
          if (contact != null) {
            displayName = contact.displayName;
          } else if (displayName == username) {
            final s = sessions.where((s) => s.username == username).firstOrNull;
            if (s != null &&
                s.displayName != null &&
                s.displayName != username &&
                s.displayName!.isNotEmpty) {
              displayName = s.displayName!;
            }
          }
        } catch (_) {}

        if (!mounted) return;

        // 获取会话详情
        ChatSession? targetSession = widget.allSessions
            .where((s) => s.username == username)
            .firstOrNull;
        if (targetSession == null) {
          _failedCount++;
          continue;
        }

        // 先获取消息总数，以便展示确定性进度条
        int totalToScan = 0;
        try {
          totalToScan = await dbService.getMessageCount(username);
        } catch (_) {}

        if (!mounted) return;
        setState(() {
          _status = _ExportStatus.exporting;
          _progress = totalToScan > 0 ? 0.0 : -1.0;
          _currentSessionName = displayName;
          _exportedCountNotifier.value = 0;
          _currentStage = '读取消息...';
        });

        // 批量读取消息并收集为大列表（一次性导出，但进度实时更新）
        final List<Message> allMessages = [];
        final int batchSize = (totalToScan > 0)
            ? (totalToScan / 40).floor().clamp(500, 10000)
            : 2000;
        int scannedCount = 0;
        await dbService.exportSessionMessages(
          username,
          (batch) async {
            allMessages.addAll(batch);
            scannedCount += batch.length;
            if (!mounted) return;
            _exportedCountNotifier.value = scannedCount;
            if (totalToScan > 0) {
              setState(() {
                _progress =
                    (scannedCount / totalToScan).clamp(0.0, 1.0) * 0.85;
              });
            }
          },
          exportBatchSize: batchSize,
          begintimestamp: startTime ?? 0,
          endTimestamp: endTime ?? 0,
        );

        if (allMessages.isEmpty) {
          _failedCount++;
          continue;
        }

        if (!mounted) return;

        var processedCount = 0;
        void onExportProgress(int current, int total, String stage) {
          if (!mounted) return;
          processedCount = current;
          _exportedCountNotifier.value = current;
          if (_currentStage != stage) {
            setState(() {
              _currentStage = stage;
            });
          }
          final effectiveTotal = total > 0 ? total : totalToScan;
          if (effectiveTotal > 0) {
            final ratio = (current / effectiveTotal).clamp(0.0, 1.0);
            final phaseWeight = stage == '写入文件...' ||
                    stage == '保存工作簿...' ||
                    stage == '构建头像索引...'
                ? 0.98
                : 0.9;
            setState(() {
              _progress = (ratio * phaseWeight).clamp(0.0, 0.98);
            });
          }
        }

        final safeName = displayName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final savePath =
            '${widget.exportFolder}/${safeName}_${DateTime.now().millisecondsSinceEpoch}.${widget.format}';

        bool result = false;
        switch (widget.format) {
          case 'json':
            result = await exportService.exportToJson(
              targetSession,
              allMessages,
              filePath: savePath,
              onProgress: onExportProgress,
            );
            break;
          case 'html':
            result = await exportService.exportToHtml(
              targetSession,
              allMessages,
              filePath: savePath,
              onProgress: onExportProgress,
            );
            break;
          case 'xlsx':
            result = await exportService.exportToExcel(
              targetSession,
              allMessages,
              filePath: savePath,
              onProgress: onExportProgress,
            );
            break;
          case 'sql':
            result = await exportService.exportToPostgreSQL(
              targetSession,
              allMessages,
              filePath: savePath,
              onProgress: onExportProgress,
            );
            break;
        }

        if (!mounted) return;

        await logger.info(
          'ChatExportPage',
          '导出完成: $displayName, 结果: ${result ? "成功" : "失败"}, 路径: $savePath',
        );

        setState(() {
          if (result) {
            _successCount++;
            _totalMessagesProcessed += processedCount;
          } else {
            _failedCount++;
          }
          _progress = 1.0;
        });
      }

      if (!mounted) return;
      setState(() {
        _status = _ExportStatus.completed;
        _progress = 1.0;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = _ExportStatus.error;
          _errorMessage = e.toString();
        });
      }
    }
  }

  // 辅助方法：打开文件夹
  Future<void> _openFolder() async {
    final path = widget.exportFolder;
    final uri = Uri.directory(path);
    try {
      if (!await launchUrl(uri)) {
        throw '无法打开文件夹';
      }
    } catch (e) {
      // 平台特定的回退处理
      try {
        if (Platform.isWindows) {
          await Process.run('explorer', [path]);
        } else if (Platform.isMacOS) {
          await Process.run('open', [path]);
        } else if (Platform.isLinux) {
          await Process.run('xdg-open', [path]);
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        width: 480,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 32,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部条
            Container(
              height: 6,
              width: double.infinity,
              color: const Color(0xFF07C160), // 微信绿
            ),
            Padding(
              padding: const EdgeInsets.all(40),
              child: Column(
                children: [
                  if (_status == _ExportStatus.exporting ||
                      _status == _ExportStatus.initializing)
                    _buildProcessingUI()
                  else if (_status == _ExportStatus.completed)
                    _buildCompletedUI()
                  else if (_status == _ExportStatus.error)
                    _buildErrorUI(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingUI() {
    return Column(
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: _progress >= 0 ? _progress : 0),
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOutCubic,
          builder: (context, value, _) {
            return Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 100,
                  height: 100,
                  child: CircularProgressIndicator(
                    value: _progress >= 0 ? value : null,
                    strokeWidth: 8,
                    backgroundColor: Colors.grey.shade100,
                    color: const Color(0xFF07C160),
                    strokeCap: StrokeCap.round,
                  ),
                ),
                if (_progress >= 0)
                  Text(
                    '${(value * 100).toInt()}%',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF07C160),
                    ),
                  )
                else
                  const Icon(
                    Icons.search_rounded,
                    size: 40,
                    color: Color(0xFF07C160),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 32),
        Text(
          _status == _ExportStatus.initializing ? '正在初始化...' : '正在处理导出',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _currentSessionName,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        if (_currentStage.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            _currentStage,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
          if (_currentStage.contains('头像')) ...[
            const SizedBox(height: 16),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF07C160).withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF07C160).withValues(alpha: 0.1),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: Color(0xFF07C160),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '正在获取头像，群聊头像较多时可能需要一些时间，请耐心等待',
                      style: TextStyle(
                        fontSize: 12,
                        color: const Color(0xFF07C160).withValues(alpha: 0.8),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
        const SizedBox(height: 24),
        ValueListenableBuilder<int>(
          valueListenable: _exportedCountNotifier,
          builder: (context, count, _) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildStatItem(
                  '已处理会话',
                  '${_successCount + _failedCount + 1} / $_totalSessions',
                ),
                Container(
                  width: 1,
                  height: 24,
                  color: Colors.grey.shade200,
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                ),
                Column(
                  children: [
                    Text(
                      '本会话消息',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade400,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _AnimatedCountText(
                      count: count,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                      ),
                      suffix: ' 条',
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildCompletedUI() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF07C160).withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.check_rounded,
            size: 48,
            color: Color(0xFF07C160),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          '导出完成',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          '所有选中的会话已成功导出',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
        ),
        const SizedBox(height: 32),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildStatItem(
              '成功',
              '$_successCount',
              valueColor: const Color(0xFF07C160),
            ),
            Container(
              width: 1,
              height: 24,
              color: Colors.grey.shade200,
              margin: const EdgeInsets.symmetric(horizontal: 20),
            ),
            _buildStatItem('失败', '$_failedCount', valueColor: Colors.red),
            Container(
              width: 1,
              height: 24,
              color: Colors.grey.shade200,
              margin: const EdgeInsets.symmetric(horizontal: 20),
            ),
            _buildStatItem('总消息', '$_totalMessagesProcessed'),
          ],
        ),
        const SizedBox(height: 40),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _openFolder,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('浏览文件'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF07C160),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('完成'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildErrorUI() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.error_outline_rounded,
            size: 48,
            color: Colors.red,
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          '导出失败',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _errorMessage ?? '未知错误',
            style: const TextStyle(
              color: Colors.red,
              fontSize: 13,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey.shade900,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('确定'),
          ),
        ),
      ],
    );
  }

  Widget _buildStatItem(String label, String value, {Color? valueColor}) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

/// 内部辅助组件：带滚动动画的数字
class _AnimatedCountText extends StatelessWidget {
  final int count;
  final TextStyle style;
  final String suffix;

  const _AnimatedCountText({
    required this.count,
    required this.style,
    this.suffix = '',
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: count.toDouble()),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      builder: (context, value, _) {
        return Text('${value.toInt()}$suffix', style: style);
      },
    );
  }
}

/// 内部辅助组件：带动画的条形图
class _AnimatedBar extends StatefulWidget {
  final int index;
  final Color color;
  final double baseHeight;
  final double maxExtraHeight;

  const _AnimatedBar({
    required this.index,
    required this.color,
    required this.baseHeight,
    required this.maxExtraHeight,
  });

  @override
  State<_AnimatedBar> createState() => _AnimatedBarState();
}

class _AnimatedBarState extends State<_AnimatedBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

    Future.delayed(Duration(milliseconds: widget.index * 150), () {
      if (mounted) _controller.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: 8,
          height:
              widget.baseHeight + (widget.maxExtraHeight * _animation.value),
          decoration: BoxDecoration(
            color: widget.color.withValues(
              alpha: 0.3 + (0.7 * _animation.value),
            ),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      },
    );
  }
}
