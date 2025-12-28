import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/message.dart';

/// 动画表情消息组件：解析 CDN URL 下载并缓存到文档目录
class EmojiMessageWidget extends StatefulWidget {
  final Message message;
  final bool isFromMe;

  const EmojiMessageWidget({
    super.key,
    required this.message,
    this.isFromMe = false,
  });

  @override
  State<EmojiMessageWidget> createState() => _EmojiMessageWidgetState();
}

class _EmojiMessageWidgetState extends State<EmojiMessageWidget> {
  String? _localPath;
  String? _errorMessage;
  bool _isLoading = true;
  late final Size _layoutSize;
  static const double _minEmojiSize = 60;
  static const double _maxEmojiSize = 140;
  static const double _fallbackEmojiSize = 90;

  static final Map<String, String> _cachedPaths = {};
  static final Map<String, Future<String?>> _inflight = {};

  @override
  void initState() {
    super.initState();
    _layoutSize = _resolveLayoutSize();
    _loadEmoji();
  }

  @override
  void didUpdateWidget(covariant EmojiMessageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.localId != widget.message.localId ||
        oldWidget.message.emojiCdnUrl != widget.message.emojiCdnUrl ||
        oldWidget.message.emojiMd5 != widget.message.emojiMd5) {
      _loadEmoji();
    }
  }

  Future<void> _loadEmoji() async {
    final url = widget.message.emojiCdnUrl;
    final md5 = widget.message.emojiMd5;
    final hasUrl = url != null && url.isNotEmpty;
    final hasMd5 = md5 != null && md5.isNotEmpty;
    if (!hasUrl && !hasMd5) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '未获取到动画表情信息';
        });
      }
      return;
    }

    final cacheKey = _cacheKey(url ?? '', md5);
    final cached = _cachedPaths[cacheKey];
    if (cached != null && await File(cached).exists()) {
      if (mounted) {
        setState(() {
          _localPath = cached;
          _isLoading = false;
        });
      }
      return;
    }

    final docs = await getApplicationDocumentsDirectory();
    final emojiDir = Directory(p.join(docs.path, 'EchoTrace', 'Emojis'));
    if (!await emojiDir.exists()) {
      await emojiDir.create(recursive: true);
    }

    final existing = await _findExistingCache(
      emojiDir,
      md5,
      url ?? '',
    );
    if (existing != null) {
      _cachedPaths[cacheKey] = existing;
      if (mounted) {
        setState(() {
          _localPath = existing;
          _isLoading = false;
        });
      }
      return;
    }

    if (!hasUrl) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '未找到本地动画表情缓存';
        });
      }
      return;
    }

    Future<String?> future;
    if (_inflight.containsKey(cacheKey)) {
      future = _inflight[cacheKey]!;
    } else {
      future = _downloadAndCache(emojiDir, url, md5);
      _inflight[cacheKey] = future;
    }

    final path = await future;
    _inflight.remove(cacheKey);
    if (path != null) {
      _cachedPaths[cacheKey] = path;
    }

    if (mounted) {
      setState(() {
        _localPath = path;
        _isLoading = false;
        _errorMessage = path == null ? '下载动画表情失败' : null;
      });
    }
  }

  String _cacheKey(String url, String? md5) {
    if (md5 != null && md5.isNotEmpty) return md5;
    return url.hashCode.toUnsigned(32).toString();
  }

  Future<String?> _findExistingCache(
    Directory dir,
    String? md5,
    String url,
  ) async {
    final base = _cacheKey(url, md5);
    for (final ext in const ['.gif', '.png', '.webp', '.jpg', '.jpeg']) {
      final candidate = File(p.join(dir.path, '$base$ext'));
      if (await candidate.exists()) {
        return candidate.path;
      }
    }
    return null;
  }

  Future<String?> _downloadAndCache(
    Directory dir,
    String url,
    String? md5,
  ) async {
    try {
      final response = await http.get(Uri.parse(url));
      final bytes = response.bodyBytes;
      if (response.statusCode != 200 || bytes.isEmpty) {
        return null;
      }

      final contentType = response.headers['content-type'] ?? '';
      final sniffedExt = _detectImageExtension(bytes);
      final ext = sniffedExt ?? _pickExtension(url, contentType);
      final base = _cacheKey(url, md5);
      final outPath = p.join(dir.path, '$base$ext');
      final file = File(outPath);
      await file.writeAsBytes(bytes, flush: true);
      return outPath;
    } catch (_) {
      return null;
    }
  }

  String _pickExtension(String url, String contentType) {
    final uriExt = p.extension(Uri.parse(url).path);
    if (uriExt.isNotEmpty && uriExt.length <= 5) {
      return uriExt;
    }
    final lower = contentType.toLowerCase();
    if (lower.contains('png')) return '.png';
    if (lower.contains('webp')) return '.webp';
    if (lower.contains('jpeg') || lower.contains('jpg')) return '.jpg';
    return '.gif';
  }

  String? _detectImageExtension(List<int> bytes) {
    if (bytes.length < 12) return null;
    // GIF87a/GIF89a
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      return '.gif';
    }
    // PNG signature
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return '.png';
    }
    // JPEG SOI
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return '.jpg';
    }
    // WEBP (RIFF....WEBP)
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _buildSizedFrame(
        Container(
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_localPath == null) {
      return _buildSizedFrame(
        InkWell(
          onTap: _loadEmoji,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: widget.isFromMe
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _errorMessage ?? '[动画表情]',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: widget.isFromMe
                        ? Colors.white
                        : Theme.of(context).colorScheme.onSurface,
                  ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: _layoutSize.width,
      height: _layoutSize.height,
      child: Image.file(
        File(_localPath!),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        width: widget.message.emojiWidth?.toDouble(),
        height: widget.message.emojiHeight?.toDouble(),
      ),
    );
  }

  Widget _buildSizedFrame(Widget child) {
    final alignment =
        widget.isFromMe ? Alignment.topRight : Alignment.topLeft;
    return SizedBox(
      width: _layoutSize.width,
      height: _layoutSize.height,
      child: Align(
        alignment: alignment,
        child: child,
      ),
    );
  }

  Size _resolveLayoutSize() {
    final width = widget.message.emojiWidth?.toDouble();
    final height = widget.message.emojiHeight?.toDouble();
    if (width == null || height == null || width <= 0 || height <= 0) {
      return const Size(_fallbackEmojiSize, _fallbackEmojiSize);
    }
    return _scaleToBounds(
      Size(width, height),
      minSize: _minEmojiSize,
      maxSize: _maxEmojiSize,
    );
  }

  Size _scaleToBounds(
    Size raw, {
    required double minSize,
    required double maxSize,
  }) {
    var width = raw.width;
    var height = raw.height;
    if (width <= 0 || height <= 0) {
      return const Size(_fallbackEmojiSize, _fallbackEmojiSize);
    }
    final maxDim = math.max(width, height);
    if (maxDim > maxSize) {
      final scale = maxSize / maxDim;
      width *= scale;
      height *= scale;
    }
    final minDim = math.min(width, height);
    if (minDim < minSize && minDim > 0) {
      final scale = minSize / minDim;
      width *= scale;
      height *= scale;
      final capped = math.max(width, height);
      if (capped > maxSize) {
        final scaleDown = maxSize / capped;
        width *= scaleDown;
        height *= scaleDown;
      }
    }
    return Size(width, height);
  }
}
