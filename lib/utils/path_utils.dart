import 'dart:io';
import 'package:path/path.dart' as p;

/// 路径工具类 - 增强对中文和空格路径的支持
class PathUtils {
  /// 规范化数据库路径
  ///
  /// 处理以下问题：
  /// 1. 中文字符路径
  /// 2. 空格路径（如 OneDrive - My Cloud Disk）
  /// 3. 路径分隔符统一
  /// 4. 相对路径转绝对路径
  static String normalizeDatabasePath(String path) {
    if (path.isEmpty) return path;

    try {
      // 1. 转换为绝对路径
      String absolutePath = p.isAbsolute(path) ? path : p.absolute(path);

      // 2. 规范化路径（处理 ./ ../ 等）
      absolutePath = p.normalize(absolutePath);

      // 3. Windows 特殊处理
      if (Platform.isWindows) {
        // 确保使用反斜杠
        absolutePath = absolutePath.replaceAll('/', '\\');

        // 处理 UNC 路径（网络路径）
        if (absolutePath.startsWith('\\\\')) {
          // UNC 路径保持不变
          return absolutePath;
        }

        // 处理长路径前缀
        // Windows 支持最长 260 字符的路径，使用 \\?\ 前缀可以支持 32767 字符
        // 但 sqflite_ffi 可能不支持 \\?\ 前缀，所以我们移除它
        if (absolutePath.startsWith('\\\\?\\')) {
          absolutePath = absolutePath.substring(4);
        }

        // 确保盘符大写（C: 而不是 c:）
        if (absolutePath.length >= 2 && absolutePath[1] == ':') {
          absolutePath =
              absolutePath[0].toUpperCase() + absolutePath.substring(1);
        }
      }

      return absolutePath;
    } catch (e) {
      // 如果规范化失败，返回原路径
      return path;
    }
  }

  /// 验证路径是否包含特殊字符
  /// 返回 true 表示路径可能有问题
  static bool hasSpecialCharacters(String path) {
    // 检查是否包含中文字符
    final chineseRegex = RegExp(r'[\u4e00-\u9fa5]');
    if (chineseRegex.hasMatch(path)) {
      return true;
    }

    // 检查是否包含空格
    if (path.contains(' ')) {
      return true;
    }

    // 检查是否包含其他特殊字符（除了路径分隔符和盘符）
    final specialChars = RegExp(r'[^\w\s\-_.:/\\]');
    if (specialChars.hasMatch(path)) {
      return true;
    }

    return false;
  }

  /// 获取路径的 URI 编码版本（用于某些 API）
  static String toUri(String path) {
    try {
      final file = File(path);
      return file.uri.toString();
    } catch (e) {
      return path;
    }
  }

  /// 从 URI 转换回路径
  static String fromUri(String uri) {
    try {
      final parsedUri = Uri.parse(uri);
      return parsedUri.toFilePath();
    } catch (e) {
      return uri;
    }
  }

  /// 确保路径存在（创建父目录）
  static Future<void> ensureParentExists(String filePath) async {
    try {
      final file = File(filePath);
      final parent = file.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
    } catch (e) {
      // 忽略错误
    }
  }

  /// 安全地拼接路径
  static String join(
    String part1,
    String part2, [
    String? part3,
    String? part4,
  ]) {
    String joined;
    if (part4 != null) {
      joined = p.join(part1, part2, part3!, part4);
    } else if (part3 != null) {
      joined = p.join(part1, part2, part3);
    } else {
      joined = p.join(part1, part2);
    }
    return normalizeDatabasePath(joined);
  }

  /// 获取文件名（不含路径）
  static String basename(String path) {
    return p.basename(path);
  }

  /// 获取目录路径（不含文件名）
  static String dirname(String path) {
    return p.dirname(path);
  }

  /// 获取文件扩展名
  static String extension(String path) {
    return p.extension(path);
  }

  /// 替换文件扩展名
  static String replaceExtension(String path, String newExtension) {
    final withoutExt = p.withoutExtension(path);
    return '$withoutExt$newExtension';
  }

  /// 检查路径是否为数据库文件
  static bool isDatabaseFile(String path) {
    final ext = extension(path).toLowerCase();
    return ext == '.db' || ext == '.sqlite' || ext == '.sqlite3';
  }

  /// 转义路径中的特殊字符（用于日志输出）
  static String escapeForLog(String path) {
    return path
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r');
  }
}
