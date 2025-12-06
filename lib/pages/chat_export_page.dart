import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_state.dart';
import '../models/chat_session.dart';
import '../models/contact_record.dart';
import '../services/chat_export_service.dart';
import '../widgets/common/shimmer_loading.dart';
import '../utils/string_utils.dart';

/// 聊天记录导出页面
class ChatExportPage extends StatefulWidget {
  const ChatExportPage({super.key});

  @override
  State<ChatExportPage> createState() => _ChatExportPageState();
}

class _ChatExportPageState extends State<ChatExportPage> {
  List<ChatSession> _allSessions = [];
  Set<String> _selectedSessions = {};
  bool _isLoadingSessions = false;
  bool _selectAll = false;
  String _searchQuery = '';
  String _selectedFormat = 'json';
  DateTimeRange? _selectedRange;
  String? _exportFolder;
  bool _useAllTime = false;
  bool _isExportingContacts = false;

  // 添加静态缓存变量，用于存储会话列表
  static List<ChatSession>? _cachedSessions;

  @override
  void initState() {
    super.initState();
    _loadSessions();
    _loadExportFolder();
    // 默认选择最近7天
    _selectedRange = DateTimeRange(
      start: DateTime.now().subtract(const Duration(days: 7)),
      end: DateTime.now(),
    );
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

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已设置导出文件夹: $result')));
  }

  Future<void> _exportContacts() async {
    final appState = context.read<AppState>();
    if (!appState.databaseService.isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先连接数据库后再导出通讯录')));
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

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(summary.toString())));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出通讯录失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isExportingContacts = false;
        });
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载会话列表失败: $e')));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('会话列表已刷新')));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已选择全部时间，无需设置日期范围')));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请至少选择一个会话')));
      return;
    }

    if (_exportFolder == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先选择导出文件夹')));
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
      case 'excel':
        return 'Excel';
      default:
        return format.toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _buildHeader(),
          _buildFilterBar(),
          Expanded(
            child: Row(
              children: [
                Expanded(flex: 2, child: _buildSessionList()),
                Container(width: 1, color: Colors.grey.withValues(alpha: 0.2)),
                Expanded(flex: 1, child: _buildExportSettings()),
              ],
            ),
          ),
        ],
      ),
    );
  }

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
          Icon(
            Icons.file_download_outlined,
            size: 28,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Text(
            '导出聊天记录',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshSessions, // 修改为使用新的刷新方法
            tooltip: '刷新列表',
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.all(16),
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
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: '搜索会话...',
                prefixIcon: const Icon(Icons.search),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.grey),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.grey, width: 1.5),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.grey),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                  _selectAll = false;
                });
              },
            ),
          ),
          const SizedBox(width: 16),
          ElevatedButton.icon(
            onPressed: _toggleSelectAll,
            icon: Icon(
              _selectAll ? Icons.check_box : Icons.check_box_outline_blank,
            ),
            label: Text(_selectAll ? '取消全选' : '全选'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '已选择: ${_selectedSessions.length}',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
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

        return ListView.builder(
          itemCount: sessions.length,
          padding: const EdgeInsets.all(8),
          itemBuilder: (context, index) {
            final session = sessions[index];
            final isSelected = _selectedSessions.contains(session.username);
            final avatarUrl = appState.getAvatarUrl(session.username);

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              elevation: isSelected ? 2 : 0,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
                  : null,
              child: ListTile(
                leading: (avatarUrl != null && avatarUrl.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: avatarUrl,
                        imageBuilder: (context, imageProvider) => CircleAvatar(
                          backgroundColor: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.shade300,
                          backgroundImage: imageProvider,
                        ),
                        placeholder: (context, url) => CircleAvatar(
                          backgroundColor: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.shade300,
                          child: Text(
                            StringUtils.getFirstChar(
                              session.displayName ?? session.username,
                            ),
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : Colors.grey.shade700,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        errorWidget: (context, url, error) => CircleAvatar(
                          backgroundColor: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.shade300,
                          child: Text(
                            StringUtils.getFirstChar(
                              session.displayName ?? session.username,
                            ),
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : Colors.grey.shade700,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      )
                    : CircleAvatar(
                        backgroundColor: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey.shade300,
                        child: Text(
                          StringUtils.getFirstChar(
                            session.displayName ?? session.username,
                          ),
                          style: TextStyle(
                            color: isSelected
                                ? Colors.white
                                : Colors.grey.shade700,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                title: Text(
                  session.displayName ?? session.username,
                  style: TextStyle(
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
                subtitle: Text(session.typeDescription),
                trailing: Checkbox(
                  value: isSelected,
                  onChanged: (value) => _toggleSession(session.username),
                ),
                onTap: () => _toggleSession(session.username),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildExportSettings() {
    return Container(
      color: Colors.grey.shade50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '导出设置',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 导出文件夹设置
                  Text(
                    '导出位置',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _selectExportFolder,
                    icon: const Icon(Icons.folder_open),
                    label: Text(
                      _exportFolder ?? '选择导出文件夹',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(16),
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                  const SizedBox(height: 24),

                  Text(
                    '通讯录导出',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '将当前账号的通讯录导出为 Excel 表格',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _isExportingContacts ? null : _exportContacts,
                    icon: _isExportingContacts
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.contacts),
                    label: Text(
                      _isExportingContacts ? '正在导出通讯录...' : '导出通讯录 (Excel)',
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 日期范围选择
                  Text(
                    '日期范围',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    value: _useAllTime,
                    onChanged: (value) {
                      setState(() {
                        _useAllTime = value ?? false;
                      });
                    },
                    title: const Text('导出全部时间'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _useAllTime ? null : _selectDateRange,
                    icon: const Icon(Icons.calendar_today),
                    label: Text(
                      _useAllTime
                          ? '全部时间'
                          : (_selectedRange != null
                                ? '${_selectedRange!.start.toLocal().toString().split(' ')[0]} 至\n${_selectedRange!.end.toLocal().toString().split(' ')[0]}'
                                : '选择日期范围'),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(16),
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 导出格式选择
                  Text(
                    '导出格式',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildFormatOption('json', 'JSON', '结构化数据格式，便于程序处理'),
                  _buildFormatOption('html', 'HTML', '网页格式，便于浏览和分享'),
                  _buildFormatOption('excel', 'Excel', '表格格式，便于数据分析'),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),

          // 导出按钮（固定在底部）
          Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _selectedSessions.isEmpty ? null : _startExport,
                icon: const Icon(Icons.download),
                label: const Text('开始导出'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormatOption(String value, String label, String description) {
    final isSelected = _selectedFormat == value;

    return InkWell(
      onTap: () => setState(() => _selectedFormat = value),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
              : Colors.white,
          border: Border.all(
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade400,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey.shade600,
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
}

/// 导出进度对话框
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
  int _currentIndex = 0;
  int _successCount = 0;
  int _failedCount = 0;
  bool _isCompleted = false;
  String _currentSessionName = '';
  int _currentMessageCount = 0;
  int _totalMessagesProcessed = 0;
  final List<String> _failedSessions = [];

  @override
  void initState() {
    super.initState();
    _startExport();
  }

  Future<void> _startExport() async {
    final appState = context.read<AppState>();
    final databaseService = appState.databaseService;

    // 计算时间戳
    int startTimestamp;
    int endTimestamp;

    if (widget.useAllTime) {
      startTimestamp = 0; // 从最早开始
      endTimestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000; // 到现在
    } else {
      startTimestamp =
          widget.dateRange.start
              .copyWith(hour: 0, minute: 0, second: 0)
              .millisecondsSinceEpoch ~/
          1000;
      final endOfDay = DateTime(
        widget.dateRange.end.year,
        widget.dateRange.end.month,
        widget.dateRange.end.day + 1,
      ).subtract(const Duration(seconds: 1));
      endTimestamp = endOfDay.millisecondsSinceEpoch ~/ 1000;
    }

    for (int i = 0; i < widget.sessions.length; i++) {
      final username = widget.sessions[i];
      final session = widget.allSessions.firstWhere(
        (s) => s.username == username,
      );

      setState(() {
        _currentIndex = i;
        _currentSessionName = session.displayName ?? session.username;
        _currentMessageCount = 0;
      });

      // 让UI有机会更新
      await Future.delayed(const Duration(milliseconds: 50));

      try {
        // 获取消息
        final messages = await databaseService.getMessagesByDate(
          username,
          startTimestamp,
          endTimestamp,
        );

        setState(() {
          _currentMessageCount = messages.length;
        });

        if (messages.isEmpty) {
          setState(() {
            _failedCount++;
            _failedSessions.add(
              '${session.displayName ?? session.username} (无消息)',
            );
          });
          continue;
        }

        // 构建文件路径
        final displayName = session.displayName ?? session.username;
        final sanitizedName = displayName.replaceAll(
          RegExp(r'[<>:"/\\|?*]'),
          '_',
        );
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final extension = widget.format == 'json'
            ? 'json'
            : (widget.format == 'html' ? 'html' : 'xlsx');
        final filePath =
            '${widget.exportFolder}${Platform.pathSeparator}${sanitizedName}_$timestamp.$extension';

        // 导出
        bool success = false;
        final exportService = ChatExportService(databaseService);

        switch (widget.format) {
          case 'json':
            success = await exportService.exportToJson(
              session,
              messages.reversed.toList(),
              filePath: filePath,
            );
            break;
          case 'html':
            success = await exportService.exportToHtml(
              session,
              messages.reversed.toList(),
              filePath: filePath,
            );
            break;
          case 'excel':
            success = await exportService.exportToExcel(
              session,
              messages.reversed.toList(),
              filePath: filePath,
            );
            break;
        }

        if (success) {
          setState(() {
            _successCount++;
            _totalMessagesProcessed += messages.length;
          });
        } else {
          setState(() {
            _failedCount++;
            _failedSessions.add(
              '${session.displayName ?? session.username} (导出失败)',
            );
          });
        }
      } catch (e) {
        setState(() {
          _failedCount++;
          _failedSessions.add(
            '${session.displayName ?? session.username} ($e)',
          );
        });
      }

      // 让UI有机会更新
      await Future.delayed(const Duration(milliseconds: 50));
    }

    setState(() => _isCompleted = true);
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.sessions.isEmpty
        ? 0.0
        : (_currentIndex + 1) / widget.sessions.length;
    final remaining = widget.sessions.length - (_currentIndex + 1);

    return AlertDialog(
      title: Text(_isCompleted ? '导出完成' : '正在导出'),
      content: SizedBox(
        width: 450,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_isCompleted) ...[
              LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 16),
              Text(
                '当前会话: $_currentSessionName',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text('当前消息数: $_currentMessageCount 条'),
              const SizedBox(height: 8),
              Text('会话进度: ${_currentIndex + 1} / ${widget.sessions.length}'),
              const SizedBox(height: 4),
              Text('剩余会话: $remaining 个'),
              const SizedBox(height: 8),
              Text(
                '已导出消息: $_totalMessagesProcessed 条',
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ] else ...[
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 48),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '成功: $_successCount',
                          style: const TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          '总计导出: $_totalMessagesProcessed 条消息',
                          style: TextStyle(color: Colors.grey.shade700),
                        ),
                        if (_failedCount > 0) ...[
                          const SizedBox(height: 4),
                          Text(
                            '失败: $_failedCount',
                            style: const TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '文件位置: ${widget.exportFolder}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              if (_failedSessions.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  '失败列表:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _failedSessions
                          .map(
                            (name) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '• $name',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        if (_isCompleted)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
      ],
    );
  }
}
