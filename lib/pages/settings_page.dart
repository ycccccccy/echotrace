import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import '../providers/app_state.dart';
import '../services/config_service.dart';
import '../services/decrypt_service.dart';
import '../services/annual_report_cache_service.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// 设置页面
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  final _keyController = TextEditingController();
  final _pathController = TextEditingController();
  final _wxidController = TextEditingController();
  final _imageXorKeyController = TextEditingController();
  final _imageAesKeyController = TextEditingController();
  final _configService = ConfigService();
  late final DecryptService _decryptService;

  bool _obscureKey = true;
  bool _obscureImageXorKey = true;
  bool _obscureImageAesKey = true;
  bool _isLoading = false;
  String? _statusMessage;
  bool _isSuccess = false;
  String _databaseMode = 'backup'; // 'backup' 或 'realtime'
  bool _showWxidInput = false; // 是否显示手动输入wxid的输入框
  bool _debugMode = false; // 调试模式开关

  @override
  void initState() {
    super.initState();
    _decryptService = DecryptService();
    _decryptService.initialize();
    _loadConfig();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _pathController.dispose();
    _wxidController.dispose();
    _imageXorKeyController.dispose();
    _imageAesKeyController.dispose();
    _decryptService.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final key = await _configService.getDecryptKey();
    final path = await _configService.getDatabasePath();
    final mode = await _configService.getDatabaseMode();
    final imageXorKey = await _configService.getImageXorKey();
    final imageAesKey = await _configService.getImageAesKey();
    final manualWxid = await _configService.getManualWxid();
    final debugMode = await _configService.getDebugMode();

    if (mounted) {
      setState(() {
        _keyController.text = key ?? '';
        _pathController.text = path ?? '';
        _databaseMode = mode;
        _imageXorKeyController.text = imageXorKey ?? '';
        _imageAesKeyController.text = imageAesKey ?? '';
        _wxidController.text = manualWxid ?? '';
        _debugMode = debugMode;
        // 如果已经有手动输入的wxid，显示输入框
        _showWxidInput = (manualWxid != null && manualWxid.isNotEmpty);
      });

      // 如果有路径，检查是否存在账号目录
      if (path != null && path.isNotEmpty) {
        _checkAccountDirectory(path);
      }
    }
  }

  /// 检查目录中是否存在账号目录（包含 db_storage 子文件夹）
  Future<void> _checkAccountDirectory(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        setState(() {
          _showWxidInput = true;
        });
        return;
      }

      // 检查是否存在包含 db_storage 的子目录
      bool foundAccountDir = false;
      await for (final entity in dir.list()) {
        if (entity is Directory) {
          final dbStoragePath =
              '${entity.path}${Platform.pathSeparator}db_storage';
          if (await Directory(dbStoragePath).exists()) {
            foundAccountDir = true;
            break;
          }
        }
      }

      setState(() {
        _showWxidInput = !foundAccountDir;
      });

      if (!foundAccountDir) {
        _showMessage('未在该目录中找到账号目录，请手动输入wxid', false);
      }
    } catch (e) {
      setState(() {
        _showWxidInput = true;
      });
    }
  }

  Future<void> _selectDatabasePath() async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择微信数据库根目录 (通常是 xwechat_files)',
      );

      if (selectedDirectory != null) {
        setState(() {
          _pathController.text = selectedDirectory;
        });
        await _checkAccountDirectory(selectedDirectory);
        _showMessage('已选择数据库根目录', true);
      }
    } catch (e) {
      _showMessage('选择目录失败: $e', false);
    }
  }

  /// 自动检测数据库目录
  Future<void> _autoDetectDatabasePath() async {
    try {
      _showMessage('正在自动检测数据库目录...', true);

      // 获取用户主目录
      final homeDir =
          Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '';

      if (homeDir.isEmpty) {
        _showMessage('无法获取用户主目录', false);
        return;
      }

      // 微信数据库路径
      final possiblePaths = [
        '$homeDir${Platform.pathSeparator}Documents${Platform.pathSeparator}xwechat_files',
      ];

      for (final path in possiblePaths) {
        final dir = Directory(path);
        if (await dir.exists()) {
          // 检查是否包含账号目录（包含 db_storage 子文件夹）
          await for (final entity in dir.list()) {
            if (entity is Directory) {
              final dbStoragePath =
                  '${entity.path}${Platform.pathSeparator}db_storage';
              final dbStorageDir = Directory(dbStoragePath);

              if (await dbStorageDir.exists()) {
                // 找到了包含 db_storage 的目录
                setState(() {
                  _pathController.text = path;
                });
                await _checkAccountDirectory(path);
                _showMessage('自动检测成功：$path', true);
                return;
              }
            }
          }
        }
      }

      setState(() {
        _showWxidInput = true;
      });
      _showMessage('未能自动检测到微信数据库目录，请手动选择或输入wxid', false);
    } catch (e) {
      setState(() {
        _showWxidInput = true;
      });
      _showMessage('自动检测失败: $e', false);
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

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = null;
    });

    try {
      final key = _keyController.text.trim();
      final path = _pathController.text.trim();

      // 检查根目录是否存在
      final rootDir = Directory(path);
      if (!await rootDir.exists()) {
        _showMessage('数据库目录不存在: $path', false);
        return;
      }

      // 在根目录下查找包含 db_storage 的账号目录
      Directory? dbStorageDir;
      await for (final entity in rootDir.list()) {
        if (entity is Directory) {
          final possibleDbStorage = Directory(
            '${entity.path}${Platform.pathSeparator}db_storage',
          );
          if (await possibleDbStorage.exists()) {
            dbStorageDir = possibleDbStorage;
            break;
          }
        }
      }

      if (dbStorageDir == null) {
        _showMessage(
          '未找到 db_storage 目录\n请确认选择了正确的微信数据库根目录（如 xwechat_files）',
          false,
        );
        return;
      }

      // 在 db_storage 目录中查找 .db 文件
      final dbFiles = await _findAllDbFiles(dbStorageDir);

      if (dbFiles.isEmpty) {
        _showMessage('db_storage 目录中没有找到.db文件', false);
        return;
      }

      // 选择最小的文件进行测试
      dbFiles.sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));
      final testFile = dbFiles.first;

      // 验证密钥
      final isValid = await _decryptService.validateKey(testFile.path, key);

      if (isValid) {
        _showMessage('密钥验证成功！可以保存配置。', true);
      } else {
        _showMessage('密钥验证失败，请检查密钥是否正确', false);
      }
    } catch (e) {
      _showMessage('测试连接失败: $e', false);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _saveConfig() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = null;
    });

    try {
      final key = _keyController.text.trim();
      final path = _pathController.text.trim();
      final wxid = _wxidController.text.trim();
      var imageXorKey = _imageXorKeyController.text.trim();
      final imageAesKey = _imageAesKeyController.text.trim();

      // 移除XOR密钥的0x前缀（如果有）
      if (imageXorKey.toLowerCase().startsWith('0x')) {
        imageXorKey = imageXorKey.substring(2);
      }

      // 保存配置
      await _configService.saveDecryptKey(key);
      await _configService.saveDatabasePath(path);
      await _configService.saveDatabaseMode(_databaseMode);

      // 保存手动输入的wxid（如果有）
      if (wxid.isNotEmpty) {
        await _configService.saveManualWxid(wxid);
      }

      // 保存图片解密密钥（可选）
      if (imageXorKey.isNotEmpty) {
        await _configService.saveImageXorKey(imageXorKey);
      }
      if (imageAesKey.isNotEmpty) {
        await _configService.saveImageAesKey(imageAesKey);
      }

      // 更新应用状态
      if (mounted) {
        context.read<AppState>().setConfigured(true);

        _showMessage('配置保存成功！正在连接数据库...', true);

        // 重新连接数据库
        try {
          await context.read<AppState>().reconnectDatabase();

          if (mounted) {
            // 检查实际连接的模式
            final currentMode = context.read<AppState>().databaseService.mode;
            final actualModeText = currentMode == DatabaseMode.realtime
                ? '实时模式'
                : '备份模式';
            _showMessage('数据库连接成功！当前使用$actualModeText', true);

            // 延迟跳转到聊天页面
            Future.delayed(const Duration(seconds: 2), () {
              if (mounted) {
                context.read<AppState>().setCurrentPage('chat');
              }
            });
          }
        } catch (e) {
          if (mounted) {
            _showMessage('数据库连接失败: $e', false);
          }
        }
      }
    } catch (e) {
      _showMessage('保存配置失败: $e', false);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
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

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? Colors.green : Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Column(
        children: [
          // 顶部导航栏
          Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outline.withOpacity(0.1),
                ),
              ),
            ),
            child: Row(
              children: [
                Text(
                  '设置',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // 测试连接按钮
                OutlinedButton(
                  onPressed: _isLoading ? null : _testConnection,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  child: const Text('测试连接'),
                ),
                const SizedBox(width: 12),
                // 保存按钮
                ElevatedButton(
                  onPressed: _isLoading ? null : _saveConfig,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                  ),
                  child: const Text('保存配置'),
                ),
              ],
            ),
          ),

          // 内容区域
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 主配置卡片
                    _buildConfigCard(context),
                    const SizedBox(height: 24),

                    // 图片解密配置卡片
                    _buildImageDecryptCard(context),
                    const SizedBox(height: 24),

                    // 数据库模式选择卡片
                    _buildDatabaseModeCard(context),
                    const SizedBox(height: 24),

                    // 缓存管理卡片
                    _buildCacheManagementCard(context),
                    const SizedBox(height: 24),

                    // 日志管理卡片
                    _buildLogManagementCard(context),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigCard(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.1),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题区域
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '微信数据库配置',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '配置解密密钥和数据库路径',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),

            // 密钥输入区域
            _buildInputSection(
              context,
              title: '解密密钥',
              subtitle: '请输入64位十六进制密钥',
              child: TextFormField(
                controller: _keyController,
                obscureText: _obscureKey,
                decoration: InputDecoration(
                  hintText: '例如: a1b2c3d4e5f6...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Colors.grey.shade300,
                      width: 1.5,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Colors.grey.shade300,
                      width: 1.5,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2.0,
                    ),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return '请输入密钥';
                  }
                  if (value.length != 64) {
                    return '密钥长度必须为64个字符';
                  }
                  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
                    return '密钥必须为十六进制格式';
                  }
                  return null;
                },
              ),
            ),
            const SizedBox(height: 24),

            // 数据库路径区域
            _buildInputSection(
              context,
              title: '数据库根目录',
              subtitle: '自动检测或手动选择xwechat_files目录',
              child: Column(
                children: [
                  TextFormField(
                    controller: _pathController,
                    decoration: InputDecoration(
                      hintText: '点击自动检测或手动选择xwechat_files目录',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Colors.grey.shade300,
                          width: 1.5,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Colors.grey.shade300,
                          width: 1.5,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Theme.of(context).colorScheme.primary,
                          width: 2.0,
                        ),
                      ),
                    ),
                    readOnly: true,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return '请选择数据库根目录';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _autoDetectDatabasePath,
                          icon: const Icon(Icons.search),
                          label: const Text('自动检测'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _selectDatabasePath,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('手动选择'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // 手动输入wxid区域（条件显示）
            if (_showWxidInput) ...[
              const SizedBox(height: 24),
              _buildInputSection(
                context,
                title: '账号wxid',
                subtitle: '未找到账号目录，请手动输入wxid（如：wxid_abc123）',
                child: TextFormField(
                  controller: _wxidController,
                  decoration: InputDecoration(
                    hintText: '请输入微信账号wxid',
                    prefixIcon: const Icon(Icons.person_outline),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Colors.grey.shade300,
                        width: 1.5,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Colors.grey.shade300,
                        width: 1.5,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2.0,
                      ),
                    ),
                  ),
                  validator: (value) {
                    if (_showWxidInput && (value == null || value.isEmpty)) {
                      return '请输入wxid';
                    }
                    return null;
                  },
                ),
              ),
            ],

            const SizedBox(height: 32),

            // 状态消息
            if (_statusMessage != null)
              Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 24),
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
          ],
        ),
      ),
    );
  }

  Widget _buildInputSection(
    BuildContext context, {
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
          ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  Widget _buildImageDecryptCard(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.1),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题区域
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '微信图片解密配置',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '配置图片解密所需的XOR和AES密钥（可选）',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),

            // XOR密钥输入区域
            _buildInputSection(
              context,
              title: 'XOR密钥',
              subtitle: '2位十六进制密钥（支持0x前缀），例如：0x53 或 53',
              child: TextFormField(
                controller: _imageXorKeyController,
                obscureText: _obscureImageXorKey,
                decoration: InputDecoration(
                  hintText: '例如: 0x53 或 A3',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Colors.grey.shade300,
                      width: 1.5,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Colors.grey.shade300,
                      width: 1.5,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2.0,
                    ),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return null; // 可选字段
                  }
                  // 移除可能的0x前缀
                  final cleanValue = value.toLowerCase().startsWith('0x')
                      ? value.substring(2)
                      : value;
                  if (cleanValue.length < 2) {
                    return 'XOR密钥至少需要2个十六进制字符';
                  }
                  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(cleanValue)) {
                    return '密钥必须为十六进制格式';
                  }
                  return null;
                },
              ),
            ),
            const SizedBox(height: 24),

            // AES密钥输入区域
            _buildInputSection(
              context,
              title: 'AES密钥',
              subtitle: '至少16个字符的字母数字字符串，从微信进程内存获取',
              child: TextFormField(
                controller: _imageAesKeyController,
                obscureText: _obscureImageAesKey,
                decoration: InputDecoration(
                  hintText: '例如: b18052363165af7e...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Colors.grey.shade300,
                      width: 1.5,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Colors.grey.shade300,
                      width: 1.5,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2.0,
                    ),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return null; // 可选字段
                  }
                  final cleanValue = value.trim();
                  if (cleanValue.length < 16) {
                    return 'AES密钥至少需要16个字符';
                  }
                  if (!RegExp(r'^[0-9a-zA-Z]+$').hasMatch(cleanValue)) {
                    return '密钥必须为字母数字格式';
                  }
                  return null;
                },
              ),
            ),
            const SizedBox(height: 16),

            // 提示信息
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '用于解密微信加密图片文件（.dat格式）',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withOpacity(0.6),
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '• XOR密钥：整数格式，如 0x52 或 52\n• AES密钥：十六进制字符串，如 b180578900456123',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withOpacity(0.5),
                                height: 1.5,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDatabaseModeCard(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.1),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '数据库模式',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '选择数据库读取方式',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 备份模式选项
            _buildModeOption(
              context,
              title: '备份模式',
              subtitle: '读取已解密的数据库副本（推荐）',
              value: 'backup',
              isSelected: _databaseMode == 'backup',
              onTap: () {
                setState(() {
                  _databaseMode = 'backup';
                });
              },
            ),

            const SizedBox(height: 16),

            // 实时模式选项
            _buildModeOption(
              context,
              title: '实时模式',
              subtitle: '直接读取微信加密数据库（实验性功能）',
              value: 'realtime',
              isSelected: _databaseMode == 'realtime',
              onTap: () {
                setState(() {
                  _databaseMode = 'realtime';
                });
              },
            ),

            const SizedBox(height: 16),

            // 提示信息
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _databaseMode == 'realtime'
                          ? '实时模式将直接读取微信原始数据库，无需解密备份'
                          : '备份模式需要先解密数据库，更稳定可靠',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeOption(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String value,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline.withOpacity(0.2),
            width: isSelected ? 2 : 1,
          ),
          color: isSelected
              ? Theme.of(context).colorScheme.primary.withOpacity(0.05)
              : Colors.transparent,
        ),
        child: Row(
          children: [
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCacheManagementCard(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.1),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '缓存管理',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '管理年度报告缓存数据',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 清除缓存按钮
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => _showClearCacheDialog(),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                ),
                child: const Text('清除年度报告缓存'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showClearCacheDialog() async {
    final cachedYears = await AnnualReportCacheService.getAllCachedYears();

    if (!mounted) return;

    if (cachedYears.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无缓存数据'), backgroundColor: Colors.orange),
      );
      return;
    }

    // 计算缓存数量
    final cacheCount = cachedYears.length;
    final yearsList = cachedYears
        .map((year) => year == -1 ? '历史以来' : '$year年')
        .join('、');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [const Text('清除缓存')]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '确定要清除所有年度报告缓存吗？',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '已缓存 $cacheCount 个报告',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    yearsList,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '清除后需要重新生成报告',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              await AnnualReportCacheService.clearAllReports();
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('已清除所有缓存'),
                    backgroundColor: Colors.green,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
  }

  Widget _buildLogManagementCard(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.1),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '日志管理',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '查看和管理应用日志',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 日志信息
            FutureBuilder<List<String>>(
              future: Future.wait([
                logger.getLogFileSize(),
                logger.getLogLineCount().then((count) => count.toString()),
              ]),
              builder: (context, snapshot) {
                final size = snapshot.data?[0] ?? '计算中...';
                final lines = snapshot.data?[1] ?? '0';

                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '日志大小',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withOpacity(0.6),
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              size,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 40,
                        color: Theme.of(
                          context,
                        ).colorScheme.outline.withOpacity(0.2),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: 16),
                              child: Text(
                                '日志条数',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface.withOpacity(0.6),
                                    ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Padding(
                              padding: const EdgeInsets.only(left: 16),
                              child: Text(
                                lines,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 16),

            // 调试模式开关
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _debugMode
                    ? Theme.of(
                        context,
                      ).colorScheme.primaryContainer.withOpacity(0.3)
                    : Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest.withOpacity(0.3),
                borderRadius: BorderRadius.circular(12),
                border: _debugMode
                    ? Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 1.5,
                      )
                    : null,
              ),
              child: Row(
                children: [
                  Icon(
                    _debugMode ? Icons.bug_report : Icons.bug_report_outlined,
                    color: _debugMode
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '调试模式',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: _debugMode
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _debugMode ? '记录详细日志（包括数据分析和年度报告）' : '仅记录错误信息',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withOpacity(0.6),
                              ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _debugMode,
                    onChanged: (value) async {
                      setState(() {
                        _debugMode = value;
                      });
                      await _configService.saveDebugMode(value);
                      await logger.setDebugMode(value);

                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('调试模式已${value ? "开启" : "关闭"}'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 日志操作按钮
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _openLogFile(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('打开日志'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _showClearLogDialog(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      foregroundColor: Colors.orange,
                      side: const BorderSide(color: Colors.orange),
                    ),
                    child: const Text('清空日志'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openLogFile() async {
    try {
      final logPath = await logger.getLogFilePath();
      if (logPath == null) {
        _showMessage('日志文件不存在', false);
        return;
      }

      final logFile = File(logPath);
      if (!await logFile.exists()) {
        _showMessage('日志文件不存在', false);
        return;
      }

      // 使用系统默认应用打开日志文件
      final uri = Uri.file(logPath);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        // 如果无法直接打开，显示日志内容对话框
        _showLogContentDialog();
      }
    } catch (e) {
      _showMessage('打开日志文件失败: $e', false);
    }
  }

  Future<void> _showLogContentDialog() async {
    final content = await logger.getLogContent();

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [const Text('应用日志')]),
        content: SizedBox(
          width: double.maxFinite,
          height: 500,
          child: SingleChildScrollView(
            child: SelectableText(
              content,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showClearLogDialog() async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [const Text('清空日志')]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '确定要清空所有日志吗？',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            Text(
              '此操作将删除所有历史日志记录',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              await logger.clearLogs();
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('已清空日志'),
                    backgroundColor: Colors.green,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
                // 刷新页面以更新日志信息
                setState(() {});
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
  }
}
