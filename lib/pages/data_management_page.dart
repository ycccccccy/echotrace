import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/app_state.dart';
import '../services/config_service.dart';
import '../services/decrypt_service.dart';
import '../services/image_decrypt_service.dart';
import '../services/logger_service.dart';
import '../services/go_decrypt_ffi.dart';
import '../utils/cpu_info.dart';

class _AsyncSemaphore {
  _AsyncSemaphore(this._permits) : assert(_permits > 0);

  int _permits;
  final List<Completer<void>> _waiters = [];

  Future<void> acquire() {
    if (_permits > 0) {
      _permits -= 1;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
      return;
    }
    _permits += 1;
  }
}

/// 数据管理页面
class DataManagementPage extends StatefulWidget {
  const DataManagementPage({super.key});

  @override
  State<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends State<DataManagementPage> {
  Color get _primaryColor => Theme.of(context).colorScheme.primary;
  Color get _tertiaryColor => Theme.of(context).colorScheme.tertiary;
  Color get _updateColor => const Color(0xFFF4B400);
  Color get _surfaceColor => Theme.of(context).cardColor;
  Color get _borderColor =>
      Theme.of(context).colorScheme.outline.withValues(alpha: 0.12);
  final ConfigService _configService = ConfigService();
  late final DecryptService _decryptService;
  late final ImageDecryptService _imageDecryptService;
  final GlobalKey<NavigatorState> _sectionNavigatorKey =
      GlobalKey<NavigatorState>();
  String _currentSection = 'database';

  // 数据库文件相关
  final List<DatabaseFile> _databaseFiles = [];
  bool _isLoading = false;
  String? _statusMessage;
  bool _isSuccess = false;
  String? _derivedKey; // 缓存派生后的密钥

  // 数据库解密进度相关
  bool _isDecrypting = false;
  int _totalFiles = 0;
  int _completedFiles = 0;
  String _currentDecryptingFile = '';
  final Map<String, bool> _decryptResults = {}; // 记录每个文件的解密结果

  // 进度节流相关
  final Map<String, DateTime> _lastProgressUpdateMap = {}; // 每个文件独立的节流时间戳
  final Map<String, double> _lastProgressValueMap = {}; // 记录上次进度值，避免重复刷新
  final Map<String, ValueNotifier<double>> _progressNotifiers = {};

  // 图片文件相关
  // 注意：图片文件列表现在由 AppState 管理，这里只保留 UI 相关状态
  String? _imageStatusMessage;
  bool _isImageSuccess = false;
  bool _showOnlyUndecrypted = false; // 只显示未解密的文件
  static const int _initialImageDisplayLimit = 1000;
  static const int _imagePageSize = 1000;
  int _displayLimit = _initialImageDisplayLimit; // 默认显示前1000条
  String _imageQualityFilter = 'all'; // 'all', 'original', 'thumbnail' - 图片质量过滤
  int _lastImageFilteredCount = 0;
  bool _isLoadingMoreImages = false;
  final ScrollController _imageListController = ScrollController();

  // 图片解密进度相关
  bool _isDecryptingImages = false;
  int _totalImageFiles = 0;
  int _completedImageFiles = 0;
  String _currentDecryptingImage = '';
  final Map<String, bool> _imageDecryptResults = {}; // 记录每个图片的解密结果
  final TextEditingController _imageSearchController = TextEditingController();
  String _imageNameQuery = '';

  @override
  void initState() {
    super.initState();
    _decryptService = DecryptService();
    _decryptService.initialize();
    _imageDecryptService = ImageDecryptService();
    _imageListController.addListener(_handleImageListScroll);
    _loadDatabaseFiles();
    // 触发图片扫描（如果尚未完成）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = context.read<AppState>();
      appState.startImageScan();
    });
  }

  @override
  void dispose() {
    for (final notifier in _progressNotifiers.values) {
      notifier.dispose();
    }
    _progressNotifiers.clear();
    _decryptService.dispose();
    _imageSearchController.dispose();
    _imageListController.dispose();
    super.dispose();
  }

  void _handleImageListScroll() {
    if (!_imageListController.hasClients) return;
    final position = _imageListController.position;
    if (position.extentAfter > 600) return;
    if (_displayLimit >= _lastImageFilteredCount) return;
    if (_isLoadingMoreImages) return;
    _isLoadingMoreImages = true;
    setState(() {
      _displayLimit = math.min(
        _displayLimit + _imagePageSize,
        _lastImageFilteredCount,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isLoadingMoreImages = false;
    });
  }

  void _resetImageListLimit() {
    _displayLimit = _initialImageDisplayLimit;
    if (_imageListController.hasClients) {
      _imageListController.jumpTo(0);
    }
  }

  /// 加载数据库文件列表
  Future<void> _loadDatabaseFiles() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
    });

    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      final documentsPath = documentsDir.path;

      // 优先使用用户配置的数据库路径
      String? configuredPath = await _configService.getDatabasePath();
      final manualWxid = await _configService.getManualWxid();

      _databaseFiles.clear();

      // 如果没有配置路径，使用默认路径
      if (configuredPath == null || configuredPath.isEmpty) {
        configuredPath = '$documentsPath${Platform.pathSeparator}xwechat_files';
      }

      // 智能识别路径类型并扫描数据库
      await _scanDatabasePath(
        configuredPath,
        documentsPath,
        manualWxid: manualWxid,
      );

      // 按文件大小排序，小的在前
      _databaseFiles.sort((a, b) => a.fileSize.compareTo(b.fileSize));

      // 清理上次更新时重命名的旧文件（.old.* 后缀）
      await _cleanupOldRenamedFiles(documentsPath);

      _syncProgressNotifiers();
    } catch (e, stackTrace) {
      await logger.error('DataManagementPage', '加载数据库文件失败', e, stackTrace);
      _showMessage('加载数据库文件失败: $e', false);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// 清理上次增量更新时重命名的旧文件
  Future<void> _cleanupOldRenamedFiles(String documentsPath) async {
    try {
      await logger.info('DataManagementPage', '开始清理重命名的旧文件（.old.* 后缀）');
      int cleanedCount = 0;

      // 扫描 EchoTrace 目录下所有的账号文件夹
      final echoTraceDir = Directory(
        '$documentsPath${Platform.pathSeparator}EchoTrace',
      );
      if (!await echoTraceDir.exists()) {
        await logger.info('DataManagementPage', 'EchoTrace 目录不存在，跳过清理');
        return;
      }

      await for (final accountEntity in echoTraceDir.list()) {
        if (accountEntity is! Directory) continue;

        final accountDirName = accountEntity.path
            .split(Platform.pathSeparator)
            .last;

        // 扫描该账号目录下的所有 .old.* 文件
        await for (final fileEntity in accountEntity.list()) {
          if (fileEntity is! File) continue;

          final fileName = fileEntity.path.split(Platform.pathSeparator).last;
          if (fileName.contains('.old.')) {
            try {
              await fileEntity.delete();
              cleanedCount++;
              await logger.info(
                'DataManagementPage',
                '已删除旧文件: $fileName (账号: $accountDirName)',
              );
            } catch (e) {
              await logger.warning(
                'DataManagementPage',
                '无法删除旧文件 $fileName: $e',
              );
              // 如果文件仍被占用，下次启动时再试
            }
          }
        }
      }

      if (cleanedCount > 0) {
        await logger.info('DataManagementPage', '清理完成，共删除 $cleanedCount 个旧文件');
      } else {
        await logger.info('DataManagementPage', '没有需要清理的旧文件');
      }
    } catch (e, stackTrace) {
      await logger.error('DataManagementPage', '清理旧文件失败', e, stackTrace);
      // 清理失败不影响主流程，继续运行
    }
  }

  /// 清理账号目录名，去除微信自动添加的后缀
  String _cleanAccountDirName(String dirName) {
    final trimmed = dirName.trim();
    if (trimmed.isEmpty) return trimmed;

    // 兼容旧版 wxid_xxx_123 目录，去掉尾部数字
    final legacyMatch = RegExp(
      r'^(wxid_[a-zA-Z0-9]+)(?:_\d+)?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (legacyMatch != null) {
      return legacyMatch.group(1)!;
    }

    // 其他命名直接返回
    return trimmed;
  }

  String? _normalizeWxid(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final legacyMatch =
        RegExp(r'^(wxid_[a-zA-Z0-9]+)(?:_\d+)?$', caseSensitive: false)
            .firstMatch(trimmed);
    if (legacyMatch != null) return legacyMatch.group(1)!.toLowerCase();
    return trimmed.toLowerCase();
  }

  /// 智能扫描数据库路径
  Future<void> _scanDatabasePath(
    String basePath,
    String documentsPath, {
    String? manualWxid,
  }) async {
    final baseDir = Directory(basePath);
    if (!await baseDir.exists()) {
      return;
    }

    final pathParts = basePath.split(Platform.pathSeparator);
    final lastPart = pathParts.isNotEmpty ? pathParts.last : '';

    final normalizedManual = _normalizeWxid(manualWxid);

    // 判断路径类型并采取不同的扫描策略
    if (lastPart == 'db_storage') {
      // 情况1：用户直接选择了 db_storage 目录
      // 从路径中提取账号文件夹名
      String accountName = 'unknown';
      if (pathParts.length >= 2) {
        final parentDirName = pathParts[pathParts.length - 2];
        accountName = _cleanAccountDirName(parentDirName);
      }
      if (normalizedManual != null &&
          _normalizeWxid(accountName) != normalizedManual) {
        await logger.warning(
          'DataManagementPage',
          '选择的db_storage账号与配置wxid不匹配，已跳过扫描',
        );
        return;
      }

      await _scanDbStorageDirectory(baseDir, accountName, documentsPath);
    } else {
      // 情况2和3：扫描该目录下所有包含 db_storage 子文件夹的子目录
      // 这样可以兼容 wxid_xxx 格式和新版微信的其他命名格式
      bool foundAnyAccount = false;

      await for (final entity in baseDir.list()) {
        if (entity is! Directory) continue;

        final accountDirName = entity.path.split(Platform.pathSeparator).last;
        final cleanedAccountName = _cleanAccountDirName(accountDirName);
        if (normalizedManual != null &&
            _normalizeWxid(cleanedAccountName) != normalizedManual) {
          continue; // 只扫描指定账号
        }
        final dbStoragePath =
            '${entity.path}${Platform.pathSeparator}db_storage';
        final dbStorageDir = Directory(dbStoragePath);

        // 检查是否存在 db_storage 子文件夹
        if (await dbStorageDir.exists()) {
          foundAnyAccount = true;
          await logger.info(
            'DataManagementPage',
            '发现账号目录: $accountDirName -> 清理后: $cleanedAccountName (包含 db_storage)',
          );
          await _scanDbStorageDirectory(
            dbStorageDir,
            cleanedAccountName,
            documentsPath,
          );
        }
      }

      // 如果没有找到任何账号目录，尝试使用手动输入的wxid
      if (!foundAnyAccount) {
        if (manualWxid != null && manualWxid.isNotEmpty) {
          await logger.info(
            'DataManagementPage',
            '未找到账号目录，使用手动输入的wxid: $manualWxid',
          );
          // 查找该wxid对应的db_storage目录
          await for (final entity in baseDir.list()) {
            if (entity is! Directory) continue;

            final dbStoragePath =
                '${entity.path}${Platform.pathSeparator}db_storage';
            final dbStorageDir = Directory(dbStoragePath);

            if (await dbStorageDir.exists()) {
              final dirName =
                  entity.path.split(Platform.pathSeparator).last;
              if (normalizedManual != null &&
                  _normalizeWxid(dirName) != normalizedManual) {
                continue;
              }
              await logger.info(
                'DataManagementPage',
                '使用手动wxid扫描数据库: $manualWxid',
              );
              await _scanDbStorageDirectory(
                dbStorageDir,
                manualWxid,
                documentsPath,
              );
              break;
            }
          }
        }
      }
    }
  }

  /// 扫描 db_storage 目录下的所有数据库文件
  Future<void> _scanDbStorageDirectory(
    Directory dbStorageDir,
    String accountName,
    String documentsPath,
  ) async {
    // 递归查找所有 .db 文件
    final dbFiles = await _findAllDbFiles(dbStorageDir);

    for (final dbFile in dbFiles) {
      final fileName = dbFile.path.split(Platform.pathSeparator).last;
      final fileSize = await dbFile.length();

      // 获取源文件修改时间
      final originalStat = await dbFile.stat();
      final originalModified = originalStat.modified;

      // 检查是否已经解密
      final ourWorkDir = Directory(
        '$documentsPath${Platform.pathSeparator}EchoTrace',
      );
      final decryptedFileName = '${fileName.split('.').first}.db';
      final decryptedFilePath =
          '${ourWorkDir.path}${Platform.pathSeparator}$accountName${Platform.pathSeparator}$decryptedFileName';
      final decryptedFile = File(decryptedFilePath);

      final isDecrypted = await decryptedFile.exists();
      DateTime? decryptedModified;

      if (isDecrypted) {
        // 获取备份文件修改时间
        final decryptedStat = await decryptedFile.stat();
        decryptedModified = decryptedStat.modified;
      }

      _databaseFiles.add(
        DatabaseFile(
          originalPath: dbFile.path,
          fileName: fileName,
          fileSize: fileSize,
          wxidName: accountName,
          isDecrypted: isDecrypted,
          decryptedPath: decryptedFilePath,
          originalModified: originalModified,
          decryptedModified: decryptedModified,
        ),
      );
    }
  }

  /// 递归查找所有 .db 文件
  Future<List<File>> _findAllDbFiles(Directory dir) async {
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

  /// 批量解密未解密的文件
  Future<void> _decryptAllPending() async {
    final pendingFiles = _databaseFiles
        .where((file) => !file.isDecrypted)
        .toList();

    if (pendingFiles.isEmpty) {
      _showMessage('所有文件都已解密！', true);
      return;
    }

    // 初始化解密状态
    if (!mounted) return;
    setState(() {
      _isDecrypting = true;
      _totalFiles = pendingFiles.length;
      _completedFiles = 0;
      _currentDecryptingFile = '';
      _decryptResults.clear();
    });

    try {
      // 获取密钥
      final key = await _configService.getDecryptKey();
      if (key == null || key.isEmpty) {
        _showMessage('请先在设置页面配置密钥', false);
        return;
      }

      // 派生密钥（只计算一次）
      _derivedKey ??= await _deriveKeyOnce(
          key,
          pendingFiles.first.originalPath,
        );

      // 步骤1：强制清理所有页面状态
      if (mounted) {
        await logger.info('DataManagementPage', '步骤1: 导航到数据管理页面并清理其他页面');
        context.read<AppState>().setCurrentPage('data_management');
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      // 步骤2：多次关闭数据库连接
      if (mounted) {
        await logger.info('DataManagementPage', '步骤2: 第1次关闭数据库连接');
        await context.read<AppState>().databaseService.close();
        await Future.delayed(const Duration(milliseconds: 1000));

        await logger.info('DataManagementPage', '步骤2: 第2次关闭数据库连接');
        await context.read<AppState>().databaseService.close();
        await logger.info('DataManagementPage', '所有数据库连接已关闭');
      }

      // 步骤3：等待文件句柄释放
      await logger.info('DataManagementPage', '步骤3: 等待文件句柄完全释放（2秒）...');
      await Future.delayed(const Duration(milliseconds: 2000));
      await logger.info('DataManagementPage', '文件句柄释放完成');

      // 步骤4：关闭当前进程中所有指向待解密文件的句柄
      await logger.info(
        'DataManagementPage',
        '步骤4: 关闭当前进程的 ${pendingFiles.length} 个数据库文件句柄...',
      );
      final goFfi = GoDecryptFFI();
      int closedCount = 0;
      for (final file in pendingFiles) {
        try {
          final error = goFfi.closeSelfFileHandles(file.originalPath);
          if (error == null) {
            closedCount++;
            await logger.info(
              'DataManagementPage',
              '成功关闭文件句柄: ${file.fileName}',
            );
          } else {
            await logger.warning(
              'DataManagementPage',
              '关闭文件句柄失败: ${file.fileName}, 错误: $error',
            );
          }
        } catch (e) {
          await logger.warning(
            'DataManagementPage',
            '关闭文件句柄时出错: ${file.fileName}',
            e,
          );
        }
      }
      await logger.info(
        'DataManagementPage',
        '文件句柄关闭完成，成功关闭 $closedCount/${pendingFiles.length} 个文件',
      );

      // 再等待一小段时间，确保文件句柄完全释放
      await Future.delayed(const Duration(milliseconds: 500));
      await logger.info('DataManagementPage', '开始全量解密');

      // -- 开始并行解密--
      if (mounted) {
        setState(() {
          _currentDecryptingFile = '同时解密 ${pendingFiles.length} 个数据库...';
        });
      }

      // 创建所有解密任务（每个数据库一个独立的Isolate线程）
      final decryptTasks = pendingFiles.map((file) async {
        try {
          // 解密（仅在进度变化明显时刷新 UI）
          final decryptedPath = await _decryptService.decryptDatabase(
            file.originalPath,
            key,
            (current, total) {
              if (total <= 0) return;
              _updateDecryptProgress(file, current / total);
            },
          );

          // 验证临时文件
          final tempFile = File(decryptedPath);
          if (!await tempFile.exists()) {
            throw Exception('临时解密文件不存在: $decryptedPath');
          }

          // -- 解密成功后的文件操作 --
          final targetFile = File(file.decryptedPath);
          final targetDir = targetFile.parent;
          if (!await targetDir.exists()) {
            await targetDir.create(recursive: true);
          }

          if (await targetFile.exists()) {
            bool deleteSucceeded = false;
            for (int i = 0; i < 10; i++) {
              try {
                await targetFile.delete();
                deleteSucceeded = true;
                break;
              } catch (e) {
                if (i < 9) {
                  final delayMs = 300 * (i + 1);
                  await Future.delayed(Duration(milliseconds: delayMs));
                } else {
                  // 删除失败，不抛出异常，而是尝试重命名
                }
              }
            }

            // 如果删除失败，尝试强制解锁文件
            if (!deleteSucceeded && await targetFile.exists()) {
              try {
                // 使用 Windows Restart Manager API 强制关闭文件句柄
                final goFfi = GoDecryptFFI();
                final unlockError = goFfi.forceUnlockFile(file.decryptedPath);

                if (unlockError == null) {
                  await Future.delayed(const Duration(milliseconds: 500));

                  // 再次尝试删除
                  try {
                    await targetFile.delete();
                    deleteSucceeded = true;
                  } catch (e) {
                    // 解锁后仍然失败
                  }
                }
              } catch (e) {
                // 强制解锁失败
              }

              // 如果解锁后仍然无法删除，尝试重命名旧文件
              if (!deleteSucceeded && await targetFile.exists()) {
                final oldPath =
                    '${file.decryptedPath}.old.${DateTime.now().millisecondsSinceEpoch}';
                try {
                  await targetFile.rename(oldPath);
                } catch (e) {
                  // 即使重命名失败，也尝试复制新文件
                }
              }
            }
          }

          await File(decryptedPath).copy(file.decryptedPath);
          _lastProgressUpdateMap.remove(file.originalPath);
          _lastProgressValueMap.remove(file.originalPath);

          if (mounted) {
            setState(() {
              final index = _databaseFiles.indexWhere(
                (f) => f.originalPath == file.originalPath,
              );
              if (index != -1) {
                _databaseFiles[index].isDecrypted = true;
                _databaseFiles[index].decryptProgress = 1.0;
                _getProgressNotifier(_databaseFiles[index]).value = 1.0;
              }
              _completedFiles++;
              _decryptResults[file.fileName] = true;
            });
          }

          // 清理临时文件
          Future.delayed(const Duration(milliseconds: 100), () async {
            try {
              await File(decryptedPath).delete();
            } catch (e) {
              /* 忽略删除错误 */
            }
          });

          return true; // 成功
        } catch (e, stackTrace) {
          // 只在出错时记录日志
          await logger.error(
            'DataManagementPage',
            '解密文件 ${file.fileName} 失败',
            e,
            stackTrace,
          );
          _lastProgressUpdateMap.remove(file.originalPath);
          _lastProgressValueMap.remove(file.originalPath);
          _decryptResults[file.fileName] = false;
          return false; // 失败
        }
      }).toList();

      // 等待所有解密任务并行完成
      await Future.wait(decryptTasks);
      // -- 并行解密结束 --

      final successCount = _decryptResults.values.where((v) => v).length;
      final failCount = _decryptResults.values.where((v) => !v).length;

      // 等待文件系统完全释放文件句柄并刷新缓存（Windows需要更长时间）
      //  修复：增加等待时间到5秒，确保数据库文件完全写入磁盘
      await logger.info('DataManagementPage', '等待文件系统稳定（5秒）...');
      await Future.delayed(const Duration(milliseconds: 5000));

      // 重新连接数据库（增加重试次数和延迟）
      if (mounted) {
        await logger.info('DataManagementPage', '开始重新连接数据库...');
        await context.read<AppState>().reconnectDatabase(
          retryCount: 5,
          retryDelay: 1500,
        );
        await logger.info('DataManagementPage', '数据库重新连接完成');
      }

      _showMessage('批量解密完成！成功: $successCount, 失败: $failCount', failCount == 0);

      // 手动刷新文件列表，确保状态（特别是isDecrypted）完全更新
      await _loadDatabaseFiles();
    } catch (e, stackTrace) {
      await logger.error('DataManagementPage', '批量解密失败', e, stackTrace);
      _showMessage('批量解密失败: $e', false);

      // 等待文件系统稳定
      await logger.info('DataManagementPage', '等待文件系统稳定...');
      await Future.delayed(const Duration(milliseconds: 2500));

      // 即使失败也要尝试重新连接数据库
      if (mounted) {
        try {
          await logger.info('DataManagementPage', '开始重新连接数据库...');
          await context.read<AppState>().reconnectDatabase(
            retryCount: 5,
            retryDelay: 1500,
          );
          await logger.info('DataManagementPage', '数据库重新连接完成');
        } catch (reconnectError) {
          await logger.error('DataManagementPage', '重新连接数据库失败', reconnectError);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDecrypting = false;
        });
      }
    }
  }

  /// 派生密钥（只计算一次）
  Future<String> _deriveKeyOnce(String key, String testFilePath) async {
    // 这里可以实现密钥派生逻辑，避免重复计算
    // 暂时直接返回原密钥
    return key;
  }

  /// 增量更新（只更新有变化的文件）
  Future<void> _updateChanged() async {
    final filesToUpdate = _databaseFiles
        .where((file) => file.needsUpdate)
        .toList();

    if (filesToUpdate.isEmpty) {
      _showMessage('所有文件都是最新的！', true);
      return;
    }

    // 警告用户确保没有后台任务
    if (mounted) {
      final shouldContinue = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('准备增量更新'),
          content: const Text(
            '增量更新需要独占访问数据库文件。\n\n'
            '请确保：\n'
            '1. 没有正在进行的数据分析任务\n'
            '2. 没有打开年度报告页面\n'
            '3. 其他页面已停止使用数据库\n\n'
            '更新过程将等待约10秒以确保文件释放。\n'
            '是否继续？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续更新'),
            ),
          ],
        ),
      );

      if (shouldContinue != true) return;
    }

    if (!mounted) return;
    setState(() {
      _isDecrypting = true;
      _totalFiles = filesToUpdate.length;
      _completedFiles = 0;
      _decryptResults.clear();
    });

    try {
      final key = await _configService.getDecryptKey();
      if (key == null || key.isEmpty) {
        _showMessage('请先在设置页面配置密钥', false);
        return;
      }

      // 步骤1：强制清理所有页面状态，确保没有页面在使用数据库
      if (mounted) {
        await logger.info('DataManagementPage', '步骤1: 导航到数据管理页面并清理其他页面');
        context.read<AppState>().setCurrentPage('data_management');
        // 通知所有页面停止数据库操作
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      // 步骤2：多次尝试关闭数据库连接，确保所有连接都被释放
      if (mounted) {
        await logger.info('DataManagementPage', '步骤2: 第1次关闭数据库连接（包括缓存）');
        await context.read<AppState>().databaseService.close();
        await Future.delayed(const Duration(milliseconds: 1000));

        // 第二次关闭，确保清理
        await logger.info('DataManagementPage', '步骤2: 第2次关闭数据库连接（确保清理）');
        await context.read<AppState>().databaseService.close();
        await logger.info('DataManagementPage', '所有数据库连接已关闭');
      }

      // 步骤3：等待足够长的时间让操作系统释放所有文件句柄
      // Windows 系统需要更长时间，特别是有多个进程/Isolate时
      await logger.info('DataManagementPage', '步骤3: 等待文件句柄完全释放（2秒）...');
      await Future.delayed(const Duration(milliseconds: 2000));
      await logger.info('DataManagementPage', '文件句柄释放完成');

      // 步骤4：关闭当前进程中所有指向待更新文件的句柄
      // 直接关闭当前进程（包括 sqflite_ffi 后台 Isolate）中的文件句柄
      await logger.info(
        'DataManagementPage',
        '步骤4: 关闭当前进程的 ${filesToUpdate.length} 个数据库文件句柄...',
      );
      final goFfi = GoDecryptFFI();
      int closedCount = 0;
      for (final file in filesToUpdate) {
        try {
          final error = goFfi.closeSelfFileHandles(file.originalPath);
          if (error == null) {
            closedCount++;
            await logger.info(
              'DataManagementPage',
              '成功关闭文件句柄: ${file.fileName}',
            );
          } else {
            await logger.warning(
              'DataManagementPage',
              '关闭文件句柄失败: ${file.fileName}, 错误: $error',
            );
          }
        } catch (e) {
          await logger.warning(
            'DataManagementPage',
            '关闭文件句柄时出错: ${file.fileName}',
            e,
          );
        }
      }
      await logger.info(
        'DataManagementPage',
        '文件句柄关闭完成，成功关闭 $closedCount/${filesToUpdate.length} 个文件',
      );

      // 再等待一小段时间，确保文件句柄完全释放
      await Future.delayed(const Duration(milliseconds: 500));
      await logger.info('DataManagementPage', '开始增量更新');

      // -- 开始串行更新 --
      for (final file in filesToUpdate) {
        try {
          if (mounted) {
            setState(() {
              _currentDecryptingFile = file.fileName;
            });
          }

          final decryptedPath = await _decryptService.decryptDatabase(
            file.originalPath,
            key,
            (current, total) {
              if (total <= 0) return;
              _updateDecryptProgress(file, current / total);
            },
          );

          // -- 更新成功后的文件操作 --
          await logger.info('DataManagementPage', '准备替换文件: ${file.fileName}');
          final targetFile = File(file.decryptedPath);

          if (await targetFile.exists()) {
            await logger.info(
              'DataManagementPage',
              '目标文件已存在，尝试删除: ${file.decryptedPath}',
            );
            bool deleteSucceeded = false;

            // 尝试删除10次
            for (int i = 0; i < 10; i++) {
              try {
                await targetFile.delete();
                await logger.info('DataManagementPage', '目标文件删除成功');
                deleteSucceeded = true;
                break;
              } catch (e) {
                if (i < 9) {
                  final delayMs = 300 * (i + 1);
                  await logger.warning(
                    'DataManagementPage',
                    '删除失败（尝试${i + 1}/10），等待${delayMs}ms后重试: $e',
                  );
                  await Future.delayed(Duration(milliseconds: delayMs));
                } else {
                  await logger.error(
                    'DataManagementPage',
                    '删除目标文件失败，已重试10次，尝试重命名方案',
                    e,
                  );
                }
              }
            }

            // 如果删除失败，尝试强制解锁文件
            if (!deleteSucceeded && await targetFile.exists()) {
              await logger.warning(
                'DataManagementPage',
                '无法删除文件（可能被其他进程占用），尝试强制解锁',
              );

              try {
                // 使用 Windows Restart Manager API 强制关闭文件句柄
                final goFfi = GoDecryptFFI();
                final unlockError = goFfi.forceUnlockFile(file.decryptedPath);

                if (unlockError == null) {
                  await logger.info(
                    'DataManagementPage',
                    '文件解锁成功，等待500ms后重试删除',
                  );
                  await Future.delayed(const Duration(milliseconds: 500));

                  // 再次尝试删除
                  try {
                    await targetFile.delete();
                    deleteSucceeded = true;
                    await logger.info('DataManagementPage', '解锁后删除成功');
                  } catch (e) {
                    await logger.warning('DataManagementPage', '解锁后删除仍然失败: $e');
                  }
                } else {
                  await logger.warning(
                    'DataManagementPage',
                    '文件解锁失败: $unlockError',
                  );
                }
              } catch (e) {
                await logger.error('DataManagementPage', '强制解锁过程出错', e);
              }

              // 如果解锁后仍然无法删除，尝试重命名旧文件
              if (!deleteSucceeded && await targetFile.exists()) {
                await logger.warning(
                  'DataManagementPage',
                  '强制解锁后仍无法删除，尝试重命名旧文件',
                );
                final oldPath =
                    '${file.decryptedPath}.old.${DateTime.now().millisecondsSinceEpoch}';

                try {
                  await targetFile.rename(oldPath);
                  await logger.info(
                    'DataManagementPage',
                    '旧文件已重命名为: $oldPath（将在下次启动时清理）',
                  );
                } catch (e) {
                  await logger.error(
                    'DataManagementPage',
                    '重命名旧文件也失败，可能文件被严格锁定',
                    e,
                  );
                  // 即使重命名失败，也尝试复制新文件（可能会覆盖）
                }
              }
            }
          }

          await logger.info(
            'DataManagementPage',
            '复制新文件: $decryptedPath -> ${file.decryptedPath}',
          );
          try {
            await File(decryptedPath).copy(file.decryptedPath);
            await logger.info('DataManagementPage', '文件复制成功: ${file.fileName}');
          } catch (e) {
            await logger.error(
              'DataManagementPage',
              '文件复制失败: ${file.fileName}',
              e,
            );
            rethrow;
          }

          final newStat = await File(file.decryptedPath).stat();
          _lastProgressUpdateMap.remove(file.originalPath);
          _lastProgressValueMap.remove(file.originalPath);

          if (mounted) {
            setState(() {
              final index = _databaseFiles.indexWhere(
                (f) => f.originalPath == file.originalPath,
              );
              if (index != -1) {
                _databaseFiles[index].decryptProgress = 1.0;
                _getProgressNotifier(_databaseFiles[index]).value = 1.0;
                _databaseFiles[index] = _databaseFiles[index].copyWith(
                  decryptedModified: newStat.modified,
                );
              }
              _completedFiles++;
              _decryptResults[file.fileName] = true;
            });
          }

          Future.delayed(const Duration(milliseconds: 100), () async {
            try {
              await File(decryptedPath).delete();
            } catch (e) {
              /* 忽略删除错误 */
            }
          });
        } catch (e) {
          _lastProgressUpdateMap.remove(file.originalPath);
          _lastProgressValueMap.remove(file.originalPath);
          _decryptResults[file.fileName] = false;
        }
      }
      // -- 串行更新结束 --

      final successCount = _decryptResults.values.where((v) => v).length;
      final failCount = _decryptResults.values.where((v) => !v).length;

      // 等待文件系统完全释放文件句柄并刷新缓存
      await logger.info('DataManagementPage', '等待文件系统稳定...');
      await Future.delayed(const Duration(milliseconds: 2500));

      // 重新连接数据库（增加重试次数和延迟）
      if (mounted) {
        await logger.info('DataManagementPage', '开始重新连接数据库...');
        await context.read<AppState>().reconnectDatabase(
          retryCount: 5,
          retryDelay: 1500,
        );
        await logger.info('DataManagementPage', '数据库重新连接完成');
      }

      if (mounted) {
        _showMessage(
          '增量更新完成！成功: $successCount, 失败: $failCount',
          failCount == 0,
        );
      }

      // 手动刷新文件列表
      await _loadDatabaseFiles();
    } catch (e, stackTrace) {
      await logger.error('DataManagementPage', '增量更新失败', e, stackTrace);
      _showMessage('增量更新失败: $e', false);

      // 等待文件系统稳定
      await logger.info('DataManagementPage', '等待文件系统稳定...');
      await Future.delayed(const Duration(milliseconds: 2500));

      // 即使失败也要尝试重新连接数据库
      if (mounted) {
        try {
          await logger.info('DataManagementPage', '开始重新连接数据库...');
          await context.read<AppState>().reconnectDatabase(
            retryCount: 5,
            retryDelay: 1500,
          );
          await logger.info('DataManagementPage', '数据库重新连接完成');
        } catch (reconnectError) {
          await logger.error('DataManagementPage', '重新连接数据库失败', reconnectError);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDecrypting = false;
        });
      }
    }
  }

  /// 解密单个文件
  Future<void> _decryptSingle(DatabaseFile file) async {
    if (file.isDecrypted) {
      _showMessage('文件已经解密', true);
      return;
    }

    if (_isDecrypting) {
      _showMessage('正在批量解密中，请稍候', false);
      return;
    }

    if (!mounted) return;
    setState(() {
      _isDecrypting = true;
    });

    try {
      final key = await _configService.getDecryptKey();
      if (key == null || key.isEmpty) {
        _showMessage('请先在设置页面配置密钥', false);
        return;
      }

      // 先导航到当前页面，确保聊天页面不再使用数据库
      if (mounted) {
        context.read<AppState>().setCurrentPage('data_management');
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // 关闭数据库连接，避免文件占用
      if (mounted) {
        await context.read<AppState>().databaseService.close();
      }

      // Windows 需要更长时间释放文件句柄，等待 2500ms
      await Future.delayed(const Duration(milliseconds: 2500));

      final decryptedPath = await _decryptService.decryptDatabase(
        file.originalPath,
        key,
        (current, total) {
          if (total <= 0) return;
          _updateDecryptProgress(file, current / total);
        },
      );

      // 验证临时文件
      final tempFile = File(decryptedPath);
      if (!await tempFile.exists()) {
        throw Exception('临时解密文件不存在: $decryptedPath');
      }

      // 确保目标目录存在
      final targetFile = File(file.decryptedPath);
      final targetDir = targetFile.parent;
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      // 删除旧文件（如果存在，带重试机制）
      if (await targetFile.exists()) {
        for (int i = 0; i < 10; i++) {
          try {
            await targetFile.delete();
            break;
          } catch (e) {
            if (i < 9) {
              final delayMs = 300 * (i + 1);
              await Future.delayed(Duration(milliseconds: delayMs));
            } else {
              rethrow;
            }
          }
        }
      }

      // 复制到目标位置
      await File(decryptedPath).copy(file.decryptedPath);

      // 清理节流时间戳
      _lastProgressUpdateMap.remove(file.originalPath);
      _lastProgressValueMap.remove(file.originalPath);

      if (mounted) {
        setState(() {
          final index = _databaseFiles.indexWhere(
            (f) => f.originalPath == file.originalPath,
          );
          if (index != -1) {
            _databaseFiles[index].isDecrypted = true;
            _databaseFiles[index].decryptProgress = 1.0;
            _getProgressNotifier(_databaseFiles[index]).value = 1.0;
          }
        });

        // 等待文件系统完全释放文件句柄并刷新缓存
        await logger.info('DataManagementPage', '等待文件系统稳定...');
        await Future.delayed(const Duration(milliseconds: 2500));

        // 重新连接数据库（增加重试次数和延迟）
        await logger.info('DataManagementPage', '开始重新连接数据库...');
        await context.read<AppState>().reconnectDatabase(
          retryCount: 5,
          retryDelay: 1500,
        );
        await logger.info('DataManagementPage', '数据库重新连接完成');

        _showMessage('解密成功: ${file.fileName}', true);
      }

      // 异步清理临时文件（避免 Windows 文件句柄未释放的问题）
      Future.delayed(const Duration(milliseconds: 100), () async {
        try {
          await File(decryptedPath).delete();
        } catch (e) {
          // 忽略删除错误，临时目录会被系统自动清理
        }
      });
    } catch (e, stackTrace) {
      await logger.error(
        'DataManagementPage',
        '解密文件失败: ${file.fileName}',
        e,
        stackTrace,
      );
      _showMessage('解密失败: $e', false);
      // 清理节流时间戳
      _lastProgressUpdateMap.remove(file.originalPath);
      _lastProgressValueMap.remove(file.originalPath);

      // 等待文件系统稳定
      await logger.info('DataManagementPage', '等待文件系统稳定...');
      await Future.delayed(const Duration(milliseconds: 2500));

      // 即使失败也要尝试重新连接数据库
      if (mounted) {
        try {
          await logger.info('DataManagementPage', '开始重新连接数据库...');
          await context.read<AppState>().reconnectDatabase(
            retryCount: 5,
            retryDelay: 1500,
          );
          await logger.info('DataManagementPage', '数据库重新连接完成');
        } catch (reconnectError) {
          await logger.error('DataManagementPage', '重新连接数据库失败', reconnectError);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDecrypting = false;
        });
      }
    }
  }

  void _showMessage(String message, bool success) {
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
      _isSuccess = success;
    });

    // 3秒后清除消息
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _statusMessage = null;
        });
      }
    });
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  // ========== 图片解密相关方法 ==========

  /// 触发重新扫描图片
  void _refreshImageFiles() {
    final appState = context.read<AppState>();
    appState.startImageScan(forceRescan: true);
  }

  /// 获取图片质量统计信息（使用 AppState 中的数据）
  Future<String> _getImageQualityStats() async {
    final appState = context.read<AppState>();
    final imageFiles = appState.imageFiles;
    if (imageFiles.isEmpty) return '';

    final originalCount = imageFiles.where((f) => f.imageQuality == 'original').length;
    final thumbnailCount = imageFiles.where((f) => f.imageQuality == 'thumbnail').length;
    final unknownCount = imageFiles.where((f) => f.imageQuality == 'unknown').length;

    return '原图: $originalCount • 缩略图: $thumbnailCount${unknownCount > 0 ? ' • 未知: $unknownCount' : ''}';
  }

  String _buildImageDecryptedPath(String documentsPath, ImageFileInfo imageFile) {
    final appState = context.read<AppState>();
    final outputRelativePath = appState.imageDisplayNameCache.isEmpty
        ? imageFile.relativePath
        : imageFile.relativePath; // 已经在扫描时处理过了
    final outputDir = Directory(
      '$documentsPath${Platform.pathSeparator}EchoTrace${Platform.pathSeparator}Images',
    );
    return '${outputDir.path}$outputRelativePath'.replaceAll('.dat', '.jpg');
  }

  /// 批量解密图片
  Future<void> _decryptAllImages() async {
    if (!mounted) return;
    final appState = context.read<AppState>();
    setState(() {
      _isDecryptingImages = true;
      _currentDecryptingImage = '初始化解密线程…';
      _totalImageFiles = 0;
      _completedImageFiles = 0;
    });

    // 应用当前筛选条件获取需要解密的图片列表
    List<ImageFileInfo> filteredFiles = appState.imageFiles.toList();

    // 应用质量过滤
    if (_imageQualityFilter != 'all') {
      filteredFiles = filteredFiles
          .where((f) => f.imageQuality == _imageQualityFilter)
          .toList();
    }

    // 应用文件名搜索
    if (_imageNameQuery.trim().isNotEmpty) {
      final query = _imageNameQuery.trim().toLowerCase();
      filteredFiles = filteredFiles.where((f) {
        return f.fileName.toLowerCase().contains(query) ||
            f.relativePath.toLowerCase().contains(query);
      }).toList();
    }

    // 应用解密状态过滤
    if (_showOnlyUndecrypted) {
      filteredFiles = filteredFiles.where((f) => !f.isDecrypted).toList();
    }

    if (filteredFiles.isEmpty) {
      _showImageMessage('当前筛选条件下没有需要解密的图片文件', false);
      if (mounted) {
        setState(() {
          _isDecryptingImages = false;
          _currentDecryptingImage = '';
        });
      }
      return;
    }

    // 检查密钥配置
    final xorKeyHex = await _configService.getImageXorKey();
    final aesKeyHex = await _configService.getImageAesKey();

    if (xorKeyHex == null || xorKeyHex.isEmpty) {
      _showImageMessage('未配置图片解密密钥，请在设置中配置 XOR 和 AES 密钥', false);
      if (mounted) {
        setState(() {
          _isDecryptingImages = false;
          _currentDecryptingImage = '';
        });
      }
      return;
    }

    try {
      final xorKey = ImageDecryptService.hexToXorKey(xorKeyHex);
      Uint8List? aesKey;

      if (aesKeyHex != null && aesKeyHex.isNotEmpty && aesKeyHex.length >= 16) {
        aesKey = ImageDecryptService.hexToBytes16(aesKeyHex);
      }

      // 直接根据扫描时的 isDecrypted 状态过滤，不再重复检查文件是否存在
      final documentsPath =
          (await getApplicationDocumentsDirectory()).path;
      final pendingFiles = filteredFiles.where((f) => !f.isDecrypted).toList();

      if (pendingFiles.isEmpty) {
        _showImageMessage('当前筛选条件下的图片均已解密', true);
        if (mounted) {
          setState(() {
            _isDecryptingImages = false;
            _currentDecryptingImage = '';
          });
        }
        return;
      }

      final cpu = CpuInfo.logicalProcessors;
      final concurrency = math.max(2, math.min(8, cpu));
      final wxid = await _configService.getManualWxid();
      final token = appState.tryStartBulkJob(
        sessionUsername:
            (wxid != null && wxid.isNotEmpty) ? wxid : 'data_management',
        typeLabel: '图片批量解密',
        poolSize: concurrency,
      );
      if (token == null) {
        _showImageMessage('已有批量任务进行中，请等待完成', false);
        if (mounted) {
          setState(() {
            _isDecryptingImages = false;
            _currentDecryptingImage = '';
          });
        }
        return;
      }

      setState(() {
        _totalImageFiles = pendingFiles.length;
        _completedImageFiles = 0;
        _imageDecryptResults.clear();
        _currentDecryptingImage = '准备解密…';
      });

      Timer? uiTimer;
      var done = 0;
      var successCount = 0;
      var failCount = 0;
      String? lastFile;

      try {
        final pool = await token.poolFuture;
        _imageDecryptService.bulkPool = pool;

        uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
          if (!mounted) return;
          setState(() {
            _completedImageFiles = done;
            final name = lastFile;
            _currentDecryptingImage = name == null
                ? '解密中（并行 $concurrency/$cpu）'
                : '$name（并行 $concurrency/$cpu）';
          });
        });

        final sem = _AsyncSemaphore(concurrency);
        final futures = <Future<void>>[];
        for (final imageFile in pendingFiles) {
          await sem.acquire();
          futures.add(() async {
            lastFile = imageFile.fileName;
            try {
              final outputPath = _buildImageDecryptedPath(
                documentsPath,
                imageFile,
              );
              final outputFile = File(outputPath);
              final outputDir = outputFile.parent;
              if (!await outputDir.exists()) {
                await outputDir.create(recursive: true);
              }

              await _imageDecryptService.decryptDatAutoAsync(
                imageFile.originalPath,
                outputPath,
                xorKey,
                aesKey,
              );

              imageFile.isDecrypted = true;
              _imageDecryptResults[imageFile.fileName] = true;
              successCount++;

              await logger.info(
                'DataManagementPage',
                '图片解密成功: ${imageFile.fileName}',
              );
            } catch (e) {
              _imageDecryptResults[imageFile.fileName] = false;
              failCount++;
              await logger.error(
                'DataManagementPage',
                '图片解密失败: ${imageFile.fileName}',
                e,
              );
            } finally {
              done += 1;
              sem.release();
            }
          }());
        }
        await Future.wait(futures);

        if (mounted) {
          setState(() {
            _completedImageFiles = done;
          });
        }

        _showImageMessage(
          '图片解密完成！成功: $successCount, 失败: $failCount',
          failCount == 0,
        );
      } catch (e, stackTrace) {
        await logger.error('DataManagementPage', '批量解密图片失败', e, stackTrace);
        _showImageMessage('批量解密失败: $e', false);
      } finally {
        uiTimer?.cancel();
        _imageDecryptService.bulkPool = null;
        await appState.endBulkJob(token);
        if (mounted) {
          setState(() {
            _isDecryptingImages = false;
            _currentDecryptingImage = '';
            if (_totalImageFiles > 0) {
              _completedImageFiles =
                  math.min(_completedImageFiles, _totalImageFiles);
            }
          });
        }
        _lastProgressUpdateMap.remove('images');
        _lastProgressValueMap.remove('images');
      }
    } catch (e, stackTrace) {
      await logger.error('DataManagementPage', '批量解密图片失败', e, stackTrace);
      _showImageMessage('批量解密失败: $e', false);
    }
  }

  /// 解密单个图片
  Future<void> _decryptSingleImage(ImageFileInfo imageFile) async {
    if (!mounted) return;
    final appState = context.read<AppState>();
    setState(() {
      _isDecryptingImages = true;
      _currentDecryptingImage = imageFile.fileName;
      _totalImageFiles = 1;
      _completedImageFiles = 0;
    });

    // 检查密钥配置
    final xorKeyHex = await _configService.getImageXorKey();
    final aesKeyHex = await _configService.getImageAesKey();

    if (xorKeyHex == null || xorKeyHex.isEmpty) {
      _showImageMessage('未配置图片解密密钥', false);
      if (mounted) {
        setState(() {
          _isDecryptingImages = false;
          _currentDecryptingImage = '';
        });
      }
      return;
    }

    try {
      final xorKey = ImageDecryptService.hexToXorKey(xorKeyHex);
      Uint8List? aesKey;

      if (aesKeyHex != null && aesKeyHex.isNotEmpty && aesKeyHex.length >= 16) {
        aesKey = ImageDecryptService.hexToBytes16(aesKeyHex);
      }

      final documentsPath = (await getApplicationDocumentsDirectory()).path;
      final outputPath = _buildImageDecryptedPath(
        documentsPath,
        imageFile,
      );

      // 创建输出目录
      final outputFile = File(outputPath);
      final outputDir = outputFile.parent;
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }

      // 解密（使用异步方法确保数据完整性）
      await _imageDecryptService.decryptDatAutoAsync(
        imageFile.originalPath,
        outputPath,
        xorKey,
        aesKey,
      );

      imageFile.isDecrypted = true;
      appState.updateImageDecryptedStatus(imageFile.originalPath, true);
      setState(() {
        _completedImageFiles = 1;
      });

      _showImageMessage('解密成功: ${imageFile.fileName}', true);
      await logger.info('DataManagementPage', '图片解密成功: ${imageFile.fileName}');
    } catch (e, stackTrace) {
      await logger.error(
        'DataManagementPage',
        '解密失败: ${imageFile.fileName}',
        e,
        stackTrace,
      );
      _showImageMessage('解密失败: $e', false);
    } finally {
      if (mounted) {
        setState(() {
          _isDecryptingImages = false;
          _currentDecryptingImage = '';
        });
      }
    }
  }

  void _showImageMessage(String message, bool success) {
    if (!mounted) return;
    setState(() {
      _imageStatusMessage = message;
      _isImageSuccess = success;
    });

    // 3秒后清除消息
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _imageStatusMessage = null;
        });
      }
    });
  }

  void _syncProgressNotifiers() {
    final activeKeys =
        _databaseFiles.map((file) => file.originalPath).toSet();
    final staleKeys = _progressNotifiers.keys
        .where((key) => !activeKeys.contains(key))
        .toList();
    for (final key in staleKeys) {
      _progressNotifiers[key]?.dispose();
      _progressNotifiers.remove(key);
    }
    for (final file in _databaseFiles) {
      _progressNotifiers.putIfAbsent(
        file.originalPath,
        () => ValueNotifier<double>(file.decryptProgress),
      );
    }
  }

  ValueNotifier<double> _getProgressNotifier(DatabaseFile file) {
    return _progressNotifiers.putIfAbsent(
      file.originalPath,
      () => ValueNotifier<double>(file.decryptProgress),
    );
  }

  bool _shouldUpdateProgress(String key, double progress) {
    final now = DateTime.now();
    final lastTime = _lastProgressUpdateMap[key];
    final lastValue = _lastProgressValueMap[key];
    final valueChanged =
        lastValue == null || (progress - lastValue).abs() >= 0.01;
    final timeElapsed =
        lastTime == null || now.difference(lastTime).inMilliseconds >= 200;
    final forceUpdate = progress >= 1.0;

    if ((valueChanged && timeElapsed) || forceUpdate) {
      _lastProgressUpdateMap[key] = now;
      _lastProgressValueMap[key] = progress;
      return true;
    }
    return false;
  }

  void _updateDecryptProgress(DatabaseFile file, double progress) {
    if (!_shouldUpdateProgress(file.originalPath, progress)) return;
    file.decryptProgress = progress;
    _getProgressNotifier(file).value = progress;
  }

  void _switchSection(String section) {
    if (_currentSection == section) return;
    setState(() {
      _currentSection = section;
    });
    _sectionNavigatorKey.currentState
        ?.pushReplacementNamed('/$section');
  }

  Widget _buildSectionSwitcher() {
    final surfaceTone = Theme.of(context)
        .colorScheme
        .surface
        .withValues(alpha: 0.7);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: surfaceTone,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SectionTab(
            label: '数据库',
            isSelected: _currentSection == 'database',
            onTap: () => _switchSection('database'),
            surfaceColor: _surfaceColor,
            borderColor: _borderColor,
            accentColor: _primaryColor,
          ),
          _SectionTab(
            label: '图片',
            isSelected: _currentSection == 'images',
            onTap: () => _switchSection('images'),
            surfaceColor: _surfaceColor,
            borderColor: _borderColor,
            accentColor: _primaryColor,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _surfaceColor,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _borderColor),
              ),
              child: Icon(icon, size: 40, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade600,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBanner({
    required String message,
    required bool success,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: success
            ? _primaryColor.withValues(alpha: 0.08)
            : Colors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: success
              ? _primaryColor.withValues(alpha: 0.25)
              : Colors.red.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: Icon(
              success ? Icons.check_circle_rounded : Icons.error_rounded,
              key: ValueKey<bool>(success),
              color: success ? _primaryColor : Colors.red,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final slide = Tween<Offset>(
                  begin: const Offset(0, 0.2),
                  end: Offset.zero,
                ).animate(animation);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(position: slide, child: child),
                );
              },
              child: Text(
                message,
                key: ValueKey<String>(message),
                style: TextStyle(
                  color: success ? _primaryColor : Colors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnimatedStatus(Widget child, {required String keyValue}) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1,
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      child: KeyedSubtree(key: ValueKey<String>(keyValue), child: child),
    );
  }

  Widget _buildRitualProgressCard({
    required String title,
    required String message,
    required double progress,
    required int completed,
    required int total,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _primaryColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _primaryColor.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: Text(
                        title,
                        key: ValueKey<String>('title-$title'),
                        style: TextStyle(
                          color: _primaryColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) {
                        final slide = Tween<Offset>(
                          begin: const Offset(0, 0.15),
                          end: Offset.zero,
                        ).animate(animation);
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(position: slide, child: child),
                        );
                      },
                      child: Text(
                        message,
                        key: ValueKey<String>('message-$message'),
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '${(progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  color: _primaryColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _SmoothLinearProgress(
              value: progress,
              minHeight: 6,
              backgroundColor: _primaryColor.withValues(alpha: 0.15),
              valueColor: _primaryColor,
              duration: const Duration(milliseconds: 520),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$completed / $total',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 12,
                ),
              ),
              Text(
                '剩余 ${total - completed}',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 42,
                              height: 42,
                              child: Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: _primaryColor.withValues(
                                    alpha: 0.1,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  _currentSection == 'database'
                                      ? Icons.storage_rounded
                                      : Icons.photo_library_outlined,
                                  size: 22,
                                  color: _primaryColor,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            SizedBox(
                              height: 42,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: AnimatedSwitcher(
                                  duration: const Duration(
                                    milliseconds: 160,
                                  ),
                                  switchInCurve: Curves.easeOutCubic,
                                  switchOutCurve: Curves.easeInCubic,
                                  transitionBuilder: (child, animation) {
                                    final slide = Tween<Offset>(
                                      begin: const Offset(0, 0.1),
                                      end: Offset.zero,
                                    ).animate(animation);
                                    return FadeTransition(
                                      opacity: animation,
                                      child: SlideTransition(
                                        position: slide,
                                        child: child,
                                      ),
                                    );
                                  },
                                  child: Text(
                                    _currentSection == 'database'
                                        ? '数据库解密'
                                        : '图片解密',
                                    key: ValueKey<String>(
                                      'title-$_currentSection',
                                    ),
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 22,
                                          letterSpacing: -0.5,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _buildSectionSwitcher(),
                ],
              ),
            ),
            Divider(height: 1, color: _borderColor),
            Expanded(
              child: Navigator(
                key: _sectionNavigatorKey,
                initialRoute: '/database',
                onGenerateRoute: (settings) {
                  switch (settings.name) {
                    case '/images':
                      return PageRouteBuilder(
                        settings: settings,
                        transitionDuration: const Duration(milliseconds: 220),
                        reverseTransitionDuration: Duration.zero,
                        pageBuilder: (_, __, ___) => _buildImageSection(),
                        transitionsBuilder: (_, animation, __, child) {
                          return FadeTransition(
                            opacity: CurvedAnimation(
                              parent: animation,
                              curve: Curves.easeInOut,
                            ),
                            child: ColoredBox(
                              color:
                                  Theme.of(context).scaffoldBackgroundColor,
                              child: ClipRect(child: child),
                            ),
                          );
                        },
                      );
                    case '/database':
                    default:
                      return PageRouteBuilder(
                        settings: settings,
                        transitionDuration: const Duration(milliseconds: 220),
                        reverseTransitionDuration: Duration.zero,
                        pageBuilder: (_, __, ___) => _buildDatabaseSection(),
                        transitionsBuilder: (_, animation, __, child) {
                          return FadeTransition(
                            opacity: CurvedAnimation(
                              parent: animation,
                              curve: Curves.easeInOut,
                            ),
                            child: ColoredBox(
                              color:
                                  Theme.of(context).scaffoldBackgroundColor,
                              child: ClipRect(child: child),
                            ),
                          );
                        },
                      );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建数据库解密页面
  Widget _buildDatabaseSection() {
    final needsUpdateCount =
        _databaseFiles.where((f) => f.needsUpdate).length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _isLoading
                      ? '正在扫描数据库...'
                      : '已找到 ${_databaseFiles.length} 个数据库',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (needsUpdateCount > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: ElevatedButton.icon(
                    onPressed: (_isLoading || _isDecrypting)
                        ? null
                        : _updateChanged,
                    icon: const Icon(Icons.update, size: 18),
                    label: Text('增量更新 ($needsUpdateCount)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _updateColor,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
              ElevatedButton.icon(
                onPressed: (_isLoading || _isDecrypting)
                    ? null
                    : _decryptAllPending,
                icon: _isDecrypting
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: _totalFiles > 0
                              ? _completedFiles / _totalFiles
                              : null,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.lock_open_rounded, size: 18),
                label: Text(_isDecrypting ? '解密中...' : '批量解密'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryColor,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _isLoading && _databaseFiles.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _databaseFiles.isEmpty
                  ? _buildEmptyState(
                      icon: Icons.folder_open_rounded,
                      title: '未找到数据库文件',
                      subtitle: '请检查微信数据目录设置是否正确',
                    )
                  : Column(
                      children: [
                        _buildAnimatedStatus(
                          _isDecrypting
                              ? _buildRitualProgressCard(
                                  title: '正在解密',
                                  message: _currentDecryptingFile,
                                  progress: _totalFiles > 0
                                      ? _completedFiles / _totalFiles
                                      : 0,
                                  completed: _completedFiles,
                                  total: _totalFiles,
                                )
                              : const SizedBox.shrink(),
                          keyValue: _isDecrypting ? 'db-progress' : 'db-empty',
                        ),
                        _buildAnimatedStatus(
                          _statusMessage != null
                              ? _buildStatusBanner(
                                  message: _statusMessage!,
                                  success: _isSuccess,
                                )
                              : const SizedBox.shrink(),
                          keyValue: _statusMessage == null
                              ? 'db-status-empty'
                              : 'db-status-${_statusMessage!}',
                        ),
                        Expanded(
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(
                              20,
                              8,
                              20,
                              20,
                            ),
                            itemCount: _databaseFiles.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final file = _databaseFiles[index];
                              return _buildFileCard(file);
                            },
                          ),
                        ),
                      ],
                    ),
        ),
      ],
    );
  }

  Widget _buildFileCard(DatabaseFile file) {
    final progressNotifier = _getProgressNotifier(file);
    return Container(
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: file.isDecrypted
              ? _primaryColor.withValues(alpha: 0.2)
              : _borderColor,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: file.isDecrypted
                    ? _primaryColor.withValues(alpha: 0.12)
                    : Colors.grey.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                file.isDecrypted
                    ? Icons.check_circle_rounded
                    : Icons.storage_rounded,
                color: file.isDecrypted ? _primaryColor : Colors.grey.shade600,
                size: 22,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.fileName,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '账号: ${file.wxidName}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey.shade600,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '大小: ${_formatFileSize(file.fileSize)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey.shade600,
                        ),
                  ),
                  ValueListenableBuilder<double>(
                    valueListenable: progressNotifier,
                    builder: (context, progress, _) {
                      if (progress <= 0 || progress >= 1) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: _SmoothLinearProgress(
                                  value: progress,
                                  minHeight: 5,
                                  backgroundColor:
                                      _primaryColor.withValues(alpha: 0.15),
                                  valueColor: _primaryColor,
                                  duration: const Duration(milliseconds: 420),
                                ),
                              ),
                            const SizedBox(height: 6),
                            Text(
                              '解密中 ${(progress * 100).toStringAsFixed(0)}%',
                              style: TextStyle(
                                fontSize: 11,
                                color: _primaryColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: file.isDecrypted
                            ? _primaryColor.withValues(alpha: 0.12)
                            : _tertiaryColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        file.isDecrypted ? '已解密' : '未解密',
                        style: TextStyle(
                          color:
                              file.isDecrypted ? _primaryColor : _tertiaryColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (file.needsUpdate) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _updateColor.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _updateColor.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.update,
                              size: 12,
                              color: _updateColor,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '有更新',
                              style: TextStyle(
                                color: _updateColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                if (!file.isDecrypted)
                  ValueListenableBuilder<double>(
                    valueListenable: progressNotifier,
                    builder: (context, progress, _) {
                      final isBusy = _isDecrypting && progress > 0;
                      return OutlinedButton(
                        onPressed:
                            (_isLoading || (_isDecrypting && progress == 0))
                                ? null
                                : () => _decryptSingle(file),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _primaryColor,
                          side: BorderSide(
                            color: _primaryColor.withValues(alpha: 0.4),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                        ),
                        child: Text(isBusy
                            ? '${(progress * 100).toStringAsFixed(0)}%'
                            : '解密'),
                      );
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 构建图片解密页面
  Widget _buildImageSection() {
    final appState = context.watch<AppState>();
    final isLoadingImages = appState.isLoadingImages;
    final imageFiles = appState.imageFiles;
    
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: FutureBuilder<String>(
                  future: _getImageQualityStats(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const SizedBox.shrink();
                    }
                    return Text(
                      snapshot.data!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    );
                  },
                ),
              ),
              OutlinedButton.icon(
                onPressed: (isLoadingImages || _isDecryptingImages)
                    ? null
                    : _refreshImageFiles,
                icon: isLoadingImages
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _primaryColor,
                        ),
                      )
                    : const Icon(Icons.refresh_rounded, size: 18),
                label: Text(isLoadingImages ? '扫描中' : '刷新'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _primaryColor,
                  side: BorderSide(
                    color: _primaryColor.withValues(alpha: 0.4),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                onPressed:
                    (isLoadingImages ||
                            _isDecryptingImages ||
                            imageFiles.isEmpty)
                        ? null
                        : _decryptAllImages,
                icon: _isDecryptingImages
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                          value: _totalImageFiles > 0
                              ? _completedImageFiles / _totalImageFiles
                              : null,
                        ),
                      )
                    : const Icon(Icons.lock_open_rounded, size: 18),
                label: Text(_isDecryptingImages ? '解密中...' : '批量解密'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryColor,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                ),
              ),
            ],
          ),
        ),

        // 列表区域
        Expanded(
          child: isLoadingImages && imageFiles.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 60,
                        height: 60,
                        child: CircularProgressIndicator(
                          strokeWidth: 4,
                          color: _primaryColor,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        '正在扫描图片文件...',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: _primaryColor,
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                      if (imageFiles.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '已找到 ${imageFiles.length} 个文件',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: _primaryColor,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        '这可能需要一些时间，请稍候',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                )
              : imageFiles.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: _surfaceColor,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: _borderColor),
                          ),
                          child: Icon(
                            Icons.image_not_supported,
                            size: 36,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '未找到图片文件',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: Colors.grey.shade800,
                              ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: _surfaceColor,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _borderColor,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.help_outline,
                                    size: 20,
                                    color: _primaryColor,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '可能的原因',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          color: _primaryColor,
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '1. 微信图片目录为空\n'
                                '2. 配置的路径不正确（应选择wxid目录或db_storage的父目录）\n'
                                '3. 图片文件不在常见位置（FileStorage/Image 或 Msg/attach）\n\n'
                                '💡 建议：点击刷新按钮重新扫描，或在设置中重新选择微信数据目录',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Colors.grey.shade600,
                                      height: 1.5,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: _refreshImageFiles,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重新扫描'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    _buildAnimatedStatus(
                      _isDecryptingImages
                          ? _buildRitualProgressCard(
                              title: '正在解密图片',
                              message: _currentDecryptingImage,
                              progress: _totalImageFiles > 0
                                  ? _completedImageFiles / _totalImageFiles
                                  : 0,
                              completed: _completedImageFiles,
                              total: _totalImageFiles,
                            )
                          : const SizedBox.shrink(),
                      keyValue:
                          _isDecryptingImages ? 'img-progress' : 'img-empty',
                    ),
                    _buildAnimatedStatus(
                      _imageStatusMessage != null
                          ? _buildStatusBanner(
                              message: _imageStatusMessage!,
                              success: _isImageSuccess,
                            )
                          : const SizedBox.shrink(),
                      keyValue: _imageStatusMessage == null
                          ? 'img-status-empty'
                          : 'img-status-${_imageStatusMessage!}',
                    ),

                    // 图片列表
                    Expanded(child: _buildImageList()),
                  ],
                ),
        ),
      ],
    );
  }

  /// 构建图片列表（带过滤和分页）
  Widget _buildImageList() {
    final appState = context.watch<AppState>();
    final isLoadingImages = appState.isLoadingImages;
    final imageFiles = appState.imageFiles;
    final scannedDecryptedCount = appState.scannedDecryptedCount;
    
    // 应用过滤
    List<ImageFileInfo> filteredFiles = imageFiles.toList();

    // 应用质量过滤
    if (_imageQualityFilter != 'all') {
      filteredFiles = filteredFiles
          .where((f) => f.imageQuality == _imageQualityFilter)
          .toList();
    }

    // 应用文件名搜索
    if (_imageNameQuery.trim().isNotEmpty) {
      final query = _imageNameQuery.trim().toLowerCase();
      filteredFiles = filteredFiles.where((f) {
        return f.fileName.toLowerCase().contains(query) ||
            f.relativePath.toLowerCase().contains(query);
      }).toList();
    }

    // 应用解密状态过滤
    if (_showOnlyUndecrypted) {
      filteredFiles = filteredFiles.where((f) => !f.isDecrypted).toList();
    }

    // 应用显示限制
    _lastImageFilteredCount = filteredFiles.length;
    final displayFiles = filteredFiles.take(_displayLimit).toList();

    return Column(
      children: [
        // 过滤和统计信息栏
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _surfaceColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _borderColor),
          ),
          child: Column(
            children: [
              // 第一行：解密状态过滤
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: _showOnlyUndecrypted,
                            onChanged: (value) {
                              setState(() {
                                _showOnlyUndecrypted = value;
                                _resetImageListLimit();
                              });
                            },
                            activeColor: _primaryColor,
                            activeTrackColor:
                                _primaryColor.withValues(alpha: 0.25),
                            inactiveThumbColor: Colors.grey.shade400,
                            inactiveTrackColor:
                                Colors.grey.shade300.withValues(alpha: 0.6),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '只显示未解密',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 统计标签：已解密/总数
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _surfaceColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _borderColor),
                    ),
                    child: Text(
                      isLoadingImages
                          ? '$scannedDecryptedCount/${imageFiles.length}'
                          : '${filteredFiles.where((f) => f.isDecrypted).length}/${filteredFiles.length}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _primaryColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 第二行：图片质量过滤
              Row(
                children: [
                  Text(
                    '质量:',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 质量过滤按钮组
                  ...['all', 'original', 'thumbnail'].map((quality) {
                    final isSelected = _imageQualityFilter == quality;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Material(
                        color: isSelected
                            ? _primaryColor.withValues(alpha: 0.12)
                            : _surfaceColor,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              _imageQualityFilter = quality;
                              _resetImageListLimit();
                            });
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected
                                    ? _primaryColor.withValues(alpha: 0.5)
                                    : _borderColor,
                                width: 1,
                              ),
                            ),
                            child: Text(
                              quality == 'all'
                                  ? '全部'
                                  : quality == 'original'
                                  ? '原图'
                                  : '缩略图',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isSelected
                                    ? _primaryColor
                                    : Colors.grey.shade700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
              const SizedBox(height: 12),
              // 第三行：文件名搜索
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _imageSearchController,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: '按文件名搜索',
                        hintText: '输入文件名或路径片段',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: _imageNameQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  setState(() {
                                    _imageNameQuery = '';
                                    _imageSearchController.clear();
                                    _resetImageListLimit();
                                  });
                                },
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: _borderColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: _primaryColor),
                        ),
                        filled: true,
                        fillColor: _surfaceColor,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      onChanged: (value) {
                        setState(() {
                          _imageNameQuery = value;
                          _resetImageListLimit();
                        });
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // 文件列表
        Expanded(
          child: displayFiles.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: _surfaceColor,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: _borderColor),
                        ),
                        child: Icon(
                          _showOnlyUndecrypted
                              ? Icons.done_all_rounded
                              : Icons.image_search_rounded,
                          size: 48,
                          color: Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _showOnlyUndecrypted ? '所有文件都已解密' : '没有图片文件',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _showOnlyUndecrypted
                            ? '可以关闭过滤查看全部文件'
                            : _imageQualityFilter == 'original'
                            ? '未找到原图文件，尝试选择"全部"查看所有图片'
                            : '点击刷新按钮重新扫描，或检查微信数据目录是否正确',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _imageListController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  physics: const BouncingScrollPhysics(),
                  itemCount: displayFiles.length,
                  itemBuilder: (context, index) {
                    final imageFile = displayFiles[index];
                    return _buildImageCard(imageFile);
                  },
                ),
        ),
      ],
    );
  }

  /// 构建图片文件卡片
  Widget _buildImageCard(ImageFileInfo imageFile) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: imageFile.isDecrypted
              ? _primaryColor.withValues(alpha: 0.2)
              : _borderColor,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: imageFile.isDecrypted
              ? null
              : (_isDecryptingImages
                    ? null
                    : () => _decryptSingleImage(imageFile)),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // 状态图标
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: imageFile.isDecrypted
                        ? _primaryColor.withValues(alpha: 0.12)
                        : Colors.grey.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    imageFile.isDecrypted
                        ? Icons.check_circle_rounded
                        : Icons.image_outlined,
                    color: imageFile.isDecrypted
                        ? _primaryColor
                        : Colors.grey.shade500,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 14),

                // 文件信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // 质量标签
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: imageFile.imageQuality == 'original'
                                  ? _primaryColor.withValues(alpha: 0.12)
                                  : _tertiaryColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              imageFile.imageQuality == 'original'
                                  ? '原图'
                                  : '缩略图',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: imageFile.imageQuality == 'original'
                                    ? _primaryColor
                                    : _tertiaryColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 文件名
                          Expanded(
                            child: Text(
                              imageFile.fileName,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Colors.grey.shade800,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_formatFileSize(imageFile.fileSize)} • V${imageFile.version == 0 ? 3 : 4}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ),

                // 状态或操作按钮
                if (imageFile.isDecrypted)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _primaryColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '已解密',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _primaryColor,
                      ),
                    ),
                  )
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.grey.shade400,
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTab extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final Color surfaceColor;
  final Color borderColor;
  final Color accentColor;

  const _SectionTab({
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.surfaceColor,
    required this.borderColor,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? surfaceColor : null,
          borderRadius: BorderRadius.circular(12),
          border: isSelected
              ? Border.all(
                  color: borderColor,
                )
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isSelected
                ? accentColor
                : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }
}

class _SmoothLinearProgress extends StatefulWidget {
  final double value;
  final double minHeight;
  final Color backgroundColor;
  final Color valueColor;
  final Duration duration;
  final Curve curve;

  const _SmoothLinearProgress({
    required this.value,
    required this.minHeight,
    required this.backgroundColor,
    required this.valueColor,
    this.duration = const Duration(milliseconds: 420),
    // ignore: unused_element_parameter
    this.curve = Curves.easeOutCubic,
  });

  @override
  State<_SmoothLinearProgress> createState() => _SmoothLinearProgressState();
}

class _SmoothLinearProgressState extends State<_SmoothLinearProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _animation;
  late double _currentValue;

  @override
  void initState() {
    super.initState();
    _currentValue = _clamp(widget.value);
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    _animation = AlwaysStoppedAnimation<double>(_currentValue);
  }

  @override
  void didUpdateWidget(covariant _SmoothLinearProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    final nextValue = _clamp(widget.value);
    if (nextValue != _currentValue) {
      _animateTo(nextValue);
    }
  }

  double _clamp(double value) => value.clamp(0.0, 1.0);

  void _animateTo(double target) {
    _controller.stop();
    _animation = Tween<double>(
      begin: _currentValue,
      end: target,
    ).animate(
      CurvedAnimation(parent: _controller, curve: widget.curve),
    )..addListener(() {
        setState(() {
          _currentValue = _animation.value;
        });
      });
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LinearProgressIndicator(
      value: _currentValue,
      minHeight: widget.minHeight,
      backgroundColor: widget.backgroundColor,
      valueColor: AlwaysStoppedAnimation<Color>(widget.valueColor),
    );
  }
}

/// 数据库文件信息
class DatabaseFile {
  final String originalPath;
  final String fileName;
  final int fileSize;
  final String wxidName;
  bool isDecrypted;
  final String decryptedPath;

  // 并行解密进度
  double decryptProgress;

  // 增量更新相关
  final DateTime? originalModified; // 源文件修改时间
  final DateTime? decryptedModified; // 备份文件修改时间

  /// 是否需要更新（源文件比备份文件新）
  bool get needsUpdate {
    if (!isDecrypted) return false;
    if (originalModified == null || decryptedModified == null) return false;
    return originalModified!.isAfter(decryptedModified!);
  }

  DatabaseFile({
    required this.originalPath,
    required this.fileName,
    required this.fileSize,
    required this.wxidName,
    required this.isDecrypted,
    required this.decryptedPath,
    this.decryptProgress = 0.0,
    this.originalModified,
    this.decryptedModified,
  });

  DatabaseFile copyWith({
    String? originalPath,
    String? fileName,
    int? fileSize,
    String? wxidName,
    bool? isDecrypted,
    String? decryptedPath,
    double? decryptProgress,
    DateTime? originalModified,
    DateTime? decryptedModified,
  }) {
    return DatabaseFile(
      originalPath: originalPath ?? this.originalPath,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      wxidName: wxidName ?? this.wxidName,
      isDecrypted: isDecrypted ?? this.isDecrypted,
      decryptedPath: decryptedPath ?? this.decryptedPath,
      decryptProgress: decryptProgress ?? this.decryptProgress,
      originalModified: originalModified ?? this.originalModified,
      decryptedModified: decryptedModified ?? this.decryptedModified,
    );
  }
}
