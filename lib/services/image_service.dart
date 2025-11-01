import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as path;
import '../utils/path_utils.dart';

/// 图片服务 - 处理微信图片的查找和显示
class ImageService {
  String? _dataPath;
  Database? _hardlinkDb;
  String? _imageTableName;
  String? _dir2idTableName;

  /// 初始化图片服务
  Future<void> init(String dataPath) async {
    _dataPath = dataPath;
    await _connectHardlinkDb();
  }

  /// 连接 hardlink 数据库
  Future<void> _connectHardlinkDb() async {
    try {
      if (_dataPath == null) return;

      final hardlinkPath = PathUtils.join(_dataPath!, 'hardlink.db');
      final file = File(hardlinkPath);

      if (!await file.exists()) {
        return;
      }

      final normalizedPath = PathUtils.normalizeDatabasePath(hardlinkPath);
      _hardlinkDb = await databaseFactory.openDatabase(
        normalizedPath,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );

      // 动态查询图片表名
      final imageTables = await _hardlinkDb!.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'image_hardlink_info%' ORDER BY name DESC",
      );
      _imageTableName = imageTables.isNotEmpty
          ? imageTables.first['name'] as String?
          : null;

      // 动态查询目录表名
      final dirTables = await _hardlinkDb!.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'dir2id%'",
      );
      _dir2idTableName = dirTables.isNotEmpty
          ? dirTables.first['name'] as String?
          : null;
    } catch (e) {
      // 连接失败
    }
  }

  /// 根据 MD5 和用户名获取图片路径
  Future<String?> getImagePath(String md5, String username) async {
    try {
      if (_hardlinkDb == null) {
        await _connectHardlinkDb();
        if (_hardlinkDb == null) return null;
      }

      // 检查图片表是否存在
      if (_imageTableName == null) {
        return null;
      }

      // 使用动态表名查询
      final rows = await _hardlinkDb!.rawQuery(
        '''
        SELECT dir1, dir2, file_name 
        FROM $_imageTableName 
        WHERE md5 = ?
        LIMIT 1
      ''',
        [md5],
      );

      if (rows.isEmpty) {
        return null;
      }

      final row = rows.first;
      final dir1 = row['dir1'] as String?;
      final dir2 = row['dir2'] as String?;
      final fileName = row['file_name'] as String?;

      if (dir1 == null || dir2 == null || fileName == null) {
        return null;
      }

      // 从 dir2id 表获取目录映射（如果表存在）
      String dirName = dir2;
      if (_dir2idTableName != null) {
        try {
          final dirRows = await _hardlinkDb!.rawQuery(
            '''
            SELECT dir_name 
            FROM $_dir2idTableName 
            WHERE dir_id = ? AND username = ?
            LIMIT 1
          ''',
            [dir2, username],
          );

          if (dirRows.isNotEmpty) {
            dirName = dirRows.first['dir_name'] as String? ?? dir2;
          }
        } catch (e) {
          // 如果查询失败，使用 dir2 作为目录名
        }
      }

      // 构建完整路径
      final fullPath = path.join(_dataPath!, dir1, dirName, fileName);
      final file = File(fullPath);

      if (await file.exists()) {
        return fullPath;
      } else {
        return null;
      }
    } catch (e) {
      // 获取图片路径失败
      return null;
    }
  }

  /// 关闭数据库连接
  Future<void> dispose() async {
    await _hardlinkDb?.close();
    _hardlinkDb = null;
  }
}
