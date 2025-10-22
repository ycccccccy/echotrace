import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../providers/app_state.dart';
import '../services/config_service.dart';
import '../services/decrypt_service.dart';
import '../services/logger_service.dart';

/// 数据管理页面
class DataManagementPage extends StatefulWidget {
  const DataManagementPage({super.key});

  @override
  State<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends State<DataManagementPage> {
  final ConfigService _configService = ConfigService();
  late final DecryptService _decryptService;
  
  List<DatabaseFile> _databaseFiles = [];
  bool _isLoading = false;
  String? _statusMessage;
  bool _isSuccess = false;
  String? _derivedKey; // 缓存派生后的密钥
  
  // 解密进度相关
  bool _isDecrypting = false;
  int _totalFiles = 0;
  int _completedFiles = 0;
  String _currentDecryptingFile = '';
  Map<String, bool> _decryptResults = {}; // 记录每个文件的解密结果
  
  // 单个文件解密进度
  int _currentFilePages = 0;
  int _totalFilePages = 0;
  
  // 进度节流相关
  final Map<String, DateTime> _lastProgressUpdateMap = {}; // 每个文件独立的节流时间戳

  @override
  void initState() {
    super.initState();
    _decryptService = DecryptService();
    _decryptService.initialize();
    _loadDatabaseFiles();
  }

  @override
  void dispose() {
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
      // 从路径中提取 wxid
      String? wxidName;
      if (pathParts.length >= 2) {
        final parentDirName = pathParts[pathParts.length - 2];
        if (parentDirName.startsWith('wxid_')) {
          wxidName = parentDirName;
        }else{
          wxidName="wxid_$parentDirName";
        }
      }
      
      await _scanDbStorageDirectory(baseDir, wxidName ?? 'unknown', documentsPath);
      
    } else if (lastPart.startsWith('wxid_')) {
      // 情况2：用户选择了 wxid_xxx 目录
      final wxidName = lastPart;
      final dbStoragePath = '$basePath${Platform.pathSeparator}db_storage';
      final dbStorageDir = Directory(dbStoragePath);
      
      if (await dbStorageDir.exists()) {
        await _scanDbStorageDirectory(dbStorageDir, wxidName, documentsPath);
      }
      
    } else {
      // 情况3：用户选择了上层目录（如 xwechat_files），扫描所有 wxid 目录
      final wxidDirs = await baseDir.list().where((entity) {
        return entity is Directory && 
               entity.path.split(Platform.pathSeparator).last.startsWith('wxid_');
      }).toList();

      for (final wxidDir in wxidDirs) {
        final wxidName = wxidDir.path.split(Platform.pathSeparator).last;
        final dbStoragePath = '${wxidDir.path}${Platform.pathSeparator}db_storage';
        final dbStorageDir = Directory(dbStoragePath);
        
        if (await dbStorageDir.exists()) {
          await _scanDbStorageDirectory(dbStorageDir, wxidName, documentsPath);
        }
      }
    }
  }

  /// 扫描 db_storage 目录下的所有数据库文件
  Future<void> _scanDbStorageDirectory(Directory dbStorageDir, String wxidName, String documentsPath) async {
    // 递归查找所有 .db 文件
    final dbFiles = await _findAllDbFiles(dbStorageDir);
    
    for (final dbFile in dbFiles) {
      final fileName = dbFile.path.split(Platform.pathSeparator).last;
      final fileSize = await dbFile.length();
      
      // 获取源文件修改时间
      final originalStat = await dbFile.stat();
      final originalModified = originalStat.modified;
      
      // 检查是否已经解密
      final ourWorkDir = Directory('$documentsPath${Platform.pathSeparator}EchoTrace');
      final decryptedFileName = '${fileName.split('.').first}.db';
      final decryptedFilePath = '${ourWorkDir.path}${Platform.pathSeparator}$wxidName${Platform.pathSeparator}$decryptedFileName';
      final decryptedFile = File(decryptedFilePath);
      
      final isDecrypted = await decryptedFile.exists();
      DateTime? decryptedModified;
      
      if (isDecrypted) {
        // 获取备份文件修改时间
        final decryptedStat = await decryptedFile.stat();
        decryptedModified = decryptedStat.modified;
      }
      
      _databaseFiles.add(DatabaseFile(
        originalPath: dbFile.path,
        fileName: fileName,
        fileSize: fileSize,
        wxidName: wxidName,
        isDecrypted: isDecrypted,
        decryptedPath: decryptedFilePath,
        originalModified: originalModified,
        decryptedModified: decryptedModified,
      ));
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
    } catch (e) {
    }
    
    return dbFiles;
  }

  /// 批量解密未解密的文件
  Future<void> _decryptAllPending() async {
    final pendingFiles = _databaseFiles.where((file) => !file.isDecrypted).toList();
    
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
        _derivedKey = await _deriveKeyOnce(key, pendingFiles.first.originalPath);
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
              if (lastUpdate == null || now.difference(lastUpdate!).inMilliseconds > 100) {
                lastUpdate = now;
                if (mounted) {
                  setState(() {
                    final index = _databaseFiles.indexWhere((f) => f.originalPath == file.originalPath);
                    if (index != -1) {
                      _databaseFiles[index].decryptProgress = current / total;
                    }
                  });
                }
              }
            },
          );

          // -- 解密成功后的文件操作 --
          final targetFile = File(file.decryptedPath);
          final targetDir = targetFile.parent;
          if (!await targetDir.exists()) {
            await targetDir.create(recursive: true);
          }

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

          await File(decryptedPath).copy(file.decryptedPath);
          _lastProgressUpdateMap.remove(file.originalPath);

          if (mounted) {
            setState(() {
              final index = _databaseFiles.indexWhere((f) => f.originalPath == file.originalPath);
              if (index != -1) {
                _databaseFiles[index].isDecrypted = true;
                _databaseFiles[index].decryptProgress = 1.0;
              }
              _completedFiles++;
              _decryptResults[file.fileName] = true;
            });
          }
          
          Future.delayed(const Duration(milliseconds: 100), () async {
            try {
              await File(decryptedPath).delete();
            } catch (e) { /* 忽略删除错误 */ }
          });

          return true; // 成功
        } catch (e) {
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
    final filesToUpdate = _databaseFiles.where((file) => file.needsUpdate).toList();
    
    if (filesToUpdate.isEmpty) {
      _showMessage('所有文件都是最新的！', true);
      return;
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
      

      // -- 开始串行更新 --
      for (final file in filesToUpdate) {
        try {
          if (mounted) {
            setState(() {
              _currentDecryptingFile = file.fileName;
            });
          }

          final decryptedPath = await _decryptService.decryptDatabase(file.originalPath, key, (current, total) {
            if (mounted) {
              setState(() {
                final index = _databaseFiles.indexWhere((f) => f.originalPath == file.originalPath);
                if (index != -1) {
                  _databaseFiles[index].decryptProgress = current / total;
                }
              });
            }
          });

          // -- 更新成功后的文件操作 --
          final targetFile = File(file.decryptedPath);
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
          await File(decryptedPath).copy(file.decryptedPath);
          
          final newStat = await File(file.decryptedPath).stat();
          _lastProgressUpdateMap.remove(file.originalPath);
          
          if (mounted) {
            setState(() {
              final index = _databaseFiles.indexWhere((f) => f.originalPath == file.originalPath);
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
            } catch (e) { /* 忽略删除错误 */ }
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
        _showMessage('增量更新完成！成功: $successCount, 失败: $failCount', failCount == 0);
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
      

      final decryptedPath = await _decryptService.decryptDatabase(file.originalPath, key, (current, total) {
        if (mounted) {
          _lastProgressUpdateMap[file.originalPath] = DateTime.now();
          setState(() {
            final index = _databaseFiles.indexWhere((f) => f.originalPath == file.originalPath);
            if (index != -1) {
              _databaseFiles[index].decryptProgress = current / total;
            }
          });
        }
      });

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
          final index = _databaseFiles.indexWhere((f) => f.originalPath == file.originalPath);
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
      await logger.error('DataManagementPage', '解密文件失败: ${file.fileName}', e, stackTrace);
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
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Column(
        children: [
          // 顶部导航栏
          Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios),
                  onPressed: () {
                    context.read<AppState>().setCurrentPage('chat');
                  },
                  style: IconButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  '数据管理',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // 增量更新按钮
                if (_databaseFiles.any((file) => file.needsUpdate))
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: OutlinedButton.icon(
                      onPressed: (_isLoading || _isDecrypting) ? null : _updateChanged,
                      icon: const Icon(Icons.update),
                      label: Text('增量更新 (${_databaseFiles.where((f) => f.needsUpdate).length})'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange,
                        side: BorderSide(color: Colors.orange.shade400),
                      ),
                    ),
                  ),
                // 批量解密按钮
                ElevatedButton.icon(
                  onPressed: (_isLoading || _isDecrypting) ? null : _decryptAllPending,
                  icon: _isDecrypting
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2, 
                          value: _totalFiles > 0 ? _completedFiles / _totalFiles : null
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
          
          // 内容区域
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
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '未找到数据库文件',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '请确保微信数据目录存在',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
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
                            color: Colors.blue.withOpacity(0.1),
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
                                    child: CircularProgressIndicator(strokeWidth: 2),
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
                                value: _totalFiles > 0 ? _completedFiles / _totalFiles : 0,
                                backgroundColor: Colors.blue.shade100,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade600),
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
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade400),
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
                                ? Colors.green.withOpacity(0.1)
                                : Colors.red.withOpacity(0.1),
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
      ),
    );
  }

  Widget _buildFileCard(DatabaseFile file) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.1),
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
                  ? Colors.green.withOpacity(0.1)
                  : Theme.of(context).colorScheme.primary.withOpacity(0.1),
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
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '大小: ${_formatFileSize(file.fileSize)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
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
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: file.isDecrypted 
                          ? Colors.green.withOpacity(0.1)
                          : Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        file.isDecrypted ? '已解密' : '未解密',
                        style: TextStyle(
                          color: file.isDecrypted ? Colors.green : Colors.orange,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (file.needsUpdate) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.1),
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
                    onPressed: (_isLoading || (_isDecrypting && file.decryptProgress == 0)) ? null : () => _decryptSingle(file),
                    child: Text(
                      _isDecrypting && file.decryptProgress > 0 
                        ? '${(file.decryptProgress * 100).toStringAsFixed(0)}%' 
                        : '解密'
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                  ),
              ],
            ),
          ],
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
  final DateTime? originalModified;  // 源文件修改时间
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
