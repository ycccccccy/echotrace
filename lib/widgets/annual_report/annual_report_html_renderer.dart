import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../config/annual_report_texts.dart';
import '../../models/advanced_analytics_data.dart';

class AnnualReportHtmlRenderer {
  static Map<String, String>? _fontCache;

  static num _parseNum(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value;
    if (value is String) return num.tryParse(value) ?? 0;
    return 0;
  }

  static Future<String> build({
    required Map<String, dynamic> reportData,
    int? year,
  }) async {
    _fontCache ??= await _loadFonts();
    final fonts = _fontCache!;

    final yearText = year != null ? '${year}年' : '历史以来';
    final numberFormat = NumberFormat.decimalPattern();

    // --- 数据准备 ---
    final totalMessages = _parseNum(reportData['totalMessages']).toInt();
    final totalFriends = _parseNum(reportData['totalFriends']).toInt();

    final List<dynamic> coreFriendsJson = reportData['coreFriends'] ?? [];
    final coreFriends = coreFriendsJson.map((e) => FriendshipRanking.fromJson(e)).toList();
    final topFriend = coreFriends.isNotEmpty ? coreFriends.first : null;

    final List<dynamic> confidantJson = reportData['confidant'] ?? [];
    final confidants = confidantJson.map((e) => FriendshipRanking.fromJson(e)).toList();
    final topConfidant = confidants.isNotEmpty ? confidants.first : null;

    final List<dynamic> listenersJson = reportData['listeners'] ?? [];
    final listeners = listenersJson.map((e) => FriendshipRanking.fromJson(e)).toList();
    final topListener = listeners.isNotEmpty ? listeners.first : null;

    final List<dynamic> mutualFriendsJson = reportData['mutualFriends'] ?? [];
    final mutualFriends = mutualFriendsJson.map((e) => FriendshipRanking.fromJson(e)).toList();

    final socialDataJson = reportData['socialInitiative'];
    final socialData = socialDataJson is Map<String, dynamic>
        ? SocialStyleData.fromJson(socialDataJson)
        : SocialStyleData(initiativeRanking: []);
    final socialTop = socialData.initiativeRanking.isNotEmpty ? socialData.initiativeRanking.first : null;

    final peakDayJson = reportData['peakDay'];
    final ChatPeakDay? peakDay = peakDayJson is Map<String, dynamic> ? ChatPeakDay.fromJson(peakDayJson) : null;

    final checkIn = reportData['checkIn'] as Map<String, dynamic>? ?? {};
    final checkInDays = _parseNum(checkIn['days']).toInt();
    final checkInName = checkIn['displayName'] ?? '未知';
    final checkInStart = _formatDate(checkIn['startDate'] as String?);
    final checkInEnd = _formatDate(checkIn['endDate'] as String?);

    final activityJson = reportData['activityPattern'];
    final ActivityHeatmap? activity = activityJson is Map<String, dynamic> ? ActivityHeatmap.fromJson(activityJson) : null;
    final mostActive = activity?.getMostActiveTime();
    final mostActiveHour = mostActive?['hour'];
    final mostActiveWeekday = mostActive?['weekday'];

    final midnightKing = reportData['midnightKing'] as Map<String, dynamic>? ?? {};
    final midnightName = midnightKing['displayName'] ?? '未知';
    final midnightCount = _parseNum(midnightKing['count']).toInt();
    final midnightPctVal = _parseNum(midnightKing['percentage']);
    final midnightPercentage = midnightPctVal.toStringAsFixed(1);

    final whoRepliesFastest = (reportData['whoRepliesFastest'] as List?) ?? [];
    final myFastestReplies = (reportData['myFastestReplies'] as List?) ?? [];

    final formerFriends = (reportData['formerFriends'] as List?) ?? [];
    final formerFriendsStats = reportData['formerFriendsStats'] as Map<String, dynamic>?;

    // --- HTML 构建 ---
    final buffer = StringBuffer();
    buffer.writeln('<!doctype html>');
    buffer.writeln('<html lang="zh-CN">');
    buffer.writeln('<head>');
    buffer.writeln('<meta charset="utf-8" />');
    buffer.writeln('<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />');
    buffer.writeln('<script src="https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js"></script>');
    buffer.writeln('<style>');
    buffer.writeln(_buildCss(fonts['regular']!, fonts['bold']!));
    buffer.writeln('</style>');
    buffer.writeln('</head>');
    buffer.writeln('<body>');
    
    buffer.writeln('<main class="main-container" id="capture">'); 
    buffer.writeln(_buildNav());

    buffer.writeln(_section('cover', 'cover', _buildCoverBody(yearText)));

    buffer.writeln(_section('intro', 'intro', 
      _buildIntroBody(numberFormat, totalFriends, totalMessages)));

    buffer.writeln(_section('friendship', 'friendship', 
      _buildFriendshipBody(numberFormat, topFriend, topConfidant, topListener)));

    buffer.writeln(_section('mutual', 'mutual', 
      _buildMutualBody(numberFormat, mutualFriends)));

    buffer.writeln(_section('initiative', 'initiative', 
      _buildSocialBody(socialTop)));

    buffer.writeln(_section('peak', 'peak-day', 
      _buildPeakBody(numberFormat, peakDay)));

    buffer.writeln(_section('checkin', 'checkin', 
      _buildCheckInBody(numberFormat, checkInName, checkInDays, checkInStart, checkInEnd)));

    final activityText = (mostActiveHour != null && mostActiveWeekday != null)
        ? '在 <span class="hl">${_weekdayName(mostActiveWeekday)} ${mostActiveHour.toString().padLeft(2, '0')}:00</span> 最活跃'
        : '暂无作息数据';
    buffer.writeln(_section('activity', 'activity', 
      _buildActivityBody(activityText, activity)));

    buffer.writeln(_section('midnight', 'midnight', 
      _buildMidnightBody(numberFormat, midnightName, midnightCount, midnightPercentage)));

    buffer.writeln(_section('response', 'response', 
      _buildResponseHtml(whoRepliesFastest, myFastestReplies)));

    buffer.writeln(_section('former', 'former', 
      _buildFormerBody(formerFriends, formerFriendsStats, numberFormat)));

    buffer.writeln(_section('ending', 'ending', _buildEndingBody()));

    buffer.writeln('</main>');
    
    buffer.writeln('''
      <div id="modal" class="modal">
        <div class="modal-content">
          <div class="modal-header">长按下方图片保存到相册</div>
          <div style="overflow:auto; max-height:80vh; width:100%;">
            <img id="result-img" />
          </div>
          <button class="close-btn" onclick="document.getElementById('modal').style.display='none'">关闭</button>
        </div>
      </div>
      <div id="loading" class="loading-mask">
        <div class="spinner"></div>
        <div style="margin-top:12px; font-size:14px; color:#fff;">正在生成长图...</div>
      </div>
    ''');

    buffer.writeln('</body>');
    buffer.writeln('</html>');

    return buffer.toString();
  }

  static Future<Map<String, String>> _loadFonts() async {
    final regular = await rootBundle.load('assets/HarmonyOS_SansSC/HarmonyOS_SansSC_Regular.ttf');
    final bold = await rootBundle.load('assets/HarmonyOS_SansSC/HarmonyOS_SansSC_Bold.ttf');
    return {
      'regular': base64Encode(regular.buffer.asUint8List()),
      'bold': base64Encode(bold.buffer.asUint8List()),
    };
  }

  static String _buildCss(String regularFont, String boldFont) {
    return '''
@font-face { font-family: "H"; src: url("data:font/ttf;base64,$regularFont") format("truetype"); font-weight: 400; }
@font-face { font-family: "H"; src: url("data:font/ttf;base64,$boldFont") format("truetype"); font-weight: 700; }

:root {
  --primary: #07C160; 
  --accent: #F2AA00; 
  --text-main: #222222;
  --text-sub: #555555;
  --bg-color: #F9F8F6;
  --line-color: rgba(0,0,0,0.06);
}

* { box-sizing: border-box; margin: 0; padding: 0; }
html { min-height: 100%; }
body {
  min-height: 100vh;
  width: 100%;
  background-color: var(--bg-color);
  font-family: "H", "PingFang SC", sans-serif;
  color: var(--text-main);
  overflow-y: auto;
  overflow-x: hidden;
}
.main-container {
  width: 100%;
  scroll-snap-type: y mandatory;
  background-color: var(--bg-color); 
}
body::before {
  content: "";
  position: fixed;
  inset: 0;
  background: 
    radial-gradient(circle at 90% 5%, rgba(242, 170, 0, 0.06), transparent 50%),
    radial-gradient(circle at 5% 90%, rgba(7, 193, 96, 0.08), transparent 50%);
  pointer-events: none;
  z-index: -1;
}

section.page {
  min-height: 100vh;
  width: 100%;
  scroll-snap-align: start;
  display: flex;
  flex-direction: column;
  justify-content: center;
  padding: 80px max(8%, 30px);
  position: relative;
}

.content-wrapper {
  max-width: 1000px;
  width: 100%;
  margin: 0 auto;
  opacity: 1; 
  transform: translateY(0);
}

section.page.visible .content-wrapper {
  animation: fadeUp 1s cubic-bezier(0.2, 0.8, 0.2, 1) forwards;
}
@keyframes fadeUp {
  from { opacity: 0; transform: translateY(40px); }
  to { opacity: 1; transform: translateY(0); }
}

.label-text { font-size: 13px; letter-spacing: 3px; text-transform: uppercase; color: #888; margin-bottom: 16px; font-weight: 600; }
.hero-title { font-size: clamp(36px, 5vw, 64px); font-weight: 700; line-height: 1.1; margin-bottom: 24px; }
.hero-desc { font-size: 18px; line-height: 1.7; color: var(--text-sub); max-width: 650px; }
.big-stat { display: flex; align-items: baseline; flex-wrap: wrap; gap: 8px; margin: 30px 0; }
.stat-num { font-size: clamp(48px, 8vw, 96px); font-weight: 700; color: var(--primary); line-height: 1; font-feature-settings: "tnum"; }
.stat-unit { font-size: 20px; color: var(--text-sub); }
.divider { width: 80px; height: 3px; background: var(--accent); margin: 36px 0; border: none; opacity: 0.8; }
.hl { color: var(--primary); font-weight: 700; }
.gold { color: var(--accent); font-weight: 700; }

.data-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 32px; margin-top: 40px; }
.list-item { border-bottom: 1px solid var(--line-color); padding-bottom: 12px; margin-bottom: 16px; display: flex; justify-content: space-between; align-items: baseline; }
.item-name { font-size: 18px; font-weight: 600; color: var(--text-main); }
.item-val { font-size: 15px; color: var(--text-sub); }

.heatmap-wrapper {
  margin-top: 36px;
  width: 100%;
  max-width: 900px;
  --gap: 3px; 
}
.heatmap-header {
  display: grid;
  grid-template-columns: 24px 1fr; 
  gap: var(--gap);
  margin-bottom: 8px;
  color: #999;
  font-size: 11px;
}
.time-labels {
  display: grid;
  grid-template-columns: repeat(24, 1fr);
  gap: var(--gap);
  position: relative;
}
.time-labels span {
  grid-column-end: span 4; 
  white-space: nowrap;
  text-align: left; 
  font-family: monospace; 
  transform: translateX(-1px); 
}
.heatmap {
  display: grid;
  grid-template-columns: 24px 1fr;
  gap: var(--gap);
  align-items: stretch;
}
.heatmap-week-col {
  display: grid;
  grid-template-rows: repeat(7, 1fr);
  gap: var(--gap);
  text-align: left;
  font-size: 11px;
  color: #999;
}
.week-label { display: flex; align-items: center; }
.heatmap-grid {
  display: grid;
  grid-template-columns: repeat(24, 1fr); 
  gap: var(--gap);
  width: 100%;
}
.h-cell {
  aspect-ratio: 1;
  background: rgba(0,0,0,0.03);
  border-radius: 2px;
}
.heatmap-tag-row {
  display: flex;
  justify-content: flex-end;
  margin-top: 12px;
  font-size: 10px;
  color: #bbb;
  letter-spacing: 1px;
  text-transform: uppercase;
}

.nav-dots { position: fixed; top: 50%; right: 20px; transform: translateY(-50%); display: flex; flex-direction: column; gap: 12px; z-index: 100; }
.dot { width: 8px; height: 8px; background: rgba(0,0,0,0.15); border-radius: 50%; cursor: pointer; transition: all 0.3s; }
.dot.active { background: var(--primary); transform: scale(1.4); box-shadow: 0 0 10px rgba(7, 193, 96, 0.4); }

.capture-btn { margin-top: 40px; padding: 14px 28px; border-radius: 99px; background: var(--primary); color: white; border: none; font-size: 16px; font-weight: 600; box-shadow: 0 4px 12px rgba(7, 193, 96, 0.3); cursor: pointer; width: 100%; max-width: 240px; }

.modal { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.85); z-index: 9999; justify-content: center; align-items: center; }
.modal-content { background: #fff; padding: 20px; border-radius: 12px; width: 90%; max-width: 500px; display: flex; flex-direction: column; align-items: center; }
.modal-header { margin-bottom: 12px; font-weight: bold; color: #333; }
#result-img { max-width: 100%; display: block; border: 1px solid #eee; }
.close-btn { margin-top: 16px; padding: 8px 24px; background: #eee; border: none; border-radius: 4px; color: #333; cursor: pointer; }

.loading-mask { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.7); z-index: 10000; flex-direction: column; justify-content: center; align-items: center; }
.spinner { width: 40px; height: 40px; border: 4px solid #fff; border-top-color: transparent; border-radius: 50%; animation: spin 1s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }

@media (max-width: 768px) {
  section.page { padding: 60px 24px; min-height: 100vh; }
  .nav-dots { display: none; }
  .hero-title { font-size: 40px; }
  .stat-num { font-size: 60px; }
  .heatmap-header, .heatmap-week-col { font-size: 9px; }
}
    ''';
  }

  static String _section(String id, String className, String content) {
    return '<section class="page $className" id="$id"><div class="content-wrapper">$content</div></section>';
  }

  static String _buildCoverBody(String yearText) {
    return '''
<div class="label-text">ECHO TRACE · ANNUAL REPORT</div>
<div class="hero-title">$yearText<br/>微信聊天报告</div>
<hr class="divider">
<div class="hero-desc">${_escapeHtmlWithBreaks(AnnualReportTexts.coverPoem1)}<br/>${_escapeHtmlWithBreaks(AnnualReportTexts.coverPoem2)}</div>
<div style="margin-top: 60px; font-size: 14px; color: #999;">↓ 滑动开启</div>
''';
  }

  static String _buildIntroBody(NumberFormat fmt, int friends, int messages) {
    return '''
<div class="label-text">年度概览</div>
<div class="hero-title">你的你的朋友们<br>互相发过</div>
<div class="big-stat">
  <div class="stat-num">${fmt.format(messages)}</div>
  <div class="stat-unit">条消息</div>
</div>
<div class="hero-desc">在这段时光里，你与 <span class="hl">${fmt.format(friends)}</span> 位好友交换过喜怒哀乐。<br>每一个对话，都是一段故事的开始。</div>
''';
  }

  static String _buildFriendshipBody(NumberFormat fmt, FriendshipRanking? top, FriendshipRanking? confidant, FriendshipRanking? listener) {
    if (top == null) return '<div class="hero-title">暂无数据</div>';
    final confidantSent = confidant?.count ?? 0;
    final confidantReceived = confidant?.details?['receivedCount'] as int? ?? 0;
    final listenerReceived = listener?.count ?? 0;
    final listenerSent = listener?.details?['sentCount'] as int? ?? 0;
    return '''
<div class="label-text">年度挚友</div>
<div class="hero-title">${_escapeHtml(top.displayName)}</div>
<div class="big-stat"><div class="stat-num">${fmt.format(top.count)}</div><div class="stat-unit">条消息</div></div>
<div class="hero-desc">在一起，就可以</div>
<div class="data-grid">
  <div><div class="label-text">倾诉对象</div><div class="item-name">${_escapeHtml(confidant?.displayName ?? '-')}</div><div class="item-val">你发出 ${fmt.format(confidantSent)} 条 · TA发来 ${fmt.format(confidantReceived)} 条</div></div>
  <div><div class="label-text">倾听对象</div><div class="item-name">${_escapeHtml(listener?.displayName ?? '-')}</div><div class="item-val">TA发来 ${fmt.format(listenerReceived)} 条 · 你回复 ${fmt.format(listenerSent)} 条</div></div>
</div>
''';
  }

  static String _buildMutualBody(NumberFormat fmt, List<FriendshipRanking> friends) {
    if (friends.isEmpty) return '<div class="hero-title">暂无数据</div>';
    final f = friends.first;
    final ratio = f.details?['ratio'] ?? '1.0';
    return '''
<div class="label-text">双向奔赴</div>
<div class="hero-title">默契与平衡</div>
<div class="big-stat"><div class="stat-num">${_escapeHtml(f.displayName)}</div></div>
<div class="hero-desc">你们的互动比例接近 <span class="hl">$ratio</span>。<br>最好的关系，就像你来我往，势均力敌。</div>
''';
  }

  static String _buildSocialBody(FriendshipRanking? social) {
    if (social == null) return '<div class="hero-title">暂无数据</div>';
    final rate = (social.percentage * 100).toStringAsFixed(1);
    return '''
<div class="label-text">社交主动性</div>
<div class="hero-title">主动才有故事</div>
<div class="big-stat"><div class="stat-num">$rate</div><div class="stat-unit">% 主动率</div></div>
<div class="hero-desc">面对 <span class="hl">${_escapeHtml(social.displayName)}</span> 的时候，你总是那个先开口的人。</div>
''';
  }

  static String _buildPeakBody(NumberFormat fmt, ChatPeakDay? peak) {
    if (peak == null) return '<div class="hero-title">暂无数据</div>';
    return '''
<div class="label-text">巅峰时刻</div>
<div class="hero-title">${peak.formattedDate}</div>
<div class="big-stat">一天里发了 <div class="stat-num">${fmt.format(peak.messageCount)}</div><div class="stat-unit">条消息</div></div>
<div class="hero-desc">那是热烈的一天，你和 <span class="hl">${_escapeHtml(peak.topFriendDisplayName ?? '好友')}</span> 聊得停不下来。</div>
''';
  }

static String _buildCheckInBody(NumberFormat fmt, String name, int days, String? start, String? end) {
    return '''
<div class="label-text">持之以恒</div>
<div class="hero-title">聊天火花</div>

<div class="hero-desc" style="margin-bottom: -10px;">
  与 <span class="hl">${_escapeHtml(name)}</span> 持续了
</div>

<div class="big-stat">
  <div class="stat-num">${fmt.format(days)}</div>
  <div class="stat-unit">天</div>
</div>

<div class="hero-desc">
  从 ${_escapeHtml(start ?? '-')} 到 ${_escapeHtml(end ?? '-')}
</div>

<div class="hero-desc" style="margin-top: 50px; font-weight: 700; letter-spacing: 2px;">
  陪伴，是最长情的告白
</div>
''';
  }

  static String _buildActivityBody(String text, ActivityHeatmap? activity) {
    final heatmap = activity != null ? _buildHeatmapHtml(activity) : '';
    return '''
<div class="label-text">作息规律</div>
<div class="hero-title">时间的痕迹</div>
<div class="hero-desc" style="font-size: 22px; color: var(--text-main); margin-bottom: 30px;">$text</div>
$heatmap
''';
  }

  static String _buildMidnightBody(NumberFormat fmt, String name, int count, String pct) {
    return '''
<div class="label-text">深夜好友</div>
<div class="hero-title">当城市睡去</div>
<div class="big-stat">你却有<div class="stat-num">$count</div><div class="stat-unit">次深夜对话</div></div>
<div class="hero-desc">其中 <span class="hl">${_escapeHtml(name)}</span> 常常在深夜中陪着你。<br>你和Ta的对话占深夜期间聊天的 <span class="gold">$pct%</span>。</div>
''';
  }

  static String _buildResponseHtml(List fastest, List myFastest) {
    String buildList(List items, String title) {
      if (items.isEmpty) return '';
      final rows = items.take(3).map((e) {
        final name = _escapeHtml(e['displayName'] ?? '-');
        final min = _parseNum(e['avgResponseTimeMinutes']).toDouble();
        String timeStr;
        if (min < 1.0) {
          final seconds = (min * 60).round();
          timeStr = '${seconds}秒';
        } else {
          timeStr = '${min.toStringAsFixed(0)}分钟';
        }
        return '<div class="list-item"><div class="item-name">$name</div><div class="item-val">$timeStr</div></div>';
      }).join('');
      return '<div><div class="label-text" style="margin-bottom:20px;">$title</div>$rows</div>';
    }
    return '''
<div class="label-text">回应速度</div>
<div class="hero-title">念念不忘，必有回响</div>
<div class="data-grid">${buildList(fastest, "秒回你的人")}${buildList(myFastest, "你最在意的人")}</div>
''';
  }

  static String _buildFormerBody(List former, Map? stats, NumberFormat fmt) {
    if (former.isEmpty) {
      String message = AnnualReportTexts.formerFriendNoData;
      if (stats != null) {
        final totalSessions = stats['totalSessions'] as int? ?? 0;
        final sessionsWithMessages = stats['sessionsWithMessages'] as int? ?? 0;
        final sessionsUnder14Days = stats['sessionsUnder14Days'] as int? ?? 0;
        if (totalSessions > 0 && sessionsWithMessages > 0) {
           if (sessionsUnder14Days == sessionsWithMessages) {
             message = '${AnnualReportTexts.formerFriendInsufficientData}<br/>${AnnualReportTexts.formerFriendInsufficientDataDetail}';
           } else if (sessionsUnder14Days > 0) {
             message = '${AnnualReportTexts.formerFriendNoQualified}<br/>有 $sessionsUnder14Days 个好友聊天记录不足14天<br/>其他好友未符合条件';
           } else {
             message = '${AnnualReportTexts.formerFriendNoQualified}<br/>${AnnualReportTexts.formerFriendAllGoodRelations}';
           }
        }
      }
      return '<div class="label-text">旧日足迹</div><div class="hero-title">无需追忆</div><div class="hero-desc">$message</div>';
    }
    final d = former.first as Map<String, dynamic>;
    final activeDays = _parseNum(d['activeDays']).toInt();
    final activeDaysCount = _parseNum(d['activeDaysCount']).toInt();
    final messageCount = _parseNum(d['activeMessageCount']).toInt();
    final daysSince = _parseNum(d['daysSinceActive']).toInt();
    return '''
<div class="label-text">曾经的好朋友</div>
<div class="hero-title">时间都带我遇见了谁<br>又留下了些什么？</div>
<div class="hero-desc"><br>你与 <span class="hl">${_escapeHtml(d['displayName'])}</span> 曾经连续聊了 ${fmt.format(activeDays)} 天<br><br>只要好友还在，我们还记得彼此<br>总有一天，我们会再次相见</div>
<div class="data-grid">
  <div><div class="label-text">曾经</div><div class="item-name">${fmt.format(activeDaysCount)} 天</div><div class="item-val">产生 ${fmt.format(messageCount)} 条回忆</div></div>
  <div><div class="label-text">离别已</div><div class="item-name">${fmt.format(daysSince)} 天</div><div class="item-val">最后活跃于 ${_formatDate(d['activeEndDate'])}</div></div>
</div>
''';
  }

  static String _buildEndingBody() {
    return '''
<div class="hero-title">尾声</div>
<div class="hero-desc" style="max-width: 100%; margin-top: 40px;">我们总是在向前走<br>却很少有机会回头看看<br>如果这份报告让你有所触动，不妨把它分享给你在意的人<br>愿新的一年，<br>所有期待，皆有回声。</div>
<hr class="divider" style="margin: 60px 0 30px;">
<div class="label-text" style="color: var(--text-main);">ECHO TRACE</div>
<div style="text-align: center; margin-bottom: 40px;">
  <button class="capture-btn" onclick="takeScreenshot()">生成年度长图报告</button>
</div>
''';
  }

  static String _buildHeatmapHtml(ActivityHeatmap activity) {
    final cells = <String>[];
    for (var w = 1; w <= 7; w++) {
      for (var h = 0; h < 24; h++) {
        final val = activity.getNormalizedValue(h, w);
        final alpha = (val * 0.9 + 0.05).clamp(0.05, 1.0); 
        cells.add('<div class="h-cell" style="background: rgba(7, 193, 96, $alpha)"></div>');
      }
    }
    
    final weeks = ['周一','周二','周三','周四','周五','周六','周日']
        .map((e) => '<div class="week-label">$e</div>').join('');
    
    return '''
<div class="heatmap-wrapper">
  <div class="heatmap-header">
     <div></div> 
     <div class="time-labels">
        <span style="grid-column: 1 / span 4">00:00</span>
        <span style="grid-column: 7 / span 4">06:00</span>
        <span style="grid-column: 13 / span 4">12:00</span>
        <span style="grid-column: 19 / span 4">18:00</span>
     </div>
  </div>
  
  <div class="heatmap">
    <div class="heatmap-week-col">$weeks</div>
    <div class="heatmap-grid">${cells.join()}</div>
  </div>
  
  <div class="heatmap-tag-row">
     <span>24H × 7Days</span>
  </div>
</div>
''';
  }
  
  static String _formatDate(String? s) => s?.split('T').first ?? '-';
  static String _weekdayName(int? w) => const {1:'周一',2:'周二',3:'周三',4:'周四',5:'周五',6:'周六',7:'周日'}[w] ?? '';
  static String _escapeHtml(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s);
  static String _escapeHtmlWithBreaks(String s) => _escapeHtml(s).replaceAll('\n', '<br/>');

  static String _buildNav() {
    return '''
<div class="nav-dots" id="nav"></div>
<script>
  try {
    const sections = document.querySelectorAll('section.page');
    const nav = document.getElementById('nav');
    
    sections.forEach((s, i) => {
      const dot = document.createElement('div');
      dot.className = 'dot';
      dot.onclick = () => s.scrollIntoView({ behavior: 'smooth' });
      nav.appendChild(dot);
    });
    
    const dots = document.querySelectorAll('.dot');
    const observer = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          entry.target.classList.add('visible');
          const id = entry.target.id;
          const index = Array.from(sections).findIndex(s => s.id === id);
          dots.forEach((d, i) => d.classList.toggle('active', i === index));
        }
      });
    }, { threshold: 0.4 });
    sections.forEach(s => observer.observe(s));
    if(dots.length > 0) dots[0].classList.add('active');
  } catch(e) { console.error(e); }

  function takeScreenshot() {
    const target = document.getElementById('capture');
    const btn = document.querySelector('.capture-btn');
    const dots = document.querySelector('.nav-dots');
    const loading = document.getElementById('loading');
    
    loading.style.display = 'flex';
    if(btn) btn.style.display = 'none';
    if(dots) dots.style.display = 'none';

    const originalStyle = target.style.cssText;
    target.style.height = 'auto';
    target.style.overflow = 'visible';
    target.style.scrollSnapType = 'none';
    
    const pages = document.querySelectorAll('section.page');
    pages.forEach(p => {
       p.style.minHeight = 'auto';
       p.style.height = 'auto';
       p.style.paddingBottom = '60px';
       const wrapper = p.querySelector('.content-wrapper');
       if(wrapper) {
         wrapper.style.opacity = '1';
         wrapper.style.transform = 'translateY(0)';
         wrapper.style.animation = 'none';
       }
    });

    html2canvas(target, {
      scale: 2, 
      useCORS: true,
      backgroundColor: '#F9F8F6',
      allowTaint: true, 
      logging: false
    }).then(canvas => {
      const imgData = canvas.toDataURL('image/png');
      const isMobile = /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent);
      
      if (!isMobile) {
        const link = document.createElement('a');
        link.download = 'report_2025.png';
        link.href = imgData;
        link.click();
        alert('年度报告已生成并下载！');
      } else {
        document.getElementById('result-img').src = imgData;
        document.getElementById('modal').style.display = 'flex';
      }
      cleanup();
    }).catch(err => {
      console.error(err);
      alert('生成失败：' + err.message);
      cleanup();
    });

    function cleanup() {
      loading.style.display = 'none';
      if(btn) btn.style.display = 'inline-block';
      if(dots) dots.style.display = 'flex';
      target.style.cssText = originalStyle;
      pages.forEach(p => {
         p.style.minHeight = '100vh';
         p.style.height = '';
         p.style.paddingBottom = '';
      });
      location.reload();
    }
  }
</script>
''';
  }
}
