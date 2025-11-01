/// 批处理工具，避免处理大量数据时阻塞用户界面
class BatchProcessor {
  /// 分批处理列表中的项目，避免一次性处理太多数据
  ///
  /// 参数说明：
  /// - [items]: 要处理的数据列表
  /// - [processor]: 对每个项目执行的处理函数
  /// - [batchSize]: 每批处理的项目数量，默认500个
  /// - [yieldEveryBatch]: 是否在每批处理完后让出控制权，默认开启
  static Future<void> processBatches<T>(
    List<T> items,
    Future<void> Function(T item, int index) processor, {
    int batchSize = 500,
    bool yieldEveryBatch = true,
  }) async {
    for (int i = 0; i < items.length; i++) {
      await processor(items[i], i);

      // 每批处理完后让出控制权，避免界面冻结
      if (yieldEveryBatch && (i + 1) % batchSize == 0) {
        await Future.delayed(Duration.zero);
      }
    }
  }

  /// 分批处理并收集所有结果
  ///
  /// 适用于需要保留每个项目处理结果的场景
  ///
  /// 参数说明：
  /// - [items]: 要处理的数据列表
  /// - [processor]: 处理函数，需要返回结果
  /// - [batchSize]: 每批处理的项目数量
  static Future<List<R>> processBatchesWithResult<T, R>(
    List<T> items,
    Future<R> Function(T item, int index) processor, {
    int batchSize = 500,
  }) async {
    final results = <R>[];

    for (int i = 0; i < items.length; i++) {
      final result = await processor(items[i], i);
      results.add(result);

      // 每批处理完后让出控制权，避免界面冻结
      if ((i + 1) % batchSize == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    return results;
  }

  /// 分批聚合处理，适合统计和累积计算
  ///
  /// 适用于需要将所有项目的结果聚合成单个值的场景，
  /// 比如统计总数、求和、找出最大值等
  ///
  /// 参数说明：
  /// - [items]: 要处理的数据列表
  /// - [processor]: 聚合处理函数，接收当前聚合值和新项目，返回更新后的聚合值
  /// - [initialValue]: 聚合的初始值，必须提供
  /// - [batchSize]: 每批处理的项目数量
  static Future<R> processBatchesWithAggregation<T, R>(
    List<T> items,
    Future<R> Function(R aggregation, T item) processor, {
    required R initialValue,
    int batchSize = 500,
  }) async {
    R result = initialValue;

    for (int i = 0; i < items.length; i++) {
      result = await processor(result, items[i]);

      // 每批处理完后让出控制权，避免界面冻结
      if ((i + 1) % batchSize == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    return result;
  }
}
