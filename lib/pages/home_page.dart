import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../widgets/sidebar.dart';
import '../widgets/decrypt_progress_overlay.dart';
import 'settings_page.dart';
import 'chat_page.dart';
import 'welcome_page.dart';
import 'data_management_page.dart';
import 'analytics_page.dart';
import 'chat_export_page.dart';

/// 应用主页面，包含侧边栏和内容区域
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              // 左侧边栏
              const Sidebar(),
              // 右侧内容区域
              Expanded(
                child: Consumer<AppState>(
                  builder: (context, appState, child) {
                    Widget currentPage;

                    // 根据应用状态决定显示哪个页面
                    if (!appState.isConfigured &&
                        appState.currentPage == 'welcome') {
                      currentPage = const WelcomePage();
                    } else if (appState.currentPage == 'settings') {
                      currentPage = const SettingsPage();
                    } else if (appState.currentPage == 'data_management') {
                      currentPage = const DataManagementPage();
                    } else if (appState.currentPage == 'analytics') {
                      currentPage = AnalyticsPage(
                        databaseService: appState.databaseService,
                      );
                    } else if (appState.currentPage == 'export') {
                      currentPage = const ChatExportPage();
                    } else if (appState.isConfigured &&
                        appState.currentPage == 'chat') {
                      currentPage = const ChatPage();
                    } else {
                      currentPage = const WelcomePage();
                    }

                    // 使用动画切换器实现平滑的页面过渡效果
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder:
                          (Widget child, Animation<double> animation) {
                            // 创建淡入淡出结合滑动和缩放的过渡动画
                            return FadeTransition(
                              opacity: Tween<double>(begin: 0.0, end: 1.0)
                                  .animate(
                                    CurvedAnimation(
                                      parent: animation,
                                      curve: const Interval(
                                        0.0,
                                        1.0,
                                        curve: Curves.easeOut,
                                      ),
                                    ),
                                  ),
                              child: SlideTransition(
                                position:
                                    Tween<Offset>(
                                      begin: const Offset(0.02, 0),
                                      end: Offset.zero,
                                    ).animate(
                                      CurvedAnimation(
                                        parent: animation,
                                        curve: const Interval(
                                          0.0,
                                          1.0,
                                          curve: Curves.easeOutCubic,
                                        ),
                                      ),
                                    ),
                                child: ScaleTransition(
                                  scale: Tween<double>(begin: 0.98, end: 1.0)
                                      .animate(
                                        CurvedAnimation(
                                          parent: animation,
                                          curve: const Interval(
                                            0.0,
                                            1.0,
                                            curve: Curves.easeOutCubic,
                                          ),
                                        ),
                                      ),
                                  child: child,
                                ),
                              ),
                            );
                          },
                      child: Container(
                        key: ValueKey<String>(appState.currentPage),
                        child: currentPage,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          // 显示数据库解密进度的覆盖层
          const DecryptProgressOverlay(),
        ],
      ),
    );
  }
}
