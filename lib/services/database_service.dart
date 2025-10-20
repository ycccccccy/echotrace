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
  String? _currentAccountWxid;
  
  // 数据库工厂（用于 Isolate 中避免全局修改）
  DatabaseFactory? _dbFactory;

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
    if (!File(dbPath).existsSync()) {
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
      dbPath,
      options: OpenDatabaseOptions(
        readOnly: true,
        singleInstance: false, // 允许多个实例，避免冲突
      ),
    );

    _mode = DatabaseMode.decrypted;
    _sessionDbPath = dbPath;
    _currentAccountWxid = _extractWxidFromPath(dbPath);
  }

  /// 连接实时加密数据库（VFS拦截模式）
  /// [dbPath] 加密数据库路径
  /// [hexKey] 解密密钥（64位十六进制）
  /// [factory] 可选的数据库工厂
  Future<void> connectRealtimeDatabase(String dbPath, String hexKey, {DatabaseFactory? factory}) async {
    if (!File(dbPath).existsSync()) {
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
    
    try {
      // 使用真正的VFS拦截打开加密数据库
      // 在SQLite文件系统层面拦截xRead操作，实时解密数据页
      _sessionDb = await WeChatVFSNative.openEncryptedDatabase(dbPath, hexKey);

      _mode = DatabaseMode.realtime;
      _sessionDbPath = dbPath;
      _currentAccountWxid = _extractWxidFromPath(dbPath);

    } catch (e) {
      rethrow; // 重新抛出异常，让上层处理
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
      throw Exception('数据库未连接');
    }

    try {
      // 先检查表是否存在
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'"
      );
      
      final tableNames = tables.map((t) => t['name'] as String).toList();
      
      // 尝试找到会话表（可能的表名）
      String? sessionTableName;
      for (final name in ['SessionTable', 'Session', 'session', 'Contact']) {
        if (tableNames.contains(name)) {
          sessionTableName = name;
          break;
        }
      }
      
      if (sessionTableName == null) {
        // 如果没有找到会话表，尝试从其他表获取联系人信息
        if (tableNames.contains('contact') || tableNames.contains('Contact')) {
          return await _getSessionsFromContactTable(tableNames);
        } else if (tableNames.contains('FMessageTable')) {
          return await _getSessionsFromFMessageTable();
        } else {
          throw Exception('数据库中未找到会话表。可用的表: ${tableNames.join(", ")}');
        }
      }

      final List<Map<String, dynamic>> maps = await db.query(
        sessionTableName,
        orderBy: 'sort_timestamp DESC',
      );

      // 获取会话列表后，尝试从 contact 数据库获取真实姓名
      final allSessions = maps.map((map) => ChatSession.fromMap(map)).toList();
      
      // 过滤掉公众号、服务号等非正常联系人
      final filteredSessions = allSessions.where((session) {
        final username = session.username;
        
        // 过滤条件：只显示正常联系人和群聊
        if (username.contains('@chatroom')) {
          // 群聊
          return true;
        } else if (username.startsWith('wxid_') && !username.contains('@')) {
          // 普通微信用户
          return true;
        } else if (username.contains('@kefu.openim') || 
                   username.contains('service_') ||
                   username.startsWith('gh_') ||
                   username.contains('@openim')) {
          // 过滤掉客服、服务号、公众号等
          return false;
        }
        
        // 其他情况默认显示
        return true;
      }).toList();
      
      // 会话过滤完成
      
      // 尝试连接 contact 数据库获取真实姓名
      await _enrichSessionsWithContactInfo(filteredSessions);
      
      return filteredSessions;
    } catch (e) {
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

  /// 获取消息列表
  Future<List<Message>> getMessages(String sessionId, {int limit = 50, int offset = 0}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      // 先尝试当前数据库
      final Database dbForMsg = await _getDbForMessages();
      final tableName = await _getMessageTableName(sessionId, dbForMsg);
      
      if (tableName != null) {
        // 找到了，直接查询
        return await _queryMessagesFromTable(dbForMsg, tableName, limit, offset);
      }
      
      final allMessageDbs = await _findAllMessageDbs();
      
      for (int i = 0; i < allMessageDbs.length; i++) {
        final dbPath = allMessageDbs[i];
        
        try {
          final tempDb = await _currentFactory.openDatabase(
            dbPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          
          try {
            final foundTableName = await _getMessageTableName(sessionId, tempDb, dbIndex: i);
            if (foundTableName != null) {
              final messages = await _queryMessagesFromTable(tempDb, foundTableName, limit, offset);
              await tempDb.close();
              return messages;
            }
          } finally {
            await tempDb.close();
          }
        } catch (e) {
        }
      }
      
      // 所有数据库都找不到
      return [];
    } catch (e) {
      throw Exception('获取消息列表失败: $e');
    }
  }

  /// 从指定表查询消息
  Future<List<Message>> _queryMessagesFromTable(
    Database db, 
    String tableName, 
    int limit, 
    int offset
  ) async {
      // 直接根据 real_sender_id 判断：1=自己发的，其他=别人发的
      // 对于群聊，需要通过 real_sender_id 查询 Name2Id 获取发送者 username
    final maps = await db.rawQuery('''
        SELECT 
          m.*,
          CASE WHEN m.real_sender_id = 1 THEN 1 ELSE 0 END AS is_send,
          n.user_name AS sender_username
        FROM $tableName m
        LEFT JOIN Name2Id n ON m.real_sender_id = n.rowid
        ORDER BY m.sort_seq DESC 
        LIMIT ? OFFSET ?
      ''', [limit, offset]);
      
      return maps.map((map) => Message.fromMap(map, myWxid: _currentAccountWxid)).toList();
  }

  /// 获取会话的消息总数
  Future<int> getMessageCount(String sessionId) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      // 先尝试当前数据库
      final Database dbForMsg = await _getDbForMessages();
      final tableName = await _getMessageTableName(sessionId, dbForMsg);
      
      if (tableName != null) {
        final result = await dbForMsg.rawQuery('SELECT COUNT(*) as count FROM $tableName');
        return (result.first['count'] as int?) ?? 0;
      }
      
      // 搜索其他消息数据库
      final allMessageDbs = await _findAllMessageDbs();
      
      for (int i = 0; i < allMessageDbs.length; i++) {
        final dbPath = allMessageDbs[i];
        
        try {
          final tempDb = await _currentFactory.openDatabase(
            dbPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          
          try {
            final foundTableName = await _getMessageTableName(sessionId, tempDb, dbIndex: i);
            if (foundTableName != null) {
              final result = await tempDb.rawQuery('SELECT COUNT(*) as count FROM $foundTableName');
              final count = (result.first['count'] as int?) ?? 0;
              await tempDb.close();
              return count;
            }
          } catch (e) {
            await tempDb.close();
          }
        } catch (e) {
          continue;
        }
      }
      
      return 0;
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
            if (kDebugMode) {
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
        } else {
        }
      } catch (e) {
        // 查询失败
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
    } catch (e) {
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
        
        final List<Map<String, dynamic>> maps = await dbForMsg.query(
          tableName,
          where: 'message_content LIKE ?',
          whereArgs: ['%$keyword%'],
          limit: limit,
        );

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
      final Database dbForMsg = await _getDbForMessages();
      final tableName = await _getMessageTableName(sessionId, dbForMsg);
      
      if (tableName == null) {
        return {};
      }

      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }

      // 按日期分组统计，包含每天的第一条消息是谁发的
      // 注意：is_send 是通过 real_sender_id = 1 判断的
      final result = await dbForMsg.rawQuery('''
        SELECT 
          DATE(create_time, 'unixepoch', 'localtime') as date,
          COUNT(*) as count,
          (SELECT CASE WHEN real_sender_id = 1 THEN 1 ELSE 0 END FROM $tableName t2 
           WHERE DATE(t2.create_time, 'unixepoch', 'localtime') = DATE(t1.create_time, 'unixepoch', 'localtime')
           ${yearFilter ?? ''}
           ORDER BY t2.create_time ASC LIMIT 1) as first_is_send
        FROM $tableName t1
        WHERE 1=1 ${yearFilter ?? ''}
        GROUP BY date
        ORDER BY date
      ''');

      final resultMap = <String, Map<String, dynamic>>{};
      for (final row in result) {
        final date = row['date'] as String;
        resultMap[date] = {
          'count': (row['count'] as int?) ?? 0,
          'firstIsSend': (row['first_is_send'] as int?) == 1,
        };
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
      final Database dbForMsg = await _getDbForMessages();
      final tableName = await _getMessageTableName(sessionId, dbForMsg);
      
      if (tableName == null) {
        return [];
      }

      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }

      // 只查询日期，不加载消息内容
      final result = await dbForMsg.rawQuery('''
        SELECT DISTINCT DATE(create_time, 'unixepoch', 'localtime') as date
        FROM $tableName
        WHERE 1=1 ${yearFilter ?? ''}
        ORDER BY date
      ''');

      return result.map((row) {
        final dateStr = row['date'] as String;
        return DateTime.parse(dateStr);
      }).toList();
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
      final Database dbForMsg = await _getDbForMessages();
      
      // 获取所有消息表
      final tables = await dbForMsg.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
      );
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      final results = <Map<String, dynamic>>[];
      
      // 只查询我发送的文本消息（local_type = 1）
      for (final table in tables) {
        final tableName = table['name'] as String;
        try {
          final msgs = await dbForMsg.rawQuery('''
            SELECT 
              local_id,
              message_content,
              compress_content,
              create_time,
              LENGTH(COALESCE(message_content, '')) as content_length
            FROM $tableName
            WHERE local_type = 1 
              AND real_sender_id = 1
              ${yearFilter ?? ''}
            ORDER BY content_length DESC
            LIMIT 100
          ''');
          
          for (final msg in msgs) {
            results.add({
              ...msg,
              'table_name': tableName,
            });
          }
        } catch (e) {
        }
      }
      
      // 按长度排序
      results.sort((a, b) => (b['content_length'] as int).compareTo(a['content_length'] as int));
      
      return results;
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
      final Database dbForMsg = await _getDbForMessages();
      
      // 获取所有消息表
      final tables = await dbForMsg.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
      );
      
      final typeCount = <int, int>{};
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      // 统计每个表的消息类型
      for (final table in tables) {
        final tableName = table['name'] as String;
        try {
          final result = await dbForMsg.rawQuery('''
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
      final Database dbForMsg = await _getDbForMessages();
      final tableName = await _getMessageTableName(sessionId, dbForMsg);
      
      if (tableName == null) {
        return {
          'total': 0,
          'sent': 0,
          'received': 0,
        };
      }

      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }

      // 使用SQL直接统计，大幅提升性能
      // 注意：is_send 是通过 real_sender_id = 1 判断的
      final result = await dbForMsg.rawQuery('''
        SELECT 
          COUNT(*) as total,
          COALESCE(SUM(CASE WHEN real_sender_id = 1 THEN 1 ELSE 0 END), 0) as sent,
          COALESCE(SUM(CASE WHEN real_sender_id != 1 THEN 1 ELSE 0 END), 0) as received
        FROM $tableName
        WHERE 1=1 ${yearFilter ?? ''}
      ''');

      final row = result.first;
      return {
        'total': (row['total'] as int?) ?? 0,
        'sent': (row['sent'] as int?) ?? 0,
        'received': (row['received'] as int?) ?? 0,
      };
    } catch (e) {
      return {
        'total': 0,
        'sent': 0,
        'received': 0,
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

  /// 关闭数据库连接
  Future<void> close() async {
    
    // 如果是实时模式，需要清理VFS资源
    if (_mode == DatabaseMode.realtime && _sessionDbPath != null && _sessionDb != null) {
      try {
        await WeChatVFSNative.closeEncryptedDatabase(_sessionDb!, _sessionDbPath!);
      } catch (e) {
      }
      _sessionDb = null;
    } else if (_sessionDb != null) {
      try {
        await _sessionDb!.close();
      } catch (e) {
      }
      _sessionDb = null;
    }
    
    if (_messageDb != null) {
      try {
        await _messageDb!.close();
      } catch (e) {
      }
      _messageDb = null;
    }
    
    // 强制触发垃圾回收，帮助释放文件句柄
    await Future.delayed(const Duration(milliseconds: 100));
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

        await contactDb.close();
        return result;
      } finally {
        await contactDb.close();
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
      // 尝试连接 contact 数据库
      final contactDbPath = await _findContactDatabase();
      if (contactDbPath == null) {
        return;
      }

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
      } finally {
        await contactDb.close();
      }
    } catch (e) {
      // 连接 contact 数据库失败
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

  /// 查找 contact 数据库文件
  Future<String?> _findContactDatabase() async {
    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      final echoTraceDir = Directory('${documentsDir.path}${Platform.pathSeparator}EchoTrace');
      
      if (!await echoTraceDir.exists()) return null;
      
      final wxidDirs = await echoTraceDir.list().where((entity) {
        return entity is Directory && 
               entity.path.split(Platform.pathSeparator).last.startsWith('wxid_');
      }).toList();
      
      for (final wxidDir in wxidDirs) {
        final contactDbPath = '${wxidDir.path}${Platform.pathSeparator}contact.db';
        final contactDbFile = File(contactDbPath);

        if (await contactDbFile.exists()) {
          return contactDbPath;
        }
      }
      
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 获取用于消息查询的数据库
  Future<dynamic> _getDbForMessages() async {
    final db = _currentDb;
    // 如果会话库本身就包含消息表，直接使用
    if (await _hasMsgTables(db)) {
      return db;
    }


    // 懒加载消息库（仅解密模式）
    if (_messageDb != null) return _messageDb!;

    final messageDbPath = await _locateMessageDbPathNearSession();
    if (messageDbPath == null) {
      throw Exception('未找到消息数据库');
    }
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
        for (int i = 0; i < 9; i++) {
          final candidate = File('${wxidDir.path}${Platform.pathSeparator}message_${i}.db');
        if (await candidate.exists()) {
            messageDbs.add(candidate.path);
          }
        }
        
        if (messageDbs.isNotEmpty) {
          return messageDbs;
        }
      }
    }

    // 兜底：扫描 EchoTrace 目录
    final documentsDir = await getApplicationDocumentsDirectory();
    final echoTraceDir = Directory('${documentsDir.path}${Platform.pathSeparator}EchoTrace');
    if (!await echoTraceDir.exists()) return messageDbs;

    final wxidDirs = await echoTraceDir.list().where((e) => e is Directory).toList();
    for (final dir in wxidDirs) {
      for (int i = 0; i < 100; i++) {
        final messageDbFile = File('${dir.path}${Platform.pathSeparator}message_${i}.db');
        if (await messageDbFile.exists()) {
          messageDbs.add(messageDbFile.path);
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

  String? _extractWxidFromPath(String path) {
    final parts = path.split(Platform.pathSeparator);
    final idx = parts.lastIndexWhere((p) => p.startsWith('wxid_'));
    if (idx != -1) return parts[idx];
    return null;
  }

  Directory? _findWxidDirFromPath(String path) {
    final dir = Directory(path).parent;
    if (dir.path.split(Platform.pathSeparator).last.startsWith('wxid_')) {
      return dir;
    }
    return null;
  }

}
