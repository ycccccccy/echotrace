import 'dart:io';
import 'dart:typed_data';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';

/// 微信图片解密服务
class ImageDecryptService {
  /// 解密微信 V3 版本的 .dat 文件
  /// [inputPath] 输入文件路径
  /// [xorKey] XOR 密钥
  Uint8List decryptDatV3(String inputPath, int xorKey) {
    final file = File(inputPath);
    final data = file.readAsBytesSync();

    final result = Uint8List(data.length);
    for (int i = 0; i < data.length; i++) {
      result[i] = data[i] ^ xorKey;
    }

    return result;
  }

  /// 解密微信 V4 版本的 .dat 文件
  /// [inputPath] 输入文件路径
  /// [xorKey] XOR 密钥
  /// [aesKey] AES 密钥（16字节）
  Uint8List decryptDatV4(String inputPath, int xorKey, Uint8List aesKey) {
    final file = File(inputPath);
    final bytes = file.readAsBytesSync();

    if (bytes.length < 0xF) {
      throw Exception('文件太小，无法解析');
    }

    // 读取文件头（15字节）
    final header = bytes.sublist(0, 0xF);
    final data = bytes.sublist(0xF);

    // 解析文件头（小端序）
    final aesSize = _bytesToInt32(header.sublist(6, 10));
    final xorSize = _bytesToInt32(header.sublist(10, 14));

    // 对齐到AES块大小（16字节）
    final alignedAesSize = aesSize <= 0 ? 0 : ((aesSize + 15) ~/ 16) * 16;
    if (alignedAesSize > data.length) {
      throw Exception('文件格式异常：AES 数据长度超过文件实际长度');
    }

    // 分离AES数据
    final aesData = data.sublist(0, alignedAesSize);

    // AES 解密并去除填充
    Uint8List unpaddedData = Uint8List(0);
    if (aesData.isNotEmpty) {
      final cipher = AESEngine();
      final params = KeyParameter(aesKey);
      cipher.init(false, params); // false = 解密模式

      final decryptedData = Uint8List(aesData.length);
      for (int offset = 0; offset < aesData.length; offset += 16) {
        cipher.processBlock(aesData, offset, decryptedData, offset);
      }

      unpaddedData = _removePadding(decryptedData);
    }

    // 处理XOR数据
    final remainingData = data.sublist(alignedAesSize);
    if (xorSize < 0 || xorSize > remainingData.length) {
      throw Exception('文件格式异常：XOR 数据长度不合法');
    }

    Uint8List rawData;
    Uint8List xoredData;

    if (xorSize > 0) {
      final rawLength = remainingData.length - xorSize;
      if (rawLength < 0) {
        throw Exception('文件格式异常：原始数据长度小于XOR长度');
      }
      rawData = remainingData.sublist(0, rawLength);
      final xorData = remainingData.sublist(rawLength);
      xoredData = Uint8List(xorData.length);
      for (int i = 0; i < xorData.length; i++) {
        xoredData[i] = xorData[i] ^ xorKey;
      }
    } else {
      rawData = remainingData;
      xoredData = Uint8List(0);
    }

    // 拼接完整数据：AES解密数据 + raw_data + XOR数据
    final result = Uint8List(
      unpaddedData.length + rawData.length + xoredData.length,
    );
    int writeOffset = 0;
    if (unpaddedData.isNotEmpty) {
      result.setRange(0, unpaddedData.length, unpaddedData);
      writeOffset += unpaddedData.length;
    }
    if (rawData.isNotEmpty) {
      result.setRange(writeOffset, writeOffset + rawData.length, rawData);
      writeOffset += rawData.length;
    }
    if (xoredData.isNotEmpty) {
      result.setRange(writeOffset, writeOffset + xoredData.length, xoredData);
    }

    return result;
  }

  /// 判断 .dat 文件的加密版本
  /// 返回：0=V3, 1=V4-V1签名, 2=V4-V2签名
  int getDatVersion(String inputPath) {
    final file = File(inputPath);
    if (!file.existsSync()) {
      throw Exception('文件不存在');
    }

    final bytes = file.readAsBytesSync();
    if (bytes.length < 6) {
      return 0; // V3版本没有签名
    }

    final signature = bytes.sublist(0, 6);

    // 检查V4签名
    if (_compareBytes(signature, [0x07, 0x08, 0x56, 0x31, 0x08, 0x07])) {
      return 1; // V4-V1
    } else if (_compareBytes(signature, [0x07, 0x08, 0x56, 0x32, 0x08, 0x07])) {
      return 2; // V4-V2
    }

    return 0; // V3
  }

  /// 自动检测版本并解密（异步版本）
  /// [inputPath] 输入文件路径
  /// [outputPath] 输出文件路径
  /// [xorKey] XOR 密钥
  /// [aesKey] AES 密钥（仅V4需要）
  Future<void> decryptDatAutoAsync(
    String inputPath,
    String outputPath,
    int xorKey,
    Uint8List? aesKey,
  ) async {
    final version = getDatVersion(inputPath);

    Uint8List decryptedData;
    if (version == 0) {
      // V3版本
      decryptedData = decryptDatV3(inputPath, xorKey);
    } else {
      // V4版本
      if (aesKey == null || aesKey.length != 16) {
        throw Exception('V4版本需要16字节AES密钥');
      }
      decryptedData = decryptDatV4(inputPath, xorKey, aesKey);
    }

    // 异步写入输出文件，确保数据完整性
    final outputFile = File(outputPath);
    await outputFile.writeAsBytes(decryptedData, flush: true);
  }

  /// 自动检测版本并解密（同步版本，保持向后兼容）
  /// [inputPath] 输入文件路径
  /// [outputPath] 输出文件路径
  /// [xorKey] XOR 密钥
  /// [aesKey] AES 密钥（仅V4需要）
  void decryptDatAuto(
    String inputPath,
    String outputPath,
    int xorKey,
    Uint8List? aesKey,
  ) {
    final version = getDatVersion(inputPath);

    Uint8List decryptedData;
    if (version == 0) {
      // V3版本
      decryptedData = decryptDatV3(inputPath, xorKey);
    } else {
      // V4版本
      if (aesKey == null || aesKey.length != 16) {
        throw Exception('V4版本需要16字节AES密钥');
      }
      decryptedData = decryptDatV4(inputPath, xorKey, aesKey);
    }

    // 同步写入输出文件
    final outputFile = File(outputPath);
    outputFile.writeAsBytesSync(decryptedData, flush: true);
  }

  /// 去除 PKCS7 填充
  Uint8List _removePadding(Uint8List data) {
    if (data.isEmpty) {
      return data;
    }

    final paddingLength = data[data.length - 1];
    if (paddingLength == 0 || paddingLength > 16 || paddingLength > data.length) {
      return data; // 无效填充，返回原数据
    }

    // 验证填充是否有效
    for (int i = data.length - paddingLength; i < data.length; i++) {
      if (data[i] != paddingLength) {
        return data; // 填充无效，返回原数据
      }
    }

    return data.sublist(0, data.length - paddingLength);
  }

  /// 将4字节转换为int32（小端序）
  int _bytesToInt32(List<int> bytes) {
    if (bytes.length != 4) {
      throw Exception('需要4个字节');
    }
    return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
  }

  /// 比较两个字节数组
  bool _compareBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 将字符串转换为AES密钥（16字节）
  /// y.encode()[:16]
  /// 将字符串的每个字符作为ASCII字节，取前16字节
  /// 例如："b18052363165af7e" -> [98, 49, 56, 48, 53, 50, 51, 54, 51, 49, 54, 53, 97, 102, 55, 101]
  static Uint8List hexToBytes16(String keyString) {
    // 去除空格，保留原始大小写
    final cleanKey = keyString.trim();

    if (cleanKey.isEmpty) {
      throw Exception('密钥不能为空');
    }

    if (cleanKey.length < 16) {
      throw Exception('AES密钥至少需要16个字符');
    }

    // 直接将字符串的每个字符转为ASCII字节
    final stringBytes = cleanKey.codeUnits;
    final bytes = Uint8List(16);

    for (int i = 0; i < 16; i++) {
      bytes[i] = stringBytes[i];
    }

    return bytes;
  }

  /// 从十六进制字符串转换XOR密钥
  static int hexToXorKey(String hexString) {
    if (hexString.isEmpty) {
      throw Exception('十六进制字符串不能为空');
    }

    // 去除可能的0x前缀
    final cleanHex = hexString.toLowerCase().replaceAll('0x', '');

    // 只取前2个字符（1字节）
    final hex = cleanHex.length >= 2 ? cleanHex.substring(0, 2) : cleanHex;
    return int.parse(hex, radix: 16);
  }
}
