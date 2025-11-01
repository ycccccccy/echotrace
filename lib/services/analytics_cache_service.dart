import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/advanced_analytics_data.dart';
import '../models/analytics_data.dart';

/// 分析结果缓存服务（使用 SharedPreferences）
class AnalyticsCacheService {
  static AnalyticsCacheService? _instance;
  static const String _keyBasicAnalytics = 'cache_basic_analytics';
  static const String _keyAnnualReport = 'cache_annual_report';
  static const String _keyCachedAt = 'cache_timestamp';
  static const String _keyDbModifiedTime = 'cache_db_modified_time';

  static AnalyticsCacheService get instance {
    _instance ??= AnalyticsCacheService._();
    return _instance!;
  }

  AnalyticsCacheService._();

  /// 保存基础分析结果
  Future<void> saveBasicAnalytics({
    required ChatStatistics? overallStats,
    required List<ContactRanking>? contactRankings,
    required int dbModifiedTime,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = serializeBasicResults(
        overallStats: overallStats,
        contactRankings: contactRankings,
      );
      await prefs.setString(_keyBasicAnalytics, json.encode(data));
      await prefs.setString(_keyCachedAt, DateTime.now().toIso8601String());
      await prefs.setInt(_keyDbModifiedTime, dbModifiedTime);
    } catch (e) {}
  }

  /// 读取基础分析结果
  Future<Map<String, dynamic>?> loadBasicAnalytics() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dataString = prefs.getString(_keyBasicAnalytics);
      if (dataString == null) return null;

      final data = json.decode(dataString);
      return deserializeBasicResults(data);
    } catch (e) {
      return null;
    }
  }

  /// 保存年度报告结果
  Future<void> saveAnnualReport({
    required ActivityHeatmap? activityHeatmap,
    required LinguisticStyle? linguisticStyle,
    required Map<String, dynamic>? hahaReport,
    required Map<String, dynamic>? midnightKing,
    required int dbModifiedTime,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = serializeResults(
        activityHeatmap: activityHeatmap,
        linguisticStyle: linguisticStyle,
        hahaReport: hahaReport,
        midnightKing: midnightKing,
      );
      await prefs.setString(_keyAnnualReport, json.encode(data));
      await prefs.setString(_keyCachedAt, DateTime.now().toIso8601String());
      await prefs.setInt(_keyDbModifiedTime, dbModifiedTime);
    } catch (e) {}
  }

  /// 读取年度报告结果
  Future<Map<String, dynamic>?> loadAnnualReport() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dataString = prefs.getString(_keyAnnualReport);
      if (dataString == null) return null;

      final data = json.decode(dataString);
      return deserializeResults(data);
    } catch (e) {
      return null;
    }
  }

  /// 清除所有缓存
  Future<void> clearAllCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyBasicAnalytics);
      await prefs.remove(_keyAnnualReport);
      await prefs.remove(_keyCachedAt);
    } catch (e) {}
  }

  /// 清除基础分析缓存
  Future<void> clearBasicCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyBasicAnalytics);
    } catch (e) {}
  }

  /// 清除年度报告缓存
  Future<void> clearAnnualReportCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyAnnualReport);
    } catch (e) {}
  }

  /// 检查数据库是否发生变化
  Future<bool> isDatabaseChanged(int currentDbModifiedTime) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedTime = prefs.getInt(_keyDbModifiedTime);

      if (cachedTime == null) return true; // 没有缓存，认为已变化

      return cachedTime != currentDbModifiedTime;
    } catch (e) {
      return true; // 出错时认为已变化
    }
  }

  /// 获取缓存信息
  Future<Map<String, dynamic>?> getCacheInfo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasBasic = prefs.containsKey(_keyBasicAnalytics);
      final hasReport = prefs.containsKey(_keyAnnualReport);
      final cachedAtString = prefs.getString(_keyCachedAt);

      if (!hasBasic && !hasReport) return null;

      DateTime? cachedAt;
      if (cachedAtString != null) {
        cachedAt = DateTime.parse(cachedAtString);
      }

      return {
        'hasBasicAnalytics': hasBasic,
        'hasAnnualReport': hasReport,
        'cachedAt': cachedAtString,
        'age': cachedAt != null
            ? DateTime.now().difference(cachedAt).inMinutes
            : null,
      };
    } catch (e) {
      return null;
    }
  }

  /// 序列化年度报告结果
  static Map<String, dynamic> serializeResults({
    required ActivityHeatmap? activityHeatmap,
    required LinguisticStyle? linguisticStyle,
    required Map<String, dynamic>? hahaReport,
    required Map<String, dynamic>? midnightKing,
  }) {
    return {
      'activityHeatmap': activityHeatmap?.toJson(),
      'linguisticStyle': linguisticStyle?.toJson(),
      'hahaReport': hahaReport,
      'midnightKing': midnightKing,
    };
  }

  /// 反序列化年度报告结果
  static Map<String, dynamic> deserializeResults(Map<String, dynamic> data) {
    return {
      'activityHeatmap': data['activityHeatmap'] != null
          ? ActivityHeatmap.fromJson(data['activityHeatmap'])
          : null,
      'linguisticStyle': data['linguisticStyle'] != null
          ? LinguisticStyle.fromJson(data['linguisticStyle'])
          : null,
      'hahaReport': data['hahaReport'],
      'midnightKing': data['midnightKing'],
    };
  }

  /// 序列化基础分析结果
  static Map<String, dynamic> serializeBasicResults({
    required ChatStatistics? overallStats,
    required List<ContactRanking>? contactRankings,
  }) {
    return {
      'overallStats': overallStats?.toJson(),
      'contactRankings': contactRankings?.map((r) => r.toJson()).toList(),
    };
  }

  /// 反序列化基础分析结果
  static Map<String, dynamic> deserializeBasicResults(
    Map<String, dynamic> data,
  ) {
    return {
      'overallStats': data['overallStats'] != null
          ? ChatStatistics.fromJson(data['overallStats'])
          : null,
      'contactRankings': data['contactRankings'] != null
          ? (data['contactRankings'] as List)
                .map((r) => ContactRanking.fromJson(r))
                .toList()
          : null,
    };
  }
}
