// 应用入口：处理 CLI 导出参数，创建全局 AppState 并启动 UI
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'cli/cli_export_runner.dart';
import 'providers/app_state.dart';
import 'pages/home_page.dart';
import 'services/config_service.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(ConfigService().markLaunchCrashed());
  };

  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    unawaited(ConfigService().markLaunchCrashed());
    return false;
  };

  final cliRunner = CliExportRunner();
  final cliExitCode = await cliRunner.tryHandle(args);
  if (cliExitCode != null) {
    exit(cliExitCode);
  }

  runApp(const EchoTraceApp());
}

class EchoTraceApp extends StatelessWidget {
  const EchoTraceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) {
        final appState = AppState();
        // 异步初始化，避免阻塞界面渲染
        appState.initialize();
        return appState;
      },
      child: MaterialApp(
        title: 'EchoTrace - 微信数据库查看器',
        debugShowCheckedModeBanner: false,
        theme: _buildLightTheme(),
        themeMode: ThemeMode.light,
        home: const HomePage(),
      ),
    );
  }

  /// 构建浅色主题
  ThemeData _buildLightTheme() {
    const wechatGreen = Color(0xFF07C160);
    const backgroundColor = Color(0xFFFAFAFA); // 更干净的浅灰背景
    const surfaceColor = Colors.white;
    const primaryTextColor = Color(0xFF1A1A1A);
    const secondaryTextColor = Color(0xFF757575);

    return ThemeData(
      useMaterial3: true,
      fontFamily: 'HarmonyOS Sans SC',
      colorScheme: ColorScheme.fromSeed(
        seedColor: wechatGreen,
        brightness: Brightness.light,
        primary: wechatGreen,
        secondary: wechatGreen,
        surface: surfaceColor,
        onSurface: primaryTextColor,
        surfaceContainerLow: Colors.white,
        outline: Colors.grey.withValues(alpha: 0.2),
      ),
      scaffoldBackgroundColor: backgroundColor,

      // 文本主题
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontFamily: 'HarmonyOS Sans SC',
          color: primaryTextColor,
          fontWeight: FontWeight.bold,
          letterSpacing: -1.0,
        ),
        titleLarge: TextStyle(
          fontFamily: 'HarmonyOS Sans SC',
          color: primaryTextColor,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.5,
        ),
        bodyLarge: TextStyle(
          fontFamily: 'HarmonyOS Sans SC',
          color: primaryTextColor,
          height: 1.5,
        ),
        bodyMedium: TextStyle(
          fontFamily: 'HarmonyOS Sans SC',
          color: secondaryTextColor,
          height: 1.5,
        ),
      ),

      // 卡片主题
      cardTheme: CardThemeData(
        elevation: 0,
        color: surfaceColor,
        shadowColor: Colors.black.withValues(alpha: 0.04), // 更柔和的阴影
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16), // 更大的圆角
        ),
      ),

      // 按钮主题
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: wechatGreen,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontFamily: 'HarmonyOS Sans SC',
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: wechatGreen,
          side: const BorderSide(color: wechatGreen),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontFamily: 'HarmonyOS Sans SC',
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      ),

      // 输入框主题
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: wechatGreen, width: 2),
        ),
        hintStyle: TextStyle(color: Colors.grey.withValues(alpha: 0.6)),
      ),

      // 分割线
      dividerTheme: DividerThemeData(
        color: Colors.grey.withValues(alpha: 0.1),
        thickness: 1,
        space: 1,
      ),

      // 图标主题
      iconTheme: IconThemeData(
        color: primaryTextColor.withValues(alpha: 0.8),
        size: 24,
      ),
    );
  }
}
