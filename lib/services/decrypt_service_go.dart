// 数据库解密服务（Go FFI）：校验密钥并解密数据库到临时路径
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'go_decrypt_ffi.dart';

/// 解密服务（使用 Go FFI）
class DecryptServiceGo {
  final GoDecryptFFI _ffi = GoDecryptFFI();

  /// 初始化服务
  Future<void> initialize() async {
    // Go FFI 在构造时自动初始化
  }

  /// 清理资源
  void dispose() {
    // 无需清理操作
  }

  /// 验证密钥
  Future<bool> validateKey(String dbPath, String hexKey) async {
    try {
      // 检查文件是否存在
      final file = File(dbPath);
      if (!await file.exists()) {
        return false;
      }

      // 调用 Go FFI 验证密钥
      return _ffi.validateKey(dbPath, hexKey);
    } catch (e) {
      return false;
    }
  }

  /// 解密数据库文件
  ///
  /// [dbPath] 输入数据库路径
  /// [hexKey] 十六进制格式的密钥（64个字符）
  /// [progressCallback] 进度回调（当前页，总页数）
  ///
  /// 返回解密后的数据库文件路径
  Future<String> decryptDatabase(
    String dbPath,
    String hexKey,
    Function(int, int) progressCallback,
  ) async {
    try {
      // 验证参数
      if (hexKey.length != 64) {
        throw Exception('密钥长度必须为64个字符（32字节）');
      }

      final file = File(dbPath);
      if (!await file.exists()) {
        throw Exception('数据库文件不存在');
      }

      // 生成输出路径
      final tempDir = await getTemporaryDirectory();
      final outputPath =
          '${tempDir.path}${Platform.pathSeparator}decrypted_${DateTime.now().millisecondsSinceEpoch}.db';

      // 获取文件大小用于进度估算
      final fileSize = await file.length();
      const pageSize = 4096;
      final totalPages = (fileSize / pageSize).ceil();

      // 开始解密前报告初始进度
      progressCallback(0, totalPages);

      // 调用 Go FFI 解密
      final error = await _decryptInBackground(dbPath, outputPath, hexKey);
      if (error != null) {
        throw Exception(error);
      }

      // 解密完成，报告最终进度
      progressCallback(totalPages, totalPages);

      return outputPath;
    } catch (e) {
      rethrow;
    }
  }

  /// 在后台线程执行解密
  Future<String?> _decryptInBackground(
    String inputPath,
    String outputPath,
    String hexKey,
  ) async {
    // 使用 compute 在独立的 isolate 中执行
    // 但由于 FFI 调用本身不能跨 isolate，这里直接调用
    return _ffi.decryptDatabase(inputPath, outputPath, hexKey);
  }
}
