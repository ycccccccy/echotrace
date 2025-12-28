import 'package:flutter/services.dart';
import 'dart:convert';

/// 双人报告HTML渲染器
class DualReportHtmlRenderer {
  /// 构建双人报告HTML
  static Future<String> build({
    required Map<String, dynamic> reportData,
    required String myName,
    required String friendName,
  }) async {
    // 加载字体
    final fonts = await _loadFonts();

    // 构建HTML
    final buffer = StringBuffer();

    // HTML头部
    buffer.writeln('<!doctype html>');
    buffer.writeln('<html lang="zh-CN">');
    buffer.writeln('<head>');
    buffer.writeln('<meta charset="utf-8" />');
    buffer.writeln('<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />');
    buffer.writeln('<title>双人聊天报告</title>');
    buffer.writeln('<script src="https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js"></script>');
    buffer.writeln('<style>');
    buffer.writeln(_buildCss(fonts['regular']!, fonts['bold']!));
    buffer.writeln('</style>');
    buffer.writeln('</head>');

    // 内容主体
    buffer.writeln('<body>');
    buffer.writeln('<main class="main-container" id="capture">');

    // 第一部分：封面（我的名字 & 好友名字）
    buffer.writeln(_buildSection('cover', _buildCoverBody(myName, friendName)));

    // 第二部分：第一次聊天
    final firstChat = reportData['firstChat'] as Map<String, dynamic>?;
    final thisYearFirstChat = reportData['thisYearFirstChat'] as Map<String, dynamic>?;
    buffer.writeln(_buildSection('first-chat', _buildFirstChatBody(firstChat, thisYearFirstChat, myName, friendName)));

    // 第三部分：年度统计
    final yearlyStats = reportData['yearlyStats'] as Map<String, dynamic>?;
    buffer.writeln(_buildSection('yearly-stats', _buildYearlyStatsBody(yearlyStats, myName, friendName, reportData['year'] as int? ?? DateTime.now().year)));

    buffer.writeln('</main>');

    // JavaScript
    buffer.writeln(_buildScript());

    buffer.writeln('</body>');
    buffer.writeln('</html>');

    return buffer.toString();
  }

  /// 加载字体文件
  static Future<Map<String, String>> _loadFonts() async {
    final regular = await rootBundle.load('assets/HarmonyOS_SansSC/HarmonyOS_SansSC_Regular.ttf');
    final bold = await rootBundle.load('assets/HarmonyOS_SansSC/HarmonyOS_SansSC_Bold.ttf');

    return {
      'regular': base64Encode(regular.buffer.asUint8List()),
      'bold': base64Encode(bold.buffer.asUint8List()),
    };
  }

  /// 构建CSS样式
  static String _buildCss(String regularFont, String boldFont) {
    return '''
@font-face {
  font-family: "H";
  src: url("data:font/ttf;base64,$regularFont") format("truetype");
  font-weight: 400;
  font-style: normal;
}

@font-face {
  font-family: "H";
  src: url("data:font/ttf;base64,$boldFont") format("truetype");
  font-weight: 700;
  font-style: normal;
}

* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: "H", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  background: #FFFFFF;
  color: #222;
  overflow-x: hidden;
}

.main-container {
  width: 100%;
  max-width: 800px;
  margin: 0 auto;
  background: #FFFFFF;
  position: relative;
}

.section {
  min-height: 100vh;
  padding: 60px 40px;
  display: flex;
  flex-direction: column;
  justify-content: center;
  position: relative;
}

.section.cover {
  background: #FFFFFF;
  text-align: center;
}

.section.first-chat {
  background: #FFFFFF;
}

.section.yearly-stats {
  background: #FFFFFF;
}

.label-text {
  font-size: 14px;
  letter-spacing: 3px;
  color: #07C160;
  font-weight: 600;
  margin-bottom: 24px;
  text-transform: uppercase;
}

.hero-title {
  font-size: clamp(32px, 6vw, 56px);
  font-weight: 700;
  line-height: 1.4;
  margin-bottom: 24px;
  color: #222;
}

.hero-names {
  font-size: clamp(28px, 5vw, 48px);
  font-weight: 700;
  line-height: 1.6;
  margin: 40px 0;
  color: #222;
}

.hero-names .ampersand {
  color: #07C160;
  margin: 0 16px;
}

.hero-names .name {
  display: inline-block;
}

.hero-desc {
  font-size: clamp(16px, 3vw, 20px);
  line-height: 2;
  color: #666;
  margin-bottom: 32px;
}

.divider {
  border: none;
  height: 2px;
  background: linear-gradient(90deg, transparent, #07C160, transparent);
  margin: 40px auto;
  width: 200px;
}

.info-card {
  background: #FAFAFA;
  border-radius: 20px;
  padding: 32px;
  margin: 24px 0;
  box-shadow: 0 4px 20px rgba(0, 0, 0, 0.06);
}

.info-row {
  display: flex;
  gap: 24px;
  flex-wrap: wrap;
  align-items: flex-start;
}

.info-item {
  flex: 1 1 200px;
  min-width: 200px;
}

.info-label {
  font-size: 14px;
  color: #999;
  margin-bottom: 12px;
  letter-spacing: 1px;
}

.info-value {
  font-size: 28px;
  font-weight: 700;
  color: #222;
  margin-bottom: 24px;
}

.info-row .info-value {
  margin-bottom: 0;
}

.info-value-sm {
  font-size: 20px;
  font-weight: 600;
  color: #222;
  word-break: break-all;
}

.emoji-thumb {
  width: 72px;
  height: 72px;
  object-fit: contain;
  border-radius: 12px;
  background: #FFFFFF;
  box-shadow: 0 2px 10px rgba(0, 0, 0, 0.06);
  margin-bottom: 8px;
}

.info-value .highlight {
  color: #07C160;
  font-size: 36px;
}

.info-value .sub-highlight {
  color: #666;
  font-size: 18px;
  font-weight: 400;
}

.conversation-box {
  background: #F5F5F5;
  border-radius: 16px;
  padding: 20px;
  margin-top: 24px;
}

.message-bubble {
  background: white;
  border-radius: 12px;
  padding: 16px 20px;
  margin-bottom: 12px;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.04);
}

.message-bubble:last-child {
  margin-bottom: 0;
}

.message-sender {
  font-size: 14px;
  color: #07C160;
  font-weight: 700;
  margin-bottom: 8px;
}

.message-content {
  font-size: 16px;
  color: #222;
  line-height: 1.6;
}

@keyframes fadeInUp {
  from {
    opacity: 0;
    transform: translateY(30px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}

.fade-in {
  animation: fadeInUp 0.8s ease-out forwards;
}

@media (max-width: 768px) {
  .section {
    padding: 40px 24px;
  }

  .hero-title {
    font-size: 32px;
  }

  .hero-names {
    font-size: 24px;
  }

  .info-value .highlight {
    font-size: 28px;
  }
}
''';
  }

  /// 构建封面
  static String _buildCoverBody(String myName, String friendName) {
    final escapedMyName = _escapeHtml(myName);
    final escapedFriendName = _escapeHtml(friendName);
    return '''
<div class="label-text">ECHO TRACE · DUAL REPORT</div>
<div class="hero-names">
  <span class="name">$escapedMyName</span>
  <span class="ampersand">&</span>
  <span class="name">$escapedFriendName</span>
</div>
<hr class="divider">
<div class="hero-desc">每一段对话<br>都是独一无二的相遇<br><br>让我们一起回顾<br>那些珍贵的聊天时光</div>
''';
  }

  /// 构建第一次聊天部分
  static String _buildFirstChatBody(
    Map<String, dynamic>? firstChat,
    Map<String, dynamic>? thisYearFirstChat,
    String myName,
    String friendName,
  ) {
    if (firstChat == null) {
      return '''
<div class="label-text">第一次聊天</div>
<div class="hero-title">暂无数据</div>
''';
    }

    final firstDate = DateTime.fromMillisecondsSinceEpoch(firstChat['createTime'] as int);
    final daysSince = DateTime.now().difference(firstDate).inDays;

    String thisYearSection = '';
    if (thisYearFirstChat != null) {
      final initiator = thisYearFirstChat['isSentByMe'] == true ? myName : friendName;
      final messages = thisYearFirstChat['firstThreeMessages'] as List<dynamic>?;

      String messagesHtml = '';
      if (messages != null && messages.isNotEmpty) {
        messagesHtml = messages.map((msg) {
          final sender = msg['isSentByMe'] == true ? myName : friendName;
          final content = _escapeHtml(msg['content'].toString());
          final timeStr = msg['createTimeStr']?.toString() ?? '';
          return '''
<div class="message-bubble">
  <div class="message-sender">$sender · $timeStr</div>
  <div class="message-content">$content</div>
</div>
''';
        }).join();
      }

      thisYearSection = '''
<div class="info-card">
  <div class="info-label">今年第一段对话</div>
  <div class="info-value">
    由 <span class="highlight">${_escapeHtml(initiator)}</span> 发起
  </div>
  <div class="info-label">前三句对话</div>
  <div class="conversation-box">
    $messagesHtml
  </div>
</div>
''';
    }

    return '''
<div class="label-text">第一次聊天</div>
<div class="hero-title">故事的开始</div>
<div class="info-card">
  <div class="info-label">我们第一次聊天在</div>
  <div class="info-value">
    <span class="highlight">${firstDate.year}年${firstDate.month}月${firstDate.day}日</span>
  </div>
  <div class="info-label">距今已有</div>
  <div class="info-value">
    <span class="highlight">$daysSince</span> <span class="sub-highlight">天</span>
  </div>
</div>
$thisYearSection
''';
  }

  /// 构建年度统计部分
  static String _buildYearlyStatsBody(
    Map<String, dynamic>? yearlyStats,
    String myName,
    String friendName,
    int year,
  ) {
    if (yearlyStats == null) {
      return '''
<div class="label-text">年度统计</div>
<div class="hero-title">暂无数据</div>
''';
    }

    final totalMessages = yearlyStats['totalMessages'] as int? ?? 0;
    final totalWords = yearlyStats['totalWords'] as int? ?? 0;
    final imageCount = yearlyStats['imageCount'] as int? ?? 0;
    final voiceCount = yearlyStats['voiceCount'] as int? ?? 0;
    final emojiCount = yearlyStats['emojiCount'] as int? ?? 0;
    final myTopEmojiMd5 = yearlyStats['myTopEmojiMd5'] as String?;
    final friendTopEmojiMd5 = yearlyStats['friendTopEmojiMd5'] as String?;
    final myTopEmojiDataUrl = yearlyStats['myTopEmojiDataUrl'] as String?;
    final friendTopEmojiDataUrl =
        yearlyStats['friendTopEmojiDataUrl'] as String?;

    // 格式化数字：千分位
    String formatNumber(int n) {
      return n.toString().replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (Match m) => '${m[1]},',
      );
    }

    String formatEmojiMd5(String? md5) {
      if (md5 == null || md5.isEmpty) return '暂无';
      return md5;
    }

    String buildEmojiBlock(String? dataUrl, String? md5) {
      if (dataUrl == null || dataUrl.isEmpty) {
        final label = _escapeHtml(formatEmojiMd5(md5));
        return '<div class="info-value info-value-sm">$label</div>';
      }
      final safeUrl = _escapeHtml(dataUrl);
      return '''
<img class="emoji-thumb" src="$safeUrl" alt="" />
''';
    }


    return '''
<div class="label-text">年度统计</div>
<div class="hero-title">${_escapeHtml(myName)} & ${_escapeHtml(friendName)}的$year年</div>
<div class="info-card">
  <div class="info-label">一共发出</div>
  <div class="info-value">
    <span class="highlight">${formatNumber(totalMessages)}</span> <span class="sub-highlight">条消息</span>
  </div>
  <div class="info-label">总计</div>
  <div class="info-value">
    <span class="highlight">${formatNumber(totalWords)}</span> <span class="sub-highlight">字</span>
  </div>
  <div class="info-label">图片</div>
  <div class="info-value">
    <span class="highlight">${formatNumber(imageCount)}</span> <span class="sub-highlight">张</span>
  </div>
  <div class="info-label">语音</div>
  <div class="info-value">
    <span class="highlight">${formatNumber(voiceCount)}</span> <span class="sub-highlight">条</span>
  </div>
  <div class="info-row">
    <div class="info-item">
      <div class="info-label">表情包</div>
      <div class="info-value">
        <span class="highlight">${formatNumber(emojiCount)}</span> <span class="sub-highlight">张</span>
      </div>
    </div>
    <div class="info-item">
      <div class="info-label">我最常用的表情包</div>
      ${buildEmojiBlock(myTopEmojiDataUrl, myTopEmojiMd5)}
    </div>
    <div class="info-item">
      <div class="info-label">${_escapeHtml(friendName)}常用的表情包</div>
      ${buildEmojiBlock(friendTopEmojiDataUrl, friendTopEmojiMd5)}
    </div>
  </div>
</div>
''';
  }

  /// HTML转义
  static String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }


  /// 构建section
  static String _buildSection(String className, String content) {
    return '''
<div class="section $className fade-in">
  $content
</div>
''';
  }

  /// 构建JavaScript
  static String _buildScript() {
    return '''
<script>
// 平滑滚动
document.addEventListener('DOMContentLoaded', function() {
  const sections = document.querySelectorAll('.section');

  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('fade-in');
      }
    });
  }, {
    threshold: 0.1
  });

  sections.forEach((section) => observer.observe(section));
});
</script>
''';
  }
}
