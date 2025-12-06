import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../providers/app_state.dart';
import '../services/config_service.dart';
import '../services/decrypt_service.dart';
import '../services/image_decrypt_service.dart';
import '../services/logger_service.dart';
import '../services/go_decrypt_ffi.dart';

/// 数据管理页面
class DataManagementPage extends StatefulWidget {
  const DataManagementPage({super.key});

  @override
  State<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends State<DataManagementPage>
    with SingleTickerProviderStateMixin {
  final ConfigService _configService = ConfigService();
  late final DecryptService _decryptService;
  late final ImageDecryptService _imageDecryptService;
  late final TabController _tabController;

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

  // 单个文件解密进度
  final int _currentFilePages = 0;
  final int _totalFilePages = 0;

  // 进度节流相关
  final Map<String, DateTime> _lastProgressUpdateMap = {}; // 每个文件独立的节流时间戳

  // 图片文件相关
  final List<ImageFile> _imageFiles = [];
  bool _isLoadingImages = false;
  String? _imageStatusMessage;
  bool _isImageSuccess = false;
  bool _showOnlyUndecrypted = false; // 只显示未解密的文件
  int _displayLimit = 1000; // 默认显示前1000条
  String _imageQualityFilter = 'all'; // 'all', 'original', 'thumbnail' - 图片质量过滤

  // 图片解密进度相关
  bool _isDecryptingImages = false;
  int _totalImageFiles = 0;
  int _completedImageFiles = 0;
  String _currentDecryptingImage = '';
  final Map<String, bool> _imageDecryptResults = {}; // 记录每个图片的解密结果
  final Map<String, String> _tableDisplayNameCache = {}; // Msg表哈希 -> 显示名

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _decryptService = DecryptService();
    _decryptService.initialize();
    _imageDecryptService = ImageDecryptService();
    _loadDatabaseFiles();
    _loadImageFiles();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _decryptService.dispose();
    super.dispose();
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

      _databaseFiles.clear();

      // 如果没有配置路径，使用默认路径
      if (configuredPath == null || configuredPath.isEmpty) {
        configuredPath = '$documentsPath${Platform.pathSeparator}xwechat_files';
      }

      // 智能识别路径类型并扫描数据库
      await _scanDatabasePath(configuredPath, documentsPath);

      // 按文件大小排序，小的在前
      _databaseFiles.sort((a, b) => a.fileSize.compareTo(b.fileSize));

      // 清理上次更新时重命名的旧文件（.old.* 后缀）
      await _cleanupOldRenamedFiles(documentsPath);
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
    // 如果是 wxid_ 开头，去除后面可能的 _数字 后缀
    if (dirName.startsWith('wxid_')) {
      // 匹配 wxid_ 开头，后面跟着字母数字但不包含下划线的部分
      final match = RegExp(r'wxid_[a-zA-Z0-9]+').firstMatch(dirName);
      if (match != null) {
        return match.group(0)!;
      }
    }
    // 非 wxid_ 格式的账号目录（新版微信），直接返回
    return dirName;
  }

  /// 智能扫描数据库路径
  Future<void> _scanDatabasePath(String basePath, String documentsPath) async {
    final baseDir = Directory(basePath);
    if (!await baseDir.exists()) {
      return;
    }

    final pathParts = basePath.split(Platform.pathSeparator);
    final lastPart = pathParts.isNotEmpty ? pathParts.last : '';

    // 判断路径类型并采取不同的扫描策略
    if (lastPart == 'db_storage') {
      // 情况1：用户直接选择了 db_storage 目录
      // 从路径中提取账号文件夹名
      String accountName = 'unknown';
      if (pathParts.length >= 2) {
        final parentDirName = pathParts[pathParts.length - 2];
        accountName = _cleanAccountDirName(parentDirName);
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
        final manualWxid = await _configService.getManualWxid();
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
      if (_derivedKey == null) {
        _derivedKey = await _deriveKeyOnce(
          key,
          pendingFiles.first.originalPath,
        );
      }

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
          // 解密（添加进度节流，避免频繁setState）
          DateTime? lastUpdate;
          final decryptedPath = await _decryptService.decryptDatabase(
            file.originalPath,
            key,
            (current, total) {
              // 节流：每100ms最多更新一次UI
              final now = DateTime.now();
              if (lastUpdate == null ||
                  now.difference(lastUpdate!).inMilliseconds > 100) {
                lastUpdate = now;
                if (mounted) {
                  setState(() {
                    final index = _databaseFiles.indexWhere(
                      (f) => f.originalPath == file.originalPath,
                    );
                    if (index != -1) {
                      _databaseFiles[index].decryptProgress = current / total;
                    }
                  });
                }
              }
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

          if (mounted) {
            setState(() {
              final index = _databaseFiles.indexWhere(
                (f) => f.originalPath == file.originalPath,
              );
              if (index != -1) {
                _databaseFiles[index].isDecrypted = true;
                _databaseFiles[index].decryptProgress = 1.0;
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
              if (mounted) {
                setState(() {
                  final index = _databaseFiles.indexWhere(
                    (f) => f.originalPath == file.originalPath,
                  );
                  if (index != -1) {
                    _databaseFiles[index].decryptProgress = current / total;
                  }
                });
              }
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

          if (mounted) {
            setState(() {
              final index = _databaseFiles.indexWhere(
                (f) => f.originalPath == file.originalPath,
              );
              if (index != -1) {
                _databaseFiles[index].decryptProgress = 1.0;
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
          if (mounted) {
            _lastProgressUpdateMap[file.originalPath] = DateTime.now();
            setState(() {
              final index = _databaseFiles.indexWhere(
                (f) => f.originalPath == file.originalPath,
              );
              if (index != -1) {
                _databaseFiles[index].decryptProgress = current / total;
              }
            });
          }
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

      if (mounted) {
        setState(() {
          final index = _databaseFiles.indexWhere(
            (f) => f.originalPath == file.originalPath,
          );
          if (index != -1) {
            _databaseFiles[index].isDecrypted = true;
            _databaseFiles[index].decryptProgress = 1.0;
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
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  // ========== 图片解密相关方法 ==========

  /// 加载图片文件列表
  Future<void> _loadImageFiles() async {
    if (!mounted) return;

    // 防止重复扫描
    if (_isLoadingImages) {
      await logger.warning('DataManagementPage', '图片扫描已在进行中，跳过本次请求');
      return;
    }

    setState(() {
      _isLoadingImages = true;
      _imageFiles.clear(); // 清空列表在setState中，确保UI立即更新
      _displayLimit = 1000; // 重置显示限制
      _showOnlyUndecrypted = false; // 重置过滤
      _imageQualityFilter = 'all'; // 重置质量过滤
    });

    try {
      await logger.info('DataManagementPage', '开始扫描图片文件...');

      final documentsDir = await getApplicationDocumentsDirectory();
      final documentsPath = documentsDir.path;

      // 获取配置的路径
      String? configuredPath = await _configService.getDatabasePath();

      if (configuredPath == null || configuredPath.isEmpty) {
        configuredPath = '$documentsPath${Platform.pathSeparator}xwechat_files';
      }

      await logger.info('DataManagementPage', '配置路径: $configuredPath');

      // 预构建 Msg 表与展示名的映射，便于输出目录使用真实名字
      await _prepareDisplayNameCache();

      // 扫描图片文件
      await _scanImagePath(configuredPath, documentsPath);

      // 按文件大小排序
      _imageFiles.sort((a, b) => a.fileSize.compareTo(b.fileSize));

      await logger.info(
        'DataManagementPage',
        '图片扫描完成，共找到 ${_imageFiles.length} 个文件',
      );

      if (_imageFiles.isNotEmpty) {
        _showImageMessage('找到 ${_imageFiles.length} 个图片文件', true);
      }
    } catch (e, stackTrace) {
      await logger.error('DataManagementPage', '加载图片文件失败', e, stackTrace);
      _showImageMessage('加载图片文件失败: $e', false);
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingImages = false;
        });
      }
    }
  }

  /// 智能扫描图片路径（参考数据库扫描逻辑）
  Future<void> _prepareDisplayNameCache() async {
    if (!mounted) return;
    try {
      final appState = Provider.of<AppState>(context, listen: false);
      final dbService = appState.databaseService;
      if (!dbService.isConnected) {
        await logger.warning('DataManagementPage', '数据库未连接，无法为图片生成展示名映射');
        return;
      }

      final sessions = await dbService.getSessions();
      if (sessions.isEmpty) {
        await logger.warning('DataManagementPage', '未获取到会话列表，跳过展示名映射');
        return;
      }

      final usernames = sessions
          .map((s) => s.username)
          .where((u) => u.isNotEmpty)
          .toList();
      final displayNames = await dbService.getDisplayNames(usernames);

      _tableDisplayNameCache.clear();
      for (final username in usernames) {
        final hash = md5.convert(utf8.encode(username)).toString().toLowerCase();
        final displayName = displayNames[username]?.trim();
        if (displayName == null || displayName.isEmpty) continue;

        _tableDisplayNameCache[hash] = displayName;
        _tableDisplayNameCache['msg_$hash'] = displayName;
      }

      await logger.info(
        'DataManagementPage',
        '已构建图片输出目录映射: ${_tableDisplayNameCache.length} 项',
      );
    } catch (e, stackTrace) {
      await logger.warning(
        'DataManagementPage',
        '构建图片展示名映射失败: $e',
        stackTrace,
      );
    }
  }

  String _sanitizePathSegment(String name) {
    var sanitized = name.replaceAll(RegExp(r'[<>:"/\\\\|?*]'), '_').trim();
    if (sanitized.isEmpty) {
      return '未知联系人';
    }
    // 避免过长的目录名
    if (sanitized.length > 60) {
      sanitized = sanitized.substring(0, 60);
    }
    return sanitized;
  }

  String _applyDisplayNameToRelativePath(String relativePath) {
    if (_tableDisplayNameCache.isEmpty) return relativePath;

    final sep = Platform.pathSeparator;
    final hasLeadingSep = relativePath.startsWith(sep);
    final parts = relativePath
        .split(sep)
        .where((p) => p.isNotEmpty)
        .toList();
    final attachIndex = parts.indexWhere((p) => p.toLowerCase() == 'attach');
    if (attachIndex != -1 && attachIndex + 1 < parts.length) {
      final tableSegment = parts[attachIndex + 1];
      final normalized = tableSegment.toLowerCase();
      String? displayName = _tableDisplayNameCache[normalized];

      if (displayName == null && normalized.startsWith('msg_')) {
        final stripped = normalized.substring(4);
        displayName = _tableDisplayNameCache[stripped];
      }

      if (displayName != null && displayName.isNotEmpty) {
        parts[attachIndex + 1] = _sanitizePathSegment(displayName);
      }
    }

    final rebuilt = parts.join(sep);
    return hasLeadingSep ? '$sep$rebuilt' : rebuilt;
  }

  Future<void> _scanImagePath(String basePath, String documentsPath) async {
    final baseDir = Directory(basePath);
    if (!await baseDir.exists()) {
      await logger.warning('DataManagementPage', '图片扫描：目录不存在 $basePath');
      return;
    }

    final pathParts = basePath.split(Platform.pathSeparator);
    final lastPart = pathParts.isNotEmpty ? pathParts.last : '';

    await logger.info(
      'DataManagementPage',
      '开始扫描图片文件，路径: $basePath, 最后部分: $lastPart',
    );

    // 判断路径类型并采取不同的扫描策略
    if (lastPart == 'db_storage') {
      // 情况1：用户选择了 db_storage 目录
      // 需要回到父目录（账号目录）来扫描图片
      if (pathParts.length >= 2) {
        final accountPath = pathParts
            .sublist(0, pathParts.length - 1)
            .join(Platform.pathSeparator);
        final accountDir = Directory(accountPath);

        await logger.info(
          'DataManagementPage',
          '检测到db_storage路径，扫描账号目录: $accountPath',
        );

        if (await accountDir.exists()) {
          await _scanWxidImageDirectory(accountDir, documentsPath);
        }
      }
    } else {
      // 情况2和3：扫描该目录下所有包含图片的账号目录
      // 通过检查是否有 db_storage 子文件夹来识别账号目录
      await logger.info('DataManagementPage', '扫描目录下的所有账号子目录');

      final entities = await baseDir.list().toList();
      final accountDirs = <Directory>[];

      for (final entity in entities) {
        if (entity is! Directory) continue;

        // 检查是否有 db_storage 子文件夹（标志账号目录）
        final dbStoragePath =
            '${entity.path}${Platform.pathSeparator}db_storage';
        if (await Directory(dbStoragePath).exists()) {
          accountDirs.add(entity);
        }
      }

      await logger.info('DataManagementPage', '找到 ${accountDirs.length} 个账号目录');

      for (final accountDir in accountDirs) {
        await _scanWxidImageDirectory(accountDir, documentsPath);
      }
    }
  }

  /// 获取图片质量统计信息
  Future<String> _getImageQualityStats() async {
    if (_imageFiles.isEmpty) return '';

    final originalCount = _imageFiles
        .where((f) => f.imageQuality == 'original')
        .length;
    final thumbnailCount = _imageFiles
        .where((f) => f.imageQuality == 'thumbnail')
        .length;
    final unknownCount = _imageFiles
        .where((f) => f.imageQuality == 'unknown')
        .length;

    return '原图: $originalCount • 缩略图: $thumbnailCount${unknownCount > 0 ? ' • 未知: $unknownCount' : ''}';
  }

  /// 检测图片质量类型（原图/缩略图）
  String _detectImageQuality(String relativePath, int fileSize) {
    final pathLower = relativePath.toLowerCase();
    final fileNameLower = relativePath
        .split(Platform.pathSeparator)
        .last
        .toLowerCase();

    // 文件大小判断（这是主要依据）
    if (fileSize < 50 * 1024) {
      // 小于50KB，很可能是缩略图
      return 'thumbnail';
    } else if (fileSize > 500 * 1024) {
      // 大于500KB，很可能是原图
      return 'original';
    }

    // 路径关键词判断
    if (pathLower.contains('thumb') ||
        pathLower.contains('small') ||
        pathLower.contains('preview') ||
        pathLower.contains('thum') ||
        fileNameLower.contains('thumb') ||
        fileNameLower.contains('small')) {
      return 'thumbnail';
    }

    // 文件名模式判断
    // 微信缩略图通常有特定后缀或模式
    if (fileNameLower.contains('_t') ||
        fileNameLower.endsWith('_thumb.dat') ||
        fileNameLower.endsWith('_small.dat')) {
      return 'thumbnail';
    }

    // 路径深度判断
    // 通常原图在Image目录下，缩略图可能在子目录中
    final pathParts = relativePath.split(Platform.pathSeparator);
    if (pathParts.length > 3) {
      // 路径较深，可能是缩略图
      return 'thumbnail';
    }

    // 默认判断为原图（文件大小适中的情况）
    return 'original';
  }

  /// 扫描单个wxid目录下的图片
  Future<void> _scanWxidImageDirectory(
    Directory wxidDir,
    String documentsPath,
  ) async {
    int foundCount = 0;
    int updateThreshold = 0; // 每100个文件更新一次UI

    try {
      await logger.info('DataManagementPage', '开始扫描wxid目录: ${wxidDir.path}');

      // 查找所有 .dat 文件（递归搜索）
      await for (final entity in wxidDir.list(recursive: true)) {
        if (entity is File) {
          final filePath = entity.path.toLowerCase();

          // 只处理 .dat 文件
          if (!filePath.endsWith('.dat')) {
            continue;
          }

          // 跳过数据库文件
          if (filePath.contains('db_storage') ||
              filePath.contains('database')) {
            continue;
          }

          final fileName = entity.path.split(Platform.pathSeparator).last;

          try {
            final fileSize = await entity.length();

            // 跳过太小的文件（可能不是图片）
            if (fileSize < 100) {
              continue;
            }

            // 获取相对路径
            final relativePath = entity.path.replaceFirst(wxidDir.path, '');
            final outputRelativePath = _applyDisplayNameToRelativePath(
              relativePath,
            );

            // 检测图片质量类型
            final imageQuality = _detectImageQuality(relativePath, fileSize);

            // 计算解密后的路径（不检查是否存在，加快扫描速度）
            final outputDir = Directory(
              '$documentsPath${Platform.pathSeparator}EchoTrace${Platform.pathSeparator}Images',
            );
            final decryptedPath = '${outputDir.path}$outputRelativePath'.replaceAll(
              '.dat',
              '.jpg',
            );

            // 快速扫描：不检测版本和解密状态（解密时再检测）
            _imageFiles.add(
              ImageFile(
                originalPath: entity.path,
                fileName: fileName,
                fileSize: fileSize,
                relativePath: outputRelativePath,
                isDecrypted: false, // 默认未解密，批量解密时会自动跳过已存在的
                decryptedPath: decryptedPath,
                version: 0, // 默认V3，解密时自动检测
                imageQuality: imageQuality,
              ),
            );

            foundCount++;

            // 每100个文件更新一次UI，减少setState频率
            if (foundCount > updateThreshold) {
              updateThreshold = foundCount + 100;
              if (mounted) {
                setState(() {}); // 触发UI更新显示当前数量
              }
            }
          } catch (e) {
            // 单个文件出错不影响整体扫描
          }
        }
      }

      await logger.info(
        'DataManagementPage',
        'wxid目录扫描完成，找到 $foundCount 个图片文件',
      );
    } catch (e, stackTrace) {
      await logger.error(
        'DataManagementPage',
        '扫描目录失败: ${wxidDir.path}',
        e,
        stackTrace,
      );
    }
  }

  /// 批量解密图片
  Future<void> _decryptAllImages() async {
    // 应用当前筛选条件获取需要解密的图片列表
    List<ImageFile> filteredFiles = _imageFiles;

    // 应用质量过滤
    if (_imageQualityFilter != 'all') {
      filteredFiles = filteredFiles
          .where((f) => f.imageQuality == _imageQualityFilter)
          .toList();
    }

    // 应用解密状态过滤
    if (_showOnlyUndecrypted) {
      filteredFiles = filteredFiles.where((f) => !f.isDecrypted).toList();
    }

    if (filteredFiles.isEmpty) {
      _showImageMessage('当前筛选条件下没有需要解密的图片文件', false);
      return;
    }

    // 检查密钥配置
    final xorKeyHex = await _configService.getImageXorKey();
    final aesKeyHex = await _configService.getImageAesKey();

    if (xorKeyHex == null || xorKeyHex.isEmpty) {
      _showImageMessage('未配置图片解密密钥，请在设置中配置 XOR 和 AES 密钥', false);
      return;
    }

    setState(() {
      _isDecryptingImages = true;
      _totalImageFiles = filteredFiles.length; // 初始化为筛选后的总数
      _completedImageFiles = 0;
      _imageDecryptResults.clear();
    });

    try {
      final xorKey = ImageDecryptService.hexToXorKey(xorKeyHex);
      Uint8List? aesKey;

      if (aesKeyHex != null && aesKeyHex.isNotEmpty && aesKeyHex.length >= 16) {
        aesKey = ImageDecryptService.hexToBytes16(aesKeyHex);
      }

      int successCount = 0;
      int failCount = 0;

      // 第一次遍历：标记已存在的文件并计算需要解密的数量
      int needDecryptCount = 0;
      for (final imageFile in filteredFiles) {
        final outputFile = File(imageFile.decryptedPath);
        if (await outputFile.exists()) {
          imageFile.isDecrypted = true;
        } else {
          needDecryptCount++;
        }
      }

      // 更新总数
      setState(() {
        _totalImageFiles = needDecryptCount;
      });

      // 第二次遍历：只解密需要解密的文件（仅处理筛选后的文件）
      for (final imageFile in filteredFiles) {
        if (imageFile.isDecrypted) {
          continue; // 跳过已存在的文件
        }

        setState(() {
          _currentDecryptingImage = imageFile.fileName;
        });

        try {
          // 创建输出目录
          final outputFile = File(imageFile.decryptedPath);
          final outputDir = outputFile.parent;
          if (!await outputDir.exists()) {
            await outputDir.create(recursive: true);
          }

          // 解密（使用异步方法确保数据完整性）
          await _imageDecryptService.decryptDatAutoAsync(
            imageFile.originalPath,
            imageFile.decryptedPath,
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
        }

        setState(() {
          _completedImageFiles++;
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
      if (mounted) {
        setState(() {
          _isDecryptingImages = false;
          _currentDecryptingImage = '';
        });
      }
    }
  }

  /// 解密单个图片
  Future<void> _decryptSingleImage(ImageFile imageFile) async {
    // 检查密钥配置
    final xorKeyHex = await _configService.getImageXorKey();
    final aesKeyHex = await _configService.getImageAesKey();

    if (xorKeyHex == null || xorKeyHex.isEmpty) {
      _showImageMessage('未配置图片解密密钥', false);
      return;
    }

    try {
      final xorKey = ImageDecryptService.hexToXorKey(xorKeyHex);
      Uint8List? aesKey;

      if (aesKeyHex != null && aesKeyHex.isNotEmpty && aesKeyHex.length >= 16) {
        aesKey = ImageDecryptService.hexToBytes16(aesKeyHex);
      }

      // 创建输出目录
      final outputFile = File(imageFile.decryptedPath);
      final outputDir = outputFile.parent;
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }

      // 解密（使用异步方法确保数据完整性）
      await _imageDecryptService.decryptDatAutoAsync(
        imageFile.originalPath,
        imageFile.decryptedPath,
        xorKey,
        aesKey,
      );

      setState(() {
        imageFile.isDecrypted = true;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Column(
        children: [
          // Tab栏
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade200, width: 1),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: '数据库文件'),
                Tab(text: '图片文件'),
              ],
              labelColor: Theme.of(context).colorScheme.primary,
              unselectedLabelColor: Colors.grey,
              indicatorColor: Theme.of(context).colorScheme.primary,
              indicatorWeight: 3,
            ),
          ),

          // Tab内容区域
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // 数据库文件页面
                _buildDatabaseTab(),
                // 图片文件页面
                _buildImageTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建数据库文件Tab页面
  Widget _buildDatabaseTab() {
    return Column(
      children: [
        // 操作按钮栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: Colors.grey.shade200, width: 1),
            ),
          ),
          child: Row(
            children: [
              const Spacer(),
              // 增量更新按钮
              if (_databaseFiles.any((file) => file.needsUpdate))
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: OutlinedButton.icon(
                    onPressed: (_isLoading || _isDecrypting)
                        ? null
                        : _updateChanged,
                    icon: const Icon(Icons.update),
                    label: Text(
                      '增量更新 (${_databaseFiles.where((f) => f.needsUpdate).length})',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange,
                      side: BorderSide(color: Colors.orange.shade400),
                    ),
                  ),
                ),
              // 批量解密按钮
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
                        ),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_isDecrypting ? '正在解密...' : '批量解密'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),

        // 列表区域
        Expanded(
          child: _isLoading && _databaseFiles.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _databaseFiles.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.folder_open,
                        size: 64,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '未找到数据库文件',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '请确保微信数据目录存在',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // 解密进度显示
                    if (_isDecrypting)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        margin: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.blue, width: 1),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    '正在解密: $_currentDecryptingFile',
                                    style: TextStyle(
                                      color: Colors.blue.shade700,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // 文件级进度
                            LinearProgressIndicator(
                              value: _totalFiles > 0
                                  ? _completedFiles / _totalFiles
                                  : 0,
                              backgroundColor: Colors.blue.shade100,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.blue.shade600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '文件进度: $_completedFiles / $_totalFiles',
                              style: TextStyle(
                                color: Colors.blue.shade600,
                                fontSize: 12,
                              ),
                            ),
                            // 页面级进度（如果有）
                            if (_totalFilePages > 0) ...[
                              const SizedBox(height: 8),
                              LinearProgressIndicator(
                                value: _currentFilePages / _totalFilePages,
                                backgroundColor: Colors.blue.shade50,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.blue.shade400,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '页面进度: $_currentFilePages / $_totalFilePages',
                                style: TextStyle(
                                  color: Colors.blue.shade500,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                            // Isolate状态提示
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Text(
                                  '解密中，中途卡住是正常现象，请不要离开此页面',
                                  style: TextStyle(
                                    color: Colors.green.shade600,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                    // 状态消息
                    if (_statusMessage != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        margin: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _isSuccess
                              ? Colors.green.withValues(alpha: 0.1)
                              : Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _isSuccess ? Colors.green : Colors.red,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _isSuccess ? Icons.check_circle : Icons.error,
                              color: _isSuccess ? Colors.green : Colors.red,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _statusMessage!,
                                style: TextStyle(
                                  color: _isSuccess ? Colors.green : Colors.red,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // 文件列表
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _databaseFiles.length,
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
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // 文件图标
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: file.isDecrypted
                    ? Colors.green.withValues(alpha: 0.1)
                    : Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                file.isDecrypted ? Icons.check_circle : Icons.storage,
                color: file.isDecrypted
                    ? Colors.green
                    : Theme.of(context).colorScheme.primary,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),

            // 文件信息
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
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '大小: ${_formatFileSize(file.fileSize)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  if (file.decryptProgress > 0 && file.decryptProgress < 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: LinearProgressIndicator(
                        value: file.decryptProgress,
                        backgroundColor: Colors.grey.shade200,
                      ),
                    ),
                ],
              ),
            ),

            // 状态和操作按钮
            Column(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: file.isDecrypted
                            ? Colors.green.withValues(alpha: 0.1)
                            : Colors.orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        file.isDecrypted ? '已解密' : '未解密',
                        style: TextStyle(
                          color: file.isDecrypted
                              ? Colors.green
                              : Colors.orange,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
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
                          color: Colors.blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.update,
                              size: 12,
                              color: Colors.blue.shade700,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '有更新',
                              style: TextStyle(
                                color: Colors.blue.shade700,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                if (!file.isDecrypted)
                  OutlinedButton(
                    onPressed:
                        (_isLoading ||
                            (_isDecrypting && file.decryptProgress == 0))
                        ? null
                        : () => _decryptSingle(file),
                    child: Text(
                      _isDecrypting && file.decryptProgress > 0
                          ? '${(file.decryptProgress * 100).toStringAsFixed(0)}%'
                          : '解密',
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 构建图片文件Tab页面（现代化UI）
  Widget _buildImageTab() {
    return Column(
      children: [
        // 顶部信息和操作栏
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.02),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.1),
              width: 1,
            ),
          ),
          child: Column(
            children: [
              // 统计信息
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.photo_library_outlined,
                      color: Theme.of(context).colorScheme.primary,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_imageFiles.length}',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                        Text(
                          '图片文件',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 4),
                        // 显示质量统计
                        FutureBuilder<String>(
                          future: _getImageQualityStats(),
                          builder: (context, snapshot) {
                            if (snapshot.hasData) {
                              return Text(
                                snapshot.data!,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey.shade500,
                                ),
                              );
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                      ],
                    ),
                  ),
                  // 操作按钮
                  Row(
                    children: [
                      // 刷新按钮
                      Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          onTap: (_isLoadingImages || _isDecryptingImages)
                              ? null
                              : _loadImageFiles,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.grey.shade300,
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_isLoadingImages)
                                  SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  )
                                else
                                  Icon(
                                    Icons.refresh_rounded,
                                    size: 18,
                                    color: Colors.grey.shade700,
                                  ),
                                const SizedBox(width: 6),
                                Text(
                                  _isLoadingImages ? '扫描中' : '刷新',
                                  style: TextStyle(
                                    color: Colors.grey.shade700,
                                    fontWeight: FontWeight.w500,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // 批量解密按钮
                      Material(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 0,
                        child: InkWell(
                          onTap:
                              (_isLoadingImages ||
                                  _isDecryptingImages ||
                                  _imageFiles.isEmpty)
                              ? null
                              : _decryptAllImages,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_isDecryptingImages)
                                  SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                      value: _totalImageFiles > 0
                                          ? _completedImageFiles /
                                                _totalImageFiles
                                          : null,
                                    ),
                                  )
                                else
                                  const Icon(
                                    Icons.lock_open_rounded,
                                    size: 18,
                                    color: Colors.white,
                                  ),
                                const SizedBox(width: 6),
                                Text(
                                  _isDecryptingImages ? '解密中' : '批量解密',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),

        // 列表区域
        Expanded(
          child: _isLoadingImages && _imageFiles.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 60,
                        height: 60,
                        child: CircularProgressIndicator(
                          strokeWidth: 4,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        '正在扫描图片文件...',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                      if (_imageFiles.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '已找到 ${_imageFiles.length} 个文件',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
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
              : _imageFiles.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.image_not_supported,
                          size: 64,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '未找到图片文件',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.blue.withValues(alpha: 0.3),
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
                                    color: Colors.blue.shade700,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '可能的原因',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          color: Colors.blue.shade700,
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
                                      color: Colors.blue.shade600,
                                      height: 1.5,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: _loadImageFiles,
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
                    // 解密进度显示
                    if (_isDecryptingImages)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.08),
                              Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.04),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '正在解密图片',
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 15,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _currentDecryptingImage,
                                        style: TextStyle(
                                          color: Colors.grey.shade600,
                                          fontSize: 12,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  '${((_completedImageFiles / _totalImageFiles) * 100).toStringAsFixed(0)}%',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: _totalImageFiles > 0
                                    ? _completedImageFiles / _totalImageFiles
                                    : 0,
                                minHeight: 6,
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.15),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '$_completedImageFiles / $_totalImageFiles 个文件',
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  '剩余 ${_totalImageFiles - _completedImageFiles} 个',
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                    // 状态消息
                    if (_imageStatusMessage != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        margin: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _isImageSuccess
                              ? Colors.green.withValues(alpha: 0.1)
                              : Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _isImageSuccess ? Colors.green : Colors.red,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _isImageSuccess
                                  ? Icons.check_circle
                                  : Icons.error,
                              color: _isImageSuccess
                                  ? Colors.green
                                  : Colors.red,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _imageStatusMessage!,
                                style: TextStyle(
                                  color: _isImageSuccess
                                      ? Colors.green
                                      : Colors.red,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
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
    // 应用过滤
    List<ImageFile> filteredFiles = _imageFiles;

    // 应用质量过滤
    if (_imageQualityFilter != 'all') {
      filteredFiles = filteredFiles
          .where((f) => f.imageQuality == _imageQualityFilter)
          .toList();
    }

    // 应用解密状态过滤
    if (_showOnlyUndecrypted) {
      filteredFiles = filteredFiles.where((f) => !f.isDecrypted).toList();
    }

    // 应用显示限制
    final displayFiles = filteredFiles.take(_displayLimit).toList();
    final hasMore = filteredFiles.length > _displayLimit;

    return Column(
      children: [
        // 过滤和统计信息栏
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
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
                              });
                            },
                            activeThumbColor: Theme.of(
                              context,
                            ).colorScheme.primary,
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
                  // 统计标签
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${displayFiles.length}/${filteredFiles.length}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
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
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              _imageQualityFilter = quality;
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
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.grey.shade300,
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
                                fontWeight: FontWeight.w500,
                                color: isSelected
                                    ? Colors.white
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
            ],
          ),
        ),

        // 加载更多提示
        if (hasMore)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.orange.shade50,
                  Colors.orange.shade50.withValues(alpha: 0.5),
                ],
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 20,
                  color: Colors.orange.shade700,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '显示前 $_displayLimit 条，共 ${filteredFiles.length} 条',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Material(
                  color: Colors.orange.shade600,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _displayLimit += 1000;
                      });
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        '加载更多',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
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
                          color: Colors.grey.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _showOnlyUndecrypted
                              ? Icons.done_all_rounded
                              : Icons.image_search_rounded,
                          size: 48,
                          color: Colors.grey.shade400,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _showOnlyUndecrypted ? '所有文件都已解密' : '没有图片文件',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade700,
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
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
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
  Widget _buildImageCard(ImageFile imageFile) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: imageFile.isDecrypted
              ? Colors.green.withValues(alpha: 0.2)
              : Colors.grey.shade200,
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
                        ? Colors.green.withValues(alpha: 0.1)
                        : Colors.grey.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    imageFile.isDecrypted
                        ? Icons.check_circle_rounded
                        : Icons.image_outlined,
                    color: imageFile.isDecrypted
                        ? Colors.green.shade600
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
                                  ? Colors.blue.withValues(alpha: 0.1)
                                  : Colors.orange.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              imageFile.imageQuality == 'original'
                                  ? '原图'
                                  : '缩略图',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: imageFile.imageQuality == 'original'
                                    ? Colors.blue.shade700
                                    : Colors.orange.shade700,
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
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '已解密',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.green.shade700,
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

/// 图片文件数据模型
class ImageFile {
  final String originalPath;
  final String fileName;
  final int fileSize;
  final String relativePath; // 相对于图片根目录的路径
  bool isDecrypted;
  final String decryptedPath;
  int version; // 0=V3, 1=V4-V1, 2=V4-V2
  String imageQuality; // 'original', 'thumbnail', 'unknown'

  ImageFile({
    required this.originalPath,
    required this.fileName,
    required this.fileSize,
    required this.relativePath,
    required this.isDecrypted,
    required this.decryptedPath,
    this.version = 0,
    this.imageQuality = 'unknown',
  });
}
