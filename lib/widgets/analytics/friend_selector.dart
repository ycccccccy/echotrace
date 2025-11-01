import 'package:flutter/material.dart';
import '../../models/chat_session.dart';

/// 好友选择器（横向滑动卡片）
class FriendSelector extends StatelessWidget {
  final List<ChatSession> friends;
  final String? selectedFriend;
  final Function(String) onFriendSelected;

  const FriendSelector({
    super.key,
    required this.friends,
    required this.selectedFriend,
    required this.onFriendSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        itemCount: friends.length,
        itemBuilder: (context, index) {
          final friend = friends[index];
          final isSelected = friend.username == selectedFriend;

          return Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _FriendCard(
              displayName: friend.displayName ?? friend.username,
              username: friend.username,
              isSelected: isSelected,
              onTap: () => onFriendSelected(friend.username),
            ),
          );
        },
      ),
    );
  }
}

class _FriendCard extends StatefulWidget {
  final String displayName;
  final String username;
  final bool isSelected;
  final VoidCallback onTap;

  const _FriendCard({
    required this.displayName,
    required this.username,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_FriendCard> createState() => _FriendCardState();
}

class _FriendCardState extends State<_FriendCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 100,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: widget.isSelected
                ? LinearGradient(
                    colors: [
                      Theme.of(context).colorScheme.primary,
                      Theme.of(context).colorScheme.secondary,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            color: widget.isSelected ? null : const Color(0xFF16213e),
            border: Border.all(
              color: _isHovered
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
            boxShadow: [
              if (widget.isSelected || _isHovered)
                BoxShadow(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: widget.isSelected
                      ? Colors.white.withOpacity(0.2)
                      : Theme.of(context).colorScheme.primary.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(Icons.person, color: Colors.white, size: 28),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  widget.displayName,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white,
                    fontWeight: widget.isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
