import 'package:flutter_test/flutter_test.dart';
import 'package:echotrace/utils/path_utils.dart';

void main() {
  group('PathUtils', () {
    test('normalizeDatabasePath - 处理中文路径', () {
      final path = r'D:\Documents\文档\EchoTrace\session.db';
      final normalized = PathUtils.normalizeDatabasePath(path);

      expect(normalized, contains('文档'));
      expect(normalized, contains('EchoTrace'));
      expect(normalized.startsWith('D:'), isTrue);
    });

    test('normalizeDatabasePath - 处理空格路径', () {
      final path =
          r'D:\Documents\OneDrive - My Cloud Disk\EchoTrace\session.db';
      final normalized = PathUtils.normalizeDatabasePath(path);

      expect(normalized, contains('OneDrive - My Cloud Disk'));
      expect(normalized, contains('EchoTrace'));
    });

    test('normalizeDatabasePath - 处理中文和空格混合路径', () {
      final path = r'D:\我的文档\OneDrive - 我的云盘\微信数据\session.db';
      final normalized = PathUtils.normalizeDatabasePath(path);

      expect(normalized, contains('我的文档'));
      expect(normalized, contains('OneDrive - 我的云盘'));
      expect(normalized, contains('微信数据'));
    });

    test('normalizeDatabasePath - 统一路径分隔符', () {
      final path = r'D:/Documents/EchoTrace/session.db';
      final normalized = PathUtils.normalizeDatabasePath(path);

      // Windows 应该使用反斜杠
      expect(normalized, contains(r'\'));
      expect(normalized, isNot(contains('/')));
    });

    test('normalizeDatabasePath - 移除长路径前缀', () {
      final path = r'\\?\D:\Documents\EchoTrace\session.db';
      final normalized = PathUtils.normalizeDatabasePath(path);

      // 应该移除 \\?\ 前缀
      expect(normalized.startsWith(r'\\?\'), isFalse);
      expect(normalized.startsWith('D:'), isTrue);
    });

    test('normalizeDatabasePath - 盘符大写', () {
      final path = r'd:\documents\echotrace\session.db';
      final normalized = PathUtils.normalizeDatabasePath(path);

      // 盘符应该大写
      expect(normalized.startsWith('D:'), isTrue);
    });

    test('hasSpecialCharacters - 检测中文', () {
      expect(PathUtils.hasSpecialCharacters(r'D:\文档\EchoTrace'), isTrue);
      expect(
        PathUtils.hasSpecialCharacters(r'D:\Documents\EchoTrace'),
        isFalse,
      );
    });

    test('hasSpecialCharacters - 检测空格', () {
      expect(
        PathUtils.hasSpecialCharacters(r'D:\My Documents\EchoTrace'),
        isTrue,
      );
      expect(
        PathUtils.hasSpecialCharacters(r'D:\Documents\EchoTrace'),
        isFalse,
      );
    });

    test('join - 安全拼接路径', () {
      final joined = PathUtils.join(r'D:\Documents', 'EchoTrace', 'session.db');

      expect(joined, contains('Documents'));
      expect(joined, contains('EchoTrace'));
      expect(joined, contains('session.db'));
      expect(joined, contains(r'\'));
    });

    test('join - 处理中文路径拼接', () {
      final joined = PathUtils.join(r'D:\文档', 'EchoTrace', 'session.db');

      expect(joined, contains('文档'));
      expect(joined, contains('EchoTrace'));
      expect(joined, contains('session.db'));
    });

    test('basename - 获取文件名', () {
      final filename = PathUtils.basename(r'D:\Documents\EchoTrace\session.db');
      expect(filename, equals('session.db'));
    });

    test('dirname - 获取目录路径', () {
      final dir = PathUtils.dirname(r'D:\Documents\EchoTrace\session.db');
      expect(dir, contains('EchoTrace'));
      expect(dir, isNot(contains('session.db')));
    });

    test('extension - 获取扩展名', () {
      final ext = PathUtils.extension(r'D:\Documents\EchoTrace\session.db');
      expect(ext, equals('.db'));
    });

    test('replaceExtension - 替换扩展名', () {
      final newPath = PathUtils.replaceExtension(
        r'D:\Documents\EchoTrace\image.dat',
        '.jpg',
      );
      expect(newPath, endsWith('.jpg'));
      expect(newPath, isNot(contains('.dat')));
    });

    test('isDatabaseFile - 检测数据库文件', () {
      expect(PathUtils.isDatabaseFile('session.db'), isTrue);
      expect(PathUtils.isDatabaseFile('data.sqlite'), isTrue);
      expect(PathUtils.isDatabaseFile('data.sqlite3'), isTrue);
      expect(PathUtils.isDatabaseFile('image.jpg'), isFalse);
    });

    test('escapeForLog - 转义特殊字符', () {
      final escaped = PathUtils.escapeForLog(r'D:\Documents\EchoTrace');
      expect(escaped, contains(r'\\'));
    });
  });
}
