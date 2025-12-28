import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/image_service.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/image_decrypt_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../services/logger_service.dart';

enum _ImageVariant { big, original, high, cache, thumb, other }

Future<List<String>> _scanDecryptedImages(String rootPath) async {
  final root = Directory(rootPath);
  if (!await root.exists()) return const [];
  final paths = <String>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      paths.add(entity.path);
    }
  }
  return paths;
}

/// 图片消息组件 - 显示聊天中的图片
class ImageMessageWidget extends StatefulWidget {
  final Message message;
  final String sessionUsername;
  final bool isFromMe;

  const ImageMessageWidget({
    super.key,
    required this.message,
    required this.sessionUsername,
    this.isFromMe = false,
  });

  @override
  State<ImageMessageWidget> createState() => _ImageMessageWidgetState();
}

class _ImageMessageWidgetState extends State<ImageMessageWidget> {
  String? _imagePath;
  bool _isLoading = true;
  bool _hasError = false;
  bool _isDecrypting = false;
  String? _statusMessage;
  String? _datName;
  String? _displayName;

  static final Map<String, String> _decryptedIndex = {};
  static final Map<String, Map<_ImageVariant, String>> _decryptedVariantIndex =
      {};
  static final Set<String> _invalidImagePaths = {};
  static DateTime? _lastIndexBuildAt;
  static const Duration _indexRefreshCooldown = Duration(seconds: 20);
  static const int _decodeConcurrency = 2;
  static int _decodeInFlight = 0;
  static final Queue<Completer<void>> _decodeWaiters = Queue();
  static const List<_ImageVariant> _variantPriority = [
    _ImageVariant.original,
    _ImageVariant.high,
    _ImageVariant.big,
    _ImageVariant.cache,
    _ImageVariant.other,
    _ImageVariant.thumb,
  ];
  static bool _indexed = false;
  static Future<void>? _indexing;
  static bool _refreshingIndex = false;
  static DateTime? _lastRefreshAttemptAt;
  static final ImageService _sharedImageService = ImageService();
  static Future<void>? _sharedImageInit;
  static String? _sharedImageDataPath;
  static const double _minImageSize = 100;
  static const double _maxImageSize = 260;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    if (!mounted) return;

    try {
      _datName = widget.message.imageDatName;
      final appState = context.read<AppState>();
      final imageService = await _getSharedImageService(appState);
      if (imageService == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _hasError = true;
            _statusMessage = '未获取到数据目录，无法加载图片';
          });
        }
        return;
      }
      // 预取会话展示名用于路径美化
      await _loadDisplayName(appState);

      // 初始化图片服务
      final dataPath = appState.databaseService.currentDataPath;
      if (dataPath != null) {
        // 获取图片路径
        if (widget.message.imageMd5 != null) {
          final hardlinkPath = await imageService.getImagePath(
            widget.message.imageMd5!,
            widget.sessionUsername,
          );

          if (hardlinkPath == null) {
            String? decodedPath =
                await _findDecryptedImageByName(_datName, refresh: false);
            if (decodedPath == null && widget.message.imageMd5 != null) {
              decodedPath = await _findDecryptedImageByName(
                widget.message.imageMd5,
                refresh: false,
              );
            }
            if (decodedPath != null &&
                !await _isImageUsable(decodedPath)) {
              decodedPath = null;
            }
            _logDebugPaths(decodedPath);
            if (mounted) {
              setState(() {
                _imagePath = decodedPath;
                _isLoading = false;
                _hasError = decodedPath == null;
              });
            }
          } else {
            final preferred =
                await _resolvePreferredImagePath(hardlinkPath);
            _logDebugPaths(preferred ?? hardlinkPath);
            if (mounted) {
              setState(() {
                _imagePath = preferred;
                _isLoading = false;
                _hasError = preferred == null;
              });
            }
          }
        } else {
          // 仅 packed_info_data 的情况
          String? decodedPath =
              await _findDecryptedImageByName(_datName, refresh: false);
          if (decodedPath == null && widget.message.imageMd5 != null) {
            decodedPath = await _findDecryptedImageByName(
              widget.message.imageMd5,
              refresh: false,
            );
          }
          if (decodedPath != null && !await _isImageUsable(decodedPath)) {
            decodedPath = null;
          }
          _logDebugPaths(decodedPath);
          if (mounted) {
            setState(() {
              _imagePath = decodedPath;
              _isLoading = false;
              _hasError = decodedPath == null;
            });
          }
        }

      } else {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _hasError = true;
            _statusMessage = '未获取到数据目录，无法加载图片';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
          _statusMessage ??= '加载图片出错: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFromMe = widget.isFromMe || widget.message.isSend == 1;
    final alignment = isFromMe ? Alignment.topRight : Alignment.topLeft;

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: alignment,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (_isLoading) {
            return Container(
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(6),
              ),
              padding: const EdgeInsets.all(18),
              child: const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }

          if (_hasError || _imagePath == null) {
            return _buildErrorPlaceholder(context);
          }

          final size = _resolveLayoutSize(constraints);
          return GestureDetector(
            onTap: () => _showFullImage(context),
            child: Hero(
              tag: 'image_${widget.message.localId}',
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.file(
                      File(_imagePath!),
                      fit: BoxFit.cover,
                      cacheWidth: 600,
                      filterQuality: FilterQuality.low,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          color: Colors.grey[300],
                          child: const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.broken_image,
                                size: 48,
                                color: Colors.grey,
                              ),
                              SizedBox(height: 8),
                              Text(
                                '[图片格式错误]',
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Size _resolveLayoutSize(BoxConstraints constraints) {
    final maxWidth =
        constraints.hasBoundedWidth ? constraints.maxWidth : _maxImageSize;
    final base = math.min(maxWidth, _maxImageSize);
    final ratio = _resolveImageAspectRatio();
    return _scaleByAspectRatio(
      ratio,
      baseWidth: base,
      minSize: _minImageSize,
      maxSize: _maxImageSize,
    );
  }

  double _resolveImageAspectRatio() {
    final raw = _parseImageSizeFromContent();
    if (raw == null) return 1.0;
    if (raw.height <= 0) return 1.0;
    return raw.width / raw.height;
  }

  Size? _parseImageSizeFromContent() {
    final primary = widget.message.messageContent;
    final secondary = widget.message.compressContent;
    final width = _extractIntAttribute(primary, const [
      'cdnthumbwidth',
      'cdnmidimgwidth',
      'width',
    ]) ?? _extractIntAttribute(secondary, const [
      'cdnthumbwidth',
      'cdnmidimgwidth',
      'width',
    ]);
    final height = _extractIntAttribute(primary, const [
      'cdnthumbheight',
      'cdnmidimgheight',
      'height',
    ]) ?? _extractIntAttribute(secondary, const [
      'cdnthumbheight',
      'cdnmidimgheight',
      'height',
    ]);
    if (width == null || height == null) return null;
    if (width <= 0 || height <= 0) return null;
    return Size(width.toDouble(), height.toDouble());
  }

  int? _extractIntAttribute(String content, List<String> keys) {
    for (final key in keys) {
      final pattern = RegExp(
        "$key\\s*=\\s*['\"](\\d+)['\"]",
        caseSensitive: false,
      );
      final match = pattern.firstMatch(content);
      if (match == null) continue;
      final value = int.tryParse(match.group(1)!);
      if (value != null && value > 0) return value;
    }
    return null;
  }

  Future<String?> _resolvePreferredImagePath(String hardlinkPath) async {
    final isThumb = _isThumbFileName(hardlinkPath);
    if (!isThumb && await _isImageUsable(hardlinkPath)) {
      return hardlinkPath;
    }

    String? decodedPath =
        await _findDecryptedImageByName(_datName, refresh: false);
    if (decodedPath == null && widget.message.imageMd5 != null) {
      decodedPath = await _findDecryptedImageByName(
        widget.message.imageMd5,
        refresh: false,
      );
    }
    if (decodedPath != null && await _isImageUsable(decodedPath)) {
      return decodedPath;
    }

    if (isThumb && await _isImageUsable(hardlinkPath)) {
      return hardlinkPath;
    }
    return null;
  }

  bool _isThumbFileName(String path) {
    final base = p.basenameWithoutExtension(path).toLowerCase();
    return base.endsWith('.t') || base.endsWith('_t');
  }

  Size _scaleByAspectRatio(
    double ratio, {
    required double baseWidth,
    required double minSize,
    required double maxSize,
  }) {
    final safeRatio = ratio <= 0 ? 1.0 : ratio;
    var width = baseWidth.clamp(minSize, maxSize);
    var height = width / safeRatio;
    if (height > maxSize) {
      height = maxSize;
      width = height * safeRatio;
    }
    if (width < minSize) {
      width = minSize;
      height = width / safeRatio;
      if (height > maxSize) {
        height = maxSize;
        width = height * safeRatio;
      }
    }
    return Size(width, height);
  }

  Widget _buildErrorPlaceholder(BuildContext context) {
    final theme = Theme.of(context);
    final isFromMe = widget.isFromMe || widget.message.isSend == 1;
    final bubbleColor = isFromMe
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isFromMe ? Colors.white : theme.colorScheme.onSurface;
    final title = _isDecrypting ? '解密中…' : '解密并显示图片';
    final status = _statusMessage;

    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: 110,
        minHeight: 32,
        maxWidth: 220,
      ),
      child: Material(
        color: bubbleColor,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: _isDecrypting ? null : _decryptOnDemand,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (_isDecrypting)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(textColor),
                    ),
                  )
                else
                  Icon(
                    Icons.lock_open_rounded,
                    size: 20,
                    color: isFromMe
                        ? Colors.white.withValues(alpha: 0.9)
                        : textColor.withValues(alpha: 0.9),
                  ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (status != null && status.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            status,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isFromMe
                                  ? Colors.white.withValues(alpha: 0.9)
                                  : theme.colorScheme.onSurface
                                      .withValues(alpha: 0.65),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 显示全屏图片
  void _showFullImage(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: Hero(
              tag: 'image_${widget.message.localId}',
              child: InteractiveViewer(
                panEnabled: true,
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.file(
                  File(_imagePath!),
                  errorBuilder: (context, error, stackTrace) {
                    return const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.broken_image,
                            size: 64,
                            color: Colors.white,
                          ),
                          SizedBox(height: 16),
                          Text(
                            '无法显示图片',
                            style: TextStyle(color: Colors.white, fontSize: 16),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<String?> _findDecryptedImageByName(String? baseName,
      {bool refresh = false}) async {
    if (baseName == null || baseName.isEmpty) return null;
    final key = _normalizeBaseName(baseName);
    if (!refresh && _decryptedIndex.containsKey(key)) {
      return _decryptedIndex[key];
    }

    if (!_indexed) {
      await _ensureDecryptedIndex();
    }
    if (!refresh && _decryptedVariantIndex.isEmpty && _shouldRefreshIndex()) {
      await _rebuildDecryptedIndex();
    }
    final resolved = await _resolveFromIndex(key);
    if (resolved != null || !refresh) return resolved;

    if (_shouldRefreshIndex()) {
      if (_refreshingIndex) {
        return _resolveFromIndex(key);
      }
      if (_lastRefreshAttemptAt != null &&
          DateTime.now().difference(_lastRefreshAttemptAt!) <
              _indexRefreshCooldown) {
        return _resolveFromIndex(key);
      }
      await _rebuildDecryptedIndex();
      return _resolveFromIndex(key);
    }
    return null;
  }

  Future<void> _ensureDecryptedIndex() async {
    if (_indexing != null) {
      await _indexing;
      return;
    }
    if (_indexed) return;
    _indexing = _buildDecryptedIndex();
    await _indexing;
  }

  Future<void> _buildDecryptedIndex() async {
    _indexed = false;
    _decryptedVariantIndex.clear();
    _invalidImagePaths.clear();
    try {
      final docs = await getApplicationDocumentsDirectory();
      final imagesRoot =
          Directory(p.join(docs.path, 'EchoTrace', 'Images'));
      if (!await imagesRoot.exists()) return;

      List<String> paths;
      try {
        paths = kIsWeb
            ? const []
            : await compute(_scanDecryptedImages, imagesRoot.path);
      } catch (_) {
        paths = await _scanDecryptedImages(imagesRoot.path);
      }
      if (paths.isEmpty && !kIsWeb) {
        paths = await _scanDecryptedImages(imagesRoot.path);
      }

      for (final path in paths) {
        final base = p.basenameWithoutExtension(path).toLowerCase();
        final normalized = _normalizeBaseName(base);
        final variant = _detectVariant(base);
        _indexDecryptedVariant(normalized, variant, path);
      }
    } catch (_) {
      // 忽略索引失败，但允许后续重建
      _indexed = false;
    } finally {
      if (_decryptedVariantIndex.isNotEmpty) {
        _indexed = true;
        _lastIndexBuildAt = DateTime.now();
      }
      _indexing = null;
    }
  }

  bool _shouldRefreshIndex() {
    if (_lastIndexBuildAt == null) return true;
    return DateTime.now().difference(_lastIndexBuildAt!) >
        _indexRefreshCooldown;
  }

  Future<void> _rebuildDecryptedIndex() async {
    if (_refreshingIndex) return;
    _refreshingIndex = true;
    _lastRefreshAttemptAt = DateTime.now();
    _indexed = false;
    _indexing = null;
    try {
      await _ensureDecryptedIndex();
    } finally {
      _refreshingIndex = false;
    }
  }

  Future<T> _withDecodePermit<T>(Future<T> Function() action) async {
    if (_decodeInFlight >= _decodeConcurrency) {
      final completer = Completer<void>();
      _decodeWaiters.add(completer);
      await completer.future;
    }
    _decodeInFlight += 1;
    try {
      return await action();
    } finally {
      _decodeInFlight -= 1;
      if (_decodeWaiters.isNotEmpty) {
        _decodeWaiters.removeFirst().complete();
      }
    }
  }

  Future<String?> _resolveFromIndex(String key) async {
    final variants = _decryptedVariantIndex[key];
    if (variants == null || variants.isEmpty) return null;

    for (final path in _orderedVariantPaths(variants)) {
      if (_invalidImagePaths.contains(path)) continue;
      if (await _isImageUsable(path)) {
        _decryptedIndex[key] = path;
        return path;
      }
      _invalidImagePaths.add(path);
    }
    return null;
  }

  void _indexDecryptedVariant(
    String key,
    _ImageVariant variant,
    String path,
  ) {
    final variants = _decryptedVariantIndex.putIfAbsent(key, () => {});
    variants[variant] ??= path;
  }

  List<String> _orderedVariantPaths(Map<_ImageVariant, String> variants) {
    final ordered = <String>[];
    for (final variant in _variantPriority) {
      final path = variants[variant];
      if (path != null) ordered.add(path);
    }
    return ordered;
  }

  String _normalizeBaseName(String name) {
    var base = name.toLowerCase();
    if (base.endsWith('.dat') || base.endsWith('.jpg')) {
      base = base.substring(0, base.length - 4);
    }
    var changed = true;
    const suffixes = [
      '.b',
      '.h',
      '.t',
      '.c',
      '.w',
      '.l',
      '_b',
      '_h',
      '_t',
      '_c',
      '_w',
      '_l',
    ];
    while (changed) {
      changed = false;
      for (final suffix in suffixes) {
        if (base.endsWith(suffix)) {
          base = base.substring(0, base.length - suffix.length);
          changed = true;
          break;
        }
      }
    }
    return base;
  }

  Future<ImageService?> _getSharedImageService(AppState appState) async {
    final dataPath = appState.databaseService.currentDataPath;
    if (dataPath == null || dataPath.isEmpty) return null;

    if (_sharedImageDataPath != dataPath) {
      await _sharedImageService.dispose();
      _sharedImageDataPath = dataPath;
      _sharedImageInit = null;
    }

    _sharedImageInit ??= _sharedImageService.init(dataPath);
    await _sharedImageInit;
    return _sharedImageService;
  }

  _ImageVariant _detectVariant(String base) {
    if (base.endsWith('.b')) return _ImageVariant.big;
    if (base.endsWith('.t')) return _ImageVariant.thumb;
    if (base.endsWith('.h')) return _ImageVariant.high;
    if (base.endsWith('.c')) return _ImageVariant.cache;
    if (base.endsWith('.w')) return _ImageVariant.big;
    if (base.endsWith('.l')) return _ImageVariant.big;
    if (base.endsWith('_b')) return _ImageVariant.big;
    if (base.endsWith('_t')) return _ImageVariant.thumb;
    if (base.endsWith('_h')) return _ImageVariant.high;
    if (base.endsWith('_c')) return _ImageVariant.cache;
    if (base.endsWith('_w')) return _ImageVariant.big;
    if (base.endsWith('_l')) return _ImageVariant.big;
    return _ImageVariant.original;
  }

  Future<bool> _isImageUsable(String path) async {
    return _withDecodePermit(() async {
      try {
        final file = File(path);
        if (!await file.exists()) return false;
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) return false;
        final codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: 8,
          targetHeight: 8,
        );
        final frame = await codec.getNextFrame();
        frame.image.dispose();
        codec.dispose();
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  void _rememberDecryptedFile(String path) {
    final base = p.basenameWithoutExtension(path).toLowerCase();
    final normalized = _normalizeBaseName(base);
    final variant = _detectVariant(base);
    _indexDecryptedVariant(normalized, variant, path);
    _decryptedIndex[normalized] = path;
  }

  Future<void> _decryptOnDemand() async {
    if (_datName == null || _datName!.isEmpty) {
      setState(() {
        _statusMessage = '未获取到图片名，无法解密';
      });
      return;
    }

    setState(() {
      _isDecrypting = true;
      _statusMessage = null;
    });

    try {
      final appState = context.read<AppState>();
      final config = appState.configService;
      final basePath = (await config.getDatabasePath()) ?? '';
      final rawWxid = await config.getManualWxid();

      if (basePath.isEmpty || rawWxid == null || rawWxid.isEmpty) {
        setState(() {
          _statusMessage = '未配置数据库路径或账号wxid，无法定位图片文件';
        });
        return;
      }

      final accountDir = Directory(p.join(basePath, rawWxid));
      if (!await accountDir.exists()) {
        setState(() {
          _statusMessage = '账号目录不存在，无法定位图片文件';
        });
        return;
      }

      await appState.ensureImageDisplayNameCache();

      final cachedDecoded =
          await _findDecryptedImageByName(_datName, refresh: true);
      final cachedByMd5 = cachedDecoded == null &&
              widget.message.imageMd5 != null
          ? await _findDecryptedImageByName(
              widget.message.imageMd5,
              refresh: true,
            )
          : null;
      final cachedPath = cachedDecoded ?? cachedByMd5;
      if (cachedPath != null && await _isImageUsable(cachedPath)) {
        if (mounted) {
          setState(() {
            _imagePath = cachedPath;
            _hasError = false;
            _statusMessage = null;
          });
        }
        return;
      }

      final datCandidates =
          await _searchDatFiles(accountDir, _datName!.toLowerCase());
      if (datCandidates.isEmpty) {
        setState(() {
          _statusMessage = '未找到对应的图片文件（*.dat），源文件没有被下载或已被删除';
        });
        return;
      }

      final xorKeyHex = await config.getImageXorKey();
      if (xorKeyHex == null || xorKeyHex.isEmpty) {
        setState(() {
          _statusMessage = '未配置图片 XOR 密钥，无法解密';
        });
        return;
      }
      final aesKeyHex = await config.getImageAesKey();
      final xorKey = ImageDecryptService.hexToXorKey(xorKeyHex);
      Uint8List? aesKey;
      if (aesKeyHex != null && aesKeyHex.isNotEmpty) {
        try {
          aesKey = ImageDecryptService.hexToBytes16(aesKeyHex);
        } catch (_) {
          // 保持 null，V3/V1 可能不需要
        }
      }

      final decryptService = ImageDecryptService();
      final docs = await getApplicationDocumentsDirectory();
      final imagesRoot = Directory(p.join(docs.path, 'EchoTrace', 'Images'));
      if (!await imagesRoot.exists()) {
        await imagesRoot.create(recursive: true);
      }

      String? validOutput;
      bool usedFallback = false;
      for (final datPath in datCandidates) {
        // 输出路径保持与原始相对路径一致，便于与“数据管理”页面统一
        String relative = p
            .relative(datPath, from: accountDir.path)
            .replaceAll('\\', p.separator);
        if (relative.startsWith('..')) {
          // 防御：相对路径异常时退化为根级文件
          relative = '${_datName!}.jpg';
        } else {
          final lowerRel = relative.toLowerCase();
          if (lowerRel.endsWith('.t.dat')) {
            relative = '${relative.substring(0, relative.length - 6)}.jpg';
          } else if (lowerRel.endsWith('.dat')) {
            relative = '${relative.substring(0, relative.length - 4)}.jpg';
          } else if (!lowerRel.endsWith('.jpg')) {
            relative = '$relative.jpg';
          }
          relative = appState.applyImageDisplayNameToRelativePath(relative);
        }

        final outPath = p.join(imagesRoot.path, relative);
        final outParent = Directory(p.dirname(outPath));
        if (!await outParent.exists()) {
          await outParent.create(recursive: true);
        }

        final existingFile = File(outPath);
        if (await existingFile.exists() && await _isImageUsable(outPath)) {
          validOutput = outPath;
          usedFallback = usedFallback || datPath != datCandidates.first;
          _rememberDecryptedFile(outPath);
          break;
        }

        try {
          await decryptService.decryptDatAutoAsync(
            datPath,
            outPath,
            xorKey,
            aesKey,
          );
        } catch (e, stack) {
          await logger.error(
            'ChatImage',
            '解密图片失败，尝试下一候选: $datPath',
            e,
            stack,
          );
          usedFallback = true;
          continue;
        }

        if (await _isImageUsable(outPath)) {
          validOutput = outPath;
          usedFallback = usedFallback || datPath != datCandidates.first;
          _rememberDecryptedFile(outPath);
          break;
        } else {
          _invalidImagePaths.add(outPath);
          usedFallback = true;
        }
      }

      if (validOutput == null) {
        setState(() {
          _statusMessage = '解密失败，图片可能已损坏';
          _hasError = true;
        });
        return;
      }

      if (mounted) {
        setState(() {
          _imagePath = validOutput;
          _hasError = false;
          _statusMessage =
              usedFallback ? '已降级展示可用版本的图片' : null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = '解密失败: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDecrypting = false;
        });
      }
    }
  }

  Future<List<String>> _searchDatFiles(
    Directory accountDir,
    String targetBase,
  ) async {
    final normalized = _normalizeBaseName(targetBase);
    final found = <_ImageVariant, String>{};
    try {
      await for (final entity
          in accountDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path).toLowerCase();
        if (!name.endsWith('.dat')) continue;
        final base = name.substring(0, name.length - 4);
        final normalizedBase = _normalizeBaseName(base);
        if (normalizedBase != normalized) continue;
        final variant = _detectVariant(base);
        found[variant] ??= entity.path;
      }
    } catch (_) {}
    return _orderedVariantPaths(found);
  }

  void _logDebugPaths(String? resolved) {
    assert(() {
      logger.debug(
        'ChatImage',
        '查找解密图片: datName=$_datName, displayName=$_displayName, 解析到=$resolved',
      );
      if (_decryptedVariantIndex.isNotEmpty) {
        final sample = _decryptedVariantIndex.entries
            .take(5)
            .map((e) {
              final variants = e.value.keys.map((v) => v.name).join('/');
              return '${e.key}:$variants';
            })
            .join(', ');
        logger.debug('ChatImage', '当前已索引解密文件(部分): $sample');
      }
      return true;
    }());
  }

  Future<void> _loadDisplayName(AppState appState) async {
    try {
      final names = await appState.databaseService
          .getDisplayNames([widget.sessionUsername]);
      final name = names[widget.sessionUsername];
      if (name != null && name.trim().isNotEmpty) {
        _displayName = _sanitizeSegment(name);
      }
    } catch (_) {}
  }

  String _sanitizeSegment(String name) {
    var sanitized = name.replaceAll(RegExp(r'[<>:"/\\\\|?*]'), '_').trim();
    if (sanitized.isEmpty) return '未知联系人';
    if (sanitized.length > 60) sanitized = sanitized.substring(0, 60);
    return sanitized;
  }

  // 路径映射统一由 AppState 处理
}
