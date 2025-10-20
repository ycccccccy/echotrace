import 'package:shared_preferences/shared_preferences.dart';

/// 配置服务 - 用于持久化存储应用配置
class ConfigService {
  static const String _keyDecryptKey = 'decrypt_key';
  static const String _keyDatabasePath = 'database_path';
  static const String _keyIsConfigured = 'is_configured';
  static const String _keyDatabaseMode = 'database_mode'; // 'realtime' 或 'backup'

  /// 保存解密密钥
  Future<void> saveDecryptKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDecryptKey, key);
  }

  /// 获取解密密钥
  Future<String?> getDecryptKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDecryptKey);
  }

  /// 保存数据库路径
  Future<void> saveDatabasePath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDatabasePath, path);
  }

  /// 获取数据库路径
  Future<String?> getDatabasePath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDatabasePath);
  }

  /// 设置配置状态
  Future<void> setConfigured(bool configured) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyIsConfigured, configured);
  }

  /// 获取配置状态
  Future<bool> isConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyIsConfigured) ?? false;
  }

  /// 保存数据库模式
  Future<void> saveDatabaseMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDatabaseMode, mode);
  }

  /// 获取数据库模式（默认为备份模式）
  Future<String> getDatabaseMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDatabaseMode) ?? 'backup';
  }

  /// 清除所有配置
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyDecryptKey);
    await prefs.remove(_keyDatabasePath);
    await prefs.remove(_keyIsConfigured);
    await prefs.remove(_keyDatabaseMode);
  }
}
