import 'package:flutter/material.dart';
import '../services/dual_report_service.dart';

/// 好友选择页面（用于双人报告）
class FriendSelectorPage extends StatefulWidget {
  final DualReportService dualReportService;
  final int? year;

  const FriendSelectorPage({
    super.key,
    required this.dualReportService,
    required this.year,
  });

  @override
  State<FriendSelectorPage> createState() => _FriendSelectorPageState();
}

class _FriendSelectorPageState extends State<FriendSelectorPage> {
  List<Map<String, dynamic>> _friends = [];
  List<Map<String, dynamic>> _filteredFriends = [];
  bool _isLoading = true;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFriends() async {
    setState(() => _isLoading = true);

    try {
      final friends = await widget.dualReportService.getRecommendedFriends(
        limit: 50,
        filterYear: widget.year,
      );

      if (mounted) {
        setState(() {
          _friends = friends;
          _filteredFriends = friends;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载好友列表失败: $e')));
      }
    }
  }

  void _filterFriends(String query) {
    setState(() {
      _searchQuery = query;
      if (query.isEmpty) {
        _filteredFriends = _friends;
      } else {
        _filteredFriends = _friends.where((friend) {
          final displayName = friend['displayName'] as String;
          return displayName.toLowerCase().contains(query.toLowerCase());
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '选择好友 - ${widget.year != null ? '${widget.year}年' : '历史以来'}',
        ),
      ),
      body: Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索好友...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _filterFriends('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: _filterFriends,
            ),
          ),

          // 好友列表
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredFriends.isEmpty
                ? Center(
                    child: Text(
                      _searchQuery.isEmpty ? '暂无好友数据' : '未找到匹配的好友',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: _filteredFriends.length,
                    itemBuilder: (context, index) {
                      final friend = _filteredFriends[index];
                      return _buildFriendItem(friend, index + 1);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFriendItem(Map<String, dynamic> friend, int rank) {
    final displayName = friend['displayName'] as String;
    final messageCount = friend['messageCount'] as int;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _getRankColor(rank),
          child: Text(
            '$rank',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          displayName,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '$messageCount 条消息',
          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: () {
          // 返回选中的好友
          Navigator.pop(context, friend);
        },
      ),
    );
  }

  Color _getRankColor(int rank) {
    if (rank == 1) return const Color(0xFFFFD700); // 金色
    if (rank == 2) return const Color(0xFFC0C0C0); // 银色
    if (rank == 3) return const Color(0xFFCD7F32); // 铜色
    if (rank <= 10) return const Color(0xFF07C160); // 绿色
    return Colors.grey;
  }
}
