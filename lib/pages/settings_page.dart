// ignore_for_file: unused_field

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:io';
import '../providers/app_state.dart';
import '../services/config_service.dart';
import '../services/decrypt_service.dart';
import '../services/annual_report_cache_service.dart';
import '../services/dual_report_cache_service.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import '../services/wxid_scan_service.dart';
import '../widgets/toast_overlay.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';

/// 设置页面
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _keyController = TextEditingController();
  final _pathController = TextEditingController();
  final _wxidController = TextEditingController();
  final _imageXorKeyController = TextEditingController();
  final _imageAesKeyController = TextEditingController();
  final _configService = ConfigService();
  late final DecryptService _decryptService;
  final _wxidScanService = WxidScanService();
  late final ToastOverlay _toast;

  final bool _obscureKey = true;
  final bool _obscureImageXorKey = true;
  final bool _obscureImageAesKey = true;
  bool _isLoading = false;
  String? _statusMessage;
  bool _isSuccess = false;
  String _databaseMode = 'backup'; // 'backup' 或 'realtime'
  bool _showWxidInput = true; // 始终允许手动输入wxid
  bool _isScanningWxid = false; // 是否正在扫描wxid
  bool _debugMode = false; // 调试模式开关
  String? _lastWxidPathChecked; // 最近扫描过wxid的路径，避免重复扫描
  // 记录初始配置，防止重复保存同样配置
  String _initialKey = '';
  String _initialPath = '';
  String _initialMode = 'backup';
  String _initialWxid = '';
  String _initialImageXorKey = '';
  String _initialImageAesKey = '';

  @override
  void initState() {
    super.initState();
    _toast = ToastOverlay(this);
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
    _toast.dispose();
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
        _initialKey = key ?? '';
        _initialPath = path ?? '';
        _initialMode = mode;
        _imageXorKeyController.text = imageXorKey ?? '';
        _imageAesKeyController.text = imageAesKey ?? '';
        _wxidController.text = manualWxid ?? '';
        _initialImageXorKey = imageXorKey ?? '';
        _initialImageAesKey = imageAesKey ?? '';
        _initialWxid = manualWxid ?? '';
        _debugMode = debugMode;
        _showWxidInput = true; // 始终显示 wxid 输入框
      });
    }
  }

  bool _hasConfigChanged() {
    final key = _keyController.text.trim();
    final path = _pathController.text.trim();
    final wxid = _wxidController.text.trim();
    final imageXorKey = _imageXorKeyController.text.trim();
    final imageAesKey = _imageAesKeyController.text.trim();

    return key != _initialKey ||
        path != _initialPath ||
        _databaseMode != _initialMode ||
        wxid != _initialWxid ||
        imageXorKey != _initialImageXorKey ||
        imageAesKey != _initialImageAesKey;
  }

  /// 检查目录中是否存在账号目录（包含 db_storage 子文件夹）
  Future<void> _checkAccountDirectory(String path) async {
    // 仍然检查目录，但不影响 wxid 输入框的显示
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        setState(() {
          _showWxidInput = true;
        });
        return;
      }

      final candidates = await _collectAccountCandidates(path);

      // 不隐藏输入框，仅记录状态
      _lastWxidPathChecked = path;

      if (candidates.isEmpty) {
        _showMessage('未在该目录中找到账号目录，请手动输入wxid', false);
        return;
      }

      if (candidates.length == 1) {
        _applyDetectedWxid(candidates.first.wxid, fromPath: candidates.first.path);
        // 若根目录框为空则填入
        if (_pathController.text.isEmpty) {
          _pathController.text = path;
        }
        return;
      }

      final chosen = await _pickWxidCandidate(candidates);
      if (chosen == null || chosen.isEmpty) {
        _showMessage('检测到多个账号，请选择其中一个', false);
        return;
      }

      final match = candidates.firstWhere(
        (c) => _normalizeWxid(c.wxid) == _normalizeWxid(chosen),
        orElse: () => candidates.first,
      );
      _applyDetectedWxid(match.wxid, fromPath: match.path);
      if (_pathController.text.isEmpty) {
        _pathController.text = path;
      }
    } catch (e) {
      // 保持输入框显示
      _lastWxidPathChecked = path;
    }
  }

  /// 从目录名提取 wxid
  String? _extractWxidFromDirName(String dirName) {
    final trimmed = dirName.trim();
    if (trimmed.isEmpty) return null;
    // 保留原始目录名（用于拼路径/展示）
    return trimmed;
  }

  String? _normalizeWxid(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    // 非 wxid_ 开头的账号：清理末尾 "_xxxx"(下划线 + 4 位字母/数字) 再统一小写用于比较
    final cleaned = trimmed.replaceFirst(RegExp(r'_[a-zA-Z0-9]{4}$'), '');

    final lower = cleaned.toLowerCase();
    if (!lower.startsWith('wxid_')) return lower;

    // wxid_x_xxx -> wxid_x
    final match =
        RegExp(r'^(wxid_[^_]+)', caseSensitive: false).firstMatch(cleaned);
    if (match != null) return match.group(1)!.toLowerCase();
    return lower;
  }

  /// 收集包含 db_storage 的账号目录候选
  Future<List<WxidCandidate>> _collectAccountCandidates(String rootPath) async {
    final rootDir = Directory(rootPath);
    if (!await rootDir.exists()) return [];

    final candidates = <WxidCandidate>[];
    final normalizedManual = _normalizeWxid(_wxidController.text.trim());

    await for (final entity in rootDir.list()) {
      if (entity is! Directory) continue;
      final wxidRaw = _extractWxidFromDirName(p.basename(entity.path));
      if (wxidRaw == null) continue;

      final dbStorage = Directory(
        '${entity.path}${Platform.pathSeparator}db_storage',
      );
      final keyInfo = File(p.join(entity.path, 'key_info.dat'));

      if (!await dbStorage.exists() && !await keyInfo.exists()) continue;

      DateTime modified;
      if (await keyInfo.exists()) {
        modified = (await keyInfo.stat()).modified;
      } else {
        modified = (await dbStorage.stat()).modified;
      }

      final wxidNormalized = _normalizeWxid(wxidRaw);
      if (normalizedManual != null &&
          wxidNormalized != null &&
          wxidNormalized != normalizedManual) {
        continue; // 只收集匹配的账号
      }

      candidates.add(
        WxidCandidate(
          wxid: wxidRaw,
          modified: modified,
          path: entity.path,
        ),
      );
    }

    candidates.sort((a, b) => b.modified.compareTo(a.modified));
    return candidates;
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
      final possiblePaths = <String>{};

      final regPath = await _wxidScanService.findWeChatFilesRoot();
      if (regPath != null && regPath.isNotEmpty) {
        possiblePaths.add(regPath);
      }

      // 兼容旧目录
      final homeDir =
          Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '';
      if (homeDir.isNotEmpty) {
        possiblePaths.add(
          '$homeDir${Platform.pathSeparator}Documents${Platform.pathSeparator}WeChat Files',
        );
        possiblePaths.add(
          '$homeDir${Platform.pathSeparator}Documents${Platform.pathSeparator}xwechat_files',
        );
      }

      for (final path in possiblePaths) {
        final dir = Directory(path);
        if (await dir.exists()) {
          final rootName = p.basename(path).toLowerCase();
          if (rootName != 'xwechat_files' && rootName != 'wechat files') {
            continue; // 避免把登录信息目录当作数据库根目录
          }
          final candidates = await _collectAccountCandidates(path);
          if (candidates.isNotEmpty) {
            setState(() {
              _pathController.text = path;
            });
            await _checkAccountDirectory(path);
            _showMessage('自动检测成功：$path', true);
            return;
          }
        }
      }

      _showMessage('未能自动检测到微信数据库目录，请手动选择或输入wxid', false);
    } catch (e) {
      _showMessage('自动检测失败: $e', false);
    }
  }

  void _applyDetectedWxid(String wxid, {String? fromPath}) {
    setState(() {
      _wxidController.text = wxid;
    });
    if (fromPath != null) {
      _lastWxidPathChecked = fromPath;
      _showMessage('已从路径检测到账号: $wxid', true);
    }
  }

  Future<String?> _pickWxidCandidate(List<WxidCandidate> candidates) async {
    final fmt = DateFormat('yyyy-MM-dd HH:mm');
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('选择微信账号'),
          content: SizedBox(
            width: 360,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: candidates.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final c = candidates[index];
                  final time = fmt.format(c.modified.toLocal());
                  return ListTile(
                    dense: true,
                    title: Text(c.wxid),
                    subtitle: Text('该账号登录时间: $time'),
                    onTap: () => Navigator.pop(context, c.wxid),
                  );
                },
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
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
      await logger.warning('SettingsPage', '扫描数据库文件失败', e);
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

      // 检查根目录是否存在
      final rootDir = Directory(path);
      if (!await rootDir.exists()) {
        _showMessage('数据库目录不存在: $path', false);
        return;
      }

      final accountCandidates = await _collectAccountCandidates(path);
      if (accountCandidates.isEmpty) {
        _showMessage(
          '未找到 db_storage 目录\n请确认选择了正确的微信数据库根目录（如 xwechat_files）',
          false,
        );
        return;
      }

      Directory? dbStorageDir;
      if (accountCandidates.length == 1) {
        dbStorageDir = Directory(
          p.join(accountCandidates.first.path, 'db_storage'),
        );
      } else {
        final wxid = _wxidController.text.trim();
        final normalizedWxid = _normalizeWxid(wxid);
        if (normalizedWxid == null || normalizedWxid.isEmpty) {
          _showMessage('检测到多个账号，请先在配置中选择一个wxid', false);
          return;
        }

        final match = accountCandidates.cast<WxidCandidate?>().firstWhere(
          (c) => _normalizeWxid(c!.wxid) == normalizedWxid,
          orElse: () => null,
        );

        if (match == null) {
          _showMessage('未找到与当前wxid匹配的账号目录，请重新选择', false);
          return;
        }

        dbStorageDir = Directory(
          p.join(match.path, 'db_storage'),
        );
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

    if (!_hasConfigChanged()) {
      _showMessage('配置未发生变化，无需保存', true);
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

      // 更新基线，避免重复提示和重复扫描
      _initialKey = key;
      _initialPath = path;
      _initialMode = _databaseMode;
      _initialWxid = wxid;
      _initialImageXorKey = imageXorKey;
      _initialImageAesKey = imageAesKey;
      _lastWxidPathChecked = path;
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

    _toast.show(context, message, success: success);
  }

  void _updateScanProgress(String message, {bool success = true}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
      _isSuccess = success;
    });
  }

  void _logScanDetail(String message, {Object? error, StackTrace? stackTrace}) {
    if (!_debugMode) return;
    unawaited(logger.debug('WxidScan', message));
    if (error != null) {
      unawaited(logger.error('WxidScan', message, error, stackTrace));
    }
  }

  /// 点击扫描按钮：通过路径扫描 wxid
  Future<void> _scanWxidFromMemory() async {
    if (_isScanningWxid) return;
    setState(() {
      _isScanningWxid = true;
    });
    void handleProgress(String msg) {
      _updateScanProgress(msg);
      _logScanDetail(msg);
    }
    try {
      handleProgress('正在扫描微信账号目录...');
      final candidates = await _wxidScanService.scanWxids(onProgress: handleProgress);

      if (candidates.isEmpty) {
        const failMsg = '扫描失败：未找到微信账号目录';
        _updateScanProgress(failMsg, success: false);
        _showMessage(failMsg, false);
        _logScanDetail(failMsg);
        setState(() {
          _showWxidInput = true;
        });
        return;
      }

      String? chosenWxid;
      if (candidates.length == 1) {
        chosenWxid = candidates.first.wxid;
      } else {
        chosenWxid = await _pickWxidCandidate(candidates);
      }

      if (chosenWxid == null || chosenWxid.isEmpty) {
        const failMsg = '扫描取消或未选择账号';
        _updateScanProgress(failMsg, success: false);
        _showMessage(failMsg, false);
        return;
      }

      _applyDetectedWxid(chosenWxid);
      _showMessage('扫描成功，已填入wxid: $chosenWxid', true);
      _logScanDetail('扫描成功，已检测到 wxid: $chosenWxid');
    } catch (e, st) {
      final msg = '扫描wxid失败: $e';
      _updateScanProgress(msg, success: false);
      _showMessage(msg, false);
      _logScanDetail(msg, error: e, stackTrace: st);
    } finally {
      if (mounted) {
        setState(() {
          _isScanningWxid = false;
        });
      }
    }
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
                  color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
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
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
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
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
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

            // 手动输入wxid区域（始终显示，可编辑/保存）
            const SizedBox(height: 24),
            _buildInputSection(
              context,
              title: '账号wxid',
              subtitle: _wxidController.text.trim().isNotEmpty
                  ? '已保存wxid，可手动修改或重新扫描'
                  : '未找到账号目录，请手动输入账号标识',
              child: Column(
                children: [
                  TextFormField(
                    controller: _wxidController,
                    decoration: InputDecoration(
                      hintText: '请输入微信账号wxid',
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
                        return '请输入wxid';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton(
                      onPressed: _isScanningWxid ? null : _scanWxidFromMemory,
                      child: _isScanningWxid
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('扫描wxid'),
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
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
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
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
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
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
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
                  hintText: '例如: 0x12 或 A3',
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
                  hintText: '例如: b123456789012345...',
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
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
                                ).colorScheme.onSurface.withValues(alpha: 0.6),
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
                                ).colorScheme.onSurface.withValues(alpha: 0.5),
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
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
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
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
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
              subtitle: '将聊天记录页面的数据源变为实时从微信数据库读取',
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
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _databaseMode == 'realtime'
                          ? '实时模式将直接读取微信原始数据库，无需解密，但分析功能仍然需要解密后使用'
                          : '备份模式需要先解密数据库，更稳定可靠',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.6),
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
                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
            width: isSelected ? 2 : 1,
          ),
          color: isSelected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.05)
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
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
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
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
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
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
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
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => _showClearDualReportCacheDialog(),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                ),
                child: const Text('清除双人年度报告缓存'),
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
      _toast.show(context, '暂无缓存数据', success: false);
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
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
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
                      ).colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '清除后需要重新生成报告',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
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
                _toast.show(this.context, '已清除所有缓存');
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

  Future<void> _showClearDualReportCacheDialog() async {
    final cacheInfo = await DualReportCacheService.getCacheInfo();
    final cacheCount = cacheInfo['count'] as int;

    if (!mounted) return;

    if (cacheCount == 0) {
      _toast.show(context, '暂无双人年度报告缓存', success: false);
      return;
    }

    final cachedKeys = cacheInfo['keys'] as List<String>;
    final keysList = cachedKeys.join('\n');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [const Text('清除双人年度报告缓存')]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '确定要清除所有双人年度报告缓存吗？',
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
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '已缓存 $cacheCount 个双人报告',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (cachedKeys.isNotEmpty)
                    Text(
                      keysList,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.5),
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '清除后需要重新生成报告',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(
                  alpha: 0.6,
                ),
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
              await DualReportCacheService.clearAllReports();
              if (context.mounted) {
                Navigator.pop(context);
                _toast.show(this.context, '已清除所有双人年度报告缓存');
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
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
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
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
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
                    ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
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
                                    ).colorScheme.onSurface.withValues(alpha: 0.6),
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
                        ).colorScheme.outline.withValues(alpha: 0.2),
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
                                      ).colorScheme.onSurface.withValues(alpha: 0.6),
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
                      ).colorScheme.primaryContainer.withValues(alpha: 0.3)
                    : Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
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
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
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
                                ).colorScheme.onSurface.withValues(alpha: 0.6),
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
                        _toast.show(
                          context,
                          '调试模式已${value ? "开启" : "关闭"}',
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
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
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
                _toast.show(this.context, '已清空日志');
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
