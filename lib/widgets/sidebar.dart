import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../providers/app_state.dart';

/// 侧边栏组件（可折叠）
class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> with SingleTickerProviderStateMixin {
  bool _isCollapsed = false;
  late AnimationController _animationController;
  late Animation<double> _widthAnimation;
  bool _showContent = true; // 控制内容显示
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _widthAnimation = Tween<double>(begin: 220.0, end: 72.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    // 监听动画进度，在适当时机切换内容显示
    _animationController.addListener(() {
      if (_animationController.value > 0.3 && _showContent && _isCollapsed) {
        // 收起时，动画进行到30%就隐藏文字
        setState(() {
          _showContent = false;
        });
      } else if (_animationController.value < 0.7 &&
          !_showContent &&
          !_isCollapsed) {
        // 展开时，动画进行到70%（从1到0.7）才显示文字
        setState(() {
          _showContent = true;
        });
      }
    });
  }

  Future<void> _loadVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _version = 'v${packageInfo.version}';
      });
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _toggleSidebar() {
    setState(() {
      _isCollapsed = !_isCollapsed;
      if (_isCollapsed) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _widthAnimation,
      builder: (context, child) {
        return Container(
          width: _widthAnimation.value,
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.03),
                blurRadius: 20,
                offset: const Offset(0, 0),
              ),
            ],
          ),
          child: Column(
            children: [
              const SizedBox(height: 24),

              // 标题（顶部，仅展开时显示）
              if (_showContent) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'EchoTrace',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 22,
                      color: Colors.black87,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ] else ...[
                const SizedBox(height: 8),
              ],

              const Spacer(),

              // 导航按钮
              Consumer<AppState>(
                builder: (context, appState, child) {
                  return Column(
                    children: [
                      _SidebarButton(
                        icon: Icons.chat_bubble_outline,
                        label: '聊天记录',
                        showLabel: _showContent,
                        isSelected: appState.currentPage == 'chat',
                        onTap: () => appState.setCurrentPage('chat'),
                      ),

                      _SidebarButton(
                        icon: Icons.analytics_outlined,
                        label: '数据分析',
                        showLabel: _showContent,
                        isSelected: appState.currentPage == 'analytics',
                        onTap: () => appState.setCurrentPage('analytics'),
                      ),

                      _SidebarButton(
                        icon: Icons.file_download_outlined,
                        label: '导出记录',
                        showLabel: _showContent,
                        isSelected: appState.currentPage == 'export',
                        onTap: () => appState.setCurrentPage('export'),
                      ),

                      _SidebarButton(
                        icon: Icons.folder_outlined,
                        label: '数据管理',
                        showLabel: _showContent,
                        isSelected: appState.currentPage == 'data_management',
                        onTap: () => appState.setCurrentPage('data_management'),
                      ),

                      _SidebarButton(
                        icon: Icons.settings_outlined,
                        label: '设置',
                        showLabel: _showContent,
                        isSelected: appState.currentPage == 'settings',
                        onTap: () => appState.setCurrentPage('settings'),
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 24),

              // 版本信息和折叠按钮
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: _isCollapsed ? 16 : 12,
                  vertical: 16,
                ),
                child: _showContent
                    ? Stack(
                        alignment: Alignment.center,
                        children: [
                          // 折叠按钮在左侧
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: _toggleSidebar,
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  child: Icon(
                                    Icons.chevron_left,
                                    size: 20,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withOpacity(0.6),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 版本号居中
                          Center(
                            child: Text(
                              _version,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withOpacity(0.3),
                                  ),
                            ),
                          ),
                        ],
                      )
                    : Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _toggleSidebar,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            child: Icon(
                              Icons.chevron_right,
                              size: 20,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withOpacity(0.6),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 侧边栏按钮
class _SidebarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool showLabel;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarButton({
    required this.icon,
    required this.label,
    required this.showLabel,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: !showLabel ? label : '',
      preferBelow: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: showLabel ? 16 : 8,
              vertical: 14,
            ),
            margin: EdgeInsets.symmetric(
              horizontal: showLabel ? 12 : 8,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: isSelected
                  ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: showLabel
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.6),
                ),
                if (showLabel) ...[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(
                                context,
                              ).colorScheme.onSurface.withOpacity(0.7),
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
