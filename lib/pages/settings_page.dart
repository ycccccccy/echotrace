import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../providers/app_state.dart';
import '../services/config_service.dart';
import '../services/decrypt_service.dart';
import '../services/annual_report_cache_service.dart';
import '../services/database_service.dart';

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
  final _configService = ConfigService();
  late final DecryptService _decryptService;
  
  bool _obscureKey = true;
  bool _isLoading = false;
  String? _statusMessage;
  bool _isSuccess = false;
  String _databaseMode = 'backup'; // 'backup' 或 'realtime'

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
    _decryptService.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final key = await _configService.getDecryptKey();
    final path = await _configService.getDatabasePath();
    final mode = await _configService.getDatabaseMode();

    if (mounted) {
      setState(() {
        _keyController.text = key ?? '';
        _pathController.text = path ?? '';
        _databaseMode = mode;
      });
    }
  }

  Future<void> _selectDatabasePath() async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择微信数据库根目录 (db_storage)',
      );

      if (selectedDirectory != null) {
        setState(() {
          _pathController.text = selectedDirectory;
        });
        _showMessage('已选择数据库根目录', true);
      }
    } catch (e) {
      _showMessage('选择目录失败: $e', false);
    }
  }

  /// 自动检测数据库路径
  Future<void> _autoDetectDatabasePath() async {
    try {
      setState(() {
        _isLoading = true;
      });


      // 获取文档目录
      final documentsDir = await getApplicationDocumentsDirectory();
      final documentsPath = documentsDir.path;


      // 常见的微信数据库路径模式
      final possiblePaths = [
        '$documentsPath${Platform.pathSeparator}xwechat_files'
      ];

      String? foundDbStoragePath;

      for (final basePath in possiblePaths) {
        
        final baseDir = Directory(basePath);
        if (await baseDir.exists()) {
          
          // 查找所有 wxid_xxx 目录
          final wxidDirs = await baseDir.list().where((entity) {
            return entity is Directory && 
                   entity.path.split(Platform.pathSeparator).last.startsWith('wxid_');
          }).toList();


          for (final wxidDir in wxidDirs) {
            final dbStoragePath = '${wxidDir.path}${Platform.pathSeparator}db_storage';
            final dbStorageDir = Directory(dbStoragePath);
            
            if (await dbStorageDir.exists()) {
              foundDbStoragePath = dbStoragePath;
              
              break;
            }
          }
        }
        
        if (foundDbStoragePath != null) break;
      }

      if (foundDbStoragePath != null) {
        setState(() {
          _pathController.text = foundDbStoragePath!;
        });
        _showMessage('自动检测到微信数据库根目录: db_storage', true);
      } else {
        _showMessage('未找到微信数据库目录，请手动选择', false);
      }
    } catch (e) {
      _showMessage('自动检测失败: $e', false);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
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


      // 查找一个小的数据库文件进行测试
      final dbStorageDir = Directory(path);
      if (!await dbStorageDir.exists()) {
        _showMessage('数据库目录不存在', false);
        return;
      }

      final dbFiles = await _findAllDbFiles(dbStorageDir);
      if (dbFiles.isEmpty) {
        _showMessage('数据库目录中没有找到.db文件', false);
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

      // 保存配置
      await _configService.saveDecryptKey(key);
      await _configService.saveDatabasePath(path);
      await _configService.saveDatabaseMode(_databaseMode);

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
            final actualModeText = currentMode == DatabaseMode.realtime ? '实时模式' : '备份模式';
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
                  '设置',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
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
                    
                    // 数据库模式选择卡片
                    _buildDatabaseModeCard(context),
                    const SizedBox(height: 24),
                    
                    // 缓存管理卡片
                    _buildCacheManagementCard(context),
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
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.storage,
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
                        '微信数据库配置',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '配置解密密钥和数据库路径',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
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
                    borderSide: BorderSide(color: Colors.grey.shade300, width: 1.5),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade300, width: 1.5),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2.0),
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off),
                    onPressed: () {
                      setState(() {
                        _obscureKey = !_obscureKey;
                      });
                    },
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
              subtitle: '自动检测或手动选择db_storage目录',
              child: Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _pathController,
                      decoration: InputDecoration(
                        hintText: '点击自动检测或手动选择db_storage目录',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey.shade300, width: 1.5),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey.shade300, width: 1.5),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2.0),
                        ),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.search),
                          onPressed: _autoDetectDatabasePath,
                          tooltip: '自动检测',
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
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _selectDatabasePath,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('浏览'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ],
              ),
            ),
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

            // 操作按钮
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isLoading ? null : _testConnection,
                    icon: _isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: const Text('测试连接'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _saveConfig,
                    icon: const Icon(Icons.save),
                    label: const Text('保存配置'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
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

  Widget _buildInputSection(BuildContext context, {
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
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


  Widget _buildDatabaseModeCard(BuildContext context) {
    const wechatGreen = Color(0xFF07C160);
    
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
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.swap_horiz,
                    color: Colors.blue,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
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
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
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
              icon: Icons.backup,
              iconColor: wechatGreen,
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
              icon: Icons.flash_on,
              iconColor: Colors.orange,
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
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _databaseMode == 'realtime' 
                        ? '实时模式将直接读取微信原始数据库，无需解密备份'
                        : '备份模式需要先解密数据库，更稳定可靠',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
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
    required IconData icon,
    required Color iconColor,
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
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                color: iconColor,
                size: 20,
              ),
            ),
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
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle,
                color: Theme.of(context).colorScheme.primary,
                size: 24,
              )
            else
              Icon(
                Icons.radio_button_unchecked,
                color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
                size: 24,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCacheManagementCard(BuildContext context) {
    const wechatGreen = Color(0xFF07C160);
    
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
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: wechatGreen.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.cleaning_services,
                    color: wechatGreen,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
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
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
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
              child: OutlinedButton.icon(
                onPressed: () => _showClearCacheDialog(),
                icon: const Icon(Icons.delete_outline),
                label: const Text('清除年度报告缓存'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                ),
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
        const SnackBar(
          content: Text('暂无缓存数据'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // 计算缓存数量
    final cacheCount = cachedYears.length;
    final yearsList = cachedYears.map((year) => year == -1 ? '历史以来' : '$year年').join('、');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.delete_outline,
                color: Colors.red,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            const Text('清除缓存'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '确定要清除所有年度报告缓存吗？',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '已缓存 $cacheCount 个报告',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    yearsList,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
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
          FilledButton.icon(
            onPressed: () async {
              await AnnualReportCacheService.clearAllReports();
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.white),
                        SizedBox(width: 12),
                        Text('已清除所有缓存'),
                      ],
                    ),
                    backgroundColor: Colors.green,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
              }
            },
            icon: const Icon(Icons.delete_sweep),
            label: const Text('确认清除'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
