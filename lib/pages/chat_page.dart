import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/chat_session.dart';
import '../models/message.dart';
import '../widgets/chat_session_item.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_loading_shimmer.dart';
import '../widgets/common/shimmer_loading.dart';
import '../utils/string_utils.dart';
import '../utils/cpu_info.dart';
import '../services/logger_service.dart';
import '../services/database_service.dart';
import '../services/image_decrypt_service.dart';
import '../widgets/toast_overlay.dart';
import '../services/voice_message_service.dart';

enum _ImageVariant { big, original, high, cache, thumb, other }

class _BulkRangeSelection {
  final DateTimeRange? range;
  final bool isAll;

  const _BulkRangeSelection._(this.range, this.isAll);

  factory _BulkRangeSelection.all() {
    return const _BulkRangeSelection._(null, true);
  }

  factory _BulkRangeSelection.range(DateTimeRange range) {
    return _BulkRangeSelection._(range, false);
  }
}

class _MessageRange {
  final int? startSec;
  final int? endSec;

  const _MessageRange({this.startSec, this.endSec});

  DateTime? get startDate => startSec == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(startSec! * 1000);
  DateTime? get endDate => endSec == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(endSec! * 1000);
}

class _BulkSearchProgress {
  final int scannedChunks;
  final int totalChunks;
  final int matchedItems;

  const _BulkSearchProgress({
    required this.scannedChunks,
    required this.totalChunks,
    required this.matchedItems,
  });
}

class _AsyncSemaphore {
  _AsyncSemaphore(this._permits) : assert(_permits > 0);

  int _permits;
  final List<Completer<void>> _waiters = [];

  Future<void> acquire() {
    if (_permits > 0) {
      _permits -= 1;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
      return;
    }
    _permits += 1;
  }
}

/// 聊天记录页面
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with TickerProviderStateMixin {
  static const int _initialMessageBatch = 30; // 初始加载数量
  static const int _loadMoreBatch = 50; // 分批加载更多
  static const double _loadTriggerDistance = 200.0;
  static const double _prefetchTriggerDistance = 500.0;
  static const List<_ImageVariant> _imageVariantPriority = [
    _ImageVariant.big,
    _ImageVariant.original,
    _ImageVariant.high,
    _ImageVariant.cache,
    _ImageVariant.thumb,
    _ImageVariant.other,
  ];

  ChatSession? _selectedSession;
  List<ChatSession> _sessions = [];
  List<ChatSession> _filteredSessions = []; // 搜索过滤后的会话列表
  List<Message> _messages = [];

  String? _myAvatarUrl; // 我的头像
  bool _isLoadingSessions = false;
  bool _isLoadingMessages = false;
  bool _isLoadingMoreMessages = false;
  bool _hasMoreMessages = true;
  int _currentOffset = 0;
  late ScrollController _scrollController;
  // 群聊成员姓名缓存（username -> displayName）
  Map<String, String> _senderDisplayNames = {};
  final Set<String> _messageKeys = {};
  late AnimationController _refreshController;
  DateTime? _lastInitialLoadTime;
  bool _prefetchScheduled = false;
  bool _isRealtimeRefreshing = false;
  Future<void>? _realtimeRefreshFuture;
  bool _realtimeRefreshQueued = false;
  int _realtimeTick = 0;
  bool _isAutoConnecting = false;
  bool _hasAttemptedRefreshAfterConnect = false;
  bool _autoLoadScheduled = false;
  Timer? _searchDebounce;
  String _lastSearchQuery = '';
  StreamSubscription<void>? _dbChangeSubscription;
  int _sessionLoadSeq = 0;
  bool _showUtilityPanel = false;
  bool _voiceBulkRunning = false;
  int _voiceBulkTotal = 0;
  int _voiceBulkDone = 0;
  int _voiceBulkFailed = 0;
  bool _imageBulkRunning = false;
  int _imageBulkTotal = 0;
  int _imageBulkDone = 0;
  int _imageBulkFailed = 0;
  String? _voiceBulkStatus;
  String? _imageBulkStatus;
  int _voiceBulkRunId = 0;
  int _imageBulkRunId = 0;
  SessionDetailInfo? _sessionDetailInfo;
  bool _isLoadingSessionDetail = false;
  String? _sessionDetailError;
  String? _sessionDetailForSession;
  final ImageDecryptService _imageDecryptService = ImageDecryptService();
  final Map<String, List<String>> _datPathCache = {};
  String? _imageDisplayNameForPath;

  // 搜索相关
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  late AnimationController _searchAnimationController;
  late Animation<double> _searchAnimation;
  late final ToastOverlay _toast;

  @override
  void initState() {
    super.initState();
    _toast = ToastOverlay(this);
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
    _listenDatabaseChanges();
    _loadSessions();
    _scrollController = ScrollController()..addListener(_onScroll);
    _loadMyAvatar();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureConnected();
    });
  }

  @override
  void dispose() {
    _toast.dispose();
    _searchDebounce?.cancel();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _refreshController.dispose();
    _searchAnimationController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _dbChangeSubscription?.cancel();
    super.dispose();
  }

  void _onSearchChanged() async {
    final query = _searchController.text.trim().toLowerCase();
    if (query == _lastSearchQuery) return;
    _lastSearchQuery = query;

    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() {
        _filteredSessions = _filterSessionsByQuery(_sessions, query);
        logger.debug('ChatPage', '搜索结果: 找到 ${_filteredSessions.length} 个匹配的会话');
      });
    });
    await logger.debug('ChatPage', '搜索关键词: "$query"');
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

  Future<void> _loadMyAvatar() async {
    try {
      final appState = context.read<AppState>();
      final myWxid = appState.databaseService.currentAccountWxid;
      if (myWxid == null || myWxid.isEmpty) return;

      // 使用全局缓存更新我的头像
      await appState.fetchAndCacheAvatars([myWxid]);

      if (!mounted) return;
      setState(() {
        _myAvatarUrl = appState.getAvatarUrl(myWxid);
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

  void _resetUtilityPanelState() {
    _showUtilityPanel = false;
    _voiceBulkRunning = false;
    _voiceBulkTotal = 0;
    _voiceBulkDone = 0;
    _voiceBulkFailed = 0;
    _imageBulkRunning = false;
    _imageBulkTotal = 0;
    _imageBulkDone = 0;
    _imageBulkFailed = 0;
    _voiceBulkStatus = null;
    _imageBulkStatus = null;
    _sessionDetailInfo = null;
    _sessionDetailError = null;
    _isLoadingSessionDetail = false;
    _sessionDetailForSession = null;
    _datPathCache.clear();
    _imageDisplayNameForPath = null;
  }

  DateTime? _getEarliestMessageDate() {
    if (_messages.isEmpty) return null;
    int minTs = _messages.first.createTime;
    for (final msg in _messages) {
      if (msg.createTime < minTs) {
        minTs = msg.createTime;
      }
    }
    return DateTime.fromMillisecondsSinceEpoch(minTs * 1000);
  }

  DateTime? _getLatestMessageDate() {
    if (_messages.isEmpty) return null;
    int maxTs = _messages.first.createTime;
    for (final msg in _messages) {
      if (msg.createTime > maxTs) {
        maxTs = msg.createTime;
      }
    }
    return DateTime.fromMillisecondsSinceEpoch(maxTs * 1000);
  }

  Future<_MessageRange?> _fetchSessionRangeFromDb(String sessionId) async {
    try {
      final detail = await context
          .read<AppState>()
          .databaseService
          .getSessionDetailInfo(sessionId);
      if (!mounted || _selectedSession?.username != sessionId) {
        return _MessageRange(
          startSec: detail.firstMessageTime,
          endSec: detail.latestMessageTime,
        );
      }
      setState(() {
        _sessionDetailInfo = detail;
        _sessionDetailForSession = sessionId;
      });
      return _MessageRange(
        startSec: detail.firstMessageTime,
        endSec: detail.latestMessageTime,
      );
    } catch (_) {
      return null;
    }
  }

  Future<_MessageRange> _resolveMessageRangeForPicker() async {
    final now = DateTime.now();
    DateTime? earliest = _getEarliestMessageDate();
    DateTime? latest = _getLatestMessageDate();

    if (_selectedSession != null) {
      _MessageRange? dbRange =
          _sessionDetailForSession == _selectedSession!.username
          ? _MessageRange(
              startSec: _sessionDetailInfo?.firstMessageTime,
              endSec: _sessionDetailInfo?.latestMessageTime,
            )
          : null;
      dbRange ??= await _fetchSessionRangeFromDb(_selectedSession!.username);
      earliest ??= dbRange?.startDate;
      latest ??= dbRange?.endDate;
    }

    final fallbackStart = DateTime(now.year - 1, now.month, now.day);
    earliest ??= fallbackStart;
    latest ??= now;
    if (latest.isBefore(earliest)) latest = earliest;
    return _MessageRange(
      startSec: earliest.millisecondsSinceEpoch ~/ 1000,
      endSec: latest.millisecondsSinceEpoch ~/ 1000,
    );
  }

  Future<_BulkRangeSelection?> _pickBulkRange(String title) async {
    final range = await _resolveMessageRangeForPicker();
    final firstDate = range.startDate ?? DateTime.now();
    final lastDate = range.endDate ?? DateTime.now();
    final initialRange = DateTimeRange(start: firstDate, end: lastDate);
    final now = DateTime.now();

    return showModalBottomSheet<_BulkRangeSelection>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(sheetContext),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '数据库时间范围：${_formatDateOnly(firstDate)} ~ ${_formatDateOnly(lastDate)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(Icons.all_inclusive_rounded),
                  title: const Text('全部时间'),
                  subtitle: const Text('对当前已加载的所有消息执行'),
                  onTap: () =>
                      Navigator.pop(sheetContext, _BulkRangeSelection.all()),
                ),
                ListTile(
                  leading: const Icon(Icons.date_range_rounded),
                  title: const Text('选择时间范围'),
                  subtitle: const Text('仅对选择的日期范围执行'),
                  onTap: () async {
                    final picked = await showDateRangePicker(
                      context: sheetContext,
                      firstDate: firstDate,
                      lastDate: lastDate.isAfter(now) ? now : lastDate,
                      initialDateRange: initialRange,
                    );
                    if (!sheetContext.mounted) return;
                    if (picked != null) {
                      Navigator.pop(
                        sheetContext,
                        _BulkRangeSelection.range(picked),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<bool> _waitVoiceFileReady(
    String expectedPath, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final completer = Completer<bool>();
    StreamSubscription<String>? sub;
    Timer? pollTimer;
    Timer? timeoutTimer;

    Future<void> resolve(bool value) async {
      if (completer.isCompleted) return;
      completer.complete(value);
    }

    Future<void> checkFile() async {
      try {
        if (await File(expectedPath).exists()) {
          await resolve(true);
        }
      } catch (_) {}
    }

    try {
      sub = context.read<AppState>().voiceService.decodeFinishedStream.listen((
        path,
      ) {
        if (path == expectedPath) {
          resolve(true);
        }
      });

      await checkFile();
      pollTimer = Timer.periodic(
        const Duration(milliseconds: 300),
        (_) => unawaited(checkFile()),
      );
      timeoutTimer = Timer(timeout, () => resolve(false));

      return await completer.future;
    } finally {
      await sub?.cancel();
      pollTimer?.cancel();
      timeoutTimer?.cancel();
    }
  }

  List<Message> _filterMessagesByRange(
    List<Message> source,
    _BulkRangeSelection selection,
  ) {
    if (selection.isAll || selection.range == null) return source;
    final startSec =
        selection.range!.start.millisecondsSinceEpoch ~/ 1000; // inclusive
    final endExclusive =
        selection.range!.end
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch ~/
        1000;
    return source.where((msg) {
      final ts = msg.createTime;
      return ts >= startSec && ts < endExclusive;
    }).toList();
  }

  Future<List<Message>> _collectMessagesForSelection(
    _BulkRangeSelection selection, {
    required bool Function(Message) predicate,
    Set<int>? fastLocalTypes,
    bool includePackedInfoDataForFast = false,
    void Function(_BulkSearchProgress progress)? onProgress,
  }) async {
    final session = _selectedSession;
    if (session == null) return [];

    int? startSec;
    int? endSec;
    if (selection.isAll || selection.range == null) {
      final dbRange = await _fetchSessionRangeFromDb(session.username);
      startSec = dbRange?.startSec;
      endSec = dbRange?.endSec;
      if (startSec == null || endSec == null) {
        final fallback = await _resolveMessageRangeForPicker();
        startSec ??= fallback.startSec;
        endSec ??= fallback.endSec;
      }
    } else {
      startSec = selection.range!.start.millisecondsSinceEpoch ~/ 1000;
      endSec =
          selection.range!.end
              .add(const Duration(days: 1))
              .millisecondsSinceEpoch ~/
          1000;
    }

    // 优先从数据库按时间分段拉取（批量解密：只拉目标类型，避免全量 Message 解析/解压造成卡顿）。
    if (startSec != null &&
        endSec != null &&
        endSec > startSec &&
        fastLocalTypes != null &&
        fastLocalTypes.isNotEmpty) {
      final db = context.read<AppState>().databaseService;
      final sources = await db.prepareBulkMessageQuerySources(session.username);

      final results = <Message>[];
      final totalRange = endSec - startSec;
      final chunkSec = totalRange >= 86400 * 180
          ? 86400 * 30
          : (totalRange >= 86400 * 30 ? 86400 * 7 : 86400);
      final int totalChunks = (((totalRange + chunkSec - 1) ~/ chunkSec).clamp(
        1,
        1 << 30,
      )).toInt();

      var scannedChunks = 0;
      for (var cursor = startSec; cursor < endSec; cursor += chunkSec) {
        if (!mounted) return results;
        final chunkEnd = math.min(cursor + chunkSec, endSec);
        final hit = await db.queryMessagesLiteFromSources(
          sources,
          cursor,
          chunkEnd,
          localTypes: fastLocalTypes,
          includePackedInfoData: includePackedInfoDataForFast,
        );
        if (hit.isNotEmpty) {
          final filteredHit = hit.where(predicate).toList();
          if (filteredHit.isNotEmpty) {
            results.addAll(filteredHit);
          }
        }
        scannedChunks += 1;
        onProgress?.call(
          _BulkSearchProgress(
            scannedChunks: scannedChunks,
            totalChunks: totalChunks,
            matchedItems: results.length,
          ),
        );

        await Future<void>.delayed(Duration.zero);
      }

      if (results.isNotEmpty) return results;
    }

    // 通用 fallback：分段拉取全量消息再 predicate 过滤（较慢，但兼容所有消息类型）。
    if (startSec != null && endSec != null && endSec > startSec) {
      final db = context.read<AppState>().databaseService;
      final results = <Message>[];
      final totalRange = endSec - startSec;
      final chunkSec = totalRange >= 86400 * 180
          ? 86400 * 30
          : (totalRange >= 86400 * 30 ? 86400 * 7 : 86400);
      final int totalChunks = (((totalRange + chunkSec - 1) ~/ chunkSec).clamp(
        1,
        1 << 30,
      )).toInt();
      var scannedChunks = 0;
      var matched = 0;

      for (var cursor = startSec; cursor < endSec; cursor += chunkSec) {
        if (!mounted) return results;
        final chunkEnd = math.min(cursor + chunkSec, endSec);
        List<Message> chunkMessages = [];
        try {
          chunkMessages = await db.getMessagesByDate(
            session.username,
            cursor,
            chunkEnd,
          );
        } catch (_) {
          chunkMessages = [];
        }

        if (chunkMessages.isNotEmpty) {
          final hit = chunkMessages.where(predicate).toList();
          if (hit.isNotEmpty) {
            matched += hit.length;
            results.addAll(hit);
          }
        }

        scannedChunks += 1;
        onProgress?.call(
          _BulkSearchProgress(
            scannedChunks: scannedChunks,
            totalChunks: totalChunks,
            matchedItems: matched,
          ),
        );
        await Future<void>.delayed(Duration.zero);
      }

      if (results.isNotEmpty) return results;
    }

    // fallback：用已加载到内存的消息过滤
    final messages = _filterMessagesByRange(_messages, selection);
    final filtered = messages.where(predicate).toList();
    onProgress?.call(
      _BulkSearchProgress(
        scannedChunks: 1,
        totalChunks: 1,
        matchedItems: filtered.length,
      ),
    );
    return filtered;
  }

  String _formatDateOnly(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _describeRange(_BulkRangeSelection selection) {
    if (selection.isAll || selection.range == null) return '全部时间';
    return '${_formatDateOnly(selection.range!.start)} ~ ${_formatDateOnly(selection.range!.end)}';
  }

  bool _shouldAnimateAvatar(String? username, AppState appState) {
    if (username == null || username.isEmpty) return true;
    return !appState.isAvatarCached(username);
  }

  List<ChatSession> _filterSessionsByQuery(
    List<ChatSession> source,
    String query,
  ) {
    if (query.isEmpty) return source;
    final lower = query.toLowerCase();
    return source.where((session) {
      final displayName = session.displayName?.toLowerCase() ?? '';
      final username = session.username.toLowerCase();
      final summary = session.displaySummary.toLowerCase();
      return displayName.contains(lower) ||
          username.contains(lower) ||
          summary.contains(lower);
    }).toList();
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

  void _queueRealtimeRefresh() {
    if (_realtimeRefreshFuture != null) {
      _realtimeRefreshQueued = true;
      return;
    }
    _realtimeRefreshFuture = _refreshRealtimeData().whenComplete(() {
      _realtimeRefreshFuture = null;
      if (_realtimeRefreshQueued) {
        _realtimeRefreshQueued = false;
        _queueRealtimeRefresh();
      }
    });
  }

  void _listenDatabaseChanges() {
    _dbChangeSubscription?.cancel();
    final dbService = context.read<AppState>().databaseService;
    _dbChangeSubscription = dbService.databaseChangeStream.listen((_) {
      _queueRealtimeRefresh();
    });
  }

  Future<void> _refreshRealtimeData() async {
    if (_isRealtimeRefreshing || !mounted) return;
    _realtimeTick++;
    final appState = context.read<AppState>();
    if (appState.databaseService.mode != DatabaseMode.realtime ||
        !appState.databaseService.isConnected) {
      return;
    }

    _isRealtimeRefreshing = true;
    try {
      final refreshSessions = _realtimeTick % 3 == 0;
      if (refreshSessions) {
        await _refreshRealtimeSessions(appState);
      }
      await _refreshRealtimeMessages(appState);
    } finally {
      _isRealtimeRefreshing = false;
    }
  }

  bool _sessionsChanged(List<ChatSession> fresh) {
    if (fresh.length != _sessions.length) return true;
    final checkLength = fresh.length < 20 ? fresh.length : 20;
    for (int i = 0; i < checkLength; i++) {
      final a = fresh[i];
      final b = _sessions[i];
      if (a.username != b.username ||
          a.sortTimestamp != b.sortTimestamp ||
          a.lastTimestamp != b.lastTimestamp ||
          a.summary != b.summary) {
        return true;
      }
    }
    return false;
  }

  Future<void> _refreshRealtimeSessions(AppState appState) async {
    if (_isLoadingSessions) return;
    try {
      final sessions = await appState.databaseService.getSessions();
      final filteredSessions = sessions.where((session) {
        return ChatSession.shouldKeep(session.username);
      }).toList();

      if (!_sessionsChanged(filteredSessions)) return;

      if (!mounted) return;
      setState(() {
        _sessions = filteredSessions;
        final query = _searchController.text.trim().toLowerCase();
        _filteredSessions = _filterSessionsByQuery(_sessions, query);
      });

      final usernamesToFetch = filteredSessions
          .map((s) => s.username)
          .where((u) => !appState.isAvatarCached(u))
          .toList();
      if (usernamesToFetch.isNotEmpty) {
        await appState.fetchAndCacheAvatars(usernamesToFetch);
      }
    } catch (e, stackTrace) {
      await logger.debug('ChatPage', '实时刷新会话失败: $e $stackTrace');
    }
  }

  int _messageTimeKey(Message m) {
    if (m.sortSeq != 0) return m.sortSeq;
    return m.createTime;
  }

  String _buildMessageKey(Message m) {
    return '${m.localId}_${m.createTime}_${m.sortSeq}';
  }

  Future<void> _refreshRealtimeMessages(AppState appState) async {
    if (_selectedSession == null ||
        _isLoadingMessages ||
        _isLoadingMoreMessages) {
      return;
    }

    try {
      const fetchLimit = 30; // 拉取一个固定窗口，避免计数开销
      final latestBatch = await appState.databaseService.getMessages(
        _selectedSession!.username,
        limit: fetchLimit,
        offset: 0,
      );
      if (latestBatch.isEmpty) return;

      if (_messages.isEmpty) {
        // 尚未加载过，交给正常加载流程
        return;
      }

      final incoming = latestBatch.reversed.toList(); // oldest -> newest
      final List<Message> newOnes = [];
      final lastKey = _messageTimeKey(_messages.last);

      for (final msg in incoming) {
        final key = _messageTimeKey(msg);
        if (key <= lastKey) continue;
        final composite = _buildMessageKey(msg);
        if (_messageKeys.contains(composite)) continue;
        _messageKeys.add(composite);
        newOnes.add(msg);
      }

      if (newOnes.isEmpty || !mounted) return;
      setState(() {
        _messages.addAll(newOnes);
        _currentOffset = _messages.length;
      });

      // 若靠近底部，自动跟随新消息
      if (_scrollController.hasClients) {
        final distanceToBottom =
            _scrollController.position.maxScrollExtent -
            _scrollController.position.pixels;
        if (distanceToBottom < 80) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_scrollController.hasClients) return;
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            );
          });
        }
      }

      if (_selectedSession!.isGroup && newOnes.isNotEmpty) {
        final newSenders = latestBatch
            .where(
              (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
            )
            .map((m) => m.senderUsername!)
            .where((username) => !_senderDisplayNames.containsKey(username))
            .toSet()
            .toList();

        if (newSenders.isNotEmpty) {
          final names = await appState.databaseService.getDisplayNames(
            newSenders,
          );
          if (mounted && _selectedSession != null) {
            setState(() {
              _senderDisplayNames.addAll(names);
            });
          }
          await appState.fetchAndCacheAvatars(newSenders);
        }
      }
    } catch (e, stackTrace) {
      await logger.debug('ChatPage', '实时刷新消息失败: $e $stackTrace');
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

      // 在后台线程过滤会话
      final filteredSessions = sessions.where((session) {
        return ChatSession.shouldKeep(session.username);
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

      // 异步加载头像（使用全局缓存）
      try {
        final appState = context.read<AppState>();
        final usernamesToFetch = filteredSessions
            .map((s) => s.username)
            .where((u) => !appState.isAvatarCached(u))
            .toList();
        if (usernamesToFetch.isNotEmpty) {
          await appState.fetchAndCacheAvatars(usernamesToFetch);
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
        _toast.show(context, '加载会话列表失败: $e', success: false);
      }
    }
  }

  Future<void> _loadMessages(ChatSession session) async {
    final loadId = ++_sessionLoadSeq;
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
      _resetScrollController();
      _resetUtilityPanelState();
    });

    // 异步加载消息 - 初次只加载少量消息以提升性能
    try {
      final appState = context.read<AppState>();
      // 若我的头像尚未就绪，尝试补载
      if (_myAvatarUrl == null || _myAvatarUrl!.isEmpty) {
        _loadMyAvatar(); // 不等待，并行加载
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

      // 如果用户已切换会话，丢弃结果
      if (_sessionLoadSeq != loadId ||
          _selectedSession?.username != session.username) {
        await logger.info('ChatPage', '会话已切换，丢弃旧的消息结果: ${session.username}');
        return;
      }

      await logger.info('ChatPage', '获取到 ${messages.length} 条消息');

      // 1. 先渲染消息，让用户立刻看到内容（渐进式渲染）
      setState(() {
        _messages = messages.reversed.toList(); // 反转顺序，最新消息在下方
        _messageKeys
          ..clear()
          ..addAll(_messages.map(_buildMessageKey));
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

      // 2. 如果是群聊，后台加载发送者显示名和头像
      if (session.isGroup && messages.isNotEmpty) {
        // 不await，让它在后台运行
        _loadGroupMemberInfo(session, messages);
      }

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
              DateTime.now().difference(_lastInitialLoadTime!).inMilliseconds <
                  1000) {
            _loadMoreMessages();
          }
        });
      }
    } catch (e) {
      if (mounted) {
        if (_sessionLoadSeq == loadId) {
          setState(() {
            _isLoadingMessages = false;
          });
        }
        _toast.show(context, '加载消息失败: $e', success: false);
      }
    }
  }

  void _resetScrollController() {
    final oldController = _scrollController;
    _scrollController = ScrollController()..addListener(_onScroll);
    oldController.removeListener(_onScroll);
    // 等待新列表构建完毕后再安全释放旧控制器，避免仍有附着的滚动位置导致报错
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !oldController.hasClients) {
        oldController.dispose();
      } else {
        // 再排队一次，确保彻底分离后释放
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!oldController.hasClients) {
            oldController.dispose();
          }
        });
      }
    });
  }

  // 新增：专门加载群成员信息的方法
  Future<void> _loadGroupMemberInfo(
    ChatSession session,
    List<Message> messages,
  ) async {
    try {
      final appState = context.read<AppState>();
      await logger.info('ChatPage', '这是群聊，开始后台查询发送者显示名');
      final senderUsernames = messages
          .where(
            (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
          )
          .map((m) => m.senderUsername!)
          .toSet()
          .toList();

      if (senderUsernames.isNotEmpty) {
        await logger.info('ChatPage', '查询 ${senderUsernames.length} 个发送者的显示名');
        final names = await appState.databaseService.getDisplayNames(
          senderUsernames,
        );

        if (!mounted || _selectedSession?.username != session.username) return;

        setState(() {
          _senderDisplayNames.addAll(names);
        });

        // 同时查询头像（使用全局缓存）
        try {
          await appState.fetchAndCacheAvatars(senderUsernames);
        } catch (_) {}

        await logger.info('ChatPage', '获取到 ${names.length} 个显示名');
      }
    } catch (e) {
      logger.error('ChatPage', '加载群成员信息失败', e);
    }
  }

  Future<void> _bulkDecodeVoices() async {
    if (_selectedSession == null || _voiceBulkRunning) return;
    final selection = await _pickBulkRange('选择语音解密时间范围');
    if (!mounted || selection == null) return;

    final appState = context.read<AppState>();
    final sessionUsername = _selectedSession!.username;
    final cpu = CpuInfo.logicalProcessors;
    final concurrency = math.max(2, math.min(8, (cpu * 3) ~/ 4));
    setState(() {
      _voiceBulkRunning = true;
      _voiceBulkTotal = 0;
      _voiceBulkDone = 0;
      _voiceBulkFailed = 0;
      _voiceBulkStatus = '启动解密引擎中…（并行 $concurrency/$cpu）';
    });

    // 让 UI 先渲染出“启动中”状态，再开始创建 Isolate 池（耗时操作）。
    await Future<void>.delayed(Duration.zero);

    final token = appState.tryStartBulkJob(
      sessionUsername: sessionUsername,
      typeLabel: '语音批量解密',
      poolSize: concurrency,
    );
    if (token == null) {
      if (!mounted) return;
      setState(() {
        _voiceBulkRunning = false;
        _voiceBulkStatus = null;
      });
      final runningSession = appState.bulkJobSession ?? '未知会话';
      final runningType = appState.bulkJobType ?? '批量任务';
      _toast.show(
        context,
        '已有任务进行中：$runningType（$runningSession），请等待完成',
        success: false,
      );
      return;
    }
    try {
      final pool = await token.poolFuture;
      appState.voiceService.bulkPool = pool;

      setState(() {
        _voiceBulkStatus = '搜索中：0 条语音（${_describeRange(selection)}）';
      });

      var lastUiTick = DateTime.fromMillisecondsSinceEpoch(0);
      final runId = ++_voiceBulkRunId;
      final voiceMessages = await _collectMessagesForSelection(
        selection,
        predicate: (m) => m.isVoiceMessage && m.isSend != 1,
        fastLocalTypes: const <int>{34},
        includePackedInfoDataForFast: false,
        onProgress: (progress) {
          final now = DateTime.now();
          if (now.difference(lastUiTick).inMilliseconds < 120) return;
          lastUiTick = now;
          if (!mounted) return;
          if (runId != _voiceBulkRunId) return;
          setState(() {
            _voiceBulkStatus =
                '搜索中：已扫描 ${progress.scannedChunks}/${progress.totalChunks} '
                '时间块，找到 ${progress.matchedItems} 条语音（${_describeRange(selection)}）';
          });
        },
      );
      if (voiceMessages.isEmpty) {
        if (mounted) {
          setState(() {
            _voiceBulkRunning = false;
            _voiceBulkStatus = null;
          });
          _toast.show(
            context,
            selection.isAll ? '当前会话没有语音消息可解密' : '所选时间范围内没有语音消息',
            success: false,
          );
        }
        return;
      }

      // 从最新开始（create_time 降序）
      voiceMessages.sort((a, b) {
        final c = b.createTime.compareTo(a.createTime);
        if (c != 0) return c;
        return b.localId.compareTo(a.localId);
      });

      setState(() {
        _voiceBulkTotal = voiceMessages.length;
        _voiceBulkDone = 0;
        _voiceBulkFailed = 0;
        _voiceBulkStatus =
            '开始解密 ${voiceMessages.length} 条语音（${_describeRange(selection)}）';
      });

      var done = 0;
      var failed = 0;
      String? lastError;

      Timer? uiTimer;
      uiTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted || runId != _voiceBulkRunId) return;
        setState(() {
          _voiceBulkDone = done;
          _voiceBulkFailed = failed;
          _voiceBulkStatus =
              '解密完成 $done/${voiceMessages.length}（并行 $concurrency/$cpu）'
              '${lastError != null ? '，最近错误：$lastError' : ''}';
        });
      });

      final sem = _AsyncSemaphore(concurrency);
      final futures = <Future<void>>[];
      for (int i = 0; i < voiceMessages.length; i++) {
        final index = i;
        final msg = voiceMessages[i];
        await sem.acquire();
        futures.add(() async {
          try {
            if (!mounted || runId != _voiceBulkRunId) return;
            final outputFile = await appState.voiceService.getOutputFile(
              msg,
              sessionUsername,
            );
            final waitReady = _waitVoiceFileReady(
              outputFile.path,
              timeout: const Duration(seconds: 45),
            );
            final decodeFuture = appState.voiceService.ensureVoiceDecoded(
              msg,
              sessionUsername,
            );

            await Future.any([
              // ignore: body_might_complete_normally_catch_error
              decodeFuture.catchError((_) {}),
              waitReady,
            ]).timeout(const Duration(seconds: 60));

            final exists = await outputFile.exists();
            if (!exists) {
              failed += 1;
              lastError = '未检测到文件';
            }
            done += 1;
          } on TimeoutException {
            failed += 1;
            done += 1;
            lastError = '超时：第 ${index + 1} 条';
          } on SelfSentVoiceNotSupportedException {
            // 跳过自己发送的消息，不计入失败
            done += 1;
          } catch (e) {
            failed += 1;
            done += 1;
            lastError = e.toString();
          } finally {
            sem.release();
          }
        }());
      }
      await Future.wait(futures);
      uiTimer.cancel();

      if (!mounted) return;
      setState(() {
        _voiceBulkDone = done;
        _voiceBulkFailed = failed;
        _voiceBulkRunning = false;
        _voiceBulkStatus = _voiceBulkFailed > 0
            ? '完成，失败 $_voiceBulkFailed 个'
            : '全部语音已解密';
      });
      _toast.show(
        context,
        '语音解密完成: $_voiceBulkDone/$_voiceBulkTotal'
        '${_voiceBulkFailed > 0 ? '，失败 $_voiceBulkFailed' : ''}',
        success: true,
      );
    } finally {
      appState.voiceService.bulkPool = null;
      await appState.endBulkJob(token);
    }
  }

  Future<void> _bulkDecryptImages() async {
    if (_selectedSession == null || _imageBulkRunning) return;
    final selection = await _pickBulkRange('选择图片解密时间范围');
    if (!mounted || selection == null) return;

    final appState = context.read<AppState>();
    final sessionUsername = _selectedSession!.username;
    final cpu = CpuInfo.logicalProcessors;
    final concurrency = math.max(2, math.min(12, cpu));
    setState(() {
      _imageBulkRunning = true;
      _imageBulkTotal = 0;
      _imageBulkDone = 0;
      _imageBulkFailed = 0;
      _imageBulkStatus = '正在开启解密线程…（并行 $concurrency/$cpu）';
    });
    await Future<void>.delayed(Duration.zero);

    final token = appState.tryStartBulkJob(
      sessionUsername: sessionUsername,
      typeLabel: '图片批量解密',
      poolSize: concurrency,
    );
    if (token == null) {
      if (!mounted) return;
      setState(() {
        _imageBulkRunning = false;
        _imageBulkStatus = null;
      });
      final runningSession = appState.bulkJobSession ?? '未知会话';
      final runningType = appState.bulkJobType ?? '批量任务';
      _toast.show(
        context,
        '已有任务进行中：$runningType（$runningSession），请等待完成',
        success: false,
      );
      return;
    }
    try {
      final pool = await token.poolFuture;
      _imageDecryptService.bulkPool = pool;

      setState(() {
        _imageBulkStatus = '搜索中：0 张图片（${_describeRange(selection)}）';
      });

      var lastUiTick = DateTime.fromMillisecondsSinceEpoch(0);
      final runId = ++_imageBulkRunId;
      final filteredMessages = await _collectMessagesForSelection(
        selection,
        predicate: (m) => m.hasImage && m.imageDatName != null,
        fastLocalTypes: const <int>{3},
        includePackedInfoDataForFast: true,
        onProgress: (progress) {
          final now = DateTime.now();
          if (now.difference(lastUiTick).inMilliseconds < 120) return;
          lastUiTick = now;
          if (!mounted) return;
          if (runId != _imageBulkRunId) return;
          setState(() {
            _imageBulkStatus =
                '搜索中：已扫描 ${progress.scannedChunks}/${progress.totalChunks} '
                '时间块，找到 ${progress.matchedItems} 张图片（${_describeRange(selection)}）';
          });
        },
      );
      // 从最新开始：按消息时间降序提取 datName，并保持插入顺序去重。
      filteredMessages.sort((a, b) {
        final c = b.createTime.compareTo(a.createTime);
        if (c != 0) return c;
        return b.localId.compareTo(a.localId);
      });
      final seen = <String>{};
      final datNames = <String>[];
      for (final m in filteredMessages) {
        final name = m.imageDatName?.toLowerCase();
        if (name == null || name.isEmpty) continue;
        if (seen.add(name)) datNames.add(name);
      }
      if (datNames.isEmpty) {
        if (mounted) {
          setState(() {
            _imageBulkRunning = false;
            _imageBulkStatus = null;
          });
          _toast.show(
            context,
            selection.isAll ? '当前会话没有图片消息可解密' : '所选时间范围内没有图片消息',
            success: false,
          );
        }
        return;
      }

      setState(() {
        _imageBulkTotal = datNames.length;
        _imageBulkDone = 0;
        _imageBulkFailed = 0;
        _imageBulkStatus =
            '开始解密 ${datNames.length} 张图片（${_describeRange(selection)}）';
      });

      final config = appState.configService;
      final basePath = await config.getDatabasePath() ?? '';
      final wxid = await config.getManualWxid();
      if (basePath.isEmpty || wxid == null || wxid.isEmpty) {
        throw Exception('未配置数据库路径或账号 wxid');
      }
      final accountDir = Directory(p.join(basePath, wxid));
      if (!await accountDir.exists()) {
        throw Exception('账号目录不存在: ${accountDir.path}');
      }

      final xorKeyHex = await config.getImageXorKey();
      if (xorKeyHex == null || xorKeyHex.isEmpty) {
        throw Exception('未配置图片 XOR 密钥');
      }
      final aesKeyHex = await config.getImageAesKey();
      final xorKey = ImageDecryptService.hexToXorKey(xorKeyHex);
      Uint8List? aesKey;
      if (aesKeyHex != null && aesKeyHex.isNotEmpty) {
        try {
          aesKey = ImageDecryptService.hexToBytes16(aesKeyHex);
        } catch (_) {
          // 允许为空，兼容 V3/V1
        }
      }

      final docs = await getApplicationDocumentsDirectory();
      final imagesRoot = Directory(p.join(docs.path, 'EchoTrace', 'Images'));
      if (!await imagesRoot.exists()) {
        await imagesRoot.create(recursive: true);
      }
      await _prepareImageDisplayName(_selectedSession!);

      // 预先建立 dat 文件索引：避免每张图片都递归扫描 accountDir。
      await _primeDatPathCache(
        accountDir,
        datNames.toSet(),
        onProgress: (scanned, matched) {
          if (!mounted || runId != _imageBulkRunId) return;
          final now = DateTime.now();
          if (now.difference(lastUiTick).inMilliseconds < 120) return;
          lastUiTick = now;
          setState(() {
            _imageBulkStatus =
                '索引中：已扫描 $scanned 个文件，命中 $matched 个（${_describeRange(selection)}）';
          });
        },
      );

      final cpu = CpuInfo.logicalProcessors;
      var done = 0;
      var failed = 0;
      String? lastError;

      Timer? uiTimer;
      uiTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted || runId != _imageBulkRunId) return;
        setState(() {
          _imageBulkDone = done;
          _imageBulkFailed = failed;
          _imageBulkStatus =
              '已解密 $done/$_imageBulkTotal（并行 $concurrency/$cpu）'
              '${lastError != null ? '，最近错误：$lastError' : ''}';
        });
      });

      final sem = _AsyncSemaphore(concurrency);
      final futures = <Future<void>>[];
      for (final datName in datNames) {
        await sem.acquire();
        futures.add(() async {
          try {
            if (!mounted || runId != _imageBulkRunId) return;
            final ok = await _decryptSingleImage(
              datName,
              accountDir,
              imagesRoot,
              xorKey,
              aesKey,
            );
            done += 1;
            if (!ok) failed += 1;
            if (!ok) lastError = '未找到或解密失败: $datName';
          } catch (e) {
            done += 1;
            failed += 1;
            lastError = '解密失败: $datName ($e)';
          } finally {
            sem.release();
          }
        }());
      }
      await Future.wait(futures);
      uiTimer.cancel();
      if (mounted && runId == _imageBulkRunId) {
        setState(() {
          _imageBulkDone = done;
          _imageBulkFailed = failed;
          _imageBulkStatus = failed > 0 ? '完成，失败 $failed 个' : '全部图片已解密';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _imageBulkStatus = '批量解密失败: $e';
        });
        _toast.show(context, '批量解密失败: $e', success: false);
      }
    } finally {
      _imageDecryptService.bulkPool = null;
      await appState.endBulkJob(token);
      if (mounted) {
        setState(() {
          // 兜底同步最终计数，避免最后一次 tick 被节流吞掉
          if (_imageBulkTotal > 0) {
            _imageBulkDone = math.min(_imageBulkDone, _imageBulkTotal);
          }
          _imageBulkRunning = false;
        });
      }
    }
  }

  Future<bool> _decryptSingleImage(
    String datName,
    Directory accountDir,
    Directory imagesRoot,
    int xorKey,
    Uint8List? aesKey,
  ) async {
    try {
      final datPaths = await _findDatFiles(accountDir, datName);
      if (datPaths.isEmpty) {
        return false;
      }

      for (final datPath in datPaths) {
        final relative = _buildRelativeImagePath(datPath, accountDir, datName);
        final outPath = p.join(imagesRoot.path, relative);
        final parent = Directory(p.dirname(outPath));
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }

        try {
          await _imageDecryptService.decryptDatAutoAsync(
            datPath,
            outPath,
            xorKey,
            aesKey,
          );
        } catch (e, stack) {
          await logger.error(
            'ChatPage',
            '解密图片失败，尝试下一候选 dat=$datName, path=$datPath',
            e,
            stack,
          );
          continue;
        }

        if (await _isImageUsable(outPath)) {
          return true;
        } else {
          try {
            await File(outPath).delete();
          } catch (_) {}
        }
      }
    } catch (e, stack) {
      await logger.error('ChatPage', '批量解密图片失败 dat=$datName', e, stack);
    }
    return false;
  }

  Future<List<String>> _findDatFiles(
    Directory accountDir,
    String datName,
  ) async {
    final lower = datName.toLowerCase();
    if (_datPathCache.containsKey(lower)) {
      return _datPathCache[lower]!;
    }
    final normalized = _normalizeBaseName(lower);
    final found = <_ImageVariant, String>{};
    try {
      await for (final entity in accountDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = p.basename(entity.path).toLowerCase();
        if (!name.endsWith('.dat')) continue;
        final base = name.substring(0, name.length - 4);
        if (_normalizeBaseName(base) != normalized) continue;
        final variant = _detectVariant(base);
        found[variant] ??= entity.path;
      }
    } catch (_) {}
    final ordered = _orderedVariantPaths(found);
    _datPathCache[lower] = ordered;
    return ordered;
  }

  Future<void> _primeDatPathCache(
    Directory accountDir,
    Set<String> datNames, {
    void Function(int scannedFiles, int matchedNames)? onProgress,
  }) async {
    final wanted = datNames.map((e) => e.toLowerCase()).toSet();
    if (wanted.isEmpty) return;

    final normalizedWanted = <String, String>{};
    for (final name in wanted) {
      normalizedWanted[_normalizeBaseName(name)] = name;
    }

    final foundByName = <String, Map<_ImageVariant, String>>{};
    var scanned = 0;
    for (final name in wanted) {
      foundByName[name] = <_ImageVariant, String>{};
    }

    try {
      await for (final entity in accountDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = p.basename(entity.path).toLowerCase();
        if (!name.endsWith('.dat')) continue;
        scanned += 1;
        if (scanned % 400 == 0) {
          onProgress?.call(scanned, _datPathCache.length);
          await Future<void>.delayed(Duration.zero);
        }

        final base = name.substring(0, name.length - 4);
        final normalized = _normalizeBaseName(base);
        final originalKey = normalizedWanted[normalized];
        if (originalKey == null) continue;

        final variant = _detectVariant(base);
        foundByName[originalKey]![variant] ??= entity.path;
      }
    } catch (_) {}

    for (final entry in foundByName.entries) {
      final ordered = _orderedVariantPaths(entry.value);
      if (ordered.isNotEmpty) {
        _datPathCache[entry.key] = ordered;
      }
    }
    onProgress?.call(scanned, _datPathCache.length);
  }

  String _buildRelativeImagePath(
    String datPath,
    Directory accountDir,
    String datName,
  ) {
    String relative = p
        .relative(datPath, from: accountDir.path)
        .replaceAll('\\', p.separator);
    if (relative.startsWith('..')) {
      relative = '$datName.jpg';
    } else {
      final lower = relative.toLowerCase();
      if (lower.endsWith('.t.dat')) {
        relative = '${relative.substring(0, relative.length - 6)}.jpg';
      } else if (lower.endsWith('.dat')) {
        relative = '${relative.substring(0, relative.length - 4)}.jpg';
      } else if (!lower.endsWith('.jpg')) {
        relative = '$relative.jpg';
      }
      relative = _applyDisplayNameToRelative(relative);
    }
    return relative;
  }

  List<String> _orderedVariantPaths(Map<_ImageVariant, String> found) {
    final ordered = <String>[];
    for (final variant in _imageVariantPriority) {
      final path = found[variant];
      if (path != null) ordered.add(path);
    }
    return ordered;
  }

  String _normalizeBaseName(String name) {
    var base = name.toLowerCase();
    if (base.endsWith('.dat') || base.endsWith('.jpg')) {
      base = base.substring(0, base.length - 4);
    }
    for (final suffix in ['_b', '_h', '_t', '_c']) {
      if (base.endsWith(suffix)) {
        base = base.substring(0, base.length - suffix.length);
        break;
      }
    }
    return base;
  }

  _ImageVariant _detectVariant(String base) {
    if (base.endsWith('_b')) return _ImageVariant.big;
    if (base.endsWith('_t')) return _ImageVariant.thumb;
    if (base.endsWith('_h')) return _ImageVariant.high;
    if (base.endsWith('_c')) return _ImageVariant.cache;
    return _ImageVariant.original;
  }

  Future<bool> _isImageUsable(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return false;
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      codec.dispose();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _prepareImageDisplayName(ChatSession session) async {
    try {
      final names = await context
          .read<AppState>()
          .databaseService
          .getDisplayNames([session.username]);
      final name = names[session.username];
      if (name != null && name.trim().isNotEmpty) {
        _imageDisplayNameForPath = _sanitizeSegment(name);
      }
    } catch (_) {}
  }

  String _sanitizeSegment(String name) {
    var sanitized = name.replaceAll(RegExp(r'[<>:"/\\\\|?*]'), '_').trim();
    if (sanitized.isEmpty) return '未知联系人';
    if (sanitized.length > 60) sanitized = sanitized.substring(0, 60);
    return sanitized;
  }

  String _applyDisplayNameToRelative(String relativePath) {
    if (_imageDisplayNameForPath == null) return relativePath;
    final sep = Platform.pathSeparator;
    final parts = relativePath.split(sep).where((p) => p.isNotEmpty).toList();
    final attachIdx = parts.indexWhere((p) => p.toLowerCase() == 'attach');
    if (attachIdx != -1 && attachIdx + 1 < parts.length) {
      parts[attachIdx + 1] = _imageDisplayNameForPath!;
      return (relativePath.startsWith(sep) ? sep : '') + parts.join(sep);
    }
    parts.insert(0, _imageDisplayNameForPath!);
    return (relativePath.startsWith(sep) ? sep : '') + parts.join(sep);
  }

  void _ensureSessionDetailLoaded() {
    if (!_showUtilityPanel) return;
    final session = _selectedSession;
    if (session == null) return;
    if (_sessionDetailInfo != null &&
        _sessionDetailForSession == session.username) {
      return;
    }
    _loadSessionDetailInfo(session: session);
  }

  Future<void> _loadSessionDetailInfo({
    ChatSession? session,
    bool force = false,
  }) async {
    final target = session ?? _selectedSession;
    if (target == null || _isLoadingSessionDetail) return;
    final sessionId = target.username;
    if (!force &&
        _sessionDetailInfo != null &&
        _sessionDetailForSession == sessionId) {
      return;
    }
    setState(() {
      _isLoadingSessionDetail = true;
      _sessionDetailError = null;
      if (_sessionDetailForSession != sessionId) {
        _sessionDetailInfo = null;
      }
      _sessionDetailForSession = sessionId;
    });
    try {
      final detail = await context
          .read<AppState>()
          .databaseService
          .getSessionDetailInfo(sessionId);
      if (!mounted || _selectedSession?.username != sessionId) return;
      setState(() {
        _sessionDetailInfo = detail;
      });
    } catch (e) {
      if (!mounted || _selectedSession?.username != sessionId) return;
      setState(() {
        _sessionDetailError = '$e';
      });
    } finally {
      if (mounted && _selectedSession?.username == sessionId) {
        setState(() {
          _isLoadingSessionDetail = false;
        });
      }
    }
  }

  String _formatDetailTime(int? timestamp) {
    if (timestamp == null || timestamp <= 0) return '未知';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
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
          final prepend = moreMessages.reversed.toList();
          _messageKeys.addAll(prepend.map(_buildMessageKey));
          _messages = [...prepend, ..._messages];
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

  Widget _buildLoadMoreIndicator() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: _isLoadingMoreMessages ? 28 : 0,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: _isLoadingMoreMessages ? 1 : 0,
          child: const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
    );
  }

  /// 判断消息是否为自己发送
  bool _isMessageFromMe(Message message) {
    if (message.isSystemLike) {
      return false;
    }
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
        _sessions.isEmpty &&
        !_autoLoadScheduled &&
        appState.databaseService.isConnected) {
      _autoLoadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        _autoLoadScheduled = false;
        await _loadSessions();
      });
    }
    if (_showUtilityPanel) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureSessionDetailLoaded();
      });
    }
    return Stack(
      children: [
        Row(
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
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
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
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.7),
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '请先在「数据管理」页面\n解密数据库文件',
                                  textAlign: TextAlign.center,
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
                          );
                        }

                        Widget sessionChild;
                        if (_isLoadingSessions) {
                          sessionChild = ShimmerLoading(
                            key: const ValueKey('session-loading'),
                            isLoading: true,
                            child: ListView.builder(
                              itemCount: 6,
                              physics: const NeverScrollableScrollPhysics(),
                              itemBuilder: (context, index) =>
                                  const ListItemShimmer(),
                            ),
                          );
                        } else if (_filteredSessions.isEmpty) {
                          sessionChild = Center(
                            key: const ValueKey('session-empty'),
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
                          );
                        } else {
                          sessionChild = ListView.builder(
                            key: const ValueKey('session-list'),
                            cacheExtent: 600,
                            addAutomaticKeepAlives: false,
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            itemCount: _filteredSessions.length,
                            itemBuilder: (context, index) {
                              final session = _filteredSessions[index];
                              return ChatSessionItem(
                                session: session,
                                isSelected:
                                    _selectedSession?.username ==
                                    session.username,
                                onTap: () => _loadMessages(session),
                                avatarUrl: appState.getAvatarUrl(
                                  session.username,
                                ),
                                enableAvatarFade: _shouldAnimateAvatar(
                                  session.username,
                                  appState,
                                ),
                              );
                            },
                          );
                        }

                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder: (child, animation) {
                            final slide = Tween<Offset>(
                              begin: const Offset(0, 0.02),
                              end: Offset.zero,
                            ).animate(animation);
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: slide,
                                child: child,
                              ),
                            );
                          },
                          child: sessionChild,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            // 右侧消息 + 工具栏
            Expanded(
              child: Row(
                children: [
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
                                      color: Colors.black.withValues(
                                        alpha: 0.05,
                                      ),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  children: [
                                    _buildSelectedSessionAvatar(
                                      context,
                                      appState,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _getSessionDisplayName(
                                              _selectedSession!,
                                            ),
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                          Text(
                                            _selectedSession!.typeDescription,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
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
                                    IconButton(
                                      tooltip: _showUtilityPanel
                                          ? '收起工具栏'
                                          : '会话工具',
                                      icon: Icon(
                                        _showUtilityPanel
                                            ? Icons.close_fullscreen_rounded
                                            : Icons.info_outline_rounded,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _showUtilityPanel =
                                              !_showUtilityPanel;
                                        });
                                        if (_showUtilityPanel) {
                                          _ensureSessionDetailLoaded();
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              // 消息列表
                              Expanded(
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: AnimatedOpacity(
                                        duration: const Duration(
                                          milliseconds: 200,
                                        ),
                                        opacity: _isLoadingMessages ? 1 : 0,
                                        child: const IgnorePointer(
                                          child: MessageLoadingShimmer(
                                            key: ValueKey('msg-loading'),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned.fill(
                                      child: AnimatedOpacity(
                                        duration: const Duration(
                                          milliseconds: 220,
                                        ),
                                        opacity: _isLoadingMessages ? 0 : 1,
                                        child: _messages.isEmpty
                                            ? Center(
                                                child: Text(
                                                  '暂无消息',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.copyWith(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .onSurface
                                                            .withValues(
                                                              alpha: 0.5,
                                                            ),
                                                      ),
                                                ),
                                              )
                                            : ListView.builder(
                                                controller: _scrollController,
                                                padding: const EdgeInsets.all(
                                                  16,
                                                ),
                                                cacheExtent: 800,
                                                addAutomaticKeepAlives: false,
                                                itemCount:
                                                    _messages.length + 1,
                                                itemBuilder: (context, index) {
                                                  if (index == 0) {
                                                    return _buildLoadMoreIndicator();
                                                  }

                                                  const offset = 1;
                                                  final message =
                                                      _messages[index - offset];

                                                  final senderName =
                                                      _getSenderDisplayName(
                                                        message,
                                                      );

                                                  bool shouldShowTime = false;
                                                  if (index - offset == 0) {
                                                    shouldShowTime = true;
                                                  } else {
                                                    final previousMessage =
                                                        _messages[index -
                                                            offset -
                                                            1];
                                                    final timeDiff =
                                                        message.createTime -
                                                        previousMessage
                                                            .createTime;
                                                    shouldShowTime =
                                                        timeDiff > 600;
                                                  }

                                                  final avatarUrl =
                                                      _selectedSession
                                                              ?.isGroup ==
                                                          true
                                                      ? (message.senderUsername !=
                                                                null
                                                            ? appState.getAvatarUrl(
                                                                message
                                                                    .senderUsername!,
                                                              )
                                                            : null)
                                                      : appState.getAvatarUrl(
                                                          _selectedSession!
                                                              .username,
                                                        );

                                                  final avatarOwner =
                                                      _isMessageFromMe(message)
                                                      ? appState
                                                                .databaseService
                                                                .currentAccountWxid ??
                                                            ''
                                                      : (message.senderUsername ??
                                                            _selectedSession
                                                                ?.username ??
                                                            '');
                                                  final animateAvatar =
                                                      _shouldAnimateAvatar(
                                                        avatarOwner,
                                                        appState,
                                                      );

                                                  return MessageBubble(
                                                    key: ValueKey(
                                                      'msg-${message.localId}-${message.createTime}',
                                                    ),
                                                    message: message,
                                                    isFromMe: _isMessageFromMe(
                                                      message,
                                                    ),
                                                    senderDisplayName:
                                                        senderName,
                                                    sessionUsername:
                                                        _selectedSession
                                                            ?.username ??
                                                        '',
                                                    shouldShowTime:
                                                        shouldShowTime,
                                                    avatarUrl:
                                                        _isMessageFromMe(
                                                          message,
                                                        )
                                                        ? _myAvatarUrl
                                                        : avatarUrl,
                                                    enableAvatarFade:
                                                        animateAvatar,
                                                  );
                                                },
                                              ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, animation) {
                      final slide = Tween<Offset>(
                        begin: const Offset(0.1, 0),
                        end: Offset.zero,
                      ).animate(animation);
                      return SizeTransition(
                        sizeFactor: animation,
                        axis: Axis.horizontal,
                        axisAlignment: -1,
                        child: SlideTransition(position: slide, child: child),
                      );
                    },
                    child: (_selectedSession != null && _showUtilityPanel)
                        ? SizedBox(
                            key: const ValueKey('utility-panel'),
                            width: 320,
                            child: _buildUtilityPanel(context),
                          )
                        : const SizedBox.shrink(
                            key: ValueKey('utility-panel-empty'),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: showErrorOverlay
                ? Container(
                    color: Colors.white.withValues(alpha: 0.9),
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
                    color: Colors.white.withValues(alpha: 0.9),
                    child: Center(child: _buildFancyLoader(context)),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  Widget _buildUtilityPanel(BuildContext context) {
    final theme = Theme.of(context);
    final session = _selectedSession;
    if (session == null) return const SizedBox.shrink();
    final appState = context.watch<AppState>();
    final bulkLocked = appState.isBulkJobRunning;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          left: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.12),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(-2, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Text(
                  '会话工具',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    setState(() {
                      _showUtilityPanel = false;
                    });
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Text(
              '批量解密',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          _buildBulkTile(
            context,
            icon: Icons.graphic_eq_rounded,
            title: '语音批量解密',
            subtitle: '解密并缓存本会话语音，供离线播放',
            isRunning: _voiceBulkRunning,
            done: _voiceBulkDone,
            total: _voiceBulkTotal,
            failed: _voiceBulkFailed,
            status: _voiceBulkStatus,
            actionLabel: '开始',
            onPressed: (_voiceBulkRunning || bulkLocked)
                ? null
                : _bulkDecodeVoices,
          ),
          _buildBulkTile(
            context,
            icon: Icons.photo_library_rounded,
            title: '图片批量解密',
            subtitle: '按会话批量导出/解密图片文件',
            isRunning: _imageBulkRunning,
            done: _imageBulkDone,
            total: _imageBulkTotal,
            failed: _imageBulkFailed,
            status: _imageBulkStatus,
            actionLabel: '开始',
            onPressed: (_imageBulkRunning || bulkLocked)
                ? null
                : _bulkDecryptImages,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Text(
                  '会话详情',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: _isLoadingSessionDetail
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('刷新'),
                  onPressed: _isLoadingSessionDetail
                      ? null
                      : () => _loadSessionDetailInfo(force: true),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: _buildSessionDetailCard(theme, session),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBulkTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isRunning,
    required int done,
    required int total,
    required int failed,
    required String? status,
    required String actionLabel,
    required VoidCallback? onPressed,
  }) {
    final theme = Theme.of(context);
    final progress = total == 0 ? 0.0 : done / total;
    final progressValue = total == 0
        ? null
        : progress.clamp(0.0, 1.0).toDouble();
    final showProgress = isRunning || total > 0 || failed > 0;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.tonal(
                  onPressed: onPressed,
                  child: Text(isRunning ? '进行中' : actionLabel),
                ),
              ],
            ),
            if (showProgress) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: progressValue,
                minHeight: 6,
                backgroundColor: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.6),
              ),
              const SizedBox(height: 6),
              Text(
                status ?? '尚未执行',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              if (total > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '进度: $done/$total${failed > 0 ? '，失败 $failed' : ''}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: failed > 0
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  '尚未执行',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionDetailCard(ThemeData theme, ChatSession session) {
    if (_sessionDetailError != null) {
      return Text(
        _sessionDetailError!,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    if (_isLoadingSessionDetail) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            children: [
              const CircularProgressIndicator(strokeWidth: 2),
              const SizedBox(height: 8),
              Text(
                '正在获取 ${session.displayName ?? session.username} 的详细信息...',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }
    if (_sessionDetailInfo == null) {
      return Text(
        '点击「加载」查看会话详情',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      );
    }
    final detail = _sessionDetailInfo!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDetailRow(theme, '显示名称', detail.displayName),
        _buildDetailRow(theme, '微信ID', detail.wxid),
        if (detail.remark != null) _buildDetailRow(theme, '备注', detail.remark!),
        if (detail.nickName != null)
          _buildDetailRow(theme, '昵称', detail.nickName!),
        if (detail.alias != null) _buildDetailRow(theme, '微信号', detail.alias!),
        const SizedBox(height: 6),
        _buildDetailRow(theme, '消息总数', '${detail.messageCount} 条'),
        _buildDetailRow(
          theme,
          '第一条消息',
          _formatDetailTime(detail.firstMessageTime),
        ),
        _buildDetailRow(
          theme,
          '最新消息',
          _formatDetailTime(detail.latestMessageTime),
        ),
        const SizedBox(height: 10),
        Text(
          '消息表分布',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        if (detail.messageTables.isEmpty)
          Text(
            '未找到消息表',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          )
        else
          ...detail.messageTables.map(
            (table) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    table.databaseName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${table.tableName} · ${table.messageCount} 条',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDetailRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              '$label:',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  Widget _buildFancyLoader(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOut,
      builder: (context, value, child) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 72,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(3, (index) {
                  final delay = index * 0.15;
                  final t = (value - delay).clamp(0.0, 1.0);
                  final height = 10 + 26 * Curves.easeInOut.transform(t);
                  final opacity = 0.2 + 0.6 * t;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeInOut,
                    width: 10,
                    height: height,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: opacity),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '正在连接数据库...',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.8),
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

    final resolvedPath = appState.resolvedSessionDbPath;
    if (resolvedPath != null) {
      try {
        if (!File(resolvedPath).existsSync()) {
          isMissingDb = true;
        }
      } catch (_) {}
    }

    final hint = isMissingDb
        ? '未找到对应账号的数据库文件，请先在「数据管理」页面解密当前选择的 wxid。'
        : '请检查数据库解密状态和密钥配置，或前往数据管理页面查看解密状态。';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.12),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.error.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.error_outline,
              size: 36,
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            isMissingDb ? '未找到数据库文件' : '无法连接数据库',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.error,
              letterSpacing: 0.1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 6),
          if (isMissingDb && resolvedPath != null)
            Text(
              '路径: $resolvedPath',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            )
          else
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: () =>
                    context.read<AppState>().setCurrentPage('data_management'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                ),
                child: const Text('前往数据管理'),
              ),
              OutlinedButton(
                onPressed: () =>
                    context.read<AppState>().setCurrentPage('settings'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                  side: BorderSide(
                    color: theme.colorScheme.outline.withValues(alpha: 0.4),
                  ),
                ),
                child: const Text('重新配置'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedSessionAvatar(BuildContext context, AppState appState) {
    final avatarUrl = _selectedSession != null
        ? appState.getAvatarUrl(_selectedSession!.username)
        : null;
    final animateAvatar = _selectedSession != null
        ? _shouldAnimateAvatar(_selectedSession!.username, appState)
        : true;

    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: avatarUrl,
        fadeInDuration: animateAvatar
            ? const Duration(milliseconds: 200)
            : Duration.zero,
        fadeOutDuration: animateAvatar
            ? const Duration(milliseconds: 200)
            : Duration.zero,
        imageBuilder: (context, imageProvider) => CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primary,
          backgroundImage: imageProvider,
        ),
        placeholder: (context, url) => CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: Text(
            StringUtils.getFirstChar(
              _selectedSession!.displayName ?? _selectedSession!.username,
            ),
            style: const TextStyle(color: Colors.white),
          ),
        ),
        errorWidget: (context, url, error) => CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: Text(
            StringUtils.getFirstChar(
              _selectedSession!.displayName ?? _selectedSession!.username,
            ),
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    } else {
      return CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: Text(
          StringUtils.getFirstChar(
            _selectedSession!.displayName ?? _selectedSession!.username,
          ),
          style: const TextStyle(color: Colors.white),
        ),
      );
    }
  }
}
