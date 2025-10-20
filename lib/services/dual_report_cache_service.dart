import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 双人报告缓存服务
class DualReportCacheService {
  static const String _keyPrefix = 'dual_report_';
  static const Duration _cacheValidity = Duration(days: 7);

  /// 生成缓存键
  static String _getCacheKey(String friendUsername, int? year) {
    final yearStr = year?.toString() ?? 'all';
    return '$_keyPrefix${friendUsername}_$yearStr';
  }

  /// 保存双人报告到缓存
  static Future<void> saveReport(
    String friendUsername,
    int? year,
    Map<String, dynamic> reportData,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getCacheKey(friendUsername, year);
      
      // 添加缓存时间戳
      final cacheData = {
        ...reportData,
        '_cachedAt': DateTime.now().toIso8601String(),
      };
      
      final jsonString = jsonEncode(cacheData);
      await prefs.setString(key, jsonString);
      
    } catch (e) {
    }
  }

  /// 从缓存加载双人报告
  static Future<Map<String, dynamic>?> loadReport(
    String friendUsername,
    int? year,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getCacheKey(friendUsername, year);
      final jsonString = prefs.getString(key);
      
      if (jsonString == null) {
        return null;
      }
      
      final data = jsonDecode(jsonString) as Map<String, dynamic>;
      
      // 检查缓存是否过期
      final cachedAtStr = data['_cachedAt'] as String?;
      if (cachedAtStr != null) {
        final cachedAt = DateTime.parse(cachedAtStr);
        final age = DateTime.now().difference(cachedAt);
        
        if (age > _cacheValidity) {
          await clearReport(friendUsername, year);
          return null;
        }
      }
      
      return data;
    } catch (e) {
      return null;
    }
  }

  /// 检查是否有缓存
  static Future<bool> hasReport(String friendUsername, int? year) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getCacheKey(friendUsername, year);
      return prefs.containsKey(key);
    } catch (e) {
      return false;
    }
  }

  /// 清除特定双人报告缓存
  static Future<void> clearReport(String friendUsername, int? year) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getCacheKey(friendUsername, year);
      await prefs.remove(key);
    } catch (e) {
    }
  }

  /// 清除所有双人报告缓存
  static Future<void> clearAllReports() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_keyPrefix)).toList();
      
      for (final key in keys) {
        await prefs.remove(key);
      }
      
    } catch (e) {
    }
  }

  /// 获取缓存信息
  static Future<Map<String, dynamic>> getCacheInfo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_keyPrefix)).toList();
      
      return {
        'count': keys.length,
        'keys': keys,
      };
    } catch (e) {
      return {'count': 0, 'keys': []};
    }
  }
}

