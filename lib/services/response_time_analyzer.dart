import '../models/message.dart';
import 'database_service.dart';
import 'analytics_service.dart';

/// 响应时间分析结果
class ResponseTimeResult {
  final String username;
  final String displayName;
  final double avgResponseTimeMinutes; // 平均响应时间（分钟）
  final int totalResponses; // 总响应次数
  final double fastestResponseMinutes; // 最快响应时间
  final double slowestResponseMinutes; // 最慢响应时间

  ResponseTimeResult({
    required this.username,
    required this.displayName,
    required this.avgResponseTimeMinutes,
    required this.totalResponses,
    required this.fastestResponseMinutes,
    required this.slowestResponseMinutes,
  });

  String get avgResponseTimeText {
    if (avgResponseTimeMinutes < 1) {
      return '${(avgResponseTimeMinutes * 60).toStringAsFixed(0)} 秒';
    } else if (avgResponseTimeMinutes < 60) {
      return '${avgResponseTimeMinutes.toStringAsFixed(1)} 分钟';
    } else {
      final hours = avgResponseTimeMinutes / 60;
      return '${hours.toStringAsFixed(1)} 小时';
    }
  }

  Map<String, dynamic> toJson() => {
    'username': username,
    'displayName': displayName,
    'avgResponseTimeMinutes': avgResponseTimeMinutes,
    'totalResponses': totalResponses,
    'fastestResponseMinutes': fastestResponseMinutes,
    'slowestResponseMinutes': slowestResponseMinutes,
  };

  factory ResponseTimeResult.fromJson(Map<String, dynamic> json) {
    return ResponseTimeResult(
      username: json['username'] as String,
      displayName: json['displayName'] as String,
      avgResponseTimeMinutes: (json['avgResponseTimeMinutes'] as num).toDouble(),
      totalResponses: json['totalResponses'] as int,
      fastestResponseMinutes: (json['fastestResponseMinutes'] as num).toDouble(),
      slowestResponseMinutes: (json['slowestResponseMinutes'] as num).toDouble(),
    );
  }
}

/// 响应时间分析服务
class ResponseTimeAnalyzer {
  final DatabaseService _databaseService;
  final AnalyticsService _analyticsService;
  int? _filterYear;

  ResponseTimeAnalyzer(this._databaseService)
      : _analyticsService = AnalyticsService(_databaseService);

  void setYearFilter(int? year) {
    _filterYear = year;
  }

  bool _isSystemAccount(String username) {
    final lower = username.toLowerCase();
    return lower.contains('filehelper') || 
           lower.contains('fmessage') || 
           lower.contains('medianote') ||
           lower.contains('qqmail');
  }

  List<Message> _filterMessagesByYear(List<Message> messages) {
    if (_filterYear == null) return messages;
    
    return messages.where((msg) {
      final time = DateTime.fromMillisecondsSinceEpoch(msg.createTime * 1000);
      return time.year == _filterYear;
    }).toList();
  }

  /// 分析谁回复我的消息最快
  /// [onProgress] 进度回调 (current, total, currentUsername)
  Future<List<ResponseTimeResult>> analyzeWhoRepliesFastest({
    Function(int current, int total, String currentUser)? onProgress,
  }) async {
    final sessions = await _databaseService.getSessions();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .toList();

    final results = <ResponseTimeResult>[];
    final displayNames = await _databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );

    for (int i = 0; i < privateSessions.length; i++) {
      final session = privateSessions[i];
      final username = session.username;
      
      onProgress?.call(i + 1, privateSessions.length, displayNames[username] ?? username);

      try {
        final allMessages = await _analyticsService.getAllMessagesForSession(username);
        final messages = _filterMessagesByYear(allMessages);
        
        // 按时间排序
        messages.sort((a, b) => a.createTime.compareTo(b.createTime));

        final responseTimes = <double>[];
        
        // 查找"我发消息 -> 对方回复"的时间间隔
        for (int j = 0; j < messages.length - 1; j++) {
          final currentMsg = messages[j];
          final nextMsg = messages[j + 1];
          
          // 我发的消息，对方回复
          if (currentMsg.isSend == 1 && nextMsg.isSend != 1) {
            final timeDiff = (nextMsg.createTime - currentMsg.createTime) / 60.0; // 转换为分钟
            
            // 过滤掉超过24小时的响应（可能不是直接回复）
            if (timeDiff <= 1440) {
              responseTimes.add(timeDiff);
            }
          }
        }

        if (responseTimes.isNotEmpty) {
          final avgTime = responseTimes.reduce((a, b) => a + b) / responseTimes.length;
          final fastest = responseTimes.reduce((a, b) => a < b ? a : b);
          final slowest = responseTimes.reduce((a, b) => a > b ? a : b);

          results.add(ResponseTimeResult(
            username: username,
            displayName: displayNames[username] ?? username,
            avgResponseTimeMinutes: avgTime,
            totalResponses: responseTimes.length,
            fastestResponseMinutes: fastest,
            slowestResponseMinutes: slowest,
          ));
        }
      } catch (e) {
        continue;
      }
    }

    // 按平均响应时间排序（从快到慢）
    results.sort((a, b) => a.avgResponseTimeMinutes.compareTo(b.avgResponseTimeMinutes));
    
    return results;
  }

  /// 分析我回复谁的消息最快
  /// [onProgress] 进度回调 (current, total, currentUsername)
  Future<List<ResponseTimeResult>> analyzeMyFastestReplies({
    Function(int current, int total, String currentUser)? onProgress,
  }) async {
    final sessions = await _databaseService.getSessions();
    final privateSessions = sessions
        .where((s) => !s.isGroup && !_isSystemAccount(s.username))
        .toList();

    final results = <ResponseTimeResult>[];
    final displayNames = await _databaseService.getDisplayNames(
      privateSessions.map((s) => s.username).toList(),
    );

    for (int i = 0; i < privateSessions.length; i++) {
      final session = privateSessions[i];
      final username = session.username;
      
      onProgress?.call(i + 1, privateSessions.length, displayNames[username] ?? username);

      try {
        final allMessages = await _analyticsService.getAllMessagesForSession(username);
        final messages = _filterMessagesByYear(allMessages);
        
        // 按时间排序
        messages.sort((a, b) => a.createTime.compareTo(b.createTime));

        final responseTimes = <double>[];
        
        // 查找"对方发消息 -> 我回复"的时间间隔
        for (int j = 0; j < messages.length - 1; j++) {
          final currentMsg = messages[j];
          final nextMsg = messages[j + 1];
          
          // 对方发的消息，我回复
          if (currentMsg.isSend != 1 && nextMsg.isSend == 1) {
            final timeDiff = (nextMsg.createTime - currentMsg.createTime) / 60.0; // 转换为分钟
            
            // 过滤掉超过24小时的响应（可能不是直接回复）
            if (timeDiff <= 1440) {
              responseTimes.add(timeDiff);
            }
          }
        }

        if (responseTimes.isNotEmpty) {
          final avgTime = responseTimes.reduce((a, b) => a + b) / responseTimes.length;
          final fastest = responseTimes.reduce((a, b) => a < b ? a : b);
          final slowest = responseTimes.reduce((a, b) => a > b ? a : b);

          results.add(ResponseTimeResult(
            username: username,
            displayName: displayNames[username] ?? username,
            avgResponseTimeMinutes: avgTime,
            totalResponses: responseTimes.length,
            fastestResponseMinutes: fastest,
            slowestResponseMinutes: slowest,
          ));
        }
      } catch (e) {
        continue;
      }
    }

    // 按平均响应时间排序（从快到慢）
    results.sort((a, b) => a.avgResponseTimeMinutes.compareTo(b.avgResponseTimeMinutes));
    
    return results;
  }
}

