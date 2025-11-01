/// 字符串处理工具类
///
/// 专门处理从微信数据库读取的字符串，解决显示时的编码问题
/// 确保所有文本都能安全地在Flutter界面中展示
///
/// 主要解决的问题：
/// - 清理无效的UTF-16编码字符
/// - 正确处理emoji等占用多个字节的特殊字符
/// - 避免因编码问题导致的界面崩溃
class StringUtils {
  /// 清理字符串中的无效字符和编码问题
  ///
  /// 解决以下问题：
  /// - 移除不可见的控制字符
  /// - 修复孤立的代理对（emoji等字符的编码问题）
  /// - 确保字符串能在Flutter界面中安全显示
  ///
  /// 示例：
  /// ```dart
  /// cleanUtf16('Hello 😊 World')  // 正常返回（emoji是有效的代理对）
  /// cleanUtf16('Bad\uD800String') // 移除孤立的高代理
  /// cleanUtf16('控\x00制符')      // 移除控制字符
  /// ```
  static String cleanUtf16(String input) {
    if (input.isEmpty) return input;

    try {
      // 移除控制字符和无效字符
      String cleaned = input.replaceAll(
        RegExp(r'[\x00-\x08\x0B-\x0C\x0E-\x1F\x7F-\x9F]'),
        '',
      );

      // 处理孤立的代理对（UTF-16编码问题）
      final codeUnits = cleaned.codeUnits;
      final validUnits = <int>[];

      for (int i = 0; i < codeUnits.length; i++) {
        final unit = codeUnits[i];

        // 检查高代理（0xD800-0xDBFF）
        if (unit >= 0xD800 && unit <= 0xDBFF) {
          // 高代理必须后跟低代理
          if (i + 1 < codeUnits.length) {
            final nextUnit = codeUnits[i + 1];
            if (nextUnit >= 0xDC00 && nextUnit <= 0xDFFF) {
              // 有效的代理对
              validUnits.add(unit);
              validUnits.add(nextUnit);
              i++; // 跳过下一个字符
              continue;
            }
          }
          // 孤立的高代理，跳过
          continue;
        }

        // 检查低代理（0xDC00-0xDFFF）
        if (unit >= 0xDC00 && unit <= 0xDFFF) {
          // 孤立的低代理，跳过
          continue;
        }

        // 普通字符
        validUnits.add(unit);
      }

      return String.fromCharCodes(validUnits);
    } catch (e) {
      // 如果清理失败，使用正则表达式保留安全字符
      // 保留：ASCII可打印字符、中文、全角空格和标点
      return input.replaceAll(
        RegExp(r'[^\u0020-\u007E\u4E00-\u9FFF\u3000-\u303F]'),
        '',
      );
    }
  }

  /// 安全获取字符串的第一个字符
  ///
  /// 专门用于头像显示等场景，能正确处理emoji等特殊字符
  ///
  /// 重要提醒：不要直接用substring(0, 1)，那样会截断emoji等字符！
  ///
  /// 示例：
  /// ```dart
  /// getFirstChar('张三')      // '张'
  /// getFirstChar('😊Hello')   // '😊' (完整的emoji)
  /// getFirstChar('John')     // 'J'
  /// getFirstChar('')         // '?' (默认字符)
  /// ```
  ///
  /// 原理：
  /// - emoji 如 😊 在 UTF-16 中是一个代理对：[0xD83D, 0xDE0A]
  /// - 如果用 substring(0,1) 只会取 0xD83D（孤立的高代理）
  /// - 导致 "string is not well-formed UTF-16" 错误
  /// - 本方法会检测并返回完整的代理对
  static String getFirstChar(String input, {String defaultChar = '?'}) {
    final cleaned = cleanUtf16(input);
    if (cleaned.isEmpty) return defaultChar;

    try {
      // 获取code units
      final codeUnits = cleaned.codeUnits;

      if (codeUnits.isEmpty) return defaultChar;

      final firstUnit = codeUnits[0];

      // 检查是否是高代理（emoji等的第一部分）
      if (firstUnit >= 0xD800 && firstUnit <= 0xDBFF) {
        // 需要包含下一个code unit（低代理）
        if (codeUnits.length > 1) {
          final secondUnit = codeUnits[1];
          if (secondUnit >= 0xDC00 && secondUnit <= 0xDFFF) {
            // 这是一个完整的代理对（emoji等）
            return String.fromCharCodes([firstUnit, secondUnit]).toUpperCase();
          }
        }
        // 如果没有配对的低代理，返回默认字符
        return defaultChar;
      }

      // 检查是否是低代理（不应该出现在第一个位置）
      if (firstUnit >= 0xDC00 && firstUnit <= 0xDFFF) {
        return defaultChar;
      }

      // 普通字符，直接返回
      return String.fromCharCodes([firstUnit]).toUpperCase();
    } catch (e) {
      return defaultChar;
    }
  }

  /// 清理并验证字符串，如果为空返回默认值
  static String cleanOrDefault(String input, String defaultValue) {
    final cleaned = cleanUtf16(input);
    return cleaned.isEmpty ? defaultValue : cleaned;
  }
}
