import 'database_service.dart';

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
      avgResponseTimeMinutes: (json['avgResponseTimeMinutes'] as num)
          .toDouble(),
      totalResponses: json['totalResponses'] as int,
      fastestResponseMinutes: (json['fastestResponseMinutes'] as num)
          .toDouble(),
      slowestResponseMinutes: (json['slowestResponseMinutes'] as num)
          .toDouble(),
    );
  }
}

/// 响应时间分析服务
class ResponseTimeAnalyzer {
  final DatabaseService _databaseService;
  int? _filterYear;

  ResponseTimeAnalyzer(this._databaseService);

  void setYearFilter(int? year) {
    _filterYear = year;
  }

  /// 分析谁回复我的消息最快
  /// [onProgress] 进度回调 (current, total, currentUsername)
  /// [onLog] 日志回调 (message, level)
  Future<List<ResponseTimeResult>> analyzeWhoRepliesFastest({
    Function(int current, int total, String currentUser)? onProgress,
    Function(String message, {String level})? onLog,
  }) async {
    onProgress?.call(0, 1, '正在分析响应速度...');
    onLog?.call(
      '开始调用 DatabaseService.analyzeResponseSpeed (对方回复我)',
      level: 'debug',
    );

    final sqlResults = await _databaseService.analyzeResponseSpeed(
      isMyResponse: false, // 对方回复我
      year: _filterYear,
      onProgress: onProgress,
      onLog: onLog,
    );

    onLog?.call(
      'DatabaseService.analyzeResponseSpeed 返回 ${sqlResults.length} 条结果',
      level: 'debug',
    );

    final results = sqlResults
        .map(
          (data) => ResponseTimeResult(
            username: data['username'] as String,
            displayName: data['displayName'] as String,
            avgResponseTimeMinutes: data['avgResponseTimeMinutes'] as double,
            totalResponses: data['totalResponses'] as int,
            fastestResponseMinutes: data['fastestResponseMinutes'] as double,
            slowestResponseMinutes: data['slowestResponseMinutes'] as double,
          ),
        )
        .toList();

    onProgress?.call(1, 1, '分析完成');
    onLog?.call(
      '转换为 ResponseTimeResult 对象完成，共 ${results.length} 个',
      level: 'debug',
    );

    return results;
  }

  /// 分析我回复谁的消息最快
  /// [onProgress] 进度回调 (current, total, currentUsername)
  /// [onLog] 日志回调 (message, level)
  Future<List<ResponseTimeResult>> analyzeMyFastestReplies({
    Function(int current, int total, String currentUser)? onProgress,
    Function(String message, {String level})? onLog,
  }) async {
    onProgress?.call(0, 1, '正在分析响应速度...');
    onLog?.call(
      '开始调用 DatabaseService.analyzeResponseSpeed (我回复对方)',
      level: 'debug',
    );

    final sqlResults = await _databaseService.analyzeResponseSpeed(
      isMyResponse: true, // 我回复对方
      year: _filterYear,
      onProgress: onProgress,
      onLog: onLog,
    );

    onLog?.call(
      'DatabaseService.analyzeResponseSpeed 返回 ${sqlResults.length} 条结果',
      level: 'debug',
    );

    final results = sqlResults
        .map(
          (data) => ResponseTimeResult(
            username: data['username'] as String,
            displayName: data['displayName'] as String,
            avgResponseTimeMinutes: data['avgResponseTimeMinutes'] as double,
            totalResponses: data['totalResponses'] as int,
            fastestResponseMinutes: data['fastestResponseMinutes'] as double,
            slowestResponseMinutes: data['slowestResponseMinutes'] as double,
          ),
        )
        .toList();

    onProgress?.call(1, 1, '分析完成');
    onLog?.call(
      '转换为 ResponseTimeResult 对象完成，共 ${results.length} 个',
      level: 'debug',
    );

    return results;
  }
}
