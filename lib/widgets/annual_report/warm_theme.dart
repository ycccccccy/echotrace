import 'package:flutter/material.dart';

/// 主题配色
class WarmTheme {
  // 主色调 - 温暖的绿色系
  static const Color primaryGreen = Color(0xFF07C160);
  static const Color primaryGreenLight = Color(0xFF4DD080);
  static const Color primaryGreenLighter = Color(0xFF7FE0A0);

  // 辅助色 - 温暖的橙色系
  static const Color warmOrange = Color(0xFFFF9800);
  static const Color warmOrangeLight = Color(0xFFFFB74D);
  static const Color warmOrangeLighter = Color(0xFFFFCC80);

  // 辅助色 - 温暖的粉色系
  static const Color warmPink = Color(0xFFE91E63);
  static const Color warmPinkLight = Color(0xFFF06292);
  static const Color warmPinkLighter = Color(0xFFF8BBD0);

  // 辅助色 - 温暖的蓝色系
  static const Color warmBlue = Color(0xFF2196F3);
  static const Color warmBlueLight = Color(0xFF64B5F6);
  static const Color warmBlueLighter = Color(0xFF90CAF9);

  // 背景色 - 温暖的白到渐变
  static const Color backgroundWhite = Color(0xFFFFFBF7); // 略带暖色的白
  static const Color backgroundWarm = Color(0xFFFFF8F0); // 更暖的白

  // 文字颜色
  static const Color textPrimary = Color(0xFF333333);
  static const Color textSecondary = Color(0xFF666666);
  static const Color textTertiary = Color(0xFF999999);

  // 页面渐变背景配置
  static List<Gradient> getPageGradients() {
    return [
      // 封面页 - 温暖的绿色渐变
      const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFFFBF7), Color(0xFFF0FFF4), Color(0xFFE8F5E9)],
      ),
      // 开场页 - 温暖的白到淡绿
      const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFFFBF7), Color(0xFFF5FFF8)],
      ),
      // 年度挚友 - 温暖的绿到白
      const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFE8F5E9), Color(0xFFFFFBF7)],
      ),
      // 双向奔赴 - 温暖的蓝绿渐变
      const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFE0F2F1), Color(0xFFF5FFF8)],
      ),
      // 主动社交 - 温暖的橙到白
      const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFFF3E0), Color(0xFFFFFBF7)],
      ),
      // 聊天巅峰日 - 温暖的粉到白
      const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFCE4EC), Color(0xFFFFFBF7)],
      ),
      // 连续打卡 - 温暖的黄到白
      const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFFF9E6), Color(0xFFFFFBF7)],
      ),
      // 作息图谱 - 温暖的蓝到白
      const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFE3F2FD), Color(0xFFFFFBF7)],
      ),
      // 深夜密友 - 温暖的紫到白
      const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFF3E5F5), Color(0xFFFFFBF7)],
      ),
      // 响应速度 - 温暖的青到白
      const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFE0F7FA), Color(0xFFFFFBF7)],
      ),
      // 曾经的好朋友 - 温暖的橙粉渐变
      const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFFF3E0), Color(0xFFFCE4EC)],
      ),
      // 结束页 - 温暖的白到淡绿
      const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFFFBF7), Color(0xFFF0FFF4)],
      ),
    ];
  }

  /// 获取柔和的阴影效果
  static List<BoxShadow> getSoftShadow({
    Color? color,
    double blurRadius = 20,
    double spreadRadius = 0,
    Offset offset = const Offset(0, 4),
  }) {
    return [
      BoxShadow(
        color: (color ?? Colors.black).withOpacity(0.08),
        blurRadius: blurRadius,
        spreadRadius: spreadRadius,
        offset: offset,
      ),
      BoxShadow(
        color: (color ?? Colors.black).withOpacity(0.04),
        blurRadius: blurRadius * 0.5,
        spreadRadius: spreadRadius,
        offset: Offset(offset.dx * 0.5, offset.dy * 0.5),
      ),
    ];
  }

  /// 获取卡片样式
  static BoxDecoration getCardDecoration({
    Color? backgroundColor,
    List<BoxShadow>? shadows,
  }) {
    return BoxDecoration(
      color: backgroundColor ?? Colors.white,
      borderRadius: BorderRadius.circular(24),
      boxShadow: shadows ?? getSoftShadow(),
    );
  }

  /// 获取温暖的文字样式
  static TextStyle getWarmTextStyle({
    double fontSize = 16,
    FontWeight fontWeight = FontWeight.normal,
    Color? color,
  }) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color ?? textPrimary,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.6,
      letterSpacing: 0.5,
    );
  }

  /// 获取标题样式
  static TextStyle getTitleStyle({double fontSize = 32, Color? color}) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      color: color ?? primaryGreen,
      fontFamily: 'HarmonyOS Sans SC',
      letterSpacing: 1.5,
      height: 1.4,
    );
  }

  /// 获取副标题样式
  static TextStyle getSubtitleStyle({double fontSize = 16, Color? color}) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w400,
      color: color ?? textSecondary,
      fontFamily: 'HarmonyOS Sans SC',
      letterSpacing: 0.8,
      height: 1.6,
    );
  }
}
