import 'package:flutter/material.dart';

/// 数据文本构建器

class RichTextBuilder {
  /// 创建一个包含数据的富文本，数据部分用不同样式突出
  ///
  /// 使用示例：
  /// RichTextBuilder.withData(
  ///   baseStyle: bodySize16,
  ///   parts: [
  ///     TextPart(text: '这一天，你们聊了'),
  ///     DataPart(text: '2947', dataStyle: dataStyle),
  ///     TextPart(text: '条消息'),
  ///   ],
  /// )
  static Widget withData({
    required TextStyle baseStyle,
    required List<TextPartBase> parts,
    TextAlign textAlign = TextAlign.center,
  }) {
    List<InlineSpan> spans = [];

    for (var part in parts) {
      if (part is TextPart) {
        spans.add(TextSpan(text: part.text, style: part.style ?? baseStyle));
      } else if (part is DataPart) {
        spans.add(
          TextSpan(
            text: part.text,
            style:
                part.style ??
                baseStyle.copyWith(
                  fontWeight: FontWeight.bold,
                  color: part.color ?? const Color(0xFF07C160),
                ),
          ),
        );
      }
    }

    return RichText(
      text: TextSpan(children: spans),
      textAlign: textAlign,
    );
  }

  /// 使用示例：
  /// RichTextBuilder.highlightNumber(
  ///   prefix: '这一天，你们聊了',
  ///   number: '2947',
  ///   suffix: '条消息',
  ///   baseStyle: bodyStyle,
  ///   highlightColor: Colors.green,
  /// )
  static Widget highlightNumber({
    required String prefix,
    required String number,
    required String suffix,
    required TextStyle baseStyle,
    Color highlightColor = const Color(0xFF07C160),
  }) {
    return RichText(
      text: TextSpan(
        style: baseStyle,
        children: [
          TextSpan(text: prefix),
          TextSpan(
            text: number,
            style: baseStyle.copyWith(
              fontWeight: FontWeight.bold,
              color: highlightColor,
            ),
          ),
          TextSpan(text: suffix),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  /// 创建多个数据高亮的文本
  ///
  /// 使用示例：
  /// RichTextBuilder.multiHighlight(
  ///   baseStyle: bodyStyle,
  ///   text: '和 {name} 聊了 {count} 条',
  ///   highlights: {
  ///     '{name}': (TextStyle(fontWeight: FontWeight.bold, color: Colors.purple)),
  ///     '{count}': (TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
  ///   },
  /// )
  static Widget multiHighlight({
    required TextStyle baseStyle,
    required String text,
    required Map<String, TextStyle> highlights,
  }) {
    List<InlineSpan> spans = [];
    String remaining = text;

    // 找到所有高亮部分的位置
    List<_HighlightMatch> matches = [];
    for (var highlightKey in highlights.keys) {
      int index = 0;
      while ((index = remaining.indexOf(highlightKey, index)) != -1) {
        matches.add(
          _HighlightMatch(
            start: index,
            end: index + highlightKey.length,
            key: highlightKey,
            style: highlights[highlightKey]!,
          ),
        );
        index += highlightKey.length;
      }
    }

    // 排序匹配位置
    matches.sort((a, b) => a.start.compareTo(b.start));

    int currentPos = 0;
    for (var match in matches) {
      if (currentPos < match.start) {
        spans.add(
          TextSpan(
            text: remaining.substring(currentPos, match.start),
            style: baseStyle,
          ),
        );
      }
      spans.add(TextSpan(text: match.key, style: match.style));
      currentPos = match.end;
    }

    if (currentPos < remaining.length) {
      spans.add(
        TextSpan(text: remaining.substring(currentPos), style: baseStyle),
      );
    }

    return RichText(
      text: TextSpan(children: spans),
      textAlign: TextAlign.center,
    );
  }
}

/// 文本部分基类
abstract class TextPartBase {
  String get text;
}

/// 普通文本部分
class TextPart extends TextPartBase {
  @override
  final String text;
  final TextStyle? style;

  TextPart({required this.text, this.style});
}

/// 数据部分 - 用于突出显示的数据
class DataPart extends TextPartBase {
  @override
  final String text;
  final TextStyle? style;
  final Color? color;

  DataPart({required this.text, this.style, this.color});
}

/// 内部辅助类 - 用于追踪高亮位置
class _HighlightMatch {
  final int start;
  final int end;
  final String key;
  final TextStyle style;

  _HighlightMatch({
    required this.start,
    required this.end,
    required this.key,
    required this.style,
  });
}

/// 预设的排版方案 - 将数据融入文案的通用模板
class TypographyTemplates {}
