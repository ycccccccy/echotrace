// 主界面布局：侧边栏 + 动画切换内容区，按 AppState.currentPage 渲染各业务页面
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
import 'group_chat_analysis_page.dart';

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
                child: Container(
                  color: Theme.of(context).scaffoldBackgroundColor,
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
                      } else if (appState.currentPage ==
                          'group_chat_analysis') {
                        currentPage = const GroupChatAnalysisPage();
                      } else {
                        currentPage = const WelcomePage();
                      }

                      // 使用动画切换器实现平滑的页面过渡效果
                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        child: KeyedSubtree(
                          key: ValueKey<String>(appState.currentPage),
                          child: currentPage,
                        ),
                      );
                    },
                  ),
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
