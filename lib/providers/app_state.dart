// 全局应用状态：初始化日志/配置/数据库，管理页面路由、解密进度、错误与头像缓存
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../services/database_service.dart';
import '../services/config_service.dart';
import '../services/logger_service.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用状态管理
class AppState extends ChangeNotifier {
  final DatabaseService databaseService = DatabaseService();
  final ConfigService configService = ConfigService();

  bool _isConfigured = false;
  String _currentPage = 'welcome';
  bool _isLoading = false;
  String? _errorMessage;

  // 解密进度
  bool _isDecrypting = false;
  String _decryptingDatabase = '';
  int _decryptProgress = 0;
  int _decryptTotal = 0;

  // 全局头像缓存 (username -> avatarUrl)
  Map<String, String> _globalAvatarCache = {};

  bool get isConfigured => _isConfigured;
  String get currentPage => _currentPage;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  // 解密进度 getters
  bool get isDecrypting => _isDecrypting;
  String get decryptingDatabase => _decryptingDatabase;
  int get decryptProgress => _decryptProgress;
  int get decryptTotal => _decryptTotal;

  /// 获取解密进度百分比
  double get decryptProgressPercent {
    if (_decryptTotal == 0) return 0;
    return _decryptProgress / _decryptTotal;
  }

  /// 获取当前数据库模式
  DatabaseMode get currentDatabaseMode => databaseService.mode;

  /// 初始化应用状态
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      // 初始化日志服务
      await logger.initialize();
      await logger.info('AppState', '应用开始初始化');

      // 加载本地缓存的头像
      await _loadCachedAvatars();

      // 初始化数据库服务
      await databaseService.initialize();

      // 检查配置状态
      _isConfigured = await configService.isConfigured();

      // 启动时始终显示欢迎页面，让用户手动选择
      _currentPage = 'welcome';

      // 如果已配置，根据配置的模式连接数据库
      if (_isConfigured) {
        final mode = await configService.getDatabaseMode();
        await logger.info('AppState', '数据库模式: $mode');
        if (mode == 'realtime') {
          await _tryConnectRealtimeDatabase();
        } else {
          await _tryConnectDecryptedDatabase();
        }
      }

      await logger.info('AppState', '应用初始化完成');
    } catch (e, stackTrace) {
      _errorMessage = '初始化失败: $e';
      await logger.error('AppState', '应用初始化失败', e, stackTrace);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 设置配置状态
  void setConfigured(bool configured) {
    _isConfigured = configured;
    configService.setConfigured(configured);
    notifyListeners();
  }

  /// 设置当前页面
  void setCurrentPage(String page) {
    _currentPage = page;
    notifyListeners();
  }

  /// 设置加载状态
  void setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  /// 设置错误消息
  void setError(String? error) {
    _errorMessage = error;
    notifyListeners();
  }

  /// 清除错误消息
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// 设置解密状态
  void setDecrypting(
    bool isDecrypting, {
    String database = '',
    int progress = 0,
    int total = 0,
  }) {
    _isDecrypting = isDecrypting;
    _decryptingDatabase = database;
    _decryptProgress = progress;
    _decryptTotal = total;
    notifyListeners();
  }

  /// 重新连接数据库（公开方法，用于配置更改后重新连接）
  /// [retryCount] 重试次数，默认3次
  /// [retryDelay] 每次重试之间的延迟（毫秒），默认1000ms
  Future<void> reconnectDatabase({
    int retryCount = 3,
    int retryDelay = 1000,
  }) async {
    if (_isLoading) {
      await logger.info('AppState', '已有重连任务进行中，跳过本次请求');
      return;
    }
    _isLoading = true;
    notifyListeners();

    Exception? lastError;

    // 强制关闭所有数据库连接，释放文件句柄
    try {
      await logger.info('AppState', '关闭旧的数据库连接...');
      await databaseService.close();
      // 等待更长时间，确保Windows系统完全释放文件句柄
      await Future.delayed(Duration(milliseconds: retryDelay * 2));
      await logger.info('AppState', '数据库连接已关闭');
    } catch (e) {
      await logger.warning('AppState', '关闭数据库连接时出现警告（可忽略）', e);
    }

    for (int attempt = 0; attempt < retryCount; attempt++) {
      try {
        await logger.info(
          'AppState',
          '尝试重新连接数据库 (第${attempt + 1}/${retryCount}次)',
        );

        // 获取配置的数据库模式
        final mode = await configService.getDatabaseMode();

        if (mode == 'realtime') {
          try {
            await _tryConnectRealtimeDatabase();
          } catch (e) {
            await logger.warning('AppState', '实时模式连接失败，回退到备份模式', e);
            // 实时模式失败，回退到备份模式
            await _tryConnectDecryptedDatabase();
          }
        } else {
          await _tryConnectDecryptedDatabase();
        }

        // 验证连接是否成功
        if (databaseService.isConnected) {
          await logger.info('AppState', '数据库重新连接成功');
          _errorMessage = null;
          _isLoading = false;
          notifyListeners();
          return; // 连接成功，退出重试循环
        } else {
          throw Exception('数据库连接失败：isConnected 返回 false');
        }
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        await logger.error('AppState', '重连数据库失败(第${attempt + 1}次)', e);

        if (attempt < retryCount - 1) {
          // 还有重试机会，等待后重试
          await logger.info('AppState', '等待${retryDelay}ms后重试...');
          await Future.delayed(Duration(milliseconds: retryDelay));
        }
      }
    }

    // 所有重试都失败
    _errorMessage =
        '数据库连接失败（已重试${retryCount}次）: ${lastError?.toString() ?? "未知错误"}';
    await logger.error('AppState', _errorMessage!);
    _isLoading = false;
    notifyListeners();
  }

  /// 尝试连接实时数据库（直接读取加密数据库）
  Future<void> _tryConnectRealtimeDatabase() async {
    try {
      await logger.info('AppState', '尝试连接实时数据库');

      final hexKey = await configService.getDecryptKey();
      if (hexKey == null) {
        await logger.error('AppState', '未配置解密密钥');
        throw Exception('未配置解密密钥，请在设置中配置密钥');
      }

      await logger.info('AppState', '已获取解密密钥（长度: ${hexKey.length}）');

      final dbPath = await configService.getDatabasePath();
      if (dbPath == null) {
        await logger.error('AppState', '未配置数据库路径');
        throw Exception('未配置数据库路径，请在设置中选择数据库目录');
      }

      await logger.info('AppState', '配置的数据库路径: $dbPath');

      // 自动定位 session.db
      final sessionDbPath = await _locateSessionDb(dbPath);
      if (sessionDbPath == null) {
        await logger.error('AppState', '未找到session.db数据库文件');
        throw Exception('未找到session.db数据库文件，请检查微信数据库目录是否正确');
      }

      await logger.info('AppState', '找到session.db: $sessionDbPath');
      // 已经是实时模式且相同路径/密钥，直接返回
      if (databaseService.mode == DatabaseMode.realtime &&
          databaseService.dbPath == sessionDbPath) {
        await logger.info('AppState', '已在实时模式且路径未变，跳过重复连接');
        return;
      }

      // 连接实时加密数据库
      await databaseService.connectRealtimeDatabase(sessionDbPath, hexKey);
      await logger.info(
        'AppState',
        '实时数据库连接成功，isConnected=${databaseService.isConnected}',
      );
    } catch (e, stackTrace) {
      await logger.error('AppState', '连接实时数据库失败', e, stackTrace);
      rethrow;
    }
  }

  /// 定位 session.db 文件（递归搜索子目录）
  Future<String?> _locateSessionDb(String dbStoragePath) async {
    try {
      final dbStorageDir = Directory(dbStoragePath);
      if (!await dbStorageDir.exists()) {
        return null;
      }

      // 递归搜索所有 .db 文件，寻找包含 session 的文件
      final allDbFiles = await _findAllDbFilesRecursively(dbStorageDir);

      // 优先查找文件名包含 session 的文件
      final sessionFiles = allDbFiles.where((file) {
        final fileName = file.path
            .split(Platform.pathSeparator)
            .last
            .toLowerCase();
        return fileName.contains('session') && fileName.endsWith('.db');
      }).toList();

      if (sessionFiles.isNotEmpty) {
        return sessionFiles.first.path;
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// 递归查找所有 .db 文件
  Future<List<File>> _findAllDbFilesRecursively(Directory dir) async {
    final List<File> dbFiles = [];

    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.db')) {
          dbFiles.add(entity);
        }
      }
    } catch (e) {}

    return dbFiles;
  }

  /// 尝试连接数据库（仅使用备份模式）
  Future<void> _tryConnectDecryptedDatabase() async {
    try {
      // 仅使用备份模式连接解密后的数据库
      await _connectDecryptedBackupDatabase();
    } catch (e) {}
  }

  /// 连接解密后的备份数据库
  Future<void> _connectDecryptedBackupDatabase() async {
    try {
      await logger.info('AppState', '尝试连接解密后的备份数据库');

      final documentsDir = await getApplicationDocumentsDirectory();
      final documentsPath = documentsDir.path;

      // 查找所有账号目录（不限制必须以 wxid_ 开头）
      final echoTraceDir = Directory(
        '$documentsPath${Platform.pathSeparator}EchoTrace',
      );
      if (!await echoTraceDir.exists()) {
        await logger.error('AppState', 'EchoTrace目录不存在: ${echoTraceDir.path}');
        throw Exception('EchoTrace目录不存在，请先解密数据库');
      }

      final accountDirs = await echoTraceDir.list().where((entity) {
        return entity is Directory;
      }).toList();

      if (accountDirs.isEmpty) {
        await logger.error('AppState', '未找到任何账号目录');
        throw Exception('未找到任何账号目录，请先解密数据库');
      }

      await logger.info('AppState', '找到 ${accountDirs.length} 个账号目录');

      final List<String> attemptedFiles = [];
      final List<String> errors = [];

      // 遍历每个账号目录，查找所有已解密的数据库
      for (final accountEntity in accountDirs) {
        final accountDir = accountEntity as Directory;

        // 获取目录下所有 .db 文件
        final dbFiles = await accountDir.list().where((entity) {
          return entity is File && entity.path.endsWith('.db');
        }).toList();

        if (dbFiles.isEmpty) {
          continue;
        }

        // 优先查找 session.db（包含会话列表）
        for (final dbFile in dbFiles) {
          final fileName = dbFile.path.split(Platform.pathSeparator).last;

          // 优先尝试 session.db
          if (fileName.contains('session')) {
            attemptedFiles.add(dbFile.path);
            await logger.info('AppState', '尝试连接数据库: ${dbFile.path}');
            try {
              await databaseService.connectDecryptedDatabase(dbFile.path);
              final tables = await databaseService.getAllTableNames();

              await logger.info(
                'AppState',
                '数据库 $fileName 包含的表: ${tables.join(", ")}',
              );

              // 检查是否包含 SessionTable
              if (tables.contains('SessionTable')) {
                await logger.info(
                  'AppState',
                  '成功连接数据库: $fileName，isConnected=${databaseService.isConnected}',
                );
                return; // 成功找到并连接
              } else {
                await logger.warning(
                  'AppState',
                  '数据库 $fileName 不包含SessionTable',
                );
              }
            } catch (e, stackTrace) {
              final errorMsg = '连接 $fileName 失败: $e';
              errors.add(errorMsg);
              await logger.error('AppState', errorMsg, e, stackTrace);
            }
          }
        }

        // 如果没找到 session.db，尝试其他数据库
        for (final dbFile in dbFiles) {
          final fileName = dbFile.path.split(Platform.pathSeparator).last;
          if (fileName.contains('session')) continue; // 已经尝试过

          attemptedFiles.add(dbFile.path);
          try {
            await databaseService.connectDecryptedDatabase(dbFile.path);
            final tables = await databaseService.getAllTableNames();

            // 检查是否包含会话相关的表（不包括纯消息数据库）
            final hasSessionTable = tables.contains('SessionTable');
            final hasContactTable =
                tables.contains('contact') || tables.contains('Contact');
            final hasFMessageTable = tables.contains('FMessageTable');

            // 只有包含会话表、联系人表或FMessageTable的数据库才能作为会话数据库
            // 纯消息数据库（只有Msg_表）不能作为会话数据库使用
            if (hasSessionTable || hasContactTable || hasFMessageTable) {
              await logger.info('AppState', '成功连接数据库: $fileName');
              return; // 成功找到并连接
            }
          } catch (e) {
            final errorMsg = '连接 $fileName 失败: $e';
            errors.add(errorMsg);
            await logger.warning('AppState', errorMsg, e);
          }
        }
      }

      // 如果到这里还没有成功连接，说明所有尝试都失败了
      if (attemptedFiles.isEmpty) {
        await logger.error('AppState', '未找到任何数据库文件');
        throw Exception('未找到任何数据库文件，请先在数据管理页面解密数据库');
      } else {
        final errorSummary = errors.take(3).join('; ');
        await logger.error(
          'AppState',
          '无法连接到任何数据库（尝试了${attemptedFiles.length}个文件）',
        );
        throw Exception(
          '无法连接到任何数据库（尝试了${attemptedFiles.length}个文件）。前3个错误: $errorSummary',
        );
      }
    } catch (e, stackTrace) {
      await logger.error('AppState', '连接解密备份数据库失败', e, stackTrace);
      rethrow;
    }
  }

  // --- 头像缓存相关方法 ---

  /// 加载本地缓存的头像
  Future<void> _loadCachedAvatars() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('avatar_cache');
      if (jsonStr != null) {
        final Map<String, dynamic> decoded = jsonDecode(jsonStr);
        _globalAvatarCache = decoded.map(
          (key, value) => MapEntry(key, value.toString()),
        );
        await logger.info('AppState', '已加载 ${_globalAvatarCache.length} 个缓存头像');
      }
    } catch (e) {
      await logger.warning('AppState', '加载头像缓存失败', e);
    }
  }

  /// 获取指定用户的头像URL
  String? getAvatarUrl(String username) {
    return _globalAvatarCache[username];
  }

  /// 判断头像是否已缓存（用于禁用重复动画）
  bool isAvatarCached(String username) {
    final url = _globalAvatarCache[username];
    return url != null && url.isNotEmpty;
  }

  /// 批量获取并更新头像缓存
  /// 如果数据库中的URL与缓存不一致，则更新缓存并持久化
  Future<void> fetchAndCacheAvatars(List<String> usernames) async {
    if (!databaseService.isConnected || usernames.isEmpty) return;

    try {
      // 过滤掉不需要查询的系统账号（可选，视需求而定）
      // final targets = usernames.where((u) => !u.startsWith('gh_')).toList();

      // 从数据库获取最新头像URL
      final latestAvatars = await databaseService.getAvatarUrls(usernames);

      bool hasChanges = false;

      for (final entry in latestAvatars.entries) {
        final username = entry.key;
        final newUrl = entry.value;

        // 如果缓存中没有，或者URL变了，则更新
        if (_globalAvatarCache[username] != newUrl) {
          _globalAvatarCache[username] = newUrl;
          hasChanges = true;
        }
      }

      // 如果有变化，保存到本地并通知监听器
      if (hasChanges) {
        await _saveAvatarCache();
        notifyListeners();
        await logger.debug(
          'AppState',
          '更新了头像缓存，当前缓存总数: ${_globalAvatarCache.length}',
        );
      }
    } catch (e) {
      await logger.warning('AppState', '更新头像缓存失败', e);
    }
  }

  /// 保存头像缓存到本地
  Future<void> _saveAvatarCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(_globalAvatarCache);
      await prefs.setString('avatar_cache', jsonStr);
    } catch (e) {
      await logger.warning('AppState', '保存头像缓存失败', e);
    }
  }
}
