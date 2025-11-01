import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 年度报告缓存服务
class AnnualReportCacheService {
  static const String _keyPrefix = 'annual_report_';
  static const String _allKey = 'annual_report_all';
  static const String _cachedYearsKey = 'cached_report_years';

  /// 保存报告
  static Future<void> saveReport(int? year, Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final key = year == null ? _allKey : '$_keyPrefix$year';

    // 添加生成时间戳
    data['generatedAt'] = DateTime.now().toIso8601String();
    data['year'] = year;

    // 保存报告数据
    await prefs.setString(key, jsonEncode(data));

    // 更新已缓存年份列表
    final cachedYears = await getAllCachedYears();
    if (year != null && !cachedYears.contains(year)) {
      cachedYears.add(year);
      await prefs.setStringList(
        _cachedYearsKey,
        cachedYears.map((y) => y.toString()).toList(),
      );
    } else if (year == null && !cachedYears.contains(-1)) {
      cachedYears.add(-1); // -1 表示"历史以来"
      await prefs.setStringList(
        _cachedYearsKey,
        cachedYears.map((y) => y.toString()).toList(),
      );
    }
  }

  /// 加载报告
  static Future<Map<String, dynamic>?> loadReport(int? year) async {
    final prefs = await SharedPreferences.getInstance();
    final key = year == null ? _allKey : '$_keyPrefix$year';

    final jsonStr = prefs.getString(key);
    if (jsonStr == null) return null;

    try {
      return jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// 检查是否已缓存
  static Future<bool> hasReport(int? year) async {
    final prefs = await SharedPreferences.getInstance();
    final key = year == null ? _allKey : '$_keyPrefix$year';
    return prefs.containsKey(key);
  }

  /// 清除特定报告
  static Future<void> clearReport(int? year) async {
    final prefs = await SharedPreferences.getInstance();
    final key = year == null ? _allKey : '$_keyPrefix$year';
    await prefs.remove(key);

    // 从已缓存年份列表中移除
    final cachedYears = await getAllCachedYears();
    final yearToRemove = year ?? -1;
    cachedYears.remove(yearToRemove);
    await prefs.setStringList(
      _cachedYearsKey,
      cachedYears.map((y) => y.toString()).toList(),
    );
  }

  /// 获取所有已缓存的年份
  static Future<List<int>> getAllCachedYears() async {
    final prefs = await SharedPreferences.getInstance();
    final yearStrings = prefs.getStringList(_cachedYearsKey) ?? [];
    return yearStrings.map((s) => int.parse(s)).toList();
  }

  /// 清除所有报告缓存
  static Future<void> clearAllReports() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedYears = await getAllCachedYears();

    for (final year in cachedYears) {
      final key = year == -1 ? _allKey : '$_keyPrefix$year';
      await prefs.remove(key);
    }

    await prefs.remove(_cachedYearsKey);
  }

  /// 获取报告生成时间
  static Future<DateTime?> getReportGeneratedTime(int? year) async {
    final report = await loadReport(year);
    if (report == null) return null;

    final timestamp = report['generatedAt'] as String?;
    if (timestamp == null) return null;

    try {
      return DateTime.parse(timestamp);
    } catch (e) {
      return null;
    }
  }
}
