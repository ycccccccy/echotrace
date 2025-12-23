import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/message.dart';
import '../providers/app_state.dart';
import '../services/logger_service.dart';
import '../services/voice_message_service.dart';
import 'toast_overlay.dart';

class VoiceMessageWidget extends StatefulWidget {
  const VoiceMessageWidget({
    super.key,
    required this.message,
    required this.sessionUsername,
    required this.isFromMe,
  });

  final Message message;
  final String sessionUsername;
  final bool isFromMe;

  @override
  State<VoiceMessageWidget> createState() => _VoiceMessageWidgetState();
}

class _VoiceMessageWidgetState extends State<VoiceMessageWidget>
    with TickerProviderStateMixin {
  late final ToastOverlay _toast;
  final AudioPlayer _player = AudioPlayer();
  bool _isDecrypting = false;
  bool _isPlaying = false;
  bool _isPaused = false;
  String? _filePath;
  int? _resolvedDurationSeconds;
  bool _durationLoading = false;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<String>? _decodeFinishedSub;
  String? _expectedOutputPath;
  static const Duration _sourceTimeout = Duration(seconds: 5);
  static const Duration _decodeTimeout = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _toast = ToastOverlay(this);
    _subscribeDecodeFinished();
    _initExisting();
    _ensureDurationLoaded();
    _stateSub = _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() {
        _isPlaying = state == PlayerState.playing;
        _isPaused = state == PlayerState.paused;
      });
    });
  }

  @override
  void didUpdateWidget(covariant VoiceMessageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当列表重建或状态变更导致重新build时，若尚未加载到本地文件，则再次检查。
    if (_filePath == null && !_isDecrypting) {
      _initExisting();
    }
    if (widget.message.localId != oldWidget.message.localId ||
        widget.sessionUsername != oldWidget.sessionUsername) {
      _resolvedDurationSeconds = null;
      _durationLoading = false;
      _subscribeDecodeFinished();
      _ensureDurationLoaded();
    }
  }

  Future<void> _ensureDurationLoaded() async {
    if (_durationLoading) return;
    final existing = widget.message.voiceDurationSeconds;
    if (existing != null && existing > 0) {
      _resolvedDurationSeconds = existing;
      return;
    }
    final derived = _durationFromDisplayContent();
    if (derived != null && derived > 0) {
      _resolvedDurationSeconds = derived;
      return;
    }
    _durationLoading = true;
    try {
      final appState = context.read<AppState>();
      final seconds =
          await appState.voiceService.fetchDurationSeconds(widget.message);
      if (!mounted) return;
      if (seconds != null && seconds > 0) {
        setState(() {
          _resolvedDurationSeconds = seconds;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _durationLoading = false;
        });
      }
    }
  }

  int? _durationFromDisplayContent() {
    final content = widget.message.displayContent;
    final match = RegExp(r'语音\\s*([0-9]+(?:\\.[0-9]+)?)\\s*秒')
        .firstMatch(content);
    if (match == null) return null;
    final raw = double.tryParse(match.group(1)!);
    if (raw == null || raw <= 0) return null;
    if (raw > 1000) return (raw / 1000).round();
    return raw.round();
  }

  int? _validDuration(int? value) {
    if (value == null || value <= 0) return null;
    return value;
  }

  Future<void> _subscribeDecodeFinished() async {
    _decodeFinishedSub?.cancel();
    final appState = context.read<AppState>();
    final outputFile = await appState.voiceService.getOutputFile(
      widget.message,
      widget.sessionUsername,
    );
    if (!mounted) return;
    _expectedOutputPath = outputFile.path;
    _decodeFinishedSub = appState.voiceService.decodeFinishedStream.listen((
      path,
    ) async {
      if (!mounted) return;
      if (path != _expectedOutputPath) return;
      final exists = await File(path).exists();
      if (!mounted || !exists) return;
      setState(() {
        _filePath = path;
        _isDecrypting = false;
        _isPaused = false;
        _isPlaying = false;
      });
    });
  }

  Future<void> _initExisting() async {
    final appState = context.read<AppState>();
    final file = await appState.voiceService.findExistingVoiceFile(
      widget.message,
      widget.sessionUsername,
    );
    if (!mounted) return;
    if (file != null) {
      await logger.debug(
        'VoiceWidget',
        'initExisting hit cache: ${file.path}, msgId=${widget.message.localId}',
      );
      if (!mounted) return;
      setState(() {
        _filePath = file.path;
        _isPaused = false;
        _isDecrypting = false;
      });
      // 延迟加载音源到播放时，避免卡住初始化
    }
  }

  Future<void> _play() async {
    if (_filePath == null) return;
    await _player.stop();
    if (await _safeSetSource(_filePath!)) {
      await _player.resume();
    }
  }

  Future<void> _decrypt() async {
    if (_isDecrypting) return;
    setState(() => _isDecrypting = true);
    try {
      final appState = context.read<AppState>();
      final file = await appState.voiceService
          .ensureVoiceDecoded(widget.message, widget.sessionUsername)
          .timeout(
            _decodeTimeout,
            onTimeout: () => throw TimeoutException('语音解密超时'),
          );
      if (!mounted) return;
      await logger.info(
        'VoiceWidget',
        'decrypt ok: ${file.path}, msgId=${widget.message.localId}',
      );
      setState(() {
        _filePath = file.path;
        _isPaused = false;
        _isPlaying = false;
      });
      // 不自动加载/播放，等待用户点击，避免卡住
    } on SelfSentVoiceNotSupportedException {
      if (!mounted) return;
      _toast.show(context, '暂不支持解密自己发送的语音', success: false);
    } catch (e) {
      if (!mounted) return;
      // 如果后台解密已完成但状态未更新，尝试直接读取缓存文件以防UI卡住
      if (_filePath == null) {
        final cached = await context
            .read<AppState>()
            .voiceService
            .findExistingVoiceFile(widget.message, widget.sessionUsername);
        if (cached != null) {
          await logger.warning(
            'VoiceWidget',
            'decode finished in background, recovered from cache: '
                '${cached.path}, msgId=${widget.message.localId}',
          );
          if (!mounted) return;
          setState(() {
            _filePath = cached.path;
            _isPaused = false;
            _isPlaying = false;
          });
        }
      }
      if (_filePath != null) {
        _toast.show(context, '解密完成，但UI未及时更新，已恢复语音文件');
        return;
      }
      _toast.show(context, '解密语音失败: $e', success: false);
    } finally {
      if (mounted) {
        setState(() => _isDecrypting = false);
      }
    }
  }

  @override
  void dispose() {
    _toast.dispose();
    _stateSub?.cancel();
    _decodeFinishedSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration =
        _validDuration(widget.message.voiceDurationSeconds) ??
        _resolvedDurationSeconds ??
        _durationFromDisplayContent();
    final durationText = duration != null && duration > 0 ? '$duration秒' : '';

    final theme = Theme.of(context);
    final bubbleColor = widget.isFromMe
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = widget.isFromMe
        ? Colors.white
        : theme.colorScheme.onSurface;

    final canPlay = _filePath != null;
    final isBusy = _isDecrypting;
    final icon = canPlay
        ? (_isPlaying
              ? Icons.pause_circle_filled_rounded
              : Icons.play_circle_fill_rounded)
        : Icons.lock_open_rounded;

    String baseLabel() => durationText.isNotEmpty ? '语音 $durationText' : '语音';

    String labelForPlayable() {
      if (_isPlaying) {
        return durationText.isNotEmpty ? '播放中 $durationText' : '播放中';
      }
      return baseLabel();
    }

    String labelForLocked() => '点击以解密${baseLabel()}';

    final label = isBusy
        ? '解密中 ${durationText.isNotEmpty ? durationText : ""}'.trim()
        : canPlay
        ? labelForPlayable()
        : labelForLocked();

    final labelStyle = theme.textTheme.bodyMedium?.copyWith(
      color: textColor,
      fontWeight: FontWeight.w600,
    );

    return GestureDetector(
      onTap: () async {
        if (isBusy) return;
        if (!canPlay) {
          await logger.debug(
            'VoiceWidget',
            'tap to decrypt msgId=${widget.message.localId}',
          );
          await _decrypt();
          return;
        }
        if (_isPlaying) {
          await logger.debug(
            'VoiceWidget',
            'tap pause msgId=${widget.message.localId}',
          );
          await _player.pause();
          return;
        }
        if (_isPaused) {
          await logger.debug(
            'VoiceWidget',
            'tap resume msgId=${widget.message.localId}',
          );
          await _player.resume();
          return;
        }
        await logger.debug(
          'VoiceWidget',
          'tap play msgId=${widget.message.localId} path=$_filePath',
        );
        if (!mounted) return;
        await _play();
        // 播放动作结束后强制刷新以更新按钮文本
        if (mounted) setState(() {});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (isBusy)
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    textColor.withValues(alpha: 0.9),
                  ),
                ),
              )
            else
              Icon(icon, size: 22, color: textColor.withValues(alpha: 0.9)),
            const SizedBox(width: 10),
            Text(label, style: labelStyle),
          ],
        ),
      ),
    );
  }

  /// 安全设置音源
  Future<bool> _safeSetSource(String path) async {
    final exists = await File(path).exists();
    if (!exists) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('语音文件不存在或已被删除')));
      }
      return false;
    }
    try {
      await _player.setSourceDeviceFile(path).timeout(_sourceTimeout);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载语音失败: $e')));
      }
      return false;
    }
  }
}
