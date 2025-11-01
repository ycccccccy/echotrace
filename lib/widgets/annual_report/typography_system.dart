import 'package:flutter/material.dart';

/// 响应式文字大小计算
class ResponsiveTextSizes {
  final double screenHeight;
  final double screenWidth;

  ResponsiveTextSizes({required this.screenHeight, required this.screenWidth});

  /// 1. 页面主标题 - 最大且最突出
  /// 用于：页面大标题、年份显示等
  double get mainTitleSize => screenHeight > 700 ? 48.0 : 40.0;

  /// 2. 页面副标题/强调标题
  /// 用于：页面说明、数据标题等
  double get subTitleSize => screenHeight > 700 ? 36.0 : 32.0;

  /// 3. 卡片标题
  /// 用于：各个卡片中的标题
  double get cardTitleSize => screenHeight > 700 ? 28.0 : 24.0;

  /// 4. 数字显示 - 大号数字
  /// 用于：关键数据的主数字
  double get largeNumberSize => screenHeight > 700 ? 78.0 : 66.0;

  /// 5. 数字显示 - 中等数字
  /// 用于：次要数据的数字
  double get mediumNumberSize => screenHeight > 700 ? 52.0 : 46.0;

  /// 6. 数字显示 - 小号数字
  /// 用于：列表中的数字
  double get smallNumberSize => screenHeight > 700 ? 32.0 : 28.0;

  /// 7. 正文文字 - 大号
  /// 用于：主要描述文字
  double get bodyLargeSize => screenHeight > 700 ? 22.0 : 20.0;

  /// 8. 正文文字 - 标准
  /// 用于：常规描述、列表项等
  double get bodySize => screenHeight > 700 ? 18.0 : 16.0;

  /// 9. 正文文字 - 小号
  /// 用于：辅助说明文字
  double get bodySmallSize => screenHeight > 700 ? 14.0 : 13.0;

  /// 10. 标签文字 - 最小
  /// 用于：说明标签、时间戳等
  double get labelSize => screenHeight > 700 ? 12.0 : 11.0;
}

/// 统一的排版系统 - 确保年度报告文字整齐统一
/// 包含主标题、副标题、数字、正文等多个层级
class AnnualReportTypography {
  /// 预定义的文字样式集合
  static TextStyle mainTitle({
    Color color = const Color(0xFF333333),
    FontWeight fontWeight = FontWeight.bold,
    double letterSpacing = 2,
  }) {
    return TextStyle(
      fontSize: 48, // 在 LayoutBuilder 中动态调整
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.2,
    );
  }

  static TextStyle subTitle({
    Color color = const Color(0xFF666666),
    FontWeight fontWeight = FontWeight.w600,
    double letterSpacing = 1,
  }) {
    return TextStyle(
      fontSize: 36,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.2,
    );
  }

  static TextStyle cardTitle({
    Color color = const Color(0xFF333333),
    FontWeight fontWeight = FontWeight.w600,
  }) {
    return TextStyle(
      fontSize: 28,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.3,
      letterSpacing: 0.5,
    );
  }

  static TextStyle largeNumber({
    Color color = const Color(0xFF07C160),
    FontWeight fontWeight = FontWeight.bold,
  }) {
    return TextStyle(
      fontSize: 78,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.0,
    );
  }

  static TextStyle mediumNumber({
    Color color = const Color(0xFF333333),
    FontWeight fontWeight = FontWeight.bold,
  }) {
    return TextStyle(
      fontSize: 52,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.0,
    );
  }

  static TextStyle smallNumber({
    Color color = const Color(0xFF333333),
    FontWeight fontWeight = FontWeight.w600,
  }) {
    return TextStyle(
      fontSize: 32,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.2,
    );
  }

  static TextStyle bodyLarge({
    Color color = const Color(0xFF333333),
    FontWeight fontWeight = FontWeight.w500,
  }) {
    return TextStyle(
      fontSize: 22,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.4,
    );
  }

  static TextStyle body({
    Color color = const Color(0xFF666666),
    FontWeight fontWeight = FontWeight.normal,
  }) {
    return TextStyle(
      fontSize: 18,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.5,
    );
  }

  static TextStyle bodySmall({
    Color color = const Color(0xFF999999),
    FontWeight fontWeight = FontWeight.normal,
  }) {
    return TextStyle(
      fontSize: 14,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.4,
    );
  }

  static TextStyle label({
    Color color = const Color(0xFFBBBBBB),
    FontWeight fontWeight = FontWeight.normal,
  }) {
    return TextStyle(
      fontSize: 12,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.3,
    );
  }

  /// 辅助方法：根据响应式尺寸获取对应的文字样式
  static TextStyle getDynamicMainTitle(
    ResponsiveTextSizes sizes, {
    Color color = const Color(0xFF333333),
    FontWeight fontWeight = FontWeight.bold,
  }) {
    return TextStyle(
      fontSize: sizes.mainTitleSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: 2,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.2,
    );
  }

  static TextStyle getDynamicSubTitle(
    ResponsiveTextSizes sizes, {
    Color color = const Color(0xFF666666),
    FontWeight fontWeight = FontWeight.w600,
  }) {
    return TextStyle(
      fontSize: sizes.subTitleSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: 1,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.2,
    );
  }

  static TextStyle getDynamicCardTitle(
    ResponsiveTextSizes sizes, {
    Color color = const Color(0xFF333333),
    FontWeight fontWeight = FontWeight.w600,
  }) {
    return TextStyle(
      fontSize: sizes.cardTitleSize,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.3,
      letterSpacing: 0.5,
    );
  }

  static TextStyle getDynamicLargeNumber(
    ResponsiveTextSizes sizes, {
    Color color = const Color(0xFF07C160),
    FontWeight fontWeight = FontWeight.bold,
  }) {
    return TextStyle(
      fontSize: sizes.largeNumberSize,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.0,
    );
  }

  static TextStyle getDynamicMediumNumber(
    ResponsiveTextSizes sizes, {
    Color color = const Color(0xFF333333),
    FontWeight fontWeight = FontWeight.bold,
  }) {
    return TextStyle(
      fontSize: sizes.mediumNumberSize,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.0,
    );
  }

  static TextStyle getDynamicSmallNumber(
    ResponsiveTextSizes sizes, {
    Color color = const Color(0xFF333333),
    FontWeight fontWeight = FontWeight.w600,
  }) {
    return TextStyle(
      fontSize: sizes.smallNumberSize,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.2,
    );
  }

  static TextStyle getDynamicBodyLarge(
    ResponsiveTextSizes sizes, {
    Color color = const Color(0xFF333333),
    FontWeight fontWeight = FontWeight.w500,
  }) {
    return TextStyle(
      fontSize: sizes.bodyLargeSize,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.4,
    );
  }

  static TextStyle getDynamicBody(
    ResponsiveTextSizes sizes, {
    Color color = const Color(0xFF666666),
    FontWeight fontWeight = FontWeight.normal,
  }) {
    return TextStyle(
      fontSize: sizes.bodySize,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.5,
    );
  }

  static TextStyle getDynamicBodySmall(
    ResponsiveTextSizes sizes, {
    Color color = const Color(0xFF999999),
    FontWeight fontWeight = FontWeight.normal,
  }) {
    return TextStyle(
      fontSize: sizes.bodySmallSize,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.4,
    );
  }

  static TextStyle getDynamicLabel(
    ResponsiveTextSizes sizes, {
    Color color = const Color(0xFFBBBBBB),
    FontWeight fontWeight = FontWeight.normal,
  }) {
    return TextStyle(
      fontSize: sizes.labelSize,
      fontWeight: fontWeight,
      color: color,
      fontFamily: 'HarmonyOS Sans SC',
      height: 1.3,
    );
  }
}

/// 排版间距参考
class TypographySpacing {
  /// 标题和副标题之间
  static const titleToSubtitle = 12.0;

  /// 副标题和内容之间
  static const subtitleToContent = 24.0;

  /// 内容块之间
  static const contentGap = 32.0;

  /// 数据项之间
  static const dataItemGap = 16.0;

  /// 卡片内部边距
  static const cardPadding = 16.0;

  /// 页面边距
  static const pageHorizontalPadding = 24.0;
  static const pageVerticalPadding = 32.0;
}
