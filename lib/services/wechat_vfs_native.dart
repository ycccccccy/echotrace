import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pointycastle/export.dart';
import 'package:cryptography/cryptography.dart';

// C++函数签名
typedef RegisterVFSNative = Int32 Function();
typedef RegisterVFSDart = int Function();

typedef RegisterCallbackNative = Void Function(Pointer<Utf8> dbPath, Pointer<Utf8> encKey, Pointer<Utf8> macKey);
typedef RegisterCallbackDart = void Function(Pointer<Utf8> dbPath, Pointer<Utf8> encKey, Pointer<Utf8> macKey);

typedef UnregisterCallbackNative = Void Function(Pointer<Utf8> dbPath);
typedef UnregisterCallbackDart = void Function(Pointer<Utf8> dbPath);

typedef GetCallbackCountNative = Int32 Function();
typedef GetCallbackCountDart = int Function();

// 解密回调签名
typedef DecryptCallbackNative = Void Function(Pointer<Utf8> dbPath, Int32 pageNum, Pointer<Uint8> encrypted, Pointer<Uint8> decrypted);
typedef DecryptCallbackDart = void Function(Pointer<Utf8> dbPath, int pageNum, Pointer<Uint8> encrypted, Pointer<Uint8> decrypted);

/// 微信VFS原生接口（轻量级）
/// 
/// C++只负责拦截，解密由Dart完成
class WeChatVFSNative {
  static const int pageSize = 4096;
  static const int iterCount = 256000;
  static const int saltSize = 16;
  static const int ivSize = 16;
  static const int keySize = 32;
  static const int reserveSize = 80;
  
  static DynamicLibrary? _lib;
  static bool _initialized = false;
  
  static RegisterVFSDart? _registerVFS;
  static RegisterCallbackDart? _registerCallback;
  static UnregisterCallbackDart? _unregisterCallback;
  static GetCallbackCountDart? _getCallbackCount;
  
  // 存储加密上下文
  static final Map<String, _EncryptionContext> _contexts = {};
  
  /// 初始化VFS
  static bool initialize() {
    if (_initialized) return true;

    try {
      // 先尝试在当前目录查找DLL
      String dllPath;
      if (Platform.isWindows) {
        dllPath = 'wechat_vfs.dll';
      } else if (Platform.isLinux) {
        dllPath = 'libwechat_vfs.so';
      } else if (Platform.isMacOS) {
        dllPath = 'libwechat_vfs.dylib';
      } else {
        return false;
      }

      // 尝试多种路径
      final possiblePaths = [
        dllPath,  // 当前目录
        'build/windows/x64/runner/$dllPath',  // 构建目录
        'windows/runner/$dllPath',  // 项目目录
      ];

      DynamicLibrary? lib;
      for (final path in possiblePaths) {
        try {
          lib = DynamicLibrary.open(path);
          break;
        } catch (e) {
        }
      }

      if (lib == null) {
        return false;
      }

      _lib = lib;

      // 加载函数
      _registerVFS = _lib!
          .lookup<NativeFunction<RegisterVFSNative>>('wechat_vfs_register')
          .asFunction();

      _registerCallback = _lib!
          .lookup<NativeFunction<RegisterCallbackNative>>('wechat_vfs_register_keys')
          .asFunction();

      _unregisterCallback = _lib!
          .lookup<NativeFunction<UnregisterCallbackNative>>('wechat_vfs_unregister_keys')
          .asFunction();
      
      _getCallbackCount = _lib!
          .lookup<NativeFunction<GetCallbackCountNative>>('wechat_vfs_get_callback_count')
          .asFunction();
      
      // 注册VFS到SQLite
      final result = _registerVFS!();
      if (result != 0) {
        return false;
      }

      _initialized = true;
      return true;
    } catch (e) {
      return false;
    }
  }
  
  // Dart回调不再需要，解密由C++完成
  
  /// 注册数据库加密密钥
  static Future<bool> registerDatabaseKey(String dbPath, String hexKey) async {
    if (!_initialized) {
      if (!initialize()) return false;
    }
    
    try {
      final key = _hexToBytes(hexKey);
      if (key.length != keySize) {
        throw Exception('密钥长度必须为64个字符（32字节）');
      }
      
      // 读取salt
      final file = File(dbPath);
      final bytes = await file.openRead(0, pageSize).first;
      final salt = bytes.sublist(0, saltSize);
      
      
      // 派生密钥
      final encKey = await _deriveEncryptionKey(key, salt);
      final macKey = await _deriveMacKey(encKey, salt);
      
      
      // 保存加密上下文
      _contexts[dbPath] = _EncryptionContext(encKey, macKey);
      
      
      // 转换密钥为hex字符串
      String encKeyHex = encKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
      String macKeyHex = macKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
      
      // 注册密钥（传递给C++，由C++完成解密）
      final pathPtr = dbPath.toNativeUtf8();
      final encKeyPtr = encKeyHex.toNativeUtf8();
      final macKeyPtr = macKeyHex.toNativeUtf8();
      
      _registerCallback!(pathPtr, encKeyPtr, macKeyPtr);
      
      malloc.free(pathPtr);
      malloc.free(encKeyPtr);
      malloc.free(macKeyPtr);
      
      
      // 验证回调是否成功注册
      final callbackCount = _getCallbackCount!();
      if (callbackCount == 0) {
        return false;
      }
      
      return true;
    } catch (e) {
      return false;
    }
  }
  
  /// 解密回调（被C++ VFS调用）
  // ignore: unused_element
  static void _decryptCallback(Pointer<Utf8> dbPathPtr, int pageNum, Pointer<Uint8> encryptedPtr, Pointer<Uint8> decryptedPtr) {
    try {
      final dbPath = dbPathPtr.toDartString();
      final context = _contexts[dbPath];
      if (context == null) {
        return;
      }
      
      // 读取加密页面（立即复制，因为C++端可能异步释放内存）
      final encryptedView = encryptedPtr.asTypedList(pageSize);
      final encrypted = Uint8List.fromList(encryptedView); // 立即复制到Dart管理的内存
      
      // 解密
      final decrypted = _decryptPage(encrypted, pageNum, context);
      
      // 调试：打印第0页的解密详情
      if (pageNum == 0) {
        final header = String.fromCharCodes(decrypted.sublist(0, 16));
      }
      
      // 写回解密结果
      for (int i = 0; i < decrypted.length && i < pageSize; i++) {
        decryptedPtr[i] = decrypted[i];
      }
    } catch (e, stackTrace) {
    }
  }
  
  /// 解密单个页面（VFS模式：总是返回4096字节）
  static Uint8List _decryptPage(Uint8List page, int pageNum, _EncryptionContext context) {
    final offset = pageNum == 0 ? saltSize : 0;
    
    // 检查是否全为零
    if (_isAllZeros(page)) {
      if (pageNum == 0) {
        // 第0页全零：返回4096字节的零
        return Uint8List(pageSize);
      } else {
        return page;
      }
    }
    
    // HMAC验证（跳过以提升性能，VFS实时模式下）
    // 可以在这里添加HMAC验证如果需要
    
    // 提取IV（从保留区开始的位置）
    final iv = page.sublist(pageSize - reserveSize, pageSize - reserveSize + ivSize);
    
    // AES-256-CBC 解密（从offset开始，到保留区之前）
    final encrypted = page.sublist(offset, pageSize - reserveSize);
    final decrypted = _aesDecrypt(encrypted, iv, context.encKey);
    
    // 拼接保留区
    final reserveData = page.sublist(pageSize - reserveSize, pageSize);
    
    // VFS需要返回4096字节
    // 第0页：解密4000字节 + 保留区80字节 = 4080字节，需要补16字节到4096
    // 其他页：解密4016字节 + 保留区80字节 = 4096字节
    final result = Uint8List(pageSize);
    result.setRange(0, decrypted.length, decrypted);
    result.setRange(decrypted.length, decrypted.length + reserveSize, reserveData);
    // 剩余部分自动填充为0（对第0页，最后16字节）
    
    return result;
  }
  
  /// AES-256-CBC 解密
  static List<int> _aesDecrypt(List<int> encrypted, List<int> iv, List<int> key) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(Uint8List.fromList(key)), Uint8List.fromList(iv)));

    final decrypted = Uint8List(encrypted.length);
    int offset = 0;

    while (offset < encrypted.length) {
      offset += cipher.processBlock(Uint8List.fromList(encrypted), offset, decrypted, offset);
    }

    return decrypted;
  }
  
  /// 检查字节数组是否全为零
  static bool _isAllZeros(List<int> bytes) {
    for (final byte in bytes) {
      if (byte != 0) return false;
    }
    return true;
  }
  
  /// 派生加密密钥（PBKDF2）
  static Future<List<int>> _deriveEncryptionKey(List<int> key, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha512(),
      iterations: iterCount,
      bits: keySize * 8,
    );
    final secretKey = SecretKey(key);
    final newKey = await pbkdf2.deriveKey(
      secretKey: secretKey,
      nonce: salt,
    );
    return await newKey.extractBytes();
  }

  /// 派生MAC密钥
  static Future<List<int>> _deriveMacKey(List<int> encKey, List<int> salt) async {
    final macSalt = Uint8List.fromList(salt.map((b) => b ^ 0x3a).toList());
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha512(),
      iterations: 2,
      bits: keySize * 8,
    );
    final secretKey = SecretKey(encKey);
    final newKey = await pbkdf2.deriveKey(
      secretKey: secretKey,
      nonce: macSalt,
    );
    return await newKey.extractBytes();
  }
  
  /// 注销数据库加密密钥
  static void unregisterDatabaseKey(String dbPath) {
    if (!_initialized) return;
    
    final pathPtr = dbPath.toNativeUtf8();
    try {
      _unregisterCallback!(pathPtr);
      _contexts.remove(dbPath);
    } finally {
      malloc.free(pathPtr);
    }
  }
  
  /// 使用VFS打开加密数据库
  static Future<Database> openEncryptedDatabase(String dbPath, String hexKey) async {
    // 注册密钥和回调
    if (!await registerDatabaseKey(dbPath, hexKey)) {
      throw Exception('注册加密密钥失败');
    }
    
    try {
      
      // 使用sqflite_common_ffi在当前isolate中打开数据库
      // 这确保VFS回调也在同一isolate中执行
      final db = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          readOnly: true,
          singleInstance: false,
        ),
      );
      
      
      return db;
    } catch (e) {
      unregisterDatabaseKey(dbPath);
      rethrow;
    }
  }
  
  /// 关闭加密数据库
  static Future<void> closeEncryptedDatabase(Database db, String dbPath) async {
    await db.close();
    unregisterDatabaseKey(dbPath);
  }
  
  static List<int> _hexToBytes(String hex) {
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
}

class _EncryptionContext {
  final List<int> encKey;
  final List<int> macKey;
  
  _EncryptionContext(this.encKey, this.macKey);
}
