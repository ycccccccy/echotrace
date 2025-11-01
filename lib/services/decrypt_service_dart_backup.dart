import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:isolate';
import 'package:path_provider/path_provider.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart';

/// Isolate 通信消息
class _IsolateMessage {
  final String type; // 'progress' | 'error' | 'done'
  final int? current;
  final int? total;
  final String? result;
  final String? error;

  _IsolateMessage({
    required this.type,
    this.current,
    this.total,
    this.result,
    this.error,
  });
}

/// 解密任务参数
class _DecryptTask {
  final String inputPath;
  final String outputPath;
  final List<int> key;
  final SendPort sendPort;
  final bool skipHmacValidation; // 是否跳过HMAC验证（提速）

  _DecryptTask({
    required this.inputPath,
    required this.outputPath,
    required this.key,
    required this.sendPort,
    this.skipHmacValidation = true, // 默认跳过以提速
  });
}

/// 解密服务
class DecryptService {
  // 微信 4.x 版本常量
  static const int pageSize = 4096;
  static const int iterCount = 256000;
  static const int hmacSize = 64;
  static const int saltSize = 16;
  static const int ivSize = 16;
  static const int keySize = 32;
  static const int reserveSize = 80;
  static final List<int> sqliteHeader = [
    83,
    81,
    76,
    105,
    116,
    101,
    32,
    102,
    111,
    114,
    109,
    97,
    116,
    32,
    51,
    0,
  ]; // "SQLite format 3\x00" 的字节表示

  /// 初始化服务（兼容性方法）
  Future<void> initialize() async {
    // 无需初始化操作
  }

  /// 清理资源
  void dispose() {
    // 无需清理操作，仅提供方法签名
  }

  /// 验证密钥
  Future<bool> validateKey(String dbPath, String hexKey) async {
    try {
      final key = _hexToBytes(hexKey);
      if (key.length != keySize) return false;

      final file = File(dbPath);
      if (!await file.exists()) return false;

      final firstPage = await _readPage(file, 0);
      if (_isAlreadyDecrypted(firstPage)) return false;

      final salt = firstPage.sublist(0, saltSize);

      // 派生密钥
      final encKey = await _deriveEncryptionKey(key, salt);
      final macKey = await _deriveMacKey(encKey, salt);

      return await _validateKey(firstPage, macKey);
    } catch (e) {
      return false;
    }
  }

  /// 解密数据库文件（使用独立后台 Isolate）
  ///
  /// [skipHmacValidation] 跳过除首页外的HMAC验证以提速（默认true，可提升30-50%速度）
  ///
  /// 每个数据库文件在独立的Isolate中完整处理，解密完成后Isolate自动销毁
  /// **所有密钥派生和验证都在Isolate中完成，主线程不阻塞**
  Future<String> decryptDatabase(
    String dbPath,
    String hexKey,
    Function(int, int) progressCallback, {
    bool skipHmacValidation = true,
  }) async {
    try {
      // 快速参数检查（主线程）
      final key = _hexToBytes(hexKey);
      if (key.length != keySize) {
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

      // 立即启动 Isolate（所有密钥派生和验证在Isolate中完成，主线程不阻塞）
      final receivePort = ReceivePort();
      final task = _DecryptTask(
        inputPath: dbPath,
        outputPath: outputPath,
        key: key,
        sendPort: receivePort.sendPort,
        skipHmacValidation: skipHmacValidation,
      );

      // 启动 Isolate（解密完成后自动销毁）
      await Isolate.spawn(_decryptInIsolate, task);

      // 监听进度消息
      String? result;
      await for (final message in receivePort) {
        if (message is _IsolateMessage) {
          if (message.type == 'progress') {
            progressCallback(message.current!, message.total!);
          } else if (message.type == 'done') {
            result = message.result;
            receivePort.close();
            break;
          } else if (message.type == 'error') {
            receivePort.close();
            throw Exception(message.error);
          }
        }
      }

      return result ?? outputPath;
    } catch (e) {
      rethrow;
    }
  }

  /// 独立 Isolate 解密入口函数
  ///
  /// 这个函数在独立的Isolate中完整处理一个数据库文件：
  /// 1. 读取文件到内存
  /// 2. 计算派生密钥
  /// 3. 逐页解密
  /// 4. 写入输出文件
  /// 5. 报告完成并自动销毁Isolate
  static Future<void> _decryptInIsolate(_DecryptTask task) async {
    try {
      // 读取整个加密文件到内存
      final encryptedData = await File(task.inputPath).readAsBytes();
      final fileSize = encryptedData.length;
      final totalPages = (fileSize / pageSize).ceil();

      // 提取 salt
      final salt = encryptedData.sublist(0, saltSize);

      // 派生密钥（每个Isolate独立计算）
      final encKey = await _deriveEncryptionKeyStatic(task.key, salt);
      final macKey = await _deriveMacKeyStatic(encKey, salt);

      // 创建输出缓冲区
      final decryptedData = BytesBuilder();
      decryptedData.add(sqliteHeader);

      // 解密所有页面
      for (int pageNum = 0; pageNum < totalPages; pageNum++) {
        // 提取页面数据
        final start = pageNum * pageSize;
        final end = (start + pageSize < fileSize) ? start + pageSize : fileSize;
        var page = encryptedData.sublist(start, end);

        // 补齐页面大小
        if (page.length < pageSize) {
          final paddedPage = Uint8List(pageSize);
          paddedPage.setRange(0, page.length, page);
          page = paddedPage;
        }

        // 检查是否全为零
        if (_isAllZerosStatic(page)) {
          // 全零页面直接添加，不做特殊处理
          decryptedData.add(page);
        } else {
          // 解密页面
          // 第一页总是验证HMAC（确保密钥正确），其他页面可选跳过
          final shouldValidate = (pageNum == 0) || !task.skipHmacValidation;
          final decryptedPage = _decryptPageStatic(
            page,
            encKey,
            macKey,
            pageNum,
            !shouldValidate, // 转换为skipValidation参数
          );
          decryptedData.add(decryptedPage);
        }

        // 每10页报告一次进度
        if (pageNum % 10 == 0 || pageNum == totalPages - 1) {
          task.sendPort.send(
            _IsolateMessage(
              type: 'progress',
              current: pageNum + 1,
              total: totalPages,
            ),
          );
        }
      }

      // 写入输出文件
      await File(task.outputPath).writeAsBytes(decryptedData.toBytes());

      // 发送完成消息（Isolate随后自动销毁）
      task.sendPort.send(
        _IsolateMessage(type: 'done', result: task.outputPath),
      );
    } catch (e) {
      // 发送错误消息
      task.sendPort.send(_IsolateMessage(type: 'error', error: e.toString()));
    }
  }

  /// 验证页面HMAC（异步版本）
  Future<bool> _validatePageHmac(
    List<int> page,
    List<int> macKey,
    int pageNum,
  ) async {
    final offset = pageNum == 0 ? saltSize : 0;
    final dataEnd = pageSize - reserveSize + ivSize;

    final pageNoBytes = Uint8List(4);
    final byteData = ByteData.sublistView(pageNoBytes);
    byteData.setUint32(0, pageNum + 1, Endian.little);

    final message = Uint8List.fromList([
      ...page.sublist(offset, dataEnd),
      ...pageNoBytes,
    ]);

    // 计算HMAC-SHA512
    final hmac = Hmac.sha512();
    final mac = await hmac.calculateMac(message, secretKey: SecretKey(macKey));
    final calculatedMac = Uint8List.fromList(mac.bytes);
    final storedMac = page.sublist(dataEnd, dataEnd + hmacSize);

    return _bytesEqual(calculatedMac, storedMac);
  }

  /// 派生加密密钥（PBKDF2）
  Future<List<int>> _deriveEncryptionKey(List<int> key, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha512(),
      iterations: iterCount,
      bits: keySize * 8,
    );
    final secretKey = SecretKey(key);
    final newKey = await pbkdf2.deriveKey(secretKey: secretKey, nonce: salt);
    return await newKey.extractBytes();
  }

  /// 派生MAC密钥
  Future<List<int>> _deriveMacKey(List<int> encKey, List<int> salt) async {
    // MAC盐值 = 盐值每个字节 XOR 0x3a
    final macSalt = Uint8List.fromList(salt.map((b) => b ^ 0x3a).toList());

    // 使用PBKDF2派生MAC密钥（2次迭代）
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha512(),
      iterations: 2,
      bits: keySize * 8,
    );
    final secretKey = SecretKey(encKey);
    final newKey = await pbkdf2.deriveKey(secretKey: secretKey, nonce: macSalt);
    return await newKey.extractBytes();
  }

  /// 验证密钥
  Future<bool> _validateKey(List<int> page, List<int> macKey) async {
    return await _validatePageHmac(page, macKey, 0);
  }

  /// 读取页面数据（用于验证密钥）
  Future<List<int>> _readPage(File file, int pageNum) async {
    final raf = await file.open();
    try {
      await raf.setPosition(pageNum * pageSize);
      final data = await raf.read(pageSize);

      // 如果读取的数据不足一页，补零
      if (data.length < pageSize) {
        return [...data, ...List<int>.filled(pageSize - data.length, 0)];
      }

      return data;
    } finally {
      await raf.close();
    }
  }

  /// 检查数据库是否已经解密
  bool _isAlreadyDecrypted(List<int> firstPage) {
    if (firstPage.length < sqliteHeader.length) return false;
    for (int i = 0; i < sqliteHeader.length - 1; i++) {
      if (firstPage[i] != sqliteHeader[i]) return false;
    }
    return true;
  }

  /// 十六进制字符串转字节数组
  List<int> _hexToBytes(String hex) {
    if (hex.length % 2 != 0) {
      throw Exception('十六进制字符串长度必须为偶数');
    }

    final bytes = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      final byte = int.parse(hex.substring(i, i + 2), radix: 16);
      bytes.add(byte);
    }
    return bytes;
  }

  /// 比较两个字节数组是否相等
  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ==================== 静态方法（供 Isolate 使用） ====================

  /// 派生加密密钥（静态版本）
  static Future<List<int>> _deriveEncryptionKeyStatic(
    List<int> key,
    List<int> salt,
  ) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha512(),
      iterations: iterCount,
      bits: keySize * 8,
    );
    final secretKey = SecretKey(key);
    final newKey = await pbkdf2.deriveKey(secretKey: secretKey, nonce: salt);
    return await newKey.extractBytes();
  }

  /// 派生MAC密钥（静态版本）
  static Future<List<int>> _deriveMacKeyStatic(
    List<int> encKey,
    List<int> salt,
  ) async {
    final macSalt = Uint8List.fromList(salt.map((b) => b ^ 0x3a).toList());
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha512(),
      iterations: 2,
      bits: keySize * 8,
    );
    final secretKey = SecretKey(encKey);
    final newKey = await pbkdf2.deriveKey(secretKey: secretKey, nonce: macSalt);
    return await newKey.extractBytes();
  }

  /// 解密单个页面（静态版本）
  static List<int> _decryptPageStatic(
    List<int> page,
    List<int> encKey,
    List<int> macKey,
    int pageNum,
    bool skipHmacValidation,
  ) {
    final offset = pageNum == 0 ? saltSize : 0;

    // HMAC 验证（可选跳过以提速）
    if (!skipHmacValidation) {
      if (!_validatePageHmacStatic(page, macKey, pageNum)) {
        throw Exception('页面 $pageNum HMAC 验证失败');
      }
    }

    // 提取IV
    final iv = page.sublist(
      pageSize - reserveSize,
      pageSize - reserveSize + ivSize,
    );

    // AES-256-CBC 解密
    final encrypted = page.sublist(offset, pageSize - reserveSize);
    final decrypted = _aesDecryptStatic(encrypted, encKey, iv);

    // 拼接保留区
    final reserveData = page.sublist(pageSize - reserveSize, pageSize);
    return [...decrypted, ...reserveData];
  }

  /// 验证页面HMAC（静态版本）
  static bool _validatePageHmacStatic(
    List<int> page,
    List<int> macKey,
    int pageNum,
  ) {
    final offset = pageNum == 0 ? saltSize : 0;
    final dataEnd = pageSize - reserveSize + ivSize;

    final pageNoBytes = Uint8List(4);
    final byteData = ByteData.sublistView(pageNoBytes);
    byteData.setUint32(0, pageNum + 1, Endian.little);

    final message = Uint8List.fromList([
      ...page.sublist(offset, dataEnd),
      ...pageNoBytes,
    ]);

    // 使用 PointyCastle 计算 HMAC-SHA512
    final hmacDigest = HMac(SHA512Digest(), 128)
      ..init(KeyParameter(Uint8List.fromList(macKey)));

    final calculatedMac = hmacDigest.process(Uint8List.fromList(message));
    final storedMac = page.sublist(dataEnd, dataEnd + hmacSize);

    return _bytesEqualStatic(calculatedMac, storedMac);
  }

  /// AES-256-CBC 解密（静态版本）
  static List<int> _aesDecryptStatic(
    List<int> encrypted,
    List<int> key,
    List<int> iv,
  ) {
    final encryptedBytes = Uint8List.fromList(encrypted);
    final keyBytes = Uint8List.fromList(key);
    final ivBytes = Uint8List.fromList(iv);

    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(keyBytes), ivBytes));

    final decrypted = Uint8List(encryptedBytes.length);
    int offset = 0;

    while (offset < encryptedBytes.length) {
      offset += cipher.processBlock(encryptedBytes, offset, decrypted, offset);
    }

    return decrypted;
  }

  /// 检查字节数组是否全为零（静态版本）
  static bool _isAllZerosStatic(List<int> bytes) {
    for (final byte in bytes) {
      if (byte != 0) return false;
    }
    return true;
  }

  /// 比较两个字节数组是否相等（静态版本）
  static bool _bytesEqualStatic(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
