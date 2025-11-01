import 'dart:io';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/image_service.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

/// 图片消息组件 - 显示聊天中的图片
class ImageMessageWidget extends StatefulWidget {
  final Message message;
  final String sessionUsername;

  const ImageMessageWidget({
    super.key,
    required this.message,
    required this.sessionUsername,
  });

  @override
  State<ImageMessageWidget> createState() => _ImageMessageWidgetState();
}

class _ImageMessageWidgetState extends State<ImageMessageWidget> {
  String? _imagePath;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    if (!mounted) return;

    try {
      final appState = context.read<AppState>();
      final imageService = ImageService();

      // 初始化图片服务
      final dataPath = appState.databaseService.currentDataPath;
      if (dataPath != null) {
        await imageService.init(dataPath);

        // 获取图片路径
        if (widget.message.imageMd5 != null) {
          final path = await imageService.getImagePath(
            widget.message.imageMd5!,
            widget.sessionUsername,
          );

          if (mounted) {
            setState(() {
              _imagePath = path;
              _isLoading = false;
              _hasError = path == null;
            });
          }
        } else {
          if (mounted) {
            setState(() {
              _isLoading = false;
              _hasError = true;
            });
          }
        }

        await imageService.dispose();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        width: 150,
        height: 150,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_hasError || _imagePath == null) {
      return Container(
        width: 150,
        height: 150,
        decoration: BoxDecoration(
          color: Colors.grey[300],
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.broken_image, size: 48, color: Colors.grey),
            SizedBox(height: 8),
            Text(
              '[图片加载失败]',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      );
    }

    // 显示图片，带点击查看大图功能
    return GestureDetector(
      onTap: () => _showFullImage(context),
      child: Hero(
        tag: 'image_${widget.message.localId}',
        child: Container(
          constraints: const BoxConstraints(
            maxWidth: 300,
            maxHeight: 300,
            minWidth: 100,
            minHeight: 100,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
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
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: 150,
                  height: 150,
                  color: Colors.grey[300],
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.broken_image, size: 48, color: Colors.grey),
                      SizedBox(height: 8),
                      Text(
                        '[图片格式错误]',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                );
              },
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
}
