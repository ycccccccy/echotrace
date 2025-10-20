import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/chat_session.dart';
import '../models/message.dart';
import '../widgets/chat_session_item.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_loading_shimmer.dart';
import '../utils/string_utils.dart';
import '../services/chat_export_service.dart';

/// 聊天记录页面
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with SingleTickerProviderStateMixin {
  ChatSession? _selectedSession;
  List<ChatSession> _sessions = [];
  List<Message> _messages = [];
  bool _isLoadingSessions = false;
  bool _isLoadingMessages = false;
  bool _isLoadingMoreMessages = false;
  bool _hasMoreMessages = true;
  int _currentOffset = 0;
  final ScrollController _scrollController = ScrollController();
  // 群聊成员姓名缓存（username -> displayName）
  Map<String, String> _senderDisplayNames = {};
  late AnimationController _refreshController;
  DateTime? _lastInitialLoadTime;

  @override
  void initState() {
    super.initState();
    _refreshController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _loadSessions();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _refreshController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // 接近顶部时加载更早消息
    if (_scrollController.hasClients &&
        _scrollController.position.pixels <= 200) {
      _loadMoreMessages();
    }
  }

  Future<void> _loadSessions() async {
    setState(() {
      _isLoadingSessions = true;
    });

    // 启动旋转动画
    _refreshController.repeat();

    try {
      final appState = context.read<AppState>();
      
      // 检查数据库是否已连接
      if (!appState.databaseService.isConnected) {
        if (mounted) {
          setState(() {
            _isLoadingSessions = false;
          });
          _refreshController.stop();
          _refreshController.reset();
        }
        return; // 数据库未连接，不显示错误，由UI显示提示
      }

      final sessions = await appState.databaseService.getSessions();
      
      // 过滤掉公众号/服务号（gh_ 开头）和其他非聊天会话
      final filteredSessions = sessions.where((session) {
        // 排除公众号/服务号
        if (session.username.startsWith('gh_')) return false;
        // 排除其他系统会话
        if (session.username.startsWith('weixin')) return false;
        if (session.username.startsWith('qqmail')) return false;
        if (session.username.startsWith('fmessage')) return false;
        if (session.username.startsWith('medianote')) return false;
        if (session.username.startsWith('floatbottle')) return false;
        // 只保留个人聊天(wxid_)和群聊(@chatroom)
        return session.username.contains('wxid_') || session.username.contains('@chatroom');
      }).toList();
      
      if (mounted) {
        setState(() {
          _sessions = filteredSessions;
          _isLoadingSessions = false;
        });
        _refreshController.stop();
        _refreshController.reset();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingSessions = false;
        });
        _refreshController.stop();
        _refreshController.reset();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载会话列表失败: $e'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _loadMessages(ChatSession session) async {
    // 立即切换选中状态，不等待加载，避免卡顿
    setState(() {
      _selectedSession = session;
      _isLoadingMessages = true;
      _currentOffset = 0;
      _hasMoreMessages = true;
      _senderDisplayNames = {}; // 清空姓名缓存
      _messages = []; // 清空旧消息
      _lastInitialLoadTime = null; // 重置初次加载时间
    });

    // 异步加载消息 - 初次只加载少量消息以提升性能
    try {
      final appState = context.read<AppState>();
      const initialLoadLimit = 20; // 初次只加载20条消息
      final messages = await appState.databaseService.getMessages(
        session.username,
        limit: initialLoadLimit,
        offset: 0,
      );

      // 如果是群聊，批量查询所有发送者的真实姓名
      if (session.isGroup && messages.isNotEmpty) {
        final senderUsernames = messages
            .where((m) => m.senderUsername != null && m.senderUsername!.isNotEmpty)
            .map((m) => m.senderUsername!)
            .toSet()
            .toList();

        if (senderUsernames.isNotEmpty) {
          _senderDisplayNames = await appState.databaseService.getDisplayNames(senderUsernames);
        }
      }

      if (mounted) {
        setState(() {
          _messages = messages.reversed.toList(); // 反转顺序，最新消息在下方
          _isLoadingMessages = false;
          _currentOffset = messages.length;
          _hasMoreMessages = messages.length >= initialLoadLimit;
        });

        // 自动滚动到底部（最新消息）
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scrollController.hasClients && _selectedSession?.username == session.username) {
            try {
              _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
            } catch (e) {
              // 忽略滚动错误
            }
          }
        });

        // 如果消息数量接近初始加载限制，延迟自动加载更多消息，提升用户体验
        if (messages.length >= initialLoadLimit - 5) {
          // 记录初次加载时间，用于避免与用户滚动触发的加载冲突
          _lastInitialLoadTime = DateTime.now();
          Future.delayed(const Duration(milliseconds: 300), () {
            // 检查是否是初次加载后不久（避免与用户滚动触发的加载冲突）
            if (mounted &&
                _selectedSession?.username == session.username &&
                !_isLoadingMoreMessages &&
                _lastInitialLoadTime != null &&
                DateTime.now().difference(_lastInitialLoadTime!).inMilliseconds < 1000) {
              _loadMoreMessages();
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingMessages = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载消息失败: $e')),
        );
      }
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMoreMessages || !_hasMoreMessages || _selectedSession == null) {
      return;
    }

    // 检查 ScrollController 是否已附加
    if (!_scrollController.hasClients) {
      return;
    }

    setState(() {
      _isLoadingMoreMessages = true;
    });

    try {
      final appState = context.read<AppState>();
      final oldPixels = _scrollController.position.pixels;
      final oldMaxExtent = _scrollController.position.maxScrollExtent;
      final currentSessionUsername = _selectedSession?.username; // 保存当前会话

      final moreMessages = await appState.databaseService.getMessages(
        _selectedSession!.username,
        limit: 50,
        offset: _currentOffset,
      );
      
      // 如果是群聊，批量查询新加载消息的发送者姓名
      if (_selectedSession!.isGroup && moreMessages.isNotEmpty) {
        final newSenderUsernames = moreMessages
            .where((m) => m.senderUsername != null && m.senderUsername!.isNotEmpty)
            .map((m) => m.senderUsername!)
            .toSet()
            .where((username) => !_senderDisplayNames.containsKey(username))
            .toList();
        
        if (newSenderUsernames.isNotEmpty) {
          final newNames = await appState.databaseService.getDisplayNames(newSenderUsernames);
          _senderDisplayNames.addAll(newNames);
        }
      }
      
      if (mounted && _selectedSession?.username == currentSessionUsername) {
        setState(() {
          _messages = [...moreMessages.reversed.toList(), ..._messages];
          _isLoadingMoreMessages = false;
          _currentOffset += moreMessages.length;
          _hasMoreMessages = moreMessages.length >= 50;
        });

        // 维持可视位置不跳动
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && 
              _scrollController.hasClients && 
              _selectedSession?.username == currentSessionUsername) {
            try {
              final newMaxExtent = _scrollController.position.maxScrollExtent;
              final delta = newMaxExtent - oldMaxExtent;
              final target = oldPixels + delta;
              if (target >= 0 && target <= _scrollController.position.maxScrollExtent) {
                _scrollController.jumpTo(target);
              }
            } catch (e) {
              // 忽略滚动错误
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingMoreMessages = false;
        });
      }
    }
  }

  /// 判断消息是否为自己发送
  bool _isMessageFromMe(Message message) {
    if (message.isSend != null) {
      return message.isSend == 1;
    }
    // Fallback判断
    final myWxid = context.read<AppState>().databaseService.currentAccountWxid ?? '';
    return message.source.isEmpty || message.source == myWxid;
  }

  /// 获取会话显示名称（如果是自己的账号显示"我"）
  String _getSessionDisplayName(ChatSession session) {
    final myWxid = context.read<AppState>().databaseService.currentAccountWxid ?? '';
    
    // 如果会话用户名是当前账号，显示"我"
    if (session.username == myWxid) {
      return '我';
    }
    
    return session.displayName ?? session.username;
  }

  /// 获取发送者显示名称（如果是自己显示"我"）
  String? _getSenderDisplayName(Message message) {
    if (_selectedSession == null || !_selectedSession!.isGroup) {
      return null;
    }
    
    // 如果是自己发的消息，不显示名称
    if (_isMessageFromMe(message)) {
      return null;
    }
    
    final myWxid = context.read<AppState>().databaseService.currentAccountWxid ?? '';
    
    // 获取发送者username
    if (message.senderUsername != null && message.senderUsername!.isNotEmpty) {
      // 如果发送者是当前账号（虽然理论上不会走到这里）
      if (message.senderUsername == myWxid) {
        return '我';
      }
      
      // 从缓存中获取显示名称
      String? displayName = _senderDisplayNames[message.senderUsername];
      
      // 如果没查到，显示默认提示而不是wxid
      if (displayName == null || displayName.isEmpty) {
        return '群成员';
      }
      
      return displayName;
    }
    
    return '群成员';
  }

  /// 显示导出选项对话框
  void _showExportDialog() {
    if (_selectedSession == null || _messages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择会话并加载消息')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出聊天记录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('会话: ${_getSessionDisplayName(_selectedSession!)}'),
            const SizedBox(height: 8),
            Text('消息数量: ${_messages.length} 条'),
            const SizedBox(height: 16),
            const Text('请选择导出格式:'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _exportChat('json');
            },
            child: const Text('JSON'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _exportChat('html');
            },
            child: const Text('HTML'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _exportChat('excel');
            },
            child: const Text('Excel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// 导出聊天记录
  Future<void> _exportChat(String format) async {
    if (_selectedSession == null || _messages.isEmpty) return;

    try {
      // 显示加载中对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在导出...'),
                ],
              ),
            ),
          ),
        ),
      );

      // 首先获取所有消息（而不只是当前加载的）
      final appState = context.read<AppState>();
      final allMessages = await _getAllMessages(appState);

      final exportService = ChatExportService(appState.databaseService);
      bool success = false;

      switch (format) {
        case 'json':
          success = await exportService.exportToJson(_selectedSession!, allMessages);
          break;
        case 'html':
          success = await exportService.exportToHtml(_selectedSession!, allMessages);
          break;
        case 'excel':
          success = await exportService.exportToExcel(_selectedSession!, allMessages);
          break;
      }

      // 关闭加载对话框
      if (mounted) {
        Navigator.pop(context);
      }

      // 显示结果
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success ? '导出成功' : '导出失败'),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
      }
    } catch (e) {
      // 关闭加载对话框
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    }
  }

  /// 获取会话的所有消息
  Future<List<Message>> _getAllMessages(AppState appState) async {
    if (_selectedSession == null) return [];

    final List<Message> allMessages = [];
    int offset = 0;
    const int limit = 1000;

    while (true) {
      final messages = await appState.databaseService.getMessages(
        _selectedSession!.username,
        limit: limit,
        offset: offset,
      );

      if (messages.isEmpty) break;

      allMessages.addAll(messages);
      offset += messages.length;

      if (messages.length < limit) break;
    }

    return allMessages.reversed.toList();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // 左侧会话列表
        Container(
          width: 300,
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 4,
                offset: const Offset(2, 0),
              ),
            ],
          ),
          child: Column(
            children: [
              // 会话列表头部
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      '会话列表',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: RotationTransition(
                        turns: _refreshController,
                        child: const Icon(Icons.refresh),
                      ),
                      onPressed: _loadSessions,
                      tooltip: '刷新',
                    ),
                  ],
                ),
              ),
              // 会话列表
              Expanded(
                child: Consumer<AppState>(
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
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '请先在「数据管理」页面\n解密数据库文件',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    
                    return _isLoadingSessions
                        ? const Center(child: CircularProgressIndicator())
                        : _sessions.isEmpty
                            ? Center(
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
                                      '暂无会话',
                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                itemCount: _sessions.length,
                                itemBuilder: (context, index) {
                                  final session = _sessions[index];
                                  return ChatSessionItem(
                                    session: session,
                                    isSelected: _selectedSession?.username == session.username,
                                    onTap: () => _loadMessages(session),
                                  );
                                },
                              );
                  },
                ),
              ),
            ],
          ),
        ),
        // 右侧消息列表
        Expanded(
          child: _selectedSession == null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.chat,
                        size: 80,
                        color: Theme.of(context).colorScheme.outline.withOpacity(0.5),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '选择一个会话开始查看',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // 消息列表头部
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            child: Text(
                              StringUtils.getFirstChar(_selectedSession!.displayName ?? _selectedSession!.username),
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _getSessionDisplayName(_selectedSession!),
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  _selectedSession!.typeDescription,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.download_rounded),
                            onPressed: _showExportDialog,
                            tooltip: '导出聊天记录',
                          ),
                        ],
                      ),
                    ),
                    // 消息列表
                    Expanded(
                      child: _isLoadingMessages
                          ? const MessageLoadingShimmer()
                          : _messages.isEmpty
                              ? Center(
                                  child: Text(
                                    '暂无消息',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  controller: _scrollController,
                                  padding: const EdgeInsets.all(16),
                                  itemCount: _messages.length + (_isLoadingMoreMessages ? 1 : 0),
                                  itemBuilder: (context, index) {
                                    // 顶部 loader
                                    if (_isLoadingMoreMessages && index == 0) {
                                      return const Padding(
                                        padding: EdgeInsets.only(bottom: 12),
                                        child: Center(child: CircularProgressIndicator()),
                                      );
                                    }

                                    final offset = _isLoadingMoreMessages ? 1 : 0;
                                    final message = _messages[index - offset];
                                    
                                    // 使用统一的方法获取发送者显示名
                                    final senderName = _getSenderDisplayName(message);
                                    
                                    // 判断是否需要显示时间分隔符
                                    bool shouldShowTime = false;
                                    if (index - offset == 0) {
                                      // 第一条消息总是显示时间
                                      shouldShowTime = true;
                                    } else {
                                      final previousMessage = _messages[index - offset - 1];
                                      final timeDiff = message.createTime - previousMessage.createTime;
                                      // 如果时间间隔超过10分钟（600秒），显示时间分隔符
                                      shouldShowTime = timeDiff > 600;
                                    }
                                    
                                    return MessageBubble(
                                      message: message,
                                      isFromMe: _isMessageFromMe(message),
                                      senderDisplayName: senderName,
                                      sessionUsername: _selectedSession?.username ?? '',
                                      shouldShowTime: shouldShowTime,
                                    );
                                  },
                                ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
