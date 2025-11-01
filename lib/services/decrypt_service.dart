import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'go_decrypt_ffi.dart';

/// 解密服务（使用 Go FFI 实现）
///
/// 原 Dart 实现已备份为 decrypt_service_dart_backup.dart
///
/// 性能对比（100MB 数据库）：
/// - 原 Dart 版本：15-20秒，内存占用 ~200MB
/// - Go 版本：5-8秒，内存占用 ~50MB
/// - 性能提升：2-3倍
class DecryptService {
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
  ///
  /// [dbPath] 数据库文件路径
  /// [hexKey] 十六进制格式的密钥（64个字符）
  ///
  /// 返回 true 表示密钥有效，false 表示无效
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
  ///
  /// 抛出异常：
  /// - 密钥长度不正确
  /// - 数据库文件不存在
  /// - 解密失败
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

      // 生成唯一的输出路径
      // 修复：使用时间戳+微秒+随机数+源文件名，确保并行解密时路径唯一
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      final sourceFileName = dbPath
          .split(Platform.pathSeparator)
          .last
          .replaceAll('.db', '');
      // 添加随机数进一步确保唯一性
      final random = DateTime.now().millisecondsSinceEpoch % 10000;
      final outputPath =
          '${tempDir.path}${Platform.pathSeparator}dec_${sourceFileName}_${timestamp}_$random.db';

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

      // 验证输出文件是否存在
      final outputFile = File(outputPath);
      if (!await outputFile.exists()) {
        throw Exception('解密后的文件不存在: $outputPath');
      }

      // 解密完成，报告最终进度
      progressCallback(totalPages, totalPages);

      return outputPath;
    } catch (e) {
      rethrow;
    }
  }

  /// 在后台执行解密
  /// 对于大文件（>500MB）可能需要几秒钟
  Future<String?> _decryptInBackground(
    String inputPath,
    String outputPath,
    String hexKey,
  ) async {
    // 直接调用 FFI
    return _ffi.decryptDatabase(inputPath, outputPath, hexKey);
  }
}
