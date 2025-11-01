import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 日志级别
enum LogLevel { debug, info, warning, error, fatal }

/// 全局日志记录服务
class LoggerService {
  static final LoggerService _instance = LoggerService._internal();
  factory LoggerService() => _instance;
  LoggerService._internal();

  File? _logFile;
  bool _isInitialized = false;
  bool _isInIsolate = false;
  bool _debugMode = false; // 调试模式标志
  final int _maxLogSize = 5 * 1024 * 1024; // 5MB
  final DateFormat _dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');

  /// 供后台 Isolate 使用的简化模式，禁用文件写入和初始化
  void enableIsolateMode() {
    _isInIsolate = true;
    _isInitialized = true;
    _logFile = null;
  }

  bool get isInIsolateMode => _isInIsolate;

  /// 初始化日志服务
  Future<void> initialize() async {
    if (_isInitialized || _isInIsolate) return;

    try {
      // 加载调试模式配置
      final prefs = await SharedPreferences.getInstance();
      _debugMode = prefs.getBool('debug_mode') ?? false;

      final tempDir = await getTemporaryDirectory().timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          // 在Isolate中可能无法访问平台通道，跳过初始化
          throw TimeoutException('获取临时目录超时（可能在Isolate中）');
        },
      );
      final logDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}echotrace_logs',
      );

      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }

      _logFile = File('${logDir.path}${Platform.pathSeparator}app.log');

      // 检查日志文件大小，如果超过限制则归档
      if (await _logFile!.exists()) {
        final fileSize = await _logFile!.length();
        if (fileSize > _maxLogSize) {
          await _archiveLogFile();
        }
      }

      _isInitialized = true;
      await _writeLog(
        LogLevel.info,
        'LoggerService',
        '日志服务初始化成功 (调试模式: ${_debugMode ? "开启" : "关闭"})',
      );
    } catch (e) {
      // 如果初始化失败（例如在Isolate中），标记为已初始化但不写入文件
      _isInitialized = true;
      _logFile = null;
    }
  }

  /// 设置调试模式
  Future<void> setDebugMode(bool enabled) async {
    _debugMode = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('debug_mode', enabled);
    await _writeLog(
      LogLevel.info,
      'LoggerService',
      '调试模式已${enabled ? "开启" : "关闭"}',
    );
  }

  /// 获取当前调试模式状态
  bool get isDebugMode => _debugMode;

  /// 归档当前日志文件
  Future<void> _archiveLogFile() async {
    if (_logFile == null || !await _logFile!.exists()) return;

    try {
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final archivePath = '${_logFile!.path}.$timestamp.archive';
      await _logFile!.copy(archivePath);
      await _logFile!.delete();
      await _logFile!.create();
    } catch (e) {}
  }

  /// 写入日志
  Future<void> _writeLog(
    LogLevel level,
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) async {
    if (_isInIsolate) {
      return;
    }

    if (!_isInitialized) {
      await initialize();
    }

    // 根据调试模式过滤日志
    // 非调试模式：只记录错误和严重错误
    // 调试模式：记录所有级别的日志
    if (!_debugMode && level != LogLevel.error && level != LogLevel.fatal) {
      return;
    }

    final timestamp = _dateFormat.format(DateTime.now());
    final levelStr = level.name.toUpperCase().padRight(7);
    final logMessage = StringBuffer();

    logMessage.write('[$timestamp] [$levelStr] [$tag] $message');

    if (error != null) {
      logMessage.write('\n错误详情: $error');
    }

    if (stackTrace != null) {
      logMessage.write('\n堆栈跟踪:\n$stackTrace');
    }

    logMessage.write('\n');

    try {
      // 写入文件（使用 UTF-8 编码以支持中文）
      if (_logFile != null) {
        await _logFile!.writeAsString(
          logMessage.toString(),
          mode: FileMode.append,
          encoding: utf8,
          flush: true,
        );
      } else {
        // 如果没有日志文件（例如在Isolate中），静默忽略
      }

      // 同时输出到控制台（仅错误和严重错误）
      if (level == LogLevel.error || level == LogLevel.fatal) {
        // print(logMessage.toString()); // 可选：输出到控制台
      }
    } catch (e) {
      // 静默失败，避免在Isolate中出现问题
    }
  }

  /// 调试日志
  Future<void> debug(String tag, String message) async {
    await _writeLog(LogLevel.debug, tag, message);
  }

  /// 信息日志
  Future<void> info(String tag, String message) async {
    await _writeLog(LogLevel.info, tag, message);
  }

  /// 警告日志
  Future<void> warning(String tag, String message, [Object? error]) async {
    await _writeLog(LogLevel.warning, tag, message, error);
  }

  /// 错误日志
  Future<void> error(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) async {
    await _writeLog(LogLevel.error, tag, message, error, stackTrace);
  }

  /// 严重错误日志
  Future<void> fatal(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) async {
    await _writeLog(LogLevel.fatal, tag, message, error, stackTrace);
  }

  /// 获取日志文件路径
  Future<String?> getLogFilePath() async {
    if (!_isInitialized) {
      await initialize();
    }
    return _logFile?.path;
  }

  /// 获取日志文件内容
  Future<String> getLogContent() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_logFile == null || !await _logFile!.exists()) {
      return '暂无日志记录';
    }

    try {
      return await _logFile!.readAsString();
    } catch (e) {
      return '读取日志失败: $e';
    }
  }

  /// 获取日志文件大小（格式化）
  Future<String> getLogFileSize() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_logFile == null || !await _logFile!.exists()) {
      return '0 KB';
    }

    try {
      final fileSize = await _logFile!.length();
      if (fileSize < 1024) {
        return '$fileSize B';
      } else if (fileSize < 1024 * 1024) {
        return '${(fileSize / 1024).toStringAsFixed(2)} KB';
      } else {
        return '${(fileSize / (1024 * 1024)).toStringAsFixed(2)} MB';
      }
    } catch (e) {
      return '未知';
    }
  }

  /// 获取日志行数
  Future<int> getLogLineCount() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_logFile == null || !await _logFile!.exists()) {
      return 0;
    }

    try {
      final content = await _logFile!.readAsString();
      return content.split('\n').where((line) => line.trim().isNotEmpty).length;
    } catch (e) {
      return 0;
    }
  }

  /// 清空日志
  Future<void> clearLogs() async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      if (_logFile != null && await _logFile!.exists()) {
        await _logFile!.delete();
        await _logFile!.create();
        await _writeLog(LogLevel.info, 'LoggerService', '日志已清空');
      }
    } catch (e) {}
  }

  /// 导出日志到指定路径
  Future<void> exportLog(String targetPath) async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_logFile == null || !await _logFile!.exists()) {
      throw Exception('日志文件不存在');
    }

    try {
      await _logFile!.copy(targetPath);
    } catch (e) {
      throw Exception('导出日志失败: $e');
    }
  }
}

/// 全局日志实例
final logger = LoggerService();
