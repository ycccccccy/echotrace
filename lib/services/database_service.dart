import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import '../models/message.dart';
import '../models/contact.dart';
import '../models/chat_session.dart';
import 'wechat_vfs_native.dart';
import 'logger_service.dart';
import '../utils/path_utils.dart';

/// 数据库读取模式
enum DatabaseMode {
  decrypted,  // 使用解密后的数据库（备份模式）
  realtime,   // 实时读取加密数据库（VFS拦截模式）
}

/// 数据库操作服务
class DatabaseService {
  // 数据库模式
  DatabaseMode _mode = DatabaseMode.decrypted;

  // 独立的数据库连接：会话/联系人 和 消息
  static Database? _sessionDb;
  static Database? _messageDb;

  // 当前会话库路径与账号 wxid
  static String? _sessionDbPath;
  static String? _messageDbPath;
  String? _currentAccountWxid;

  // 数据库工厂（用于 Isolate 中避免全局修改）
  DatabaseFactory? _dbFactory;

  // 缓存的消息数据库连接
  final Map<String, Database> _cachedMessageDbs = {};
  DateTime? _cacheLastUsed;
  static const Duration _cacheDuration = Duration(minutes: 5);

  /// 获取当前数据库路径
  String? get dbPath => _sessionDbPath;

  /// 初始化数据库
  Future<void> initialize({DatabaseFactory? factory}) async {
    sqfliteFfiInit();
    _dbFactory = factory;
    // 只在没有指定工厂时才设置全局工厂（用于主线程）
    if (factory == null) {
      databaseFactory = databaseFactoryFfi;
    }
  }

  

  /// 连接解密后的数据库（作为会话库）
  /// [factory] 可选的数据库工厂，用于 Isolate 中避免全局修改
  Future<void> connectDecryptedDatabase(String dbPath, {DatabaseFactory? factory}) async {
    try {
      // 规范化路径，支持中文和空格
      final normalizedPath = PathUtils.normalizeDatabasePath(dbPath);
      await logger.info('DatabaseService', '尝试连接解密后的数据库: ${PathUtils.escapeForLog(normalizedPath)}');

      if (PathUtils.hasSpecialCharacters(normalizedPath)) {
        await logger.warning('DatabaseService', '路径包含特殊字符（中文/空格），已规范化处理');
      }

      if (!File(normalizedPath).existsSync()) {
        await logger.error('DatabaseService', '数据库文件不存在: ${PathUtils.escapeForLog(normalizedPath)}');
        throw Exception('解密后的数据库文件不存在');
      }

      // 保存工厂实例供后续使用
      if (factory != null) {
        _dbFactory = factory;
      }

      // 关闭旧的会话库连接（消息库保持不动）
      if (_sessionDb != null) {
        await _sessionDb!.close();
        _sessionDb = null;
      }

      // 使用指定的工厂或已保存的工厂或默认工厂
      final dbFactory = factory ?? _dbFactory ?? databaseFactory;

      // 以只读模式打开数据库，不指定 version 避免写入操作
      _sessionDb = await dbFactory.openDatabase(
        normalizedPath,
        options: OpenDatabaseOptions(
          readOnly: true,
          singleInstance: false, // 允许多个实例，避免冲突
        ),
      );

      _mode = DatabaseMode.decrypted;
      _sessionDbPath = normalizedPath;
      _currentAccountWxid = _extractWxidFromPath(normalizedPath);

      await logger.info('DatabaseService', '成功连接解密数据库，模式: ${_mode.name}, 当前账号wxid: $_currentAccountWxid');
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '连接解密数据库失败', e, stackTrace);
      rethrow;
    }
  }

  /// 连接实时加密数据库（VFS拦截模式）
  /// [dbPath] 加密数据库路径
  /// [hexKey] 解密密钥（64位十六进制）
  /// [factory] 可选的数据库工厂
  Future<void> connectRealtimeDatabase(String dbPath, String hexKey, {DatabaseFactory? factory}) async {
    try {
      // 规范化路径，支持中文和空格
      final normalizedPath = PathUtils.normalizeDatabasePath(dbPath);
      await logger.info('DatabaseService', '尝试连接实时加密数据库: ${PathUtils.escapeForLog(normalizedPath)}');

      if (PathUtils.hasSpecialCharacters(normalizedPath)) {
        await logger.warning('DatabaseService', '路径包含特殊字符（中文/空格），已规范化处理');
      }

      if (!File(normalizedPath).existsSync()) {
        await logger.error('DatabaseService', '数据库文件不存在: ${PathUtils.escapeForLog(normalizedPath)}');
        throw Exception('数据库文件不存在');
      }

      // 保存工厂实例供后续使用
      if (factory != null) {
        _dbFactory = factory;
      }

      // 关闭旧的会话库连接
      if (_sessionDb != null) {
        await _sessionDb!.close();
        _sessionDb = null;
      }

      // 使用真正的VFS拦截打开加密数据库
      // 在SQLite文件系统层面拦截xRead操作，实时解密数据页
      _sessionDb = await WeChatVFSNative.openEncryptedDatabase(normalizedPath, hexKey);

      _mode = DatabaseMode.realtime;
      _sessionDbPath = normalizedPath;
      _currentAccountWxid = _extractWxidFromPath(normalizedPath);

      await logger.info('DatabaseService', '成功连接实时加密数据库，模式: ${_mode.name}, 当前账号wxid: $_currentAccountWxid');
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '连接实时加密数据库失败', e, stackTrace);
      rethrow;
    }
  }
  
  /// 获取当前使用的数据库工厂
  DatabaseFactory get _currentFactory => _dbFactory ?? databaseFactory;
  
  /// 获取当前数据库模式
  DatabaseMode get mode => _mode;

  /// 获取当前使用的数据库
  Database? get _currentDb => _sessionDb;
  
  /// 获取会话列表
  Future<List<ChatSession>> getSessions() async {
    final db = _currentDb;
    if (db == null) {
      await logger.error('DatabaseService', '获取会话列表失败：数据库未连接');
      throw Exception('数据库未连接');
    }

    try {
      await logger.info('DatabaseService', '开始获取会话列表');
      
      // 先检查表是否存在
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'"
      );
      
      final tableNames = tables.map((t) => t['name'] as String).toList();
      
      await logger.info('DatabaseService', '数据库中的表: ${tableNames.join(", ")}');
      
      // 尝试找到会话表（可能的表名）
      String? sessionTableName;
      for (final name in ['SessionTable', 'Session', 'session', 'Contact']) {
        if (tableNames.contains(name)) {
          sessionTableName = name;
          await logger.info('DatabaseService', '找到会话表: $name');
          break;
        }
      }
      
      if (sessionTableName == null) {
        await logger.warning('DatabaseService', '未找到标准会话表，尝试其他表');
        // 如果没有找到会话表，尝试从其他表获取联系人信息
        if (tableNames.contains('contact') || tableNames.contains('Contact')) {
          return await _getSessionsFromContactTable(tableNames);
        } else if (tableNames.contains('FMessageTable')) {
          return await _getSessionsFromFMessageTable();
        } else {
          // 检查是否是纯消息数据库
          final hasMsgTables = tableNames.any((t) => t.startsWith('Msg_'));
          if (hasMsgTables) {
            throw Exception('当前连接的是消息数据库（message_x.db），无法获取会话列表。请确保系统连接的是 session.db 或 contact.db。如果问题持续，请尝试重新解密数据库。');
          }
          throw Exception('数据库中未找到会话表。可用的表: ${tableNames.join(", ")}');
        }
      }

      await logger.info('DatabaseService', '从表 $sessionTableName 查询会话');
      
      final List<Map<String, dynamic>> maps = await db.query(
        sessionTableName,
        orderBy: 'sort_timestamp DESC',
      );

      await logger.info('DatabaseService', '查询到 ${maps.length} 条原始会话记录');
      
      // 获取会话列表后，尝试从 contact 数据库获取真实姓名
      final allSessions = maps.map((map) => ChatSession.fromMap(map)).toList();
      
      await logger.info('DatabaseService', '转换为 ${allSessions.length} 个ChatSession对象');
      
      // 过滤掉公众号、服务号等非正常联系人
      final filteredSessions = allSessions.where((session) {
        final username = session.username;
        
        // 过滤条件：只显示正常联系人和群聊
        final shouldKeep = username.contains('@chatroom') ||
                          (username.startsWith('wxid_') && !username.contains('@')) ||
                          (!username.contains('@kefu.openim') && 
                           !username.contains('service_') &&
                           !username.startsWith('gh_') &&
                           !username.contains('@openim'));
        
        return shouldKeep;
      }).toList();
      
      await logger.info('DatabaseService', '过滤后剩余 ${filteredSessions.length} 个会话');
      
      // 尝试连接 contact 数据库获取真实姓名
      await _enrichSessionsWithContactInfo(filteredSessions);
      
      await logger.info('DatabaseService', '成功返回 ${filteredSessions.length} 个会话');
      
      return filteredSessions;
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '获取会话列表失败', e, stackTrace);
      throw Exception('获取会话列表失败: $e');
    }
  }

  /// 获取联系人信息
  Future<Contact?> getContact(String username) async {
    final db = _currentDb;
    if (db == null) {
      throw Exception('数据库未连接');
    }

    try {
      final List<Map<String, dynamic>> maps = await db.query(
        'contact',
        where: 'username = ?',
        whereArgs: [username],
        limit: 1,
      );

      if (maps.isNotEmpty) {
        return Contact.fromMap(maps.first);
      }
      return null;
    } catch (e) {
      throw Exception('获取联系人信息失败: $e');
    }
  }

  /// 获取消息列表（支持跨多个数据库合并，按时间正确排序）
  Future<List<Message>> getMessages(String sessionId, {int limit = 50, int offset = 0}) async {
    if (_sessionDb == null) {
      await logger.error('DatabaseService', '获取消息列表失败：数据库未连接');
      throw Exception('数据库未连接');
    }

    try {
      await logger.info('DatabaseService', '开始获取消息，sessionId=$sessionId, limit=$limit, offset=$offset');
      
      // 第一步：找到所有包含该会话消息的数据库及表
      final List<_DatabaseTableInfo> dbInfos = [];
      
      // 1. 检查当前数据库
      final Database dbForMsg = await _getDbForMessages();
      final String? currentDbPath = _messageDbPath;
      final tableName = await _getMessageTableName(sessionId, dbForMsg);
      
      if (tableName != null) {
        dbInfos.add(_DatabaseTableInfo(
          database: dbForMsg,
          tableName: tableName,
          latestTimestamp: 0,
          needsClose: false,
        ));
        await logger.info('DatabaseService', '当前数据库找到消息表: $tableName');
      }
      
      // 2. 搜索所有其他消息数据库
      final allMessageDbs = await _findAllMessageDbs();
      await logger.info('DatabaseService', '搜索 ${allMessageDbs.length} 个消息数据库');
      
      for (int i = 0; i < allMessageDbs.length; i++) {
        final dbPath = allMessageDbs[i];
        
        if (currentDbPath != null && dbPath == currentDbPath) {
          await logger.info('DatabaseService', '跳过已查询的当前数据库: $dbPath');
          continue;
        }
        
        try {
          final normalizedDbPath = PathUtils.normalizeDatabasePath(dbPath);
          final tempDb = await _currentFactory.openDatabase(
            normalizedDbPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );

          try {
            final foundTableName = await _getMessageTableName(sessionId, tempDb, dbIndex: i);
            if (foundTableName != null) {
              dbInfos.add(_DatabaseTableInfo(
                database: tempDb,
                tableName: foundTableName,
                latestTimestamp: 0,
                needsClose: true,
              ));
              await logger.info('DatabaseService', '数据库$i找到消息表: $foundTableName');
            } else {
              await tempDb.close();
            }
          } catch (e) {
            await tempDb.close();
            rethrow;
          }
        } catch (e) {
          await logger.warning('DatabaseService', '数据库$i查询失败', e);
        }
      }
      
      if (dbInfos.isEmpty) {
        await logger.warning('DatabaseService', '未找到任何包含该会话消息的数据库');
        return [];
      }
      
      await logger.info('DatabaseService', '找到 ${dbInfos.length} 个包含该会话消息的数据库');
      
      try {
        // 第二步：从所有数据库收集消息的时间戳信息（轻量级查询）
        final List<_MessageTimeInfo> timeInfos = [];
        
        for (int i = 0; i < dbInfos.length; i++) {
          final dbInfo = dbInfos[i];
          await logger.info('DatabaseService', '从数据库$i收集时间戳信息');
          
          try {
            final rows = await dbInfo.database.rawQuery('''
              SELECT local_id, create_time 
              FROM ${dbInfo.tableName} 
              ORDER BY create_time DESC
            ''');
            
            for (final row in rows) {
              timeInfos.add(_MessageTimeInfo(
                localId: row['local_id'] as int,
                createTime: row['create_time'] as int,
                dbIndex: i,
              ));
            }
            
            await logger.info('DatabaseService', '数据库$i收集到 ${rows.length} 条时间戳');
          } catch (e) {
            await logger.warning('DatabaseService', '数据库$i收集时间戳失败', e);
          }
        }
        
        if (timeInfos.isEmpty) {
          await logger.warning('DatabaseService', '未收集到任何消息时间戳');
          return [];
        }
        
        // 第三步：按时间排序所有时间戳（降序）
        timeInfos.sort((a, b) => b.createTime.compareTo(a.createTime));
        await logger.info('DatabaseService', '收集到 ${timeInfos.length} 条时间戳，已排序');
        
        // 第四步：根据分页需求确定需要加载的消息
        final startIndex = offset.clamp(0, timeInfos.length);
        final endIndex = (offset + limit).clamp(0, timeInfos.length);
        final neededTimeInfos = timeInfos.sublist(startIndex, endIndex);
        
        await logger.info('DatabaseService', '需要加载 ${neededTimeInfos.length} 条消息 (offset=$offset, limit=$limit)');
        
        // 第五步：按数据库分组需要加载的消息ID
        final Map<int, List<int>> dbIndexToLocalIds = {};
        for (final info in neededTimeInfos) {
          dbIndexToLocalIds.putIfAbsent(info.dbIndex, () => []).add(info.localId);
        }
        
        // 第六步：从各个数据库加载完整消息内容
        final List<Message> messages = [];
        
        for (final entry in dbIndexToLocalIds.entries) {
          final dbIndex = entry.key;
          final localIds = entry.value;
          final dbInfo = dbInfos[dbIndex];
          
          await logger.info('DatabaseService', '从数据库$dbIndex加载 ${localIds.length} 条消息');
          
          try {
            // 分批查询，避免SQL太长
            const batchSize = 500;
            for (int i = 0; i < localIds.length; i += batchSize) {
              final batchIds = localIds.sublist(i, (i + batchSize).clamp(0, localIds.length));
              final idsStr = batchIds.join(',');
              
              final rows = await dbInfo.database.rawQuery('''
                SELECT 
                  m.*,
                  CASE WHEN m.real_sender_id = (
                    SELECT rowid FROM Name2Id WHERE user_name = ?
                  ) THEN 1 ELSE 0 END AS is_send,
                  n.user_name AS sender_username
                FROM ${dbInfo.tableName} m 
                LEFT JOIN Name2Id n ON m.real_sender_id = n.rowid
                WHERE m.local_id IN ($idsStr)
              ''', [_currentAccountWxid ?? '']);
              
              messages.addAll(rows.map((map) => Message.fromMap(map, myWxid: _currentAccountWxid)));
            }
          } catch (e) {
            await logger.error('DatabaseService', '从数据库$dbIndex加载消息失败', e);
          }
        }
        
        // 第七步：按时间排序返回（确保顺序）
        messages.sort((a, b) => b.createTime.compareTo(a.createTime));
        
        await logger.info('DatabaseService', '成功加载 ${messages.length} 条消息');
        return messages;
      } finally {
        // 关闭临时打开的数据库
        for (final dbInfo in dbInfos) {
          if (dbInfo.needsClose) {
            try {
              await dbInfo.database.close();
            } catch (e) {
              // 忽略关闭错误
            }
          }
        }
      }
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '获取消息列表失败', e, stackTrace);
      throw Exception('获取消息列表失败: $e');
    }
  }

  /// 根据日期查询消息（支持跨多个数据库合并）
  Future<List<Message>> getMessagesByDate(String sessionId, int begintimestamp, int endtimestamp) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      // 收集所有消息（可能分散在多个数据库中）
      final List<Message> allMessages = [];
      
      // 1. 先尝试当前数据库
      final Database dbForMsg = await _getDbForMessages();
      final String? currentDbPath = _messageDbPath; // 保存当前数据库路径用于后续排除
      final tableName = await _getMessageTableName(sessionId, dbForMsg);

      if (tableName != null) {
        final messages = await _queryMessagesFromTable(dbForMsg, tableName, 0, 0, begintimestamp: begintimestamp, endTimestamp: endtimestamp);
        allMessages.addAll(messages);
      }

      // 2. 搜索所有其他消息数据库，排除当前已查询的数据库
      final allMessageDbs = await _findAllMessageDbs();

      for (int i = 0; i < allMessageDbs.length; i++) {
        final dbPath = allMessageDbs[i];

        // 跳过已经查询过的当前数据库
        if (currentDbPath != null && dbPath == currentDbPath) {
          continue;
        }

        try {
          final normalizedDbPath = PathUtils.normalizeDatabasePath(dbPath);
          final tempDb = await _currentFactory.openDatabase(
            normalizedDbPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );

          try {
            final foundTableName = await _getMessageTableName(sessionId, tempDb, dbIndex: i);
            if (foundTableName != null) {
              final messages = await _queryMessagesFromTable(tempDb, foundTableName, 0, 0, begintimestamp: begintimestamp, endTimestamp: endtimestamp);
              allMessages.addAll(messages);
            }
          } finally {
            await tempDb.close();
          }
        } catch (e) {
          // 忽略单个数据库的错误，继续查询其他数据库
        }
      }

      // 3. 按时间戳排序（降序，最新的在前）
      allMessages.sort((a, b) => b.createTime.compareTo(a.createTime));

      return allMessages;
    } catch (e) {
      throw Exception('获取消息列表失败: $e');
    }
  }

  /// 从指定表查询消息
  Future<List<Message>> _queryMessagesFromTable(
    Database db, 
    String tableName,
    int limit,
    int offset,
    {int begintimestamp=0, int endTimestamp=0,}
  ) async {
      // 根据 real_sender_id 判断是否为自己发送
      // real_sender_id 是 Name2Id 表的 rowid，需要先查找当前用户wxid对应的rowid

    // 调试：先查询当前用户的rowid
    try {
      final myRowidResult = await db.rawQuery(
        'SELECT rowid FROM Name2Id WHERE user_name = ?',
        [_currentAccountWxid ?? '']
      );
      await logger.info('DatabaseService', '当前用户wxid: $_currentAccountWxid, 在Name2Id表中的rowid: ${myRowidResult.isNotEmpty ? myRowidResult.first['rowid'] : '未找到'}');
      
      // 查看Name2Id表的前几条记录（从 rowid=1 开始）
      final name2idSample = await db.rawQuery('SELECT rowid, user_name FROM Name2Id WHERE rowid <= 5 ORDER BY rowid');
      await logger.info('DatabaseService', 'Name2Id表样本数据(rowid 1-5): $name2idSample');
    } catch (e) {
      await logger.error('DatabaseService', '调试查询失败', e);
    }

    // 构建基本 SQL
    // 使用子查询找到当前用户wxid在Name2Id表中的rowid，然后与real_sender_id比较
     final buffer = StringBuffer('''
      SELECT 
      m.*,
      CASE WHEN m.real_sender_id = (
        SELECT rowid FROM Name2Id WHERE user_name = ?
      ) THEN 1 ELSE 0 END AS is_send,
      n.user_name AS sender_username,
      m.real_sender_id as debug_real_sender_id,
      (SELECT rowid FROM Name2Id WHERE user_name = ?) as debug_my_rowid
      FROM $tableName m 
      LEFT JOIN Name2Id n ON m.real_sender_id = n.rowid
      ''');

      // 构建 where 条件
      final whereClauses = <String>[];
      // 两个参数都是当前用户的wxid（用于两个子查询：is_send判断 和 调试用的my_rowid）
      final args = <Object?>[_currentAccountWxid ?? '', _currentAccountWxid ?? ''];
      
      if (begintimestamp > 0) {
        whereClauses.add('m.create_time >= ?');
        args.add(begintimestamp);
      }
      if (endTimestamp > 0) {
        whereClauses.add('m.create_time <= ?');
        args.add(endTimestamp);
      }
      // 拼接 where
      if (whereClauses.isNotEmpty) {
        buffer.write(' WHERE ${whereClauses.join(' AND ')}');
      }


      //拼接排序
      buffer.write(' ORDER BY m.sort_seq DESC ');

      // 分页
      if(limit>0 || offset>0) {
        buffer.write(' LIMIT ? OFFSET ?');
        args.addAll([limit, offset]);
      }

      //执行查询
      final maps = await db.rawQuery(buffer.toString(), args);
      
      // 调试：打印前几条消息的is_send判断结果
      if (maps.isNotEmpty) {
        await logger.info('DatabaseService', '查询到 ${maps.length} 条消息');
        final sampleSize = maps.length > 3 ? 3 : maps.length;
        for (int i = 0; i < sampleSize; i++) {
          final map = maps[i];
          await logger.info('DatabaseService', '消息$i: real_sender_id=${map['debug_real_sender_id']}, my_rowid=${map['debug_my_rowid']}, is_send=${map['is_send']}, sender_username=${map['sender_username']}');
        }
      }

      return maps.map((map) => Message.fromMap(map, myWxid: _currentAccountWxid)).toList();
  }

  /// 获取会话的消息总数
  Future<int> getMessageCount(String sessionId) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      int totalCount = 0;
      
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      // 从所有数据库累加计数
      for (final dbInfo in dbInfos) {
        try {
          final result = await dbInfo.database.rawQuery('SELECT COUNT(*) as count FROM ${dbInfo.tableName}');
          totalCount += (result.first['count'] as int?) ?? 0;
        } catch (e) {
          // 忽略错误，继续下一个
        }
      }
      
      return totalCount;
    } catch (e) {
      return 0;
    }
  }

  /// 根据会话ID获取消息表名
  Future<String?> _getMessageTableName(String sessionId, Database db, {int? dbIndex}) async {
    try {
      // 查询所有消息表
      final List<Map<String, dynamic>> tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
      );
      
      // 计算sessionId的MD5值（32位小写）
      final sessionMd5 = _md5(sessionId);
      
      // 1. 精确匹配：Msg_{md5} 格式
      final expectedTableName = 'Msg_$sessionMd5';
      for (final table in tables) {
        final tableName = table['name'] as String;
        if (tableName.toLowerCase() == expectedTableName.toLowerCase()) {
          return tableName;
        }
      }
      
      // 2. 包含匹配：表名中包含完整MD5
      for (final table in tables) {
        final tableName = table['name'] as String;
        if (tableName.toLowerCase().contains(sessionMd5.toLowerCase())) {
          return tableName;
        }
      }

      // 2.5. 部分MD5匹配（前24位）
      final partialMd5 = sessionMd5.substring(0, 24);
      for (final table in tables) {
        final tableName = table['name'] as String;
        if (tableName.toLowerCase().contains(partialMd5.toLowerCase())) {
          return tableName;
        }
      }

      // 2.6. 尝试不同的大小写组合
      final variants = [
        'Msg_$sessionMd5',
        'msg_$sessionMd5',
        'MSG_$sessionMd5',
        'Msg_${sessionMd5.toUpperCase()}',
      ];
      
      for (final variant in variants) {
        for (final table in tables) {
          final tableName = table['name'] as String;
          if (tableName == variant) {
            return tableName;
          }
        }
      }

      // 3. 检查 Name2Id 表，验证用户是否存在
      try {
        // 首先尝试精确匹配
        var name2IdRows = await db.rawQuery(
          'SELECT rowid, user_name FROM Name2Id WHERE user_name = ? LIMIT 1',
          [sessionId]
        );
        
        if (name2IdRows.isEmpty) {
          // 尝试模糊匹配（可能有前缀或后缀）
          name2IdRows = await db.rawQuery(
            "SELECT rowid, user_name FROM Name2Id WHERE user_name LIKE ? LIMIT 5",
            ['%$sessionId%']
          );
          
          if (name2IdRows.isNotEmpty) {
            for (final row in name2IdRows) {
              // 尝试使用找到的用户名计算MD5并查找表
              final altUsername = row['user_name'] as String;
              final altMd5 = _md5(altUsername);
              final altTableName = 'Msg_$altMd5';
              
              for (final table in tables) {
                final tableName = table['name'] as String;
                if (tableName.toLowerCase() == altTableName.toLowerCase()) {
                  return tableName;
                }
              }
            }
          }
        }
      } catch (e) {
        // 查询失败，继续
      }

      // 4. 检查 DeleteInfo 表，看是否有删除记录
      try {
        final deleteInfoRows = await db.rawQuery(
          'SELECT delete_table_name FROM DeleteInfo WHERE chat_name_id IN (SELECT rowid FROM Name2Id WHERE user_name = ?)',
          [sessionId]
        );
        
        if (deleteInfoRows.isNotEmpty) {
        }
      } catch (e) {
        // DeleteInfo 表可能不存在，忽略错误
      }

      // 5. 尝试通过 Name2Id 反向查找可能的表
      try {
        // 查询所有 Name2Id 记录，看看是否有相似的
        final allName2Id = await db.rawQuery('SELECT rowid, user_name FROM Name2Id LIMIT 100');
        
        for (final row in allName2Id) {
          final userName = row['user_name'] as String?;
          if (userName != null && userName.toLowerCase().contains(sessionId.toLowerCase())) {
            // 找到相似用户名
          }
        }
      } catch (e) {
        // 忽略错误
      }
      
      return null;
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '查找消息表异常', e, stackTrace);
      return null;
    }
  }

  /// 计算MD5哈希
  String _md5(String input) {
    var bytes = utf8.encode(input);
    var digest = md5.convert(bytes);
    return digest.toString();
  }

  /// 搜索消息
  Future<List<Message>> searchMessages(String keyword, {int limit = 100}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final Database dbForMsg = await _getDbForMessages();
      final List<Map<String, dynamic>> tables = await dbForMsg.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
      );

      final List<Message> results = [];
      
      for (final table in tables) {
        final tableName = table['name'] as String;
        
        // 使用JOIN和子查询来正确判断is_send
        final List<Map<String, dynamic>> maps = await dbForMsg.rawQuery('''
          SELECT 
            m.*,
            CASE WHEN m.real_sender_id = (
              SELECT rowid FROM Name2Id WHERE user_name = ?
            ) THEN 1 ELSE 0 END AS is_send,
            n.user_name AS sender_username
          FROM $tableName m 
          LEFT JOIN Name2Id n ON m.real_sender_id = n.rowid
          WHERE m.message_content LIKE ?
          LIMIT ?
        ''', [_currentAccountWxid ?? '', '%$keyword%', limit]);

        results.addAll(maps.map((map) => Message.fromMap(map, myWxid: _currentAccountWxid)));
      }

      return results;
    } catch (e) {
      throw Exception('搜索消息失败: $e');
    }
  }

  /// 快速获取会话按日期分组的消息统计（包含第一条消息发送者）
  Future<Map<String, Map<String, dynamic>>> getSessionMessagesByDate(String sessionId, {int? filterYear}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final resultMap = <String, Map<String, dynamic>>{};
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      // 从所有数据库查询并合并
      for (final dbInfo in dbInfos) {
        try {
          final result = await dbInfo.database.rawQuery('''
            SELECT 
              DATE(create_time, 'unixepoch', 'localtime') as date,
              COUNT(*) as count,
              (SELECT CASE WHEN real_sender_id = (SELECT rowid FROM Name2Id WHERE user_name = ?) THEN 1 ELSE 0 END 
               FROM ${dbInfo.tableName} t2 
               WHERE DATE(t2.create_time, 'unixepoch', 'localtime') = DATE(t1.create_time, 'unixepoch', 'localtime')
               ${yearFilter ?? ''}
               ORDER BY t2.create_time ASC LIMIT 1) as first_is_send
            FROM ${dbInfo.tableName} t1
            WHERE 1=1 ${yearFilter ?? ''}
            GROUP BY date
            ORDER BY date
          ''', [_currentAccountWxid ?? '']);
          
          for (final row in result) {
            final date = row['date'] as String;
            final count = (row['count'] as int?) ?? 0;
            final firstIsSend = (row['first_is_send'] as int?) == 1;
            
            if (resultMap.containsKey(date)) {
              resultMap[date]!['count'] = (resultMap[date]!['count'] as int) + count;
            } else {
              resultMap[date] = {
                'count': count,
                'firstIsSend': firstIsSend,
              };
            }
          }
        } catch (e) {
        }
      }
      
      return resultMap;
    } catch (e) {
      return {};
    }
  }

  /// 快速获取会话消息的日期列表（用于连续打卡等分析，不加载消息内容）
  Future<List<DateTime>> getSessionMessageDates(String sessionId, {int? filterYear}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final allDates = <String>{};
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      // 从所有数据库查询并合并
      for (final dbInfo in dbInfos) {
        try {
          final result = await dbInfo.database.rawQuery('''
            SELECT DISTINCT DATE(create_time, 'unixepoch', 'localtime') as date
            FROM ${dbInfo.tableName}
            WHERE 1=1 ${yearFilter ?? ''}
          ''');
          
          for (final row in result) {
            allDates.add(row['date'] as String);
          }
        } catch (e) {
        }
      }
      
      // 排序并转换为DateTime
      final sortedDates = allDates.toList()..sort();
      return sortedDates.map((dateStr) => DateTime.parse(dateStr)).toList();
    } catch (e) {
      return [];
    }
  }

  /// 快速获取我发送的文本消息（用于长度分析，只加载必要字段）
  Future<List<Map<String, dynamic>>> getMyTextMessagesForLengthAnalysis({int? filterYear}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final results = <Map<String, dynamic>>[];
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      // 使用缓存的数据库连接
      final cachedDbs = await _getCachedMessageDatabases();
      
      // 从所有数据库查询
      for (int dbIdx = 0; dbIdx < cachedDbs.length; dbIdx++) {
        final dbInfo = cachedDbs[dbIdx];
        try {
          // 获取所有消息表
          final tables = await dbInfo.database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
          );
          
          // 只查询我发送的文本消息（local_type = 1）
          for (final table in tables) {
            final tableName = table['name'] as String;
            try {
              final msgs = await dbInfo.database.rawQuery('''
                SELECT 
                  local_id,
                  message_content,
                  compress_content,
                  create_time,
                  LENGTH(COALESCE(message_content, '')) as content_length
                FROM $tableName
                WHERE local_type = 1 
                  AND real_sender_id = (
                    SELECT rowid FROM Name2Id WHERE user_name = ?
                  )
                  ${yearFilter ?? ''}
                ORDER BY content_length DESC
                LIMIT 100
              ''', [_currentAccountWxid ?? '']);
              
              for (final msg in msgs) {
                results.add({
                  ...msg,
                  'table_name': tableName,
                  'db_index': dbIdx,
                });
              }
            } catch (e) {
            }
          }
        } catch (e) {
        }
      }
      
      // 按长度排序，返回前100条
      results.sort((a, b) => (b['content_length'] as int).compareTo(a['content_length'] as int));
      return results.take(100).toList();
    } catch (e) {
      return [];
    }
  }

  /// 快速获取所有会话的消息类型分布（SQL直接统计）
  Future<Map<int, int>> getAllMessageTypeDistribution({int? filterYear}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final typeCount = <int, int>{};
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      // 使用缓存的数据库连接
      final cachedDbs = await _getCachedMessageDatabases();
      
      // 从所有数据库查询并累加
      for (final dbInfo in cachedDbs) {
        try {
          // 获取所有消息表
          final tables = await dbInfo.database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
          );
          
          // 统计每个表的消息类型
          for (final table in tables) {
            final tableName = table['name'] as String;
            try {
              final result = await dbInfo.database.rawQuery('''
                SELECT local_type, COUNT(*) as count
                FROM $tableName
                WHERE 1=1 ${yearFilter ?? ''}
                GROUP BY local_type
              ''');
              
              for (final row in result) {
                final type = row['local_type'] as int;
                final count = row['count'] as int;
                typeCount[type] = (typeCount[type] ?? 0) + count;
              }
            } catch (e) {
            }
          }
        } catch (e) {
        }
      }
      
      return typeCount;
    } catch (e) {
      return {};
    }
  }

  /// 快速获取会话消息统计（不加载所有消息，直接SQL统计）
  Future<Map<String, dynamic>> getSessionMessageStats(String sessionId, {int? filterYear}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      int totalCount = 0;
      int sentCount = 0;
      int receivedCount = 0;
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      // 从所有数据库查询并累加统计
      for (final dbInfo in dbInfos) {
        try {
          final result = await dbInfo.database.rawQuery('''
            SELECT 
              COUNT(*) as total,
              COALESCE(SUM(CASE WHEN real_sender_id = (SELECT rowid FROM Name2Id WHERE user_name = ?) THEN 1 ELSE 0 END), 0) as sent,
              COALESCE(SUM(CASE WHEN real_sender_id != (SELECT rowid FROM Name2Id WHERE user_name = ?) THEN 1 ELSE 0 END), 0) as received
            FROM ${dbInfo.tableName}
            WHERE 1=1 ${yearFilter ?? ''}
          ''', [_currentAccountWxid ?? '', _currentAccountWxid ?? '']);
          
          final row = result.first;
          totalCount += (row['total'] as int?) ?? 0;
          sentCount += (row['sent'] as int?) ?? 0;
          receivedCount += (row['received'] as int?) ?? 0;
        } catch (e) {
        }
      }
      
      return {
        'total': totalCount,
        'sent': sentCount,
        'received': receivedCount,
      };
    } catch (e) {
      return {
        'total': 0,
        'sent': 0,
        'received': 0,
      };
    }
  }

  /// 获取深夜消息统计（0:00-5:59）
  Future<Map<String, dynamic>> getMidnightMessageStats(String sessionId, {int? filterYear}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      int midnightCount = 0;
      final hourlyData = <int, int>{};
      for (int h = 0; h < 6; h++) {
        hourlyData[h] = 0;
      }
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      // 从所有数据库查询并累加统计
      for (final dbInfo in dbInfos) {
        try {
          // 统计深夜总消息数（0-5点）
          final result = await dbInfo.database.rawQuery('''
            SELECT 
              CAST(strftime('%H', datetime(create_time, 'unixepoch', 'localtime')) AS INTEGER) as hour,
              COUNT(*) as count
            FROM ${dbInfo.tableName}
            WHERE CAST(strftime('%H', datetime(create_time, 'unixepoch', 'localtime')) AS INTEGER) < 6
              ${yearFilter ?? ''}
            GROUP BY hour
          ''');
          
          for (final row in result) {
            final hour = row['hour'] as int;
            final count = row['count'] as int;
            hourlyData[hour] = (hourlyData[hour] ?? 0) + count;
            midnightCount += count;
          }
        } catch (e) {
          // 忽略错误
        }
      }
      
      return {
        'midnightCount': midnightCount,
        'hourlyData': hourlyData,
      };
    } catch (e) {
      return {
        'midnightCount': 0,
        'hourlyData': <int, int>{},
      };
    }
  }

  /// 获取数据库统计信息
  Future<Map<String, int>> getDatabaseStats() async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final stats = <String, int>{};

      // 获取会话数量
      final sessionResult = await _sessionDb!.rawQuery(
        'SELECT COUNT(*) as count FROM SessionTable'
      );
      final sessionCount = sessionResult.first['count'] as int? ?? 0;
      stats['sessions'] = sessionCount;

      // 获取联系人数量
      final contactResult = await _sessionDb!.rawQuery(
        'SELECT COUNT(*) as count FROM contact'
      );
      final contactCount = contactResult.first['count'] as int? ?? 0;
      stats['contacts'] = contactCount;

      // 获取消息表数量
      final Database dbForMsg = await _getDbForMessages();
      final messageTables = await dbForMsg.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
      );
      stats['message_tables'] = messageTables.length;

      return stats;
    } catch (e) {
      throw Exception('获取数据库统计信息失败: $e');
    }
  }

  /// 获取会话的消息类型分布
  Future<Map<String, int>> getSessionTypeDistribution(String sessionId) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      int textCount = 0;
      int imageCount = 0;
      int voiceCount = 0;
      int videoCount = 0;
      int otherCount = 0;
      
      // 从所有数据库查询并累加
      for (final dbInfo in dbInfos) {
        try {
          final result = await dbInfo.database.rawQuery('''
            SELECT 
              SUM(CASE WHEN local_type IN (1, 244813135921) THEN 1 ELSE 0 END) as text,
              SUM(CASE WHEN local_type = 3 THEN 1 ELSE 0 END) as image,
              SUM(CASE WHEN local_type = 34 THEN 1 ELSE 0 END) as voice,
              SUM(CASE WHEN local_type = 43 THEN 1 ELSE 0 END) as video,
              SUM(CASE WHEN local_type NOT IN (1, 3, 34, 43, 244813135921) THEN 1 ELSE 0 END) as other
            FROM ${dbInfo.tableName}
          ''');
          
          final row = result.first;
          textCount += (row['text'] as int?) ?? 0;
          imageCount += (row['image'] as int?) ?? 0;
          voiceCount += (row['voice'] as int?) ?? 0;
          videoCount += (row['video'] as int?) ?? 0;
          otherCount += (row['other'] as int?) ?? 0;
        } catch (e) {
          // 忽略错误
        }
      }
      
      return {
        'text': textCount,
        'image': imageCount,
        'voice': voiceCount,
        'video': videoCount,
        'other': otherCount,
      };
    } catch (e) {
      return {'text': 0, 'image': 0, 'voice': 0, 'video': 0, 'other': 0};
    }
  }

  /// 获取会话的时间范围（第一条和最后一条消息时间，用于分析服务）
  Future<Map<String, int?>> getSessionTimeRange(String sessionId) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      int? firstTime;
      int? lastTime;
      
      // 从所有数据库查询并比较
      for (final dbInfo in dbInfos) {
        try {
          final result = await dbInfo.database.rawQuery('''
            SELECT 
              MIN(create_time) as first,
              MAX(create_time) as last
            FROM ${dbInfo.tableName}
          ''');
          
          final row = result.first;
          final dbFirst = row['first'] as int?;
          final dbLast = row['last'] as int?;
          
          if (dbFirst != null && (firstTime == null || dbFirst < firstTime)) {
            firstTime = dbFirst;
          }
          if (dbLast != null && (lastTime == null || dbLast > lastTime)) {
            lastTime = dbLast;
          }
        } catch (e) {
          // 忽略错误
        }
      }
      
      return {
        'first': firstTime,
        'last': lastTime,
      };
    } catch (e) {
      return {'first': null, 'last': null};
    }
  }

  /// 批量获取多个会话的统计数据
  Future<Map<String, Map<String, dynamic>>> getBatchSessionStats(List<String> sessionIds) async {
    await logger.debug('DatabaseService', '========== 开始批量获取会话统计 ==========');
    await logger.debug('DatabaseService', '需要查询的会话数: ${sessionIds.length}');

    if (_sessionDb == null) {
      await logger.error('DatabaseService', '数据库未连接');
      throw Exception('数据库未连接');
    }

    final result = <String, Map<String, dynamic>>{};

    // 使用缓存的数据库连接
    await logger.debug('DatabaseService', '获取缓存的数据库连接');
    final cachedDbs = await _getCachedMessageDatabases();
    await logger.debug('DatabaseService', '缓存的数据库数量: ${cachedDbs.length}');

    int processedCount = 0;
    int emptySessionCount = 0;
    int errorSessionCount = 0;

    for (final sessionId in sessionIds) {
      try {
        // 收集该会话在所有数据库的表
        final dbInfos = <_DatabaseTableInfo>[];

        for (final dbInfo in cachedDbs) {
          try {
            final tableName = await _getMessageTableName(
              sessionId,
              dbInfo.database,
            );

            if (tableName != null) {
              dbInfos.add(_DatabaseTableInfo(
                database: dbInfo.database,
                tableName: tableName,
                latestTimestamp: 0,
                needsClose: false,
              ));
            }
          } catch (e) {
            // 忽略错误
          }
        }

        if (dbInfos.isEmpty) {
          emptySessionCount++;
          // 每处理50个会话记录一次
          if ((processedCount + 1) % 50 == 0) {
            await logger.debug('DatabaseService', '已处理 ${processedCount + 1}/${sessionIds.length} 个会话（空会话: $emptySessionCount, 错误: $errorSessionCount）');
          }
          continue;
        }

        await logger.debug('DatabaseService', '会话 $sessionId 在 ${dbInfos.length} 个数据库中找到消息表');
        
        // 统计数据
        int totalCount = 0;
        int sentCount = 0;
        int receivedCount = 0;
        int textCount = 0;
        int imageCount = 0;
        int voiceCount = 0;
        int videoCount = 0;
        int otherCount = 0;
        int? firstTime;
        int? lastTime;
        final datesSet = <String>{};

        // 从所有数据库累加统计
        for (final dbInfo in dbInfos) {
          try {
            // 一次查询获取所有统计
            final statResult = await dbInfo.database.rawQuery('''
              SELECT
                COUNT(*) as total,
                SUM(CASE WHEN real_sender_id = (SELECT rowid FROM Name2Id WHERE user_name = ?) THEN 1 ELSE 0 END) as sent,
                SUM(CASE WHEN real_sender_id != (SELECT rowid FROM Name2Id WHERE user_name = ?) THEN 1 ELSE 0 END) as received,
                SUM(CASE WHEN local_type IN (1, 244813135921) THEN 1 ELSE 0 END) as text,
                SUM(CASE WHEN local_type = 3 THEN 1 ELSE 0 END) as image,
                SUM(CASE WHEN local_type = 34 THEN 1 ELSE 0 END) as voice,
                SUM(CASE WHEN local_type = 43 THEN 1 ELSE 0 END) as video,
                SUM(CASE WHEN local_type NOT IN (1, 3, 34, 43, 244813135921) THEN 1 ELSE 0 END) as other,
                MIN(create_time) as first,
                MAX(create_time) as last
              FROM ${dbInfo.tableName}
            ''', [_currentAccountWxid ?? '', _currentAccountWxid ?? '']);

            final row = statResult.first;
            final dbTotal = (row['total'] as int?) ?? 0;
            totalCount += dbTotal;
            sentCount += (row['sent'] as int?) ?? 0;
            receivedCount += (row['received'] as int?) ?? 0;
            textCount += (row['text'] as int?) ?? 0;
            imageCount += (row['image'] as int?) ?? 0;
            voiceCount += (row['voice'] as int?) ?? 0;
            videoCount += (row['video'] as int?) ?? 0;
            otherCount += (row['other'] as int?) ?? 0;

            final dbFirst = row['first'] as int?;
            final dbLast = row['last'] as int?;
            if (dbFirst != null && (firstTime == null || dbFirst < firstTime)) {
              firstTime = dbFirst;
            }
            if (dbLast != null && (lastTime == null || dbLast > lastTime)) {
              lastTime = dbLast;
            }

            await logger.debug('DatabaseService', '  表 ${dbInfo.tableName}: 消息数=$dbTotal, 首条=${dbFirst != null ? DateTime.fromMillisecondsSinceEpoch(dbFirst * 1000) : null}, 末条=${dbLast != null ? DateTime.fromMillisecondsSinceEpoch(dbLast * 1000) : null}');

            // 获取日期列表
            final dateResult = await dbInfo.database.rawQuery('''
              SELECT DISTINCT DATE(create_time, 'unixepoch', 'localtime') as date
              FROM ${dbInfo.tableName}
            ''');

            final beforeDateCount = datesSet.length;
            for (final dateRow in dateResult) {
              final dateValue = dateRow['date'];
              if (dateValue != null) {
                final date = dateValue as String;
                datesSet.add(date);
              }
            }
            final addedDates = datesSet.length - beforeDateCount;
            await logger.debug('DatabaseService', '  表 ${dbInfo.tableName}: 查询到 ${dateResult.length} 个日期，新增 $addedDates 个唯一日期（总计: ${datesSet.length}）');

            // 如果日期数为0但有消息，记录详细信息
            if (dateResult.isEmpty && dbTotal > 0) {
              await logger.warning('DatabaseService', '  警告：表 ${dbInfo.tableName} 有 $dbTotal 条消息但日期查询为空！');
              // 尝试直接查询一条消息看看时间戳
              final sampleResult = await dbInfo.database.rawQuery('''
                SELECT create_time, DATE(create_time, 'unixepoch', 'localtime') as date
                FROM ${dbInfo.tableName}
                LIMIT 1
              ''');
              if (sampleResult.isNotEmpty) {
                await logger.debug('DatabaseService', '  样本消息: create_time=${sampleResult.first['create_time']}, date=${sampleResult.first['date']}');
              }
            }
          } catch (e, stackTrace) {
            await logger.warning('DatabaseService', '  查询表 ${dbInfo.tableName} 失败: $e\n$stackTrace');
          }
        }

        processedCount++;

        result[sessionId] = {
          'total': totalCount,
          'sent': sentCount,
          'received': receivedCount,
          'text': textCount,
          'image': imageCount,
          'voice': voiceCount,
          'video': videoCount,
          'other': otherCount,
          'first': firstTime,
          'last': lastTime,
          'activeDays': datesSet.length,
        };

        await logger.debug('DatabaseService', '会话 $sessionId 统计完成: 总消息=$totalCount, 活跃天数=${datesSet.length}, 首条=${firstTime != null ? DateTime.fromMillisecondsSinceEpoch(firstTime * 1000) : null}');

        // 如果活跃天数为0但有消息，记录警告
        if (datesSet.isEmpty && totalCount > 0) {
          await logger.warning('DatabaseService', '警告：会话 $sessionId 有 $totalCount 条消息但活跃天数为0！');
        }

        // 每处理50个会话记录一次
        if (processedCount % 50 == 0) {
          await logger.debug('DatabaseService', '已处理 $processedCount/${sessionIds.length} 个会话（空会话: $emptySessionCount, 错误: $errorSessionCount）');
        }
      } catch (e, stackTrace) {
        // 该会话查询失败，跳过
        errorSessionCount++;
        await logger.warning('DatabaseService', '会话 $sessionId 查询失败: $e\n$stackTrace');
      }
    }

    await logger.info('DatabaseService', '批量查询完成: 成功=${result.length}, 空会话=$emptySessionCount, 错误=$errorSessionCount');
    await logger.debug('DatabaseService', '========== 批量获取会话统计完成 ==========');

    return result;
  }

  /// 获取会话的时间分布数据
  Future<Map<String, dynamic>> getSessionTimeDistribution(String sessionId) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      final hourlyDistribution = <int, int>{};
      final weekdayDistribution = <int, int>{};
      final monthlyDistribution = <String, int>{};
      
      // 初始化小时分布 (0-23)
      for (int i = 0; i < 24; i++) {
        hourlyDistribution[i] = 0;
      }
      
      // 初始化星期分布 (1-7)
      for (int i = 1; i <= 7; i++) {
        weekdayDistribution[i] = 0;
      }
      
      // 从所有数据库查询并累加
      for (final dbInfo in dbInfos) {
        try {
          // 小时分布
          final hourlyResult = await dbInfo.database.rawQuery('''
            SELECT 
              CAST(strftime('%H', create_time, 'unixepoch', 'localtime') AS INTEGER) as hour,
              COUNT(*) as count
            FROM ${dbInfo.tableName}
            GROUP BY hour
          ''');
          
          for (final row in hourlyResult) {
            final hour = row['hour'] as int;
            final count = row['count'] as int;
            hourlyDistribution[hour] = (hourlyDistribution[hour] ?? 0) + count;
          }
          
          // 星期分布 (strftime('%w') 返回 0-6，0是星期日)
          final weekdayResult = await dbInfo.database.rawQuery('''
            SELECT 
              CASE CAST(strftime('%w', create_time, 'unixepoch', 'localtime') AS INTEGER)
                WHEN 0 THEN 7
                ELSE CAST(strftime('%w', create_time, 'unixepoch', 'localtime') AS INTEGER)
              END as weekday,
              COUNT(*) as count
            FROM ${dbInfo.tableName}
            GROUP BY weekday
          ''');
          
          for (final row in weekdayResult) {
            final weekday = row['weekday'] as int;
            final count = row['count'] as int;
            weekdayDistribution[weekday] = (weekdayDistribution[weekday] ?? 0) + count;
          }
          
          // 月份分布
          final monthlyResult = await dbInfo.database.rawQuery('''
            SELECT 
              strftime('%Y-%m', create_time, 'unixepoch', 'localtime') as month,
              COUNT(*) as count
            FROM ${dbInfo.tableName}
            GROUP BY month
          ''');
          
          for (final row in monthlyResult) {
            final month = row['month'] as String;
            final count = row['count'] as int;
            monthlyDistribution[month] = (monthlyDistribution[month] ?? 0) + count;
          }
        } catch (e) {
          // 忽略错误
        }
      }
      
      return {
        'hourly': hourlyDistribution,
        'weekday': weekdayDistribution,
        'monthly': monthlyDistribution,
      };
    } catch (e) {
      return {
        'hourly': <int, int>{},
        'weekday': <int, int>{},
        'monthly': <String, int>{},
      };
    }
  }

  /// 关闭数据库连接
  Future<void> close() async {
    await logger.info('DatabaseService', '开始关闭数据库连接...');

    // 先清理缓存的数据库连接
    await clearDatabaseCache();
    await logger.info('DatabaseService', '已清理缓存的数据库连接');

    // 如果是实时模式，需要清理VFS资源
    if (_mode == DatabaseMode.realtime && _sessionDbPath != null && _sessionDb != null) {
      try {
        await logger.info('DatabaseService', '关闭实时加密数据库: $_sessionDbPath');
        await WeChatVFSNative.closeEncryptedDatabase(_sessionDb!, _sessionDbPath!);
        await logger.info('DatabaseService', '实时加密数据库已关闭');
      } catch (e) {
        await logger.warning('DatabaseService', '关闭实时加密数据库时出错（可忽略）', e);
      }
      _sessionDb = null;
    } else if (_sessionDb != null) {
      try {
        await logger.info('DatabaseService', '关闭会话数据库: $_sessionDbPath');
        await _sessionDb!.close();
        await logger.info('DatabaseService', '会话数据库已关闭');
      } catch (e) {
        await logger.warning('DatabaseService', '关闭会话数据库时出错（可忽略）', e);
      }
      _sessionDb = null;
    }

    if (_messageDb != null) {
      try {
        await logger.info('DatabaseService', '关闭消息数据库: $_messageDbPath');
        await _messageDb!.close();
        await logger.info('DatabaseService', '消息数据库已关闭');
      } catch (e) {
        await logger.warning('DatabaseService', '关闭消息数据库时出错（可忽略）', e);
      }
      _messageDb = null;
    }

    // 等待更长时间，确保 sqflite_ffi 的后台 Isolate 完全释放文件句柄
    // Windows 系统需要更长的时间来释放文件句柄
    await logger.info('DatabaseService', '等待文件句柄释放...');
    await Future.delayed(const Duration(milliseconds: 500));
    await logger.info('DatabaseService', '数据库连接已完全关闭');
  }

  /// 检查数据库是否已连接
  bool get isConnected => _sessionDb != null;

  /// 当前账户 wxid
  String? get currentAccountWxid => _currentAccountWxid;

  /// 当前数据路径（从session数据库路径推导）
  String? get currentDataPath {
    if (_sessionDbPath == null) return null;
    // 获取数据库文件所在目录
    final lastSeparator = _sessionDbPath!.lastIndexOf(Platform.pathSeparator);
    if (lastSeparator == -1) return null;
    return _sessionDbPath!.substring(0, lastSeparator);
  }

  /// 批量获取联系人显示名称（remark > nick_name > username）
  Future<Map<String, String>> getDisplayNames(List<String> usernames) async {
    if (_sessionDb == null || usernames.isEmpty) {
      return {};
    }

    try {
      final contactDbPath = _sessionDbPath?.replaceAll('session.db', 'contact.db');
      if (contactDbPath == null || !await File(contactDbPath).exists()) {
        return {};
      }

      final contactDb = await _currentFactory.openDatabase(contactDbPath);
      
      try {
        final result = <String, String>{};
        final placeholders = List.filled(usernames.length, '?').join(',');
        
        // 1. 先从 contact 表查询
        try {
          var rows = await contactDb.rawQuery('''
            SELECT username, remark, nick_name 
            FROM contact 
            WHERE username IN ($placeholders)
          ''', usernames);

          for (final row in rows) {
            final username = row['username'] as String;
            final remark = row['remark'] as String?;
            final nickName = row['nick_name'] as String?;
            final displayName = remark?.isNotEmpty == true 
                ? remark! 
                : (nickName?.isNotEmpty == true ? nickName! : username);
            result[username] = displayName;
          }
        } catch (e) {
        }

        // 2. 对于没找到的，从 stranger 表查询
        var notFoundUsernames = usernames.where((u) => !result.containsKey(u)).toList();
        if (notFoundUsernames.isNotEmpty) {
          try {
            final strangerPlaceholders = List.filled(notFoundUsernames.length, '?').join(',');
            final strangerRows = await contactDb.rawQuery('''
              SELECT username, remark, nick_name 
              FROM stranger 
              WHERE username IN ($strangerPlaceholders)
            ''', notFoundUsernames);

            for (final row in strangerRows) {
              final username = row['username'] as String;
              final remark = row['remark'] as String?;
              final nickName = row['nick_name'] as String?;
              final displayName = remark?.isNotEmpty == true 
                  ? remark! 
                  : (nickName?.isNotEmpty == true ? nickName! : username);
              result[username] = displayName;
            }
          } catch (e) {
          }
        }

        // 3. 对于仍然没找到的群聊，尝试模糊匹配
        notFoundUsernames = usernames.where((u) => !result.containsKey(u)).toList();
        if (notFoundUsernames.isNotEmpty) {
          final chatroomUsernames = notFoundUsernames.where((u) => u.contains('@chatroom')).toList();
          
          for (final username in chatroomUsernames) {
            try {
              final chatroomId = username.split('@').first;
              final rows = await contactDb.rawQuery(
                'SELECT username, remark, nick_name FROM contact WHERE username LIKE ? LIMIT 1',
                ['%$chatroomId%']
              );
              
              if (rows.isNotEmpty) {
                final row = rows.first;
                final remark = row['remark'] as String?;
                final nickName = row['nick_name'] as String?;
                
                String displayName;
                if (remark?.isNotEmpty == true) {
                  displayName = remark!;
                } else if (nickName?.isNotEmpty == true) {
                  displayName = nickName!;
                } else {
                  // 群聊没有名称，使用成员列表生成（仿微信）
                  displayName = await _getChatroomDisplayName(username, contactDb);
                }
                
                result[username] = displayName;
                
              }
            } catch (e) {
              // 忽略单个查询错误
            }
          }
        }
        
        // 4. 对于还是没找到的，尝试从 Name2Id 表查询（消息数据库中）
        notFoundUsernames = usernames.where((u) => !result.containsKey(u)).toList();
        if (notFoundUsernames.isNotEmpty) {
          try {
            final Database dbForMsg = await _getDbForMessages();
            for (final username in notFoundUsernames) {
              try {
                final rows = await dbForMsg.rawQuery(
                  'SELECT user_name FROM Name2Id WHERE user_name LIKE ? LIMIT 1',
                  ['%$username%']
                );
                if (rows.isNotEmpty) {
                  final foundName = rows.first['user_name'] as String?;
                  if (foundName != null) {
                    // 使用找到的名称（可能包含更完整的信息）
                    result[username] = foundName;
                  }
                }
              } catch (e) {
                // 忽略单个查询错误
              }
            }
          } catch (e) {
          }
        }

        if (kDebugMode && result.length < usernames.length) {
          // 部分用户未找到显示名
        }

        return result;
      } finally {
        try {
          await contactDb.close();
        } catch (e) {
          // 忽略关闭错误
        }
      }
    } catch (e) {
      return {};
    }
  }

  /// 获取数据库中所有表名（调试用）
  Future<List<String>> getAllTableNames() async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final tables = await _sessionDb!.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
      );
      
      return tables.map((t) => t['name'] as String).toList();
    } catch (e) {
      throw Exception('获取表列表失败: $e');
    }
  }

  /// 诊断会话-消息表映射关系
  Future<Map<String, dynamic>> diagnoseSessionMessageMapping(String sessionId) async {
    final result = <String, dynamic>{
      'sessionId': sessionId,
      'md5': _md5(sessionId),
      'expectedTableName': 'Msg_${_md5(sessionId)}',
      'foundInDatabases': <Map<String, dynamic>>[],
      'name2IdExists': false,
      'allMessageTables': <String>[],
    };

    try {
      final allMessageDbs = await _findAllMessageDbs();
      
      for (final dbPath in allMessageDbs) {
        try {
          final tempDb = await _currentFactory.openDatabase(
            dbPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          
          try {
            // 检查 Name2Id
            final name2IdRows = await tempDb.rawQuery(
              'SELECT rowid FROM Name2Id WHERE user_name = ? LIMIT 1',
              [sessionId]
            );
            
            if (name2IdRows.isNotEmpty) {
              result['name2IdExists'] = true;
              result['name2IdRowId'] = name2IdRows.first['rowid'];
            }
            
            // 获取所有消息表
            final tables = await tempDb.rawQuery(
              "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
            );
            
            final tableNames = tables.map((t) => t['name'] as String).toList();
            (result['allMessageTables'] as List<String>).addAll(tableNames);
            
            // 查找匹配的表
            final foundTableName = await _getMessageTableName(sessionId, tempDb);
            if (foundTableName != null) {
              (result['foundInDatabases'] as List<Map<String, dynamic>>).add({
                'database': dbPath,
                'tableName': foundTableName,
              });
            }
          } finally {
            await tempDb.close();
          }
        } catch (e) {
          // 检查数据库出错
        }
      }
    } catch (e) {
      result['error'] = e.toString();
    }

    return result;
  }

  /// 从联系人表获取会话信息
  Future<List<ChatSession>> _getSessionsFromContactTable(List<String> tableNames) async {
    final db = _currentDb;
    try {
      String contactTableName = 'contact';
      if (tableNames.contains('Contact')) {
        contactTableName = 'Contact';
      }
      
      final List<Map<String, dynamic>> maps = await db!.query(
        contactTableName,
        columns: ['username', 'nick_name', 'remark', 'big_head_url'],
        where: 'local_type = ?',
        whereArgs: [1], // 只获取好友联系人
      );

      return maps.map((map) {
        return ChatSession(
          username: map['username'] as String? ?? '',
          type: 0, // 私聊
          unreadCount: 0,
          unreadFirstMsgSrvId: 0,
          isHidden: 0,
          summary: '暂无消息',
          draft: '',
          status: 0,
          lastTimestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          sortTimestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          lastClearUnreadTimestamp: 0,
          lastMsgLocalId: 0,
          lastMsgType: 1, // 文本消息
          lastMsgSubType: 0,
          lastMsgSender: '',
          lastSenderDisplayName: map['remark'] as String? ?? map['nick_name'] as String? ?? '未知联系人',
        );
      }).toList();
    } catch (e) {
      throw Exception('从联系人表获取会话失败: $e');
    }
  }

  /// 从FMessageTable获取会话信息
  Future<List<ChatSession>> _getSessionsFromFMessageTable() async {
    final db = _currentDb;
    try {
      final List<Map<String, dynamic>> maps = await db!.query(
        'FMessageTable',
        columns: ['user_name_', 'content_', 'timestamp_'],
        orderBy: 'timestamp_ DESC',
      );

      // 按用户名分组，获取每个联系人的最新消息
      final Map<String, Map<String, dynamic>> userMessages = {};
      for (final map in maps) {
        final userName = map['user_name_'] as String? ?? '';
        if (userName.isNotEmpty && !userMessages.containsKey(userName)) {
          userMessages[userName] = map;
        }
      }

      return userMessages.values.map((map) {
        final timestamp = map['timestamp_'] as int? ?? 0;
        return ChatSession(
          username: map['user_name_'] as String? ?? '',
          type: 0, // 私聊
          unreadCount: 0,
          unreadFirstMsgSrvId: 0,
          isHidden: 0,
          summary: map['content_'] as String? ?? '暂无消息',
          draft: '',
          status: 0,
          lastTimestamp: timestamp,
          sortTimestamp: timestamp,
          lastClearUnreadTimestamp: 0,
          lastMsgLocalId: 0,
          lastMsgType: 1, // 文本消息
          lastMsgSubType: 0,
          lastMsgSender: '',
          lastSenderDisplayName: map['user_name_'] as String? ?? '未知联系人',
        );
      }).toList();
    } catch (e) {
      throw Exception('从FMessageTable获取会话失败: $e');
    }
  }

  /// 获取群聊显示名称（仿微信逻辑）
  Future<String> _getChatroomDisplayName(String chatroomId, Database contactDb) async {
    try {
      // 1. 查询群聊成员
      final memberRows = await contactDb.rawQuery('''
        SELECT member_id FROM chatroom_member 
        WHERE room_id = (SELECT rowid FROM name2id WHERE username = ?) 
        LIMIT 3
      ''', [chatroomId]);
      
      if (memberRows.isEmpty) {
        return chatroomId; // 没有成员信息，返回原ID
      }
      
      // 2. 获取总成员数
      final countRows = await contactDb.rawQuery('''
        SELECT COUNT(*) as total FROM chatroom_member 
        WHERE room_id = (SELECT rowid FROM name2id WHERE username = ?)
      ''', [chatroomId]);
      final totalCount = countRows.first['total'] as int? ?? memberRows.length;
      
      // 3. 查询成员显示名称
      final memberNames = <String>[];
      for (final row in memberRows) {
        final memberId = row['member_id'] as int?;
        if (memberId == null) continue;
        
        // 从 name2id 获取 username
        final usernameRows = await contactDb.rawQuery(
          'SELECT username FROM name2id WHERE rowid = ?', 
          [memberId]
        );
        
        if (usernameRows.isNotEmpty) {
          final username = usernameRows.first['username'] as String?;
          if (username != null) {
            // 查询显示名称
            var displayName = username;
            
            // 先从 contact 查
            final contactRows = await contactDb.rawQuery(
              'SELECT remark, nick_name FROM contact WHERE username = ?',
              [username]
            );
            
            if (contactRows.isNotEmpty) {
              final remark = contactRows.first['remark'] as String?;
              final nickName = contactRows.first['nick_name'] as String?;
              displayName = remark?.isNotEmpty == true ? remark! : 
                           (nickName?.isNotEmpty == true ? nickName! : username);
            } else {
              // 再从 stranger 查
              final strangerRows = await contactDb.rawQuery(
                'SELECT remark, nick_name FROM stranger WHERE username = ?',
                [username]
              );
              if (strangerRows.isNotEmpty) {
                final remark = strangerRows.first['remark'] as String?;
                final nickName = strangerRows.first['nick_name'] as String?;
                displayName = remark?.isNotEmpty == true ? remark! : 
                             (nickName?.isNotEmpty == true ? nickName! : username);
              }
            }
            
            memberNames.add(displayName);
          }
        }
      }
      
      // 4. 格式化显示名称
      if (memberNames.isEmpty) {
        return chatroomId;
      }
      
      final displayName = memberNames.join('、');
      return totalCount > memberNames.length ? '$displayName($totalCount)' : displayName;
      
    } catch (e) {
      return chatroomId;
    }
  }

  /// 使用联系人信息丰富会话列表
  Future<void> _enrichSessionsWithContactInfo(List<ChatSession> sessions) async {
    try {
      await logger.info('DatabaseService', '开始从contact数据库加载联系人信息，会话数量: ${sessions.length}');
      
      // 尝试连接 contact 数据库（带重试机制）
      final contactDbPath = await _findContactDatabase(retryCount: 3, retryDelayMs: 500);
      if (contactDbPath == null) {
        await logger.warning('DatabaseService', '无法找到contact数据库，会话将显示原始用户名');
        return;
      }

      await logger.info('DatabaseService', '正在打开contact数据库: $contactDbPath');
      
      // 临时连接 contact 数据库
      final contactDb = await _currentFactory.openDatabase(
        contactDbPath,
        options: OpenDatabaseOptions(
          readOnly: true,
          singleInstance: false,
        ),
      );

      try {
        // 获取 contact 数据库的表结构
        final tables = await contactDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        );
        
        // 为每个会话查找对应的联系人信息
        for (final session in sessions) {
          try {
            // 尝试多个可能的表名
            List<Map<String, dynamic>> contactMaps = [];
            
            // 首先尝试 'contact' 表（包括精确匹配和模糊匹配）
            try {
              // 1. 精确匹配
              contactMaps = await contactDb.query(
                'contact',
                where: 'username = ?',
                whereArgs: [session.username],
                limit: 1,
              );
              
              // 2. 如果是群聊且精确匹配失败，尝试模糊匹配
              if (contactMaps.isEmpty && session.username.contains('@chatroom')) {
                // 提取群聊ID部分（去掉@chatroom）
                final chatroomId = session.username.split('@').first;
                contactMaps = await contactDb.rawQuery(
                  'SELECT * FROM contact WHERE username LIKE ? LIMIT 1',
                  ['%$chatroomId%']
                );
                if (contactMaps.isNotEmpty && kDebugMode) {
                  // 模糊匹配找到群聊
                }
              }
            } catch (e) {
              // contact 表查询失败
            }
            
            // 如果 contact 表找不到，尝试 stranger 表
            if (contactMaps.isEmpty) {
              try {
                contactMaps = await contactDb.query(
                  'stranger',
                  where: 'username = ?',
                  whereArgs: [session.username],
                  limit: 1,
                );
              } catch (e) {
                // stranger 表查询失败
              }
            }
            
            // 如果还是找不到，尝试其他包含 'contact' 的表
            if (contactMaps.isEmpty) {
              for (final table in tables) {
                final tableName = table['name'] as String;
                if (tableName.toLowerCase().contains('contact') && 
                    tableName != 'contact' && 
                    tableName != 'stranger') {
                  try {
                    contactMaps = await contactDb.query(
                      tableName,
                      where: 'username = ?',
                      whereArgs: [session.username],
                      limit: 1,
                    );
                    if (contactMaps.isNotEmpty) {
                      break;
                    }
                  } catch (e) {
                    // 继续尝试下一个表
                  }
                }
              }
            }

            if (contactMaps.isNotEmpty) {
              final contact = contactMaps.first;
              
              // 检查联系人类型，过滤掉公众号、服务号等
              final localType = contact['local_type'] as int? ?? 0;
              final username = contact['username'] as String? ?? session.username;
              
              // 过滤条件：只显示正常联系人和群聊
              bool shouldShow = false;
              if (username.contains('@chatroom')) {
                // 群聊
                shouldShow = true;
              } else if (localType == 0 || localType == 1) {
                // 正常联系人 (0=好友, 1=可能是好友)
                shouldShow = true;
              } else if (username.startsWith('wxid_') && !username.contains('@')) {
                // 普通微信用户
                shouldShow = true;
              }
              
              if (shouldShow) {
                // 优先显示备注，没有备注时显示昵称
                String displayName = '';
                final remark = contact['remark'] as String?;
                final nickName = contact['nick_name'] as String?;
                
                if (remark != null && remark.isNotEmpty && remark.trim().isNotEmpty) {
                  displayName = remark.trim();
                } else if (nickName != null && nickName.isNotEmpty && nickName.trim().isNotEmpty) {
                  displayName = nickName.trim();
                } else if (username.contains('@chatroom')) {
                  // 群聊没有名称，使用成员列表生成（仿微信）
                  displayName = await _getChatroomDisplayName(session.username, contactDb);
                } else {
                  displayName = session.username;
                }
                
                // 清理显示名称中的无效字符
                displayName = _cleanDisplayName(displayName);
                
                // 更新会话的显示名称
                session.displayName = displayName;
              }
            }
          } catch (e) {
            // 查找联系人失败
          }
        }
        
        await logger.info('DatabaseService', '成功加载联系人信息，已更新${sessions.where((s) => s.displayName != null && s.displayName!.isNotEmpty).length}个会话的显示名称');
      } finally {
        await contactDb.close();
      }
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '从contact数据库加载联系人信息失败', e, stackTrace);
    }
  }

  /// 清理显示名称中的无效字符
  String _cleanDisplayName(String name) {
    if (name.isEmpty) return name;
    
    try {
      // 移除控制字符和无效字符
      String cleaned = name.replaceAll(RegExp(r'[\x00-\x08\x0B-\x0C\x0E-\x1F\x7F-\x9F]'), '');
      
      // 处理可能的孤立代理对（UTF-16编码问题）
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
      // 如果清理失败，返回一个安全的替代字符串
      return name.replaceAll(RegExp(r'[^\u0020-\u007E\u4E00-\u9FFF\u3000-\u303F]'), '');
    }
  }

  /// 查找 contact 数据库文件（带重试机制）
  Future<String?> _findContactDatabase({int retryCount = 3, int retryDelayMs = 500}) async {
    for (int attempt = 0; attempt < retryCount; attempt++) {
      try {
        final documentsDir = await getApplicationDocumentsDirectory();
        final echoTraceDir = Directory('${documentsDir.path}${Platform.pathSeparator}EchoTrace');
        
        if (!await echoTraceDir.exists()) {
          if (attempt == 0) {
            await logger.warning('DatabaseService', 'EchoTrace目录不存在: ${echoTraceDir.path}');
          }
          if (attempt < retryCount - 1) {
            await Future.delayed(Duration(milliseconds: retryDelayMs));
            continue;
          }
          return null;
        }
        
        // 扫描所有账号目录（不限制必须以 wxid_ 开头）
        final accountDirs = await echoTraceDir.list().where((entity) {
          return entity is Directory;
        }).toList();
        
        if (accountDirs.isEmpty) {
          if (attempt == 0) {
            await logger.warning('DatabaseService', '未找到任何账号目录');
          }
          if (attempt < retryCount - 1) {
            await Future.delayed(Duration(milliseconds: retryDelayMs));
            continue;
          }
          return null;
        }
        
        for (final accountDir in accountDirs) {
          final contactDbPath = '${accountDir.path}${Platform.pathSeparator}contact.db';
          final contactDbFile = File(contactDbPath);

          if (await contactDbFile.exists()) {
            await logger.info('DatabaseService', '找到contact数据库: $contactDbPath');
            return contactDbPath;
          }
        }
        
        if (attempt == 0) {
          await logger.warning('DatabaseService', '在所有账号目录中都未找到contact.db');
        }
        
        if (attempt < retryCount - 1) {
          await logger.info('DatabaseService', '将在${retryDelayMs}ms后重试查找contact.db（第${attempt + 1}次尝试失败）');
          await Future.delayed(Duration(milliseconds: retryDelayMs));
        }
      } catch (e, stackTrace) {
        await logger.error('DatabaseService', '查找contact数据库失败（尝试${attempt + 1}/$retryCount）', e, stackTrace);
        if (attempt < retryCount - 1) {
          await Future.delayed(Duration(milliseconds: retryDelayMs));
        }
      }
    }
    
    await logger.warning('DatabaseService', '经过$retryCount次尝试，仍未找到contact数据库');
    return null;
  }

  /// 获取用于消息查询的数据库
  Future<dynamic> _getDbForMessages() async {
    final db = _currentDb;
    // 如果会话库本身就包含消息表，直接使用
    if (await _hasMsgTables(db)) {
      _messageDbPath = _sessionDbPath; // 使用会话库路径
      return db;
    }


    // 懒加载消息库（仅解密模式）
    if (_messageDb != null) return _messageDb!;

    final messageDbPath = await _locateMessageDbPathNearSession();
    if (messageDbPath == null) {
      throw Exception('未找到消息数据库');
    }
    _messageDbPath = messageDbPath; // 保存消息库路径
    _messageDb = await _currentFactory.openDatabase(
      messageDbPath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    return _messageDb!;
  }

  Future<bool> _hasMsgTables(dynamic db) async {
    if (db == null) return false;
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'",
    );
    return tables.isNotEmpty;
  }

  /// 查找所有可用的消息数据库路径
  Future<List<String>> _findAllMessageDbs() async {
    final List<String> messageDbs = [];

    // 优先基于会话库所在 wxid 目录
    if (_sessionDbPath != null) {
      final wxidDir = _findWxidDirFromPath(_sessionDbPath!);
      if (wxidDir != null) {
        // 查找所有 message_[0-9].db 文件
        for (int i = 0; i < 10; i++) {
          final candidatePath = PathUtils.join(wxidDir.path, 'message_$i.db');
          final candidate = File(candidatePath);
          if (await candidate.exists()) {
            messageDbs.add(PathUtils.normalizeDatabasePath(candidate.path));
          }
        }

        if (messageDbs.isNotEmpty) {
          return messageDbs;
        }
      }
    }

    // 兜底：扫描 EchoTrace 目录
    final documentsDir = await getApplicationDocumentsDirectory();
    final echoTracePath = PathUtils.join(documentsDir.path, 'EchoTrace');
    final echoTraceDir = Directory(echoTracePath);
    if (!await echoTraceDir.exists()) return messageDbs;

    final wxidDirs = await echoTraceDir.list().where((e) => e is Directory).toList();
    for (final dir in wxidDirs) {
      for (int i = 0; i < 100; i++) {
        final messageDbPath = PathUtils.join(dir.path, 'message_$i.db');
        final messageDbFile = File(messageDbPath);
        if (await messageDbFile.exists()) {
          messageDbs.add(PathUtils.normalizeDatabasePath(messageDbFile.path));
        }
      }
    }

    return messageDbs;
  }

  Future<String?> _locateMessageDbPathNearSession() async {
    final allDbs = await _findAllMessageDbs();
    if (allDbs.isEmpty) return null;
    
    // 返回第一个
    return allDbs.first;
  }

  /// 清理账号目录名，去除微信自动添加的后缀
  String _cleanAccountDirName(String dirName) {
    // 如果是 wxid_ 开头，去除后面可能的 _数字 后缀
    if (dirName.startsWith('wxid_')) {
      // 匹配 wxid_ 开头，后面跟着字母数字但不包含下划线的部分
      final match = RegExp(r'wxid_[a-zA-Z0-9]+').firstMatch(dirName);
      if (match != null) {
        return match.group(0)!;
      }
    }
    // 非 wxid_ 格式的账号目录（新版微信），直接返回
    return dirName;
  }

  String? _extractWxidFromPath(String path) {
    final parts = path.split(Platform.pathSeparator);
    
    // 策略1: 从 EchoTrace 目录提取（解密后的路径）
    // 例如: Documents/EchoTrace/wxid_xxx_8602/session.db -> wxid_xxx
    //      Documents/EchoTrace/123/session.db -> 123
    final echoTraceIdx = parts.lastIndexWhere((p) => p == 'EchoTrace');
    if (echoTraceIdx != -1 && echoTraceIdx + 1 < parts.length) {
      return _cleanAccountDirName(parts[echoTraceIdx + 1]);
    }
    
    // 策略2: 从 db_storage 的父目录提取（原始微信数据库路径）
    // 例如: xwechat_files/wxid_xxx_8602/db_storage/session.db -> wxid_xxx
    //      xwechat_files/123/db_storage/session.db -> 123
    final dbStorageIdx = parts.lastIndexWhere((p) => p == 'db_storage');
    if (dbStorageIdx != -1 && dbStorageIdx > 0) {
      // db_storage 的父目录就是账号目录
      return _cleanAccountDirName(parts[dbStorageIdx - 1]);
    }
    
    // 策略3: 向后兼容，查找 wxid_ 开头的目录（旧版路径）
    final wxidIdx = parts.lastIndexWhere((p) => p.startsWith('wxid_'));
    if (wxidIdx != -1) {
      return _cleanAccountDirName(parts[wxidIdx]);
    }
    
    return null;
  }

  Directory? _findWxidDirFromPath(String path) {
    final parts = path.split(Platform.pathSeparator);
    
    // 策略1: 如果路径包含 EchoTrace，查找 EchoTrace 下的账号目录
    final echoTraceIdx = parts.lastIndexWhere((p) => p == 'EchoTrace');
    if (echoTraceIdx != -1 && echoTraceIdx + 1 < parts.length) {
      final accountDirPath = parts.sublist(0, echoTraceIdx + 2).join(Platform.pathSeparator);
      return Directory(accountDirPath);
    }
    
    // 策略2: 如果路径包含 db_storage，其父目录就是账号目录
    final dbStorageIdx = parts.lastIndexWhere((p) => p == 'db_storage');
    if (dbStorageIdx != -1 && dbStorageIdx > 0) {
      final accountDirPath = parts.sublist(0, dbStorageIdx).join(Platform.pathSeparator);
      return Directory(accountDirPath);
    }
    
    // 策略3: 向后兼容，检查父目录是否以 wxid_ 开头
    final dir = Directory(path).parent;
    if (dir.path.split(Platform.pathSeparator).last.startsWith('wxid_')) {
      return dir;
    }
    
    return null;
  }

  /// 清理缓存的数据库连接（可手动调用或自动触发）
  Future<void> clearDatabaseCache() async {
    for (final db in _cachedMessageDbs.values) {
      try {
        await db.close();
      } catch (e) {
        // 忽略关闭错误
      }
    }
    _cachedMessageDbs.clear();
    _cacheLastUsed = null;
  }

  /// 获取会话的详细信息（包括所在表、加好友时间等）
  Future<SessionDetailInfo> getSessionDetailInfo(String sessionId) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      await logger.info('DatabaseService', '获取会话详细信息: $sessionId');
      
      // 1. 获取联系人信息
      Contact? contactInfo;
      String displayName = sessionId;
      String? remark;
      String? nickName;
      String? alias;
      
      try {
        final contactDbPath = _sessionDbPath?.replaceAll('session.db', 'contact.db');
        if (contactDbPath != null && await File(contactDbPath).exists()) {
          final contactDb = await _currentFactory.openDatabase(
            contactDbPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          
          try {
            final contactMaps = await contactDb.query(
              'contact',
              where: 'username = ?',
              whereArgs: [sessionId],
              limit: 1,
            );
            
            if (contactMaps.isNotEmpty) {
              contactInfo = Contact.fromMap(contactMaps.first);
              displayName = contactInfo.displayName;
              remark = contactInfo.remark.isNotEmpty ? contactInfo.remark : null;
              nickName = contactInfo.nickName.isNotEmpty ? contactInfo.nickName : null;
              alias = contactInfo.alias.isNotEmpty ? contactInfo.alias : null;
            }
          } finally {
            await contactDb.close();
          }
        }
      } catch (e) {
        await logger.error('DatabaseService', '获取联系人信息失败', e);
      }
      
      // 2. 查找所有包含该会话消息的数据库和表
      final List<MessageTableLocation> messageTables = [];
      int totalMessageCount = 0;
      int? firstMessageTime;
      int? latestMessageTime;
      
      // 获取所有消息数据库
      final allMessageDbs = await _findAllMessageDbs();
      await logger.info('DatabaseService', '搜索 ${allMessageDbs.length} 个消息数据库');
      
      for (final dbPath in allMessageDbs) {
        try {
          final db = await _currentFactory.openDatabase(
            dbPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          
          try {
            final tableName = await _getMessageTableName(sessionId, db);
            
            if (tableName != null) {
              // 获取该表的消息数量
              final countResult = await db.rawQuery(
                'SELECT COUNT(*) as count FROM $tableName'
              );
              final count = (countResult.first['count'] as int?) ?? 0;
              
              if (count > 0) {
                totalMessageCount += count;
                
                // 获取第一条消息时间
                final firstMsgResult = await db.rawQuery(
                  'SELECT create_time FROM $tableName ORDER BY create_time ASC LIMIT 1'
                );
                if (firstMsgResult.isNotEmpty) {
                  final time = firstMsgResult.first['create_time'] as int?;
                  if (time != null) {
                    if (firstMessageTime == null || time < firstMessageTime) {
                      firstMessageTime = time;
                    }
                  }
                }
                
                // 获取最新消息时间
                final latestMsgResult = await db.rawQuery(
                  'SELECT create_time FROM $tableName ORDER BY create_time DESC LIMIT 1'
                );
                if (latestMsgResult.isNotEmpty) {
                  final time = latestMsgResult.first['create_time'] as int?;
                  if (time != null) {
                    if (latestMessageTime == null || time > latestMessageTime) {
                      latestMessageTime = time;
                    }
                  }
                }
                
                // 提取数据库名称（从路径中提取）
                final dbName = dbPath.split(Platform.pathSeparator).last;
                
                messageTables.add(MessageTableLocation(
                  databasePath: dbPath,
                  databaseName: dbName,
                  tableName: tableName,
                  messageCount: count,
                ));
                
                await logger.info('DatabaseService', '在 $dbName 中找到表 $tableName，消息数: $count');
              }
            }
          } finally {
            await db.close();
          }
        } catch (e) {
          await logger.error('DatabaseService', '处理消息数据库失败: $dbPath', e);
        }
      }
      
      return SessionDetailInfo(
        wxid: sessionId,
        displayName: displayName,
        remark: remark,
        nickName: nickName,
        alias: alias,
        messageTables: messageTables,
        firstMessageTime: firstMessageTime,
        latestMessageTime: latestMessageTime,
        messageCount: totalMessageCount,
        contactInfo: contactInfo,
      );
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '获取会话详细信息失败', e, stackTrace);
      rethrow;
    }
  }

  /// 获取或打开缓存的消息数据库连接
  Future<List<_CachedDatabaseInfo>> _getCachedMessageDatabases() async {
    // 检查缓存是否过期
    if (_cacheLastUsed != null && 
        DateTime.now().difference(_cacheLastUsed!) > _cacheDuration) {
      await clearDatabaseCache();
    }

    // 更新最后使用时间
    _cacheLastUsed = DateTime.now();

    // 如果缓存为空，打开所有数据库
    if (_cachedMessageDbs.isEmpty) {
      final allMessageDbPaths = await _findAllMessageDbs();
      
      // 获取所有唯一的数据库路径（去重）
      final uniquePaths = allMessageDbPaths.toSet().toList();
      
      // 打开所有消息数据库
      for (int i = 0; i < uniquePaths.length; i++) {
        final dbPath = uniquePaths[i];
        try {
          final normalizedDbPath = PathUtils.normalizeDatabasePath(dbPath);
          final db = await _currentFactory.openDatabase(
            normalizedDbPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          _cachedMessageDbs[normalizedDbPath] = db;
        } catch (e) {
          // 忽略打开失败的数据库
        }
      }
      
      // 如果没有打开任何数据库，添加当前数据库作为后备
      if (_cachedMessageDbs.isEmpty) {
        try {
          final currentDb = await _getDbForMessages();
          _cachedMessageDbs['_current'] = currentDb;
        } catch (e) {
          // 忽略错误
        }
      }
    }

    // 构建缓存信息列表
    final result = <_CachedDatabaseInfo>[];
    for (final entry in _cachedMessageDbs.entries) {
      result.add(_CachedDatabaseInfo(
        database: entry.value,
        key: entry.key,
      ));
    }
    
    return result;
  }

  /// 通用的跨数据库查询辅助方法
  Future<List<_DatabaseTableInfo>> _collectTableInfosAcrossDatabases(
    String sessionId, 
    {bool includeLatestTimestamp = false}
  ) async {
    final result = <_DatabaseTableInfo>[];
    final cachedDbs = await _getCachedMessageDatabases();

    for (final dbInfo in cachedDbs) {
      try {
        final tableName = await _getMessageTableName(
          sessionId, 
          dbInfo.database,
        );
        
        if (tableName != null) {
          int latestTimestamp = 0;
          if (includeLatestTimestamp) {
            try {
              final timeResult = await dbInfo.database.rawQuery(
                'SELECT MAX(create_time) as max_time FROM $tableName'
              );
              latestTimestamp = (timeResult.first['max_time'] as int?) ?? 0;
            } catch (e) {
              // 忽略错误
            }
          }
          
          result.add(_DatabaseTableInfo(
            database: dbInfo.database,
            tableName: tableName,
            latestTimestamp: latestTimestamp,
            needsClose: false,
          ));
        }
      } catch (e) {
        // 忽略错误，继续下一个数据库
      }
    }

    return result;
  }

  /// 获取活动热力图数据（24小时×7天）
  Future<Map<int, Map<int, int>>> getActivityHeatmapData({
    int? year,
    List<String>? sessionIds,
  }) async {
    if (!isConnected) {
      throw Exception('数据库未连接');
    }

    // 初始化数据结构
    final data = <int, Map<int, int>>{};
    for (int hour = 0; hour < 24; hour++) {
      data[hour] = {};
      for (int weekday = 1; weekday <= 7; weekday++) {
        data[hour]![weekday] = 0;
      }
    }

    try {
      final cachedDbs = await _getCachedMessageDatabases();

      for (final cachedDb in cachedDbs) {
        try {
          // 查找所有消息表
          final tables = await cachedDb.database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'",
          );

          for (final tableRow in tables) {
            final tableName = tableRow['name'] as String;

            // 如果指定了sessionIds，只查询这些会话
            String whereClause = '';
            if (sessionIds != null && sessionIds.isNotEmpty) {
              // 从表名提取MD5，与sessionIds比对（需要逆向查找）
              // 这里简化处理，查询所有然后过滤
            }

            // 构建年份过滤条件
            if (year != null) {
              final startTime = DateTime(year, 1, 1).millisecondsSinceEpoch ~/ 1000;
              final endTime = DateTime(year + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
              whereClause = 'WHERE create_time >= $startTime AND create_time < $endTime';
            }

            // 单次SQL查询获取所有时段统计
            final result = await cachedDb.database.rawQuery('''
              SELECT 
                CAST(strftime('%H', create_time, 'unixepoch', 'localtime') AS INTEGER) as hour,
                CASE CAST(strftime('%w', create_time, 'unixepoch', 'localtime') AS INTEGER) 
                  WHEN 0 THEN 7 
                  ELSE CAST(strftime('%w', create_time, 'unixepoch', 'localtime') AS INTEGER) 
                END as weekday,
                COUNT(*) as count
              FROM $tableName
              $whereClause
              GROUP BY hour, weekday
            ''');

            for (final row in result) {
              final hour = row['hour'] as int;
              final weekday = row['weekday'] as int;
              final count = row['count'] as int;
              data[hour]![weekday] = (data[hour]![weekday] ?? 0) + count;
            }
          }
        } catch (e) {
          // 忽略单个数据库的错误
        }
      }
    } catch (e) {
      await logger.error('DatabaseService', '获取活动热力图数据失败', e);
      rethrow;
    }

    return data;
  }

  /// 获取最频繁联系人数据
  Future<List<Map<String, dynamic>>> getTopContactsData({
    required int limit,
    int? year,
  }) async {
    if (!isConnected) {
      throw Exception('数据库未连接');
    }

    final contactStats = <String, Map<String, dynamic>>{};

    try {
      final cachedDbs = await _getCachedMessageDatabases();

      for (final cachedDb in cachedDbs) {
        try {
          final tables = await cachedDb.database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'",
          );

          for (final tableRow in tables) {
            final tableName = tableRow['name'] as String;

            // 构建年份过滤条件
            String whereClause = '';
            if (year != null) {
              final startTime = DateTime(year, 1, 1).millisecondsSinceEpoch ~/ 1000;
              final endTime = DateTime(year + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
              whereClause = 'WHERE create_time >= $startTime AND create_time < $endTime';
            }

            // 获取该表的统计数据
            final result = await cachedDb.database.rawQuery('''
              SELECT 
                COUNT(*) as total,
                SUM(CASE WHEN real_sender_id = (SELECT rowid FROM Name2Id WHERE user_name = ?) THEN 1 ELSE 0 END) as sent,
                SUM(CASE WHEN real_sender_id != (SELECT rowid FROM Name2Id WHERE user_name = ?) THEN 1 ELSE 0 END) as received,
                MAX(create_time) as last_time
              FROM $tableName
              $whereClause
            ''', [_currentAccountWxid ?? '', _currentAccountWxid ?? '']);

            if (result.isNotEmpty && result[0]['total'] != null) {
              final total = result[0]['total'] as int;
              if (total > 0) {
                // 从表名提取会话ID（需要反查Name2Id表）
                // 这里简化处理，直接使用表名
                final sessionId = tableName; // 临时使用表名，实际需要反查

                if (!contactStats.containsKey(sessionId)) {
                  contactStats[sessionId] = {
                    'sessionId': sessionId,
                    'total': 0,
                    'sent': 0,
                    'received': 0,
                    'lastTime': 0,
                  };
                }

                contactStats[sessionId]!['total'] = (contactStats[sessionId]!['total'] as int) + total;
                contactStats[sessionId]!['sent'] = (contactStats[sessionId]!['sent'] as int) + (result[0]['sent'] as int? ?? 0);
                contactStats[sessionId]!['received'] = (contactStats[sessionId]!['received'] as int) + (result[0]['received'] as int? ?? 0);
                
                final lastTime = result[0]['last_time'] as int? ?? 0;
                if (lastTime > (contactStats[sessionId]!['lastTime'] as int)) {
                  contactStats[sessionId]!['lastTime'] = lastTime;
                }
              }
            }
          }
        } catch (e) {
          // 忽略单个数据库的错误
        }
      }

      // 排序并返回top N
      final sortedContacts = contactStats.values.toList()
        ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));

      return sortedContacts.take(limit).toList();
    } catch (e) {
      await logger.error('DatabaseService', '获取最频繁联系人数据失败', e);
      rethrow;
    }
  }

  /// 获取所有私聊会话的活动数据（用于热力图等）
  Future<List<Map<String, dynamic>>> getAllPrivateSessionsActivity({
    int? year,
  }) async {
    if (!isConnected) {
      throw Exception('数据库未连接');
    }

    try {
      // 获取所有私聊会话
      final sessions = await getSessions();
      final privateSessions = sessions.where((s) => !s.isGroup).map((s) => s.username).toList();

      // 使用批量查询获取统计
      final batchStats = await getBatchSessionStats(privateSessions);

      // 如果有年份过滤，需要重新查询（带年份条件）
      if (year != null) {
        final filteredStats = <Map<String, dynamic>>[];
        final startTime = DateTime(year, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTime = DateTime(year + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;

        for (final sessionId in privateSessions) {
          try {
            final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
            int totalMessages = 0;

            for (final dbInfo in dbInfos) {
              final result = await dbInfo.database.rawQuery('''
                SELECT COUNT(*) as count
                FROM ${dbInfo.tableName}
                WHERE create_time >= $startTime AND create_time < $endTime
              ''');

              if (result.isNotEmpty && result[0]['count'] != null) {
                totalMessages += result[0]['count'] as int;
              }
            }

            if (totalMessages > 0) {
              filteredStats.add({
                'sessionId': sessionId,
                'total': totalMessages,
              });
            }
          } catch (e) {
            // 忽略单个会话的错误
          }
        }

        return filteredStats;
      }

      // 无年份过滤，返回完整统计
      return batchStats.entries.map((e) => {
        'sessionId': e.key,
        ...e.value,
      }).toList();
    } catch (e) {
      await logger.error('DatabaseService', '获取所有私聊会话活动数据失败', e);
      rethrow;
    }
  }

  /// 获取数据库中最新的消息日期
  Future<DateTime?> getLatestMessageDate() async {
    if (!isConnected) {
      return null;
    }

    try {
      final cachedDbs = await _getCachedMessageDatabases();

      int? maxTimestamp;

      for (final cachedDb in cachedDbs) {
        try {
          // 获取所有消息表
          final tables = await cachedDb.database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'",
          );

          for (final table in tables) {
            final tableName = table['name'] as String;

            try {
              // 直接查询该表的最大create_time
              final result = await cachedDb.database.rawQuery(
                'SELECT MAX(create_time) as max_time FROM $tableName'
              );

              final timestamp = result.first['max_time'] as int?;
              if (timestamp != null && (maxTimestamp == null || timestamp > maxTimestamp)) {
                maxTimestamp = timestamp;
              }
            } catch (e) {
              // 忽略单个表的错误
            }
          }
        } catch (e) {
          // 忽略单个数据库的错误
        }
      }

      if (maxTimestamp == null) {
        return null;
      }

      // 将时间戳转换为DateTime
      return DateTime.fromMillisecondsSinceEpoch(maxTimestamp * 1000);
    } catch (e) {
      return null;
    }
  }

  /// 批量获取所有私聊会话的按日期消息统计
  /// 返回格式：{username: {date: {count: int, firstIsSend: bool}}}
  Future<Map<String, Map<String, Map<String, dynamic>>>> getAllPrivateSessionsMessagesByDate({
    int? filterYear,
  }) async {
    if (!isConnected) {
      throw Exception('数据库未连接');
    }

    try {
      final result = <String, Map<String, Map<String, dynamic>>>{};

      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }

      final cachedDbs = await _getCachedMessageDatabases();

      for (final cachedDb in cachedDbs) {
        try {
          // 获取所有消息表
          final tables = await cachedDb.database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'",
          );

          for (final table in tables) {
            final tableName = table['name'] as String;

            try {
              // 从表名提取会话ID（Msg_<hash> 格式）
              // 需要通过查询 Name2Id 表来找到对应的 username

              // 一次查询获取该表所有日期的统计
              final rows = await cachedDb.database.rawQuery('''
                SELECT
                  DATE(create_time, 'unixepoch', 'localtime') as date,
                  COUNT(*) as count,
                  (SELECT CASE WHEN real_sender_id = (SELECT rowid FROM Name2Id WHERE user_name = ?) THEN 1 ELSE 0 END
                   FROM $tableName t2
                   WHERE DATE(t2.create_time, 'unixepoch', 'localtime') = DATE(t1.create_time, 'unixepoch', 'localtime')
                   ${yearFilter ?? ''}
                   ORDER BY t2.create_time ASC LIMIT 1) as first_is_send
                FROM $tableName t1
                WHERE 1=1 ${yearFilter ?? ''}
                GROUP BY date
                ORDER BY date
              ''', [_currentAccountWxid ?? '']);

              if (rows.isEmpty) continue;

              // 从表名推断会话username（需要查询session表）
              // 这里我们需要找到这个表对应的会话
              // 由于表名是 Msg_<hash>，我们需要通过其他方式关联

              // 暂时跳过，因为需要重新设计这个方法
              // 改为按会话批量查询的方式

            } catch (e) {
              // 忽略单个表的错误
            }
          }
        } catch (e) {
          // 忽略单个数据库的错误
        }
      }

      return result;
    } catch (e) {
      await logger.error('DatabaseService', '批量获取会话消息统计失败', e);
      rethrow;
    }
  }

  /// 批量获取所有私聊会话的消息日期列表
  /// 返回格式：{username: [date1, date2, ...]}
  Future<Map<String, Set<String>>> getAllPrivateSessionsMessageDates({
    int? filterYear,
  }) async {
    if (!isConnected) {
      throw Exception('数据库未连接');
    }

    try {
      final result = <String, Set<String>>{};

      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }

      // 获取所有私聊会话
      final sessions = await getSessions();
      final privateSessions = sessions.where((s) => !s.isGroup).toList();

      // 使用缓存的数据库连接
      final cachedDbs = await _getCachedMessageDatabases();

      // 为每个会话收集表信息
      for (final session in privateSessions) {
        final allDates = <String>{};

        // 从所有数据库查询该会话的消息日期
        for (final cachedDb in cachedDbs) {
          try {
            final tableName = await _getMessageTableName(session.username, cachedDb.database);
            if (tableName == null) continue;

            final rows = await cachedDb.database.rawQuery('''
              SELECT DISTINCT DATE(create_time, 'unixepoch', 'localtime') as date
              FROM $tableName
              WHERE 1=1 ${yearFilter ?? ''}
            ''');

            for (final row in rows) {
              allDates.add(row['date'] as String);
            }
          } catch (e) {
            // 忽略错误
          }
        }

        if (allDates.isNotEmpty) {
          result[session.username] = allDates;
        }
      }

      return result;
    } catch (e) {
      await logger.error('DatabaseService', '批量获取会话消息日期失败', e);
      rethrow;
    }
  }

  /// 获取文本消息长度统计
  Future<Map<String, dynamic>> getTextMessageLengthStats({
    int? year,
  }) async {
    if (!isConnected) {
      throw Exception('数据库未连接');
    }

    try {
      final cachedDbs = await _getCachedMessageDatabases();
      
      int totalLength = 0;
      int textMessageCount = 0;
      int longestLength = 0;
      Map<String, dynamic>? longestMessage;

      // 构建年份过滤条件
      String whereClause = 'WHERE real_sender_id = (SELECT rowid FROM Name2Id WHERE user_name = ?) AND local_type IN (1, 244813135921)';
      if (year != null) {
        final startTime = DateTime(year, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTime = DateTime(year + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        whereClause += ' AND create_time >= $startTime AND create_time < $endTime';
      }

      for (final cachedDb in cachedDbs) {
        try {
          final tables = await cachedDb.database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'",
          );

          for (final tableRow in tables) {
            final tableName = tableRow['name'] as String;

            // 统计总长度和数量
            final statsResult = await cachedDb.database.rawQuery('''
              SELECT 
                SUM(LENGTH(display_content)) as total_length,
                COUNT(*) as count
              FROM $tableName
              $whereClause
              AND display_content IS NOT NULL 
              AND display_content != ''
              AND display_content NOT LIKE '[%'
            ''', [_currentAccountWxid ?? '']);

            if (statsResult.isNotEmpty && statsResult[0]['count'] != null) {
              final count = statsResult[0]['count'] as int;
              final length = statsResult[0]['total_length'] as int? ?? 0;
              
              totalLength += length;
              textMessageCount += count;
            }

            // 查找该表中最长的消息
            final longestResult = await cachedDb.database.rawQuery('''
              SELECT 
                display_content,
                LENGTH(display_content) as len,
                create_time
              FROM $tableName
              $whereClause
              AND display_content IS NOT NULL 
              AND display_content != ''
              AND display_content NOT LIKE '[%'
              ORDER BY len DESC
              LIMIT 1
            ''', [_currentAccountWxid ?? '']);

            if (longestResult.isNotEmpty) {
              final len = longestResult[0]['len'] as int? ?? 0;
              if (len > longestLength) {
                longestLength = len;
                longestMessage = {
                  'content': longestResult[0]['display_content'] as String,
                  'length': len,
                  'createTime': longestResult[0]['create_time'] as int,
                  'tableName': tableName,
                };
              }
            }
          }
        } catch (e) {
          // 忽略单个数据库的错误
        }
      }

      return {
        'totalLength': totalLength,
        'textMessageCount': textMessageCount,
        'averageLength': textMessageCount > 0 ? totalLength / textMessageCount : 0.0,
        'longestLength': longestLength,
        'longestMessage': longestMessage,
      };
    } catch (e) {
      await logger.error('DatabaseService', '获取文本消息长度统计失败', e);
      rethrow;
    }
  }

  /// 分析响应速度（谁回复我最快）
  Future<List<Map<String, dynamic>>> analyzeResponseSpeed({
    required bool isMyResponse, // true: 我回复对方, false: 对方回复我
    int? year,
    Function(int current, int total, String currentUser)? onProgress,
    Function(String message, {String level})? onLog,
  }) async {
    if (!isConnected) {
      throw Exception('数据库未连接');
    }

    // 辅助函数：记录日志（优先使用 onLog 回调，否则使用 LoggerService）
    Future<void> log(String message, {String level = 'info'}) async {
      if (onLog != null) {
        onLog(message, level: level);
      } else {
        switch (level) {
          case 'debug':
            await logger.debug('DatabaseService', message);
            break;
          case 'warning':
            await logger.warning('DatabaseService', message);
            break;
          case 'error':
            await logger.error('DatabaseService', message);
            break;
          default:
            await logger.info('DatabaseService', message);
        }
      }
    }

    try {
      await log('========== 开始分析响应速度 ==========', level: 'debug');
      await log('分析类型: ${isMyResponse ? "我回复对方" : "对方回复我"}', level: 'debug');
      await log('年份过滤: ${year ?? "无"}', level: 'debug');

      final sessions = await getSessions();
      final privateSessions = sessions.where((s) => !s.isGroup).toList();
      await log('找到 ${privateSessions.length} 个私聊会话', level: 'info');

      // 批量获取显示名称
      final displayNames = await getDisplayNames(privateSessions.map((s) => s.username).toList());

      final results = <Map<String, dynamic>>[];
      int processedCount = 0;
      int hasDataCount = 0;

      // 缓存所有数据库，避免重复获取
      final cachedDbs = await _getCachedMessageDatabases();

      // 预先查询当前用户的 rowid（所有数据库共享同一个 Name2Id 表）
      int? myRowId;
      if (cachedDbs.isNotEmpty) {
        try {
          final myRowIdRows = await cachedDbs.first.database.rawQuery(
            'SELECT rowid FROM Name2Id WHERE user_name = ? LIMIT 1',
            [_currentAccountWxid ?? '']
          );
          if (myRowIdRows.isNotEmpty) {
            myRowId = myRowIdRows.first['rowid'] as int?;
            await log('当前用户 $_currentAccountWxid 在 Name2Id 表中的 rowid: $myRowId', level: 'debug');
          } else {
            await log('警告：未在 Name2Id 表中找到当前用户 $_currentAccountWxid', level: 'warning');
          }
        } catch (e) {
          await log('查询 Name2Id 表失败: $e', level: 'warning');
        }
      }

      if (myRowId == null) {
        await log('无法确定当前用户的 rowid，分析终止', level: 'error');
        return [];
      }

      for (int idx = 0; idx < privateSessions.length; idx++) {
        final session = privateSessions[idx];
        final displayName = displayNames[session.username] ?? session.username;

        // 报告进度
        onProgress?.call(idx + 1, privateSessions.length, displayName);

        try {
          // 使用已缓存的数据库列表
          final dbInfos = <_DatabaseTableInfo>[];
          for (final dbInfo in cachedDbs) {
            try {
              final tableName = await _getMessageTableName(
                session.username,
                dbInfo.database,
              );
              if (tableName != null) {
                dbInfos.add(_DatabaseTableInfo(
                  database: dbInfo.database,
                  tableName: tableName,
                  latestTimestamp: 0,
                  needsClose: false,
                ));
              }
            } catch (e) {
              // 忽略错误
            }
          }

          // 如果没有找到消息表，跳过
          if (dbInfos.isEmpty) {
            processedCount++;
            continue;
          }

          final responseTimes = <double>[];

          // 构建年份过滤条件（只构建一次）
          String whereClause = '';
          List<dynamic> queryParams = [myRowId];
          if (year != null) {
            final startTime = DateTime(year, 1, 1).millisecondsSinceEpoch ~/ 1000;
            final endTime = DateTime(year + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
            whereClause = 'WHERE create_time >= $startTime AND create_time < $endTime';
          }

          for (final dbInfo in dbInfos) {
            // 简化查询，只获取必要字段
            final query = '''
              SELECT
                create_time,
                CASE WHEN real_sender_id = ? THEN 1 ELSE 0 END AS is_send
              FROM ${dbInfo.tableName}
              $whereClause
              ORDER BY create_time ASC
            ''';

            final rows = await dbInfo.database.rawQuery(query, queryParams);

            // 减少日志输出，只在有数据时输出
            if (rows.isEmpty) continue;

            // 直接在查询结果上处理，避免额外的循环
            // 在内存中快速处理相邻消息
            for (int i = 0; i < rows.length - 1; i++) {
              final current = rows[i];
              final next = rows[i + 1];

              final currentIsSend = current['is_send'] as int;
              final nextIsSend = next['is_send'] as int;

              // 检查是否符合响应模式
              final isMatch = isMyResponse
                  ? (currentIsSend == 0 && nextIsSend == 1)  // 我回复对方：对方发消息(0)，然后我发消息(1)
                  : (currentIsSend == 1 && nextIsSend == 0);  // 对方回复我：我发消息(1)，然后对方发消息(0)

              if (isMatch) {
                final currentTime = current['create_time'] as int;
                final nextTime = next['create_time'] as int;
                final timeDiff = (nextTime - currentTime) / 60.0; // 转换为分钟

                // 过滤24小时内的响应
                if (timeDiff > 0 && timeDiff <= 1440) {
                  responseTimes.add(timeDiff);
                }
              }
            }
          }

          // 只处理有数据的会话
          if (responseTimes.isNotEmpty) {
            // 使用更高效的算法计算统计值
            double sum = 0;
            double fastest = responseTimes[0];
            double slowest = responseTimes[0];

            for (final time in responseTimes) {
              sum += time;
              if (time < fastest) fastest = time;
              if (time > slowest) slowest = time;
            }

            final avgTime = sum / responseTimes.length;

            results.add({
              'username': session.username,
              'displayName': displayName,
              'avgResponseTimeMinutes': avgTime,
              'totalResponses': responseTimes.length,
              'fastestResponseMinutes': fastest,
              'slowestResponseMinutes': slowest,
            });

            hasDataCount++;
          }

          processedCount++;
        } catch (e) {
          // 减少错误日志，只在调试模式下输出
          continue;
        }
      }

      // 按平均响应时间排序（从快到慢）
      results.sort((a, b) => (a['avgResponseTimeMinutes'] as double)
          .compareTo(b['avgResponseTimeMinutes'] as double));

      await log('========== 响应速度分析完成 ==========', level: 'info');
      await log('处理: $processedCount 个会话, 有数据: $hasDataCount 个, 结果: ${results.length} 个', level: 'info');

      // 只在有结果时输出详细信息
      if (results.isNotEmpty && results.length <= 5) {
        await log('前${results.length}名结果:', level: 'info');
        for (int i = 0; i < results.length; i++) {
          final r = results[i];
          await log('  ${i + 1}. ${r['displayName']}: 平均${(r['avgResponseTimeMinutes'] as double).toStringAsFixed(1)}分钟 (${r['totalResponses']}次)', level: 'info');
        }
      }

      return results;
    } catch (e, stackTrace) {
      await log('分析响应速度失败: $e\n堆栈: $stackTrace', level: 'error');
      rethrow;
    }
  }

}

/// 数据库表信息（用于消息查询优先级排序）
class _DatabaseTableInfo {
  final Database database;
  final String tableName;
  final int latestTimestamp;
  final bool needsClose;

  _DatabaseTableInfo({
    required this.database,
    required this.tableName,
    required this.latestTimestamp,
    required this.needsClose,
  });
}

/// 消息时间信息（用于跨数据库排序）
class _MessageTimeInfo {
  final int localId;
  final int createTime;
  final int dbIndex;

  _MessageTimeInfo({
    required this.localId,
    required this.createTime,
    required this.dbIndex,
  });
}

/// 缓存的数据库信息
class _CachedDatabaseInfo {
  final Database database;
  final String key;

  _CachedDatabaseInfo({
    required this.database,
    required this.key,
  });
}

/// 会话详细信息
class SessionDetailInfo {
  final String wxid;
  final String displayName;
  final String? remark;
  final String? nickName;
  final String? alias;
  final List<MessageTableLocation> messageTables;
  final int? firstMessageTime;
  final int? latestMessageTime;
  final int messageCount;
  final Contact? contactInfo;

  SessionDetailInfo({
    required this.wxid,
    required this.displayName,
    this.remark,
    this.nickName,
    this.alias,
    required this.messageTables,
    this.firstMessageTime,
    this.latestMessageTime,
    required this.messageCount,
    this.contactInfo,
  });
}

/// 消息表位置信息
class MessageTableLocation {
  final String databasePath;
  final String databaseName;
  final String tableName;
  final int messageCount;

  MessageTableLocation({
    required this.databasePath,
    required this.databaseName,
    required this.tableName,
    required this.messageCount,
  });
}
