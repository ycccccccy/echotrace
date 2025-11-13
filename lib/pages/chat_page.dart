import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/chat_session.dart';
import '../models/message.dart';
import '../widgets/chat_session_item.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_loading_shimmer.dart';
import '../widgets/common/shimmer_loading.dart';
import '../utils/string_utils.dart';
import '../services/logger_service.dart';

/// 聊天记录页面
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with TickerProviderStateMixin {
  static const int _initialMessageBatch = 90;
  static const int _loadMoreBatch = 210;
  static const double _loadTriggerDistance = 160.0;
  static const double _prefetchTriggerDistance = 560.0;

  ChatSession? _selectedSession;
  List<ChatSession> _sessions = [];
  List<ChatSession> _filteredSessions = []; // 搜索过滤后的会话列表
  List<Message> _messages = [];
  // 会话头像缓存（username -> avatarUrl）
  Map<String, String> _sessionAvatarUrls = {};
  // 群聊成员头像缓存（username -> avatarUrl）
  Map<String, String> _senderAvatarUrls = {};
  String? _myAvatarUrl; // 我的头像
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
  bool _prefetchScheduled = false;

  // 搜索相关
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  late AnimationController _searchAnimationController;
  late Animation<double> _searchAnimation;

  @override
  void initState() {
    super.initState();
    _refreshController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _searchAnimationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _searchAnimation = CurvedAnimation(
      parent: _searchAnimationController,
      curve: Curves.easeInOut,
    );
    _searchController.addListener(_onSearchChanged);
    _loadSessions();
    _scrollController.addListener(_onScroll);
    _loadMyAvatar();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _refreshController.dispose();
    _searchAnimationController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() async {
    final query = _searchController.text.trim().toLowerCase();
    await logger.debug('ChatPage', '搜索关键词: "$query"');

    setState(() {
      if (query.isEmpty) {
        _filteredSessions = _sessions;
        logger.debug('ChatPage', '清空搜索，显示全部 ${_sessions.length} 个会话');
      } else {
        _filteredSessions = _sessions.where((session) {
          final displayName = session.displayName?.toLowerCase() ?? '';
          final username = session.username.toLowerCase();
          final summary = session.displaySummary.toLowerCase();
          return displayName.contains(query) ||
              username.contains(query) ||
              summary.contains(query);
        }).toList();
        logger.debug('ChatPage', '搜索结果: 找到 ${_filteredSessions.length} 个匹配的会话');
      }
    });
  }

  Future<void> _loadMyAvatar() async {
    try {
      final appState = context.read<AppState>();
      final myWxid = appState.databaseService.currentAccountWxid;
      if (myWxid == null || myWxid.isEmpty) return;
      final map = await appState.databaseService.getAvatarUrls([myWxid]);
      if (!mounted) return;
      setState(() {
        _myAvatarUrl = map[myWxid];
      });
    } catch (_) {}
  }

  void _toggleSearch() async {
    await logger.debug('ChatPage', '切换搜索模式: ${!_isSearching}');

    setState(() {
      _isSearching = !_isSearching;
      if (_isSearching) {
        _searchAnimationController.forward();
        _searchFocusNode.requestFocus();
      } else {
        _searchAnimationController.reverse();
        _searchController.clear();
        _filteredSessions = _sessions;
        _searchFocusNode.unfocus();
      }
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients || !_hasMoreMessages) {
      return;
    }

    final position = _scrollController.position;
    final distanceToTop = position.pixels;

    if (distanceToTop > _prefetchTriggerDistance) {
      _prefetchScheduled = false;
    }

    if (_isLoadingMoreMessages) {
      return;
    }

    if (distanceToTop <= _loadTriggerDistance) {
      _prefetchScheduled = false;
      _loadMoreMessages();
    } else if (distanceToTop <= _prefetchTriggerDistance &&
        position.userScrollDirection == ScrollDirection.reverse &&
        !_prefetchScheduled) {
      _prefetchScheduled = true;
      _loadMoreMessages();
    }
  }

  Future<void> _loadSessions() async {
    // 防止重复加载
    if (_isLoadingSessions) return;

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

      // 异步加载会话列表
      final sessions = await appState.databaseService.getSessions();

      // 在后台线程过滤会话（避免阻塞 UI）
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
        return session.username.contains('wxid_') ||
            session.username.contains('@chatroom');
      }).toList();

      if (mounted) {
        setState(() {
          _sessions = filteredSessions;
          _filteredSessions = filteredSessions; // 初始化过滤列表
          _isLoadingSessions = false;
        });
        _refreshController.stop();
        _refreshController.reset();
      }

      // 确保我的头像已加载（数据库连接后再尝试一次）
      if (_myAvatarUrl == null || _myAvatarUrl!.isEmpty) {
        await _loadMyAvatar();
      }

      // 异步加载头像（不阻塞会话渲染）
      try {
        final avatarMap = await appState.databaseService.getAvatarUrls(
          filteredSessions.map((s) => s.username).toList(),
        );
        if (mounted) {
          setState(() {
            _sessionAvatarUrls = avatarMap;
          });
        }
      } catch (_) {}
    } catch (e, stackTrace) {
      await logger.error('ChatPage', '加载会话列表失败', e, stackTrace);
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
    await logger.info(
      'ChatPage',
      '开始加载会话消息: ${session.username} (${session.displayName ?? "无显示名"})',
    );

    // 立即切换选中状态，不等待加载，避免卡顿
    setState(() {
      _selectedSession = session;
      _isLoadingMessages = true;
      _currentOffset = 0;
      _hasMoreMessages = true;
      _senderDisplayNames = {}; // 清空姓名缓存
      _messages = []; // 清空旧消息
      _lastInitialLoadTime = null; // 重置初次加载时间
      _prefetchScheduled = false;
    });

    // 异步加载消息 - 初次只加载少量消息以提升性能
    try {
      final appState = context.read<AppState>();
      // 若我的头像尚未就绪，尝试补载
      if (_myAvatarUrl == null || _myAvatarUrl!.isEmpty) {
        await _loadMyAvatar();
      }
      await logger.info(
        'ChatPage',
        '查询消息，limit=$_initialMessageBatch, offset=0',
      );
      final messages = await appState.databaseService.getMessages(
        session.username,
        limit: _initialMessageBatch,
        offset: 0,
      );

      if (!mounted) {
        return;
      }

      await logger.info('ChatPage', '获取到 ${messages.length} 条消息');

      // 如果是群聊，批量查询所有发送者的真实姓名
      if (session.isGroup && messages.isNotEmpty) {
        await logger.info('ChatPage', '这是群聊，开始查询发送者显示名');
        final senderUsernames = messages
            .where(
              (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
            )
            .map((m) => m.senderUsername!)
            .toSet()
            .toList();

        if (senderUsernames.isNotEmpty) {
          await logger.info(
            'ChatPage',
            '查询 ${senderUsernames.length} 个发送者的显示名',
          );
          _senderDisplayNames = await appState.databaseService.getDisplayNames(
            senderUsernames,
          );
          // 同时查询头像
          try {
            _senderAvatarUrls = await appState.databaseService.getAvatarUrls(
              senderUsernames,
            );
          } catch (_) {}
          if (!mounted) {
            return;
          }

          await logger.info(
            'ChatPage',
            '获取到 ${_senderDisplayNames.length} 个显示名',
          );
        }
      }

      if (mounted) {
        setState(() {
          _messages = messages.reversed.toList(); // 反转顺序，最新消息在下方
          _isLoadingMessages = false;
          _currentOffset = messages.length;
          _hasMoreMessages = messages.length >= _initialMessageBatch;
        });

        // 自动滚动到底部（最新消息）
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _scrollController.hasClients &&
              _selectedSession?.username == session.username) {
            try {
              _scrollController.jumpTo(
                _scrollController.position.maxScrollExtent,
              );
            } catch (e) {
              // 忽略滚动错误
            }
          }
        });

        // 如果消息数量接近初始加载限制，延迟自动加载更多消息，提升用户体验
        if (messages.length >= _initialMessageBatch - 10) {
          // 记录初次加载时间，用于避免与用户滚动触发的加载冲突
          _lastInitialLoadTime = DateTime.now();
          Future.delayed(const Duration(milliseconds: 300), () {
            // 检查是否是初次加载后不久（避免与用户滚动触发的加载冲突）
            if (mounted &&
                _selectedSession?.username == session.username &&
                !_isLoadingMoreMessages &&
                _lastInitialLoadTime != null &&
                DateTime.now()
                        .difference(_lastInitialLoadTime!)
                        .inMilliseconds <
                    1000) {
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载消息失败: $e')));
      }
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMoreMessages ||
        !_hasMoreMessages ||
        _selectedSession == null) {
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
        limit: _loadMoreBatch,
        offset: _currentOffset,
      );

      // 如果是群聊，批量查询新加载消息的发送者姓名
      if (_selectedSession!.isGroup && moreMessages.isNotEmpty) {
        final newSenderUsernames = moreMessages
            .where(
              (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
            )
            .map((m) => m.senderUsername!)
            .toSet()
            .where((username) => !_senderDisplayNames.containsKey(username))
            .toList();

        if (newSenderUsernames.isNotEmpty) {
          final newNames = await appState.databaseService.getDisplayNames(
            newSenderUsernames,
          );
          _senderDisplayNames.addAll(newNames);
        }
      }

      if (mounted && _selectedSession?.username == currentSessionUsername) {
        setState(() {
          _messages = [...moreMessages.reversed, ..._messages];
          _isLoadingMoreMessages = false;
          _currentOffset += moreMessages.length;
          _hasMoreMessages = moreMessages.length >= _loadMoreBatch;
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
              if (target >= 0 &&
                  target <= _scrollController.position.maxScrollExtent) {
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
    } finally {
      _prefetchScheduled = false;
    }
  }

  /// 判断消息是否为自己发送
  bool _isMessageFromMe(Message message) {
    if (message.isSend != null) {
      return message.isSend == 1;
    }
    // Fallback判断
    final myWxid =
        context.read<AppState>().databaseService.currentAccountWxid ?? '';
    return message.source.isEmpty || message.source == myWxid;
  }

  /// 获取会话显示名称（如果是自己的账号显示"我"）
  String _getSessionDisplayName(ChatSession session) {
    final myWxid =
        context.read<AppState>().databaseService.currentAccountWxid ?? '';

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

    final myWxid =
        context.read<AppState>().databaseService.currentAccountWxid ?? '';

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
                color: Colors.black.withValues(alpha: 0.05),
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
                      color: Theme.of(
                        context,
                      ).colorScheme.outline.withValues(alpha: 0.2),
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
                      icon: Icon(_isSearching ? Icons.close : Icons.search),
                      onPressed: _toggleSearch,
                      tooltip: _isSearching ? '关闭搜索' : '搜索',
                    ),
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
              // 搜索框（带动画）
              SizeTransition(
                sizeFactor: _searchAnimation,
                axisAlignment: -1.0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    border: Border(
                      bottom: BorderSide(
                        color: Theme.of(
                          context,
                        ).colorScheme.outline.withValues(alpha: 0.1),
                      ),
                    ),
                  ),
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    decoration: InputDecoration(
                      hintText: '搜索会话或消息内容...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 20),
                              onPressed: () {
                                _searchController.clear();
                              },
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      isDense: true,
                    ),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
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
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withValues(alpha: 0.7),
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '请先在「数据管理」页面\n解密数据库文件',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                                  ),
                            ),
                          ],
                        ),
                      );
                    }

                    return _isLoadingSessions
                        ? ShimmerLoading(
                            isLoading: true,
                            child: ListView.builder(
                              itemCount: 6,
                              physics: const NeverScrollableScrollPhysics(),
                              itemBuilder: (context, index) =>
                                  const ListItemShimmer(),
                            ),
                          )
                        : _filteredSessions.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _isSearching
                                      ? Icons.search_off
                                      : Icons.chat_bubble_outline,
                                  size: 64,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  _isSearching ? '未找到匹配的会话' : '暂无会话',
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.5),
                                      ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: _filteredSessions.length,
                            itemBuilder: (context, index) {
                              final session = _filteredSessions[index];
                              return ChatSessionItem(
                                session: session,
                                isSelected:
                                    _selectedSession?.username ==
                                    session.username,
                                onTap: () => _loadMessages(session),
                                avatarUrl: _sessionAvatarUrls[session.username],
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
              ? const SizedBox.shrink()
              : Column(
                  children: [
                    // 消息列表头部
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            backgroundImage: (_selectedSession != null &&
                                    _sessionAvatarUrls[_selectedSession!.username] != null &&
                                    _sessionAvatarUrls[_selectedSession!.username]!.isNotEmpty)
                                ? NetworkImage(
                                    _sessionAvatarUrls[_selectedSession!.username]!,
                                  )
                                : null,
                            child: (_selectedSession == null ||
                                    _sessionAvatarUrls[_selectedSession!.username] == null ||
                                    _sessionAvatarUrls[_selectedSession!.username]!.isEmpty)
                                ? Text(
                                    StringUtils.getFirstChar(
                                      _selectedSession!.displayName ??
                                          _selectedSession!.username,
                                    ),
                                    style: const TextStyle(color: Colors.white),
                                  )
                                : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _getSessionDisplayName(_selectedSession!),
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  _selectedSession!.typeDescription,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                ),
                              ],
                            ),
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
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface.withValues(alpha: 0.5),
                                    ),
                              ),
                            )
                          : ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.all(16),
                              itemCount:
                                  _messages.length +
                                  (_isLoadingMoreMessages ? 1 : 0),
                              itemBuilder: (context, index) {
                                // 顶部 loader
                                if (_isLoadingMoreMessages && index == 0) {
                                  return const Padding(
                                    padding: EdgeInsets.only(bottom: 12),
                                    child: Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  );
                                }

                                final offset = _isLoadingMoreMessages ? 1 : 0;
                                final message = _messages[index - offset];

                                // 使用统一的方法获取发送者显示名
                                final senderName = _getSenderDisplayName(
                                  message,
                                );

                                // 判断是否需要显示时间分隔符
                                bool shouldShowTime = false;
                                if (index - offset == 0) {
                                  // 第一条消息总是显示时间
                                  shouldShowTime = true;
                                } else {
                                  final previousMessage =
                                      _messages[index - offset - 1];
                                  final timeDiff =
                                      message.createTime -
                                      previousMessage.createTime;
                                  // 如果时间间隔超过10分钟（600秒），显示时间分隔符
                                  shouldShowTime = timeDiff > 600;
                                }

                                // 选择头像：
                                // 私聊：使用会话头像；群聊：使用发送者头像
                                final avatarUrl = _selectedSession?.isGroup == true
                                    ? (message.senderUsername != null
                                        ? _senderAvatarUrls[message.senderUsername!]
                                        : null)
                                    : _sessionAvatarUrls[_selectedSession!.username];

                                return MessageBubble(
                                  message: message,
                                  isFromMe: _isMessageFromMe(message),
                                  senderDisplayName: senderName,
                                  sessionUsername:
                                      _selectedSession?.username ?? '',
                                  shouldShowTime: shouldShowTime,
                                  avatarUrl: _isMessageFromMe(message)
                                      ? _myAvatarUrl
                                      : avatarUrl,
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
