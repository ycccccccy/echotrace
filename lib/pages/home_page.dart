// 主界面布局：侧边栏 + 动画切换内容区，按 AppState.currentPage 渲染各业务页面
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/config_service.dart';
import '../widgets/sidebar.dart';
import '../widgets/decrypt_progress_overlay.dart';
import '../widgets/privacy_agreement_dialog.dart';
import 'settings_page.dart';
import 'chat_page.dart';
import 'welcome_page.dart';
import 'data_management_page.dart';
import 'analytics_page.dart';
import 'chat_export_page.dart';
import 'group_chat_analysis_page.dart';
import 'chat_timeline_page.dart';

/// 应用主页面，包含侧边栏和内容区域
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _safeModeDialogShown = false;
  bool _privacyCheckCompleted = false;
  bool _privacyCheckInProgress = false;
  bool _privacyDialogActive = false;

  void _maybeShowPrivacyAgreementDialog(BuildContext context) {
    if (_privacyCheckCompleted ||
        _privacyCheckInProgress ||
        _privacyDialogActive) {
      return;
    }

    _privacyCheckInProgress = true;
    ConfigService().isPrivacyAccepted().then((accepted) {
      _privacyCheckInProgress = false;
      if (!mounted) return;
      if (accepted) {
        _privacyCheckCompleted = true;
        setState(() {});
        return;
      }

      _privacyDialogActive = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final result = await showPrivacyAgreementDialog(context);
        if (!mounted) return;
        if (result == true) {
          await ConfigService().setPrivacyAccepted(true);
          _privacyDialogActive = false;
          _privacyCheckCompleted = true;
          setState(() {});
        } else {
          _exitApp();
        }
      });
    });
  }

  void _exitApp() {
    if (Platform.isAndroid || Platform.isIOS) {
      SystemNavigator.pop();
    } else {
      exit(0);
    }
  }

  void _maybeShowSafeModeDialog(BuildContext context, AppState appState) {
    if (!_privacyCheckCompleted || _privacyDialogActive) return;
    if (_safeModeDialogShown || !appState.needsSafeModePrompt) return;
    _safeModeDialogShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('检测到异常退出'),
            content: const Text(
              '上一次启动可能异常中断。是否使用安全模式启动？\n'
              '安全模式将跳过自动连接数据库/解密流程，方便排查问题。',
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await appState.resolveSafeModeChoice(useSafeMode: false);
                },
                child: const Text('正常启动'),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await appState.resolveSafeModeChoice(useSafeMode: true);
                },
                child: const Text('安全模式'),
              ),
            ],
          );
        },
      );
    });
  }

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
                      _maybeShowPrivacyAgreementDialog(context);
                      _maybeShowSafeModeDialog(context, appState);

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
                      } else if (appState.currentPage == 'timeline') {
                        currentPage = ChatTimelinePage(
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
