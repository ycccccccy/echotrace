import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import '../utils/string_utils.dart';

class ChatTimelinePage extends StatefulWidget {
  final DatabaseService databaseService;

  const ChatTimelinePage({super.key, required this.databaseService});

  @override
  State<ChatTimelinePage> createState() => _ChatTimelinePageState();
}

class _ChatTimelinePageState extends State<ChatTimelinePage> {
  final List<_FriendTimeline> _friends = [];
  final List<_TimelineSegment> _segments = [];
  final Set<String> _selectedUsernames = {};

  bool _isLoading = false;
  String _loadingStatus = '';
  int _processedCount = 0;
  int _totalCount = 0;

  String _searchQuery = '';
  bool _filtersExpanded = false;
  double _timeScale = 1.0;

  static const double _minScale = 0.6;
  static const double _maxScale = 2.6;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  Future<void> _loadData() async {
    await logger.debug('ChatTimelinePage', '========== 开始加载聊天时间线 ==========');

    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _loadingStatus = '正在连接数据库...';
      _processedCount = 0;
      _totalCount = 0;
    });

    if (!widget.databaseService.isConnected) {
      await logger.warning('ChatTimelinePage', '数据库未连接，尝试自动连接');
      final appState = context.read<AppState>();
      try {
        await appState.reconnectDatabase();
      } catch (e) {
        await logger.error('ChatTimelinePage', '自动连接失败', e);
      }
    }

    if (!widget.databaseService.isConnected) {
      await logger.warning('ChatTimelinePage', '数据库仍未连接');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadingStatus = '数据库未连接';
        });
      }
      return;
    }

    try {
      if (!mounted) return;
      setState(() {
        _loadingStatus = '正在获取会话列表...';
      });

      final sessions = await widget.databaseService.getSessions();
      final privateSessions = sessions.where((s) => !s.isGroup).toList();

      if (!mounted) return;
      setState(() {
        _totalCount = privateSessions.length;
        _processedCount = 0;
        _loadingStatus = '正在读取好友信息...';
      });

      final displayNames = await widget.databaseService.getDisplayNames(
        privateSessions.map((s) => s.username).toList(),
      );

      _friends.clear();
      _segments.clear();

      for (var i = 0; i < privateSessions.length; i++) {
        final session = privateSessions[i];
        final displayName =
            displayNames[session.username] ?? session.username;

        if (!mounted) return;
        setState(() {
          _processedCount = i + 1;
          _loadingStatus = '读取: $displayName';
        });

        try {
          final activeDates = await widget.databaseService
              .getSessionActiveDates(session.username);
          if (activeDates.isEmpty) {
            continue;
          }
          _friends.add(
            _FriendTimeline(
              username: session.username,
              displayName: displayName,
              activeDates: activeDates,
            ),
          );
        } catch (e) {
          await logger.warning(
            'ChatTimelinePage',
            '读取 ${session.username} 活跃日期失败: $e',
          );
        }
      }

      _friends.sort((a, b) => a.firstDate.compareTo(b.firstDate));
      for (final friend in _friends) {
        _segments.addAll(_buildSegments(friend));
      }
      _segments.sort((a, b) => a.start.compareTo(b.start));
      _syncSelections();
      _warmAvatarCache();

      if (mounted) {
        setState(() {
          _loadingStatus = '完成';
        });
      }
    } catch (e, stackTrace) {
      await logger.error('ChatTimelinePage', '加载数据失败: $e', e, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载数据失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      await logger.debug('ChatTimelinePage', '========== 时间线加载完成 ==========');
    }
  }

  void _syncSelections() {
    if (_friends.isEmpty) {
      _selectedUsernames.clear();
      return;
    }
    if (_selectedUsernames.isEmpty) {
      _selectedUsernames.addAll(_friends.map((e) => e.username));
      return;
    }
    final existing = _friends.map((e) => e.username).toSet();
    _selectedUsernames.removeWhere((u) => !existing.contains(u));
  }

  List<_TimelineSegment> get _visibleSegments {
    final query = _searchQuery.trim().toLowerCase();
    return _segments.where((segment) {
      if (!_selectedUsernames.contains(segment.username)) return false;
      if (query.isEmpty) return true;
      return segment.displayName.toLowerCase().contains(query) ||
          segment.username.toLowerCase().contains(query);
    }).toList();
  }

  DateTime? get _minStart {
    final segments = _visibleSegments;
    if (segments.isEmpty) return null;
    return segments.first.start;
  }

  DateTime? get _maxEnd {
    final segments = _visibleSegments;
    if (segments.isEmpty) return null;
    return segments.map((e) => e.end).reduce(
      (a, b) => a.isAfter(b) ? a : b,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: _isLoading
                ? _buildLoadingView()
                : _friends.isEmpty
                    ? _buildEmptyView()
                    : _buildContent(),
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
            Icons.timeline_rounded,
            size: 28,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Text(
            '聊天时间线',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const Spacer(),
          if (!_isLoading)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadData,
              tooltip: '刷新数据',
            ),
        ],
      ),
    );
  }

  Widget _buildLoadingView() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 80,
              height: 80,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                value: _totalCount > 0 ? _processedCount / _totalCount : null,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              _loadingStatus,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (_totalCount > 0)
              Text(
                '$_processedCount / $_totalCount',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6),
                    ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.timeline_rounded, size: 80, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            '暂无时间线数据',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(color: Colors.grey[400]),
          ),
          const SizedBox(height: 8),
          Text(
            '请先连接数据库',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final minStart = _minStart;
    final maxEnd = _maxEnd;
    final segments = _visibleSegments;
    final daySpacing = 36.0 * _timeScale;

    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && _isZooming()) {
          final delta = event.scrollDelta.dy;
          setState(() {
            _timeScale = (_timeScale + (-delta * 0.002))
                .clamp(_minScale, _maxScale);
          });
        }
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildFilterCard(),
          const SizedBox(height: 16),
          _buildSummaryCard(minStart, maxEnd),
          const SizedBox(height: 16),
          if (segments.isEmpty)
            _buildNoVisibleData()
          else
            _TimelineAxis(
              segments: segments,
              daySpacing: daySpacing,
            ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(DateTime? minStart, DateTime? maxEnd) {
    final segments = _visibleSegments;
    final totalDays = segments.fold<int>(
      0,
      (sum, seg) => sum + seg.durationDays,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.date_range_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '时间线概览',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '已选 ${_selectedUsernames.length} 位好友 · 连续段 ${segments.length} · 共 ${totalDays} 天',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                  ),
                ],
              ),
            ),
            if (minStart != null && maxEnd != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatDate(minStart),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatDate(maxEnd),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterCard() {
    final selectedCount = _selectedUsernames.length;
    return Card(
      child: ExpansionTile(
        initiallyExpanded: _filtersExpanded,
        onExpansionChanged: (value) {
          setState(() => _filtersExpanded = value);
        },
        title: Text(
          '筛选好友 ($selectedCount)',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        subtitle: Text(
          '勾选需要渲染的好友，按住 Ctrl 滚轮缩放时间轴',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
              ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              children: [
                TextField(
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: '搜索好友',
                    isDense: true,
                    filled: true,
                    fillColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.35),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (value) {
                    setState(() => _searchQuery = value);
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: () {
                    setState(() {
                      _selectedUsernames
                        ..clear()
                        ..addAll(_friends.map((e) => e.username));
                    });
                  },
                  child: const Text('全选'),
                ),
                    TextButton(
                      onPressed: () {
                        setState(() => _selectedUsernames.clear());
                      },
                      child: const Text('清空'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: _buildFilterList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterList() {
    final query = _searchQuery.trim().toLowerCase();
    final filtered = _friends.where((entry) {
      if (query.isEmpty) return true;
      return entry.displayName.toLowerCase().contains(query) ||
          entry.username.toLowerCase().contains(query);
    }).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的好友',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
              ),
        ),
      );
    }

    return ListView.separated(
      itemCount: filtered.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        color: Theme.of(context).dividerTheme.color?.withValues(alpha: 0.2),
      ),
      itemBuilder: (context, index) {
        final entry = filtered[index];
        final isChecked = _selectedUsernames.contains(entry.username);
        return CheckboxListTile(
          value: isChecked,
          onChanged: (value) {
            setState(() {
              if (value == true) {
                _selectedUsernames.add(entry.username);
              } else {
                _selectedUsernames.remove(entry.username);
              }
            });
          },
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(
            StringUtils.cleanOrDefault(entry.displayName, entry.username),
          ),
          subtitle: Text(
            '活跃 ${entry.activeDates.length} 天 · 连续段 ${_buildSegments(entry).length}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
          ),
        );
      },
    );
  }

  bool _isZooming() {
    return HardwareKeyboard.instance.logicalKeysPressed
            .contains(LogicalKeyboardKey.controlLeft) ||
        HardwareKeyboard.instance.logicalKeysPressed
            .contains(LogicalKeyboardKey.controlRight);
  }

  Widget _buildNoVisibleData() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            '没有符合条件的活跃日期',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
          ),
        ),
      ),
    );
  }

  List<_TimelineSegment> _buildSegments(_FriendTimeline friend) {
    if (friend.activeDates.isEmpty) return [];
    final dates = friend.activeDates;
    final segments = <_TimelineSegment>[];
    var start = dates.first;
    var previous = dates.first;

    for (var i = 1; i < dates.length; i++) {
      final current = dates[i];
      final gap = current.difference(previous).inDays;
      if (gap == 1) {
        previous = current;
      } else {
        segments.add(
          _TimelineSegment(
            username: friend.username,
            displayName: friend.displayName,
            start: start,
            end: previous,
          ),
        );
        start = current;
        previous = current;
      }
    }

    segments.add(
      _TimelineSegment(
        username: friend.username,
        displayName: friend.displayName,
        start: start,
        end: previous,
      ),
    );

    return segments;
  }

  void _warmAvatarCache() {
    final appState = context.read<AppState>();
    final uncached = _friends
        .map((f) => f.username)
        .where((u) => !appState.isAvatarCached(u))
        .toList();

    if (uncached.isEmpty) return;

    Future(() async {
      const chunkSize = 40;
      for (var i = 0; i < uncached.length; i += chunkSize) {
        final chunk = uncached.sublist(
          i,
          i + chunkSize > uncached.length ? uncached.length : i + chunkSize,
        );
        await appState.fetchAndCacheAvatars(chunk);
        await Future.delayed(const Duration(milliseconds: 120));
      }
    });
  }
}

class _FriendTimeline {
  final String username;
  final String displayName;
  final List<DateTime> activeDates;

  _FriendTimeline({
    required this.username,
    required this.displayName,
    required this.activeDates,
  });

  DateTime get firstDate => activeDates.first;
}

class _TimelineEvent {
  final String username;
  final String displayName;

  _TimelineEvent({required this.username, required this.displayName});
}

class _TimelineAxis extends StatelessWidget {
  final List<_TimelineSegment> segments;
  final double daySpacing;

  const _TimelineAxis({required this.segments, required this.daySpacing});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(segments.length, (index) {
        final segment = segments[index];
        return _TimelineSegmentRow(
          segment: segment,
          daySpacing: daySpacing,
          alignLeft: index.isEven,
          isFirst: index == 0,
          isLast: index == segments.length - 1,
        );
      }),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? avatarUrl;
  final String fallbackText;

  const _Avatar({required this.avatarUrl, required this.fallbackText});

  @override
  Widget build(BuildContext context) {
    final hasAvatar = avatarUrl != null && avatarUrl!.isNotEmpty;
    final theme = Theme.of(context);

    if (!hasAvatar) {
      return CircleAvatar(
        radius: 22,
        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
        child: Text(
          fallbackText,
          style: TextStyle(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }

    return CachedNetworkImage(
      imageUrl: avatarUrl!,
      imageBuilder: (context, imageProvider) => CircleAvatar(
        radius: 22,
        backgroundColor: Colors.transparent,
        backgroundImage: imageProvider,
      ),
      placeholder: (context, url) => CircleAvatar(
        radius: 22,
        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
        child: Text(
          fallbackText,
          style: TextStyle(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      errorWidget: (context, url, error) => CircleAvatar(
        radius: 22,
        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
        child: Text(
          fallbackText,
          style: TextStyle(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _TimelineSegmentRow extends StatelessWidget {
  final _TimelineSegment segment;
  final double daySpacing;
  final bool alignLeft;
  final bool isFirst;
  final bool isLast;

  const _TimelineSegmentRow({
    required this.segment,
    required this.daySpacing,
    required this.alignLeft,
    required this.isFirst,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final minHeight = 80.0;
    final height = segment.durationDays * daySpacing;
    final resolvedHeight = height < minHeight ? minHeight : height;
    final friendChip = _TimelineFriendChip(
      event: _TimelineEvent(
        username: segment.username,
        displayName: segment.displayName,
      ),
      avatarUrl: context.read<AppState>().getAvatarUrl(segment.username),
      textAlign: alignLeft ? TextAlign.right : TextAlign.left,
    );

    return SizedBox(
      height: resolvedHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: alignLeft
                ? Align(
                    alignment: Alignment.centerRight,
                    child: friendChip,
                  )
                : const SizedBox.shrink(),
          ),
          SizedBox(
            width: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.center,
                    child: Container(
                      width: 2,
                      margin: EdgeInsets.only(
                        top: isFirst ? resolvedHeight / 2 : 0,
                        bottom: isLast ? resolvedHeight / 2 : 0,
                      ),
                      color: theme.colorScheme.primary.withValues(alpha: 0.3),
                    ),
                  ),
                ),
                Positioned(
                  left: alignLeft ? 14 : 96,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 6,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
                Positioned(
                  top: 6,
                  child: _AxisLabel(
                    label: _formatDate(segment.start),
                  ),
                ),
                Positioned(
                  bottom: 6,
                  child: _AxisLabel(
                    label: _formatDate(segment.end),
                  ),
                ),
                Positioned(
                  top: 0,
                  child: _AxisDot(color: theme.colorScheme.primary),
                ),
                Positioned(
                  bottom: 0,
                  child: _AxisDot(color: theme.colorScheme.primary),
                ),
              ],
            ),
          ),
          Expanded(
            child: alignLeft
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.centerLeft,
                    child: friendChip,
                  ),
          ),
        ],
      ),
    );
  }
}

class _TimelineFriendChip extends StatelessWidget {
  final _TimelineEvent event;
  final String? avatarUrl;
  final TextAlign textAlign;

  const _TimelineFriendChip({
    required this.event,
    required this.avatarUrl,
    required this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallbackText = StringUtils.getFirstChar(
      event.displayName,
      defaultChar: '聊',
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Avatar(avatarUrl: avatarUrl, fallbackText: fallbackText),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              StringUtils.cleanOrDefault(event.displayName, event.username),
              textAlign: textAlign,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime dateTime) {
  return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
}

class _TimelineSegment {
  final String username;
  final String displayName;
  final DateTime start;
  final DateTime end;

  _TimelineSegment({
    required this.username,
    required this.displayName,
    required this.start,
    required this.end,
  });

  int get durationDays => end.difference(start).inDays + 1;
}

class _AxisDot extends StatelessWidget {
  final Color color;

  const _AxisDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 6,
          ),
        ],
      ),
    );
  }
}

class _AxisLabel extends StatelessWidget {
  final String label;

  const _AxisLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
