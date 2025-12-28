import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_xlsio/xlsio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/message.dart';
import '../models/chat_session.dart';
import '../models/contact_record.dart';
import '../utils/path_utils.dart';
import 'database_service.dart';
import 'logger_service.dart';

/// 聊天记录导出服务
class ChatExportService {
  final DatabaseService _databaseService;
  final Set<String> _missingDisplayNameLog = <String>{};
  final Map<String, String> _avatarBase64CacheByUrl = <String, String>{};
  ChatExportService(this._databaseService);

  /// 后台写入字符串到文件（在 Isolate 中执行以避免阻塞 UI）
  static bool _writeStringToFileSync(Map<String, String> params) {
    try {
      final file = File(params['path']!);
      final parentDir = file.parent;
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }
      file.writeAsStringSync(params['content']!);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 后台写入字节到文件（在 Isolate 中执行以避免阻塞 UI）
  static bool _writeBytesToFileSync(Map<String, dynamic> params) {
    try {
      final file = File(params['path'] as String);
      final parentDir = file.parent;
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }
      file.writeAsBytesSync(params['bytes'] as Uint8List);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 数据大小阈值：超过此大小则直接异步写入，避免 Isolate 间传输开销
  static const int _largeDataThreshold = 5 * 1024 * 1024; // 5MB

  /// 使用 compute 在后台写入字符串文件（智能选择策略）
  Future<bool> _writeStringInBackground(String path, String content) async {
    final contentBytes = content.length * 2; // UTF-16 估算
    await logger.info(
      'ChatExportService',
      '开始写入文件: $path, 内容大小: ${(contentBytes / (1024 * 1024)).toStringAsFixed(2)} MB',
    );

    try {
      final file = File(path);
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      // 对于大数据，直接使用异步IO（dart:io 内部使用IO线程池，不会阻塞主线程）
      // 避免 compute 序列化大数据到另一个 Isolate 的开销
      if (contentBytes > _largeDataThreshold) {
        await logger.info('ChatExportService', '数据较大，使用直接异步写入模式');
        await file.writeAsString(content);
      } else {
        await logger.info('ChatExportService', '数据较小，使用 compute 后台写入模式');
        final result = await compute(_writeStringToFileSync, {
          'path': path,
          'content': content,
        });
        if (!result) {
          await logger.error('ChatExportService', '后台写入失败: $path');
          return false;
        }
      }

      await logger.info('ChatExportService', '文件写入完成: $path');
      return true;
    } catch (e, stack) {
      await logger.error('ChatExportService', '写入文件异常: $e\n$stack');
      return false;
    }
  }

  /// 使用 compute 在后台写入字节文件（智能选择策略）
  Future<bool> _writeBytesInBackground(String path, Uint8List bytes) async {
    await logger.info(
      'ChatExportService',
      '开始写入字节文件: $path, 大小: ${(bytes.length / (1024 * 1024)).toStringAsFixed(2)} MB',
    );

    try {
      final file = File(path);
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      // 对于大数据，直接使用异步IO
      if (bytes.length > _largeDataThreshold) {
        await logger.info('ChatExportService', '数据较大，使用直接异步写入模式');
        await file.writeAsBytes(bytes);
      } else {
        await logger.info('ChatExportService', '数据较小，使用 compute 后台写入模式');
        final result = await compute(_writeBytesToFileSync, {
          'path': path,
          'bytes': bytes,
        });
        if (!result) {
          await logger.error('ChatExportService', '后台写入失败: $path');
          return false;
        }
      }

      await logger.info('ChatExportService', '字节文件写入完成: $path');
      return true;
    } catch (e, stack) {
      await logger.error('ChatExportService', '写入字节文件异常: $e\n$stack');
      return false;
    }
  }

  /// 导出聊天记录为 JSON 格式
  /// [onProgress] 进度回调：(当前处理的消息数, 总消息数, 阶段描述)
  Future<bool> exportToJson(
    ChatSession session,
    List<Message> messages, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
  }) async {
    try {
      final totalMessages = messages.length;
      onProgress?.call(0, totalMessages, '准备元数据...');

      // 获取联系人详细信息
      final contactInfo = await _getContactInfo(session.username);
      final senderUsernameSet = messages
          .where(
            (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
          )
          .map((m) => m.senderUsername!)
          .toSet();

      final rawMyWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedMyWxid = rawMyWxid.trim();
      if (trimmedMyWxid.isNotEmpty) {
        senderUsernameSet.add(trimmedMyWxid);
      }
      final myWxid = _sanitizeUsername(rawMyWxid);
      if (myWxid.isNotEmpty) {
        senderUsernameSet.add(myWxid);
      }
      final senderUsernames = senderUsernameSet.toList();

      final senderDisplayNames = senderUsernames.isNotEmpty
          ? await _databaseService.getDisplayNames(senderUsernames)
          : <String, String>{};

      final myContactInfo = rawMyWxid.isNotEmpty
          ? await _getContactInfo(rawMyWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(rawMyWxid, myContactInfo);

      onProgress?.call(0, totalMessages, '构建头像索引...');
      final avatars = await _buildAvatarIndex(
        session: session,
        messages: messages,
        contactInfo: contactInfo,
        senderDisplayNames: senderDisplayNames,
        rawMyWxid: rawMyWxid,
        myDisplayName: myDisplayName,
      );

      onProgress?.call(0, totalMessages, '处理消息数据...');

      // 分批处理消息以显示进度
      final messageItems = <Map<String, dynamic>>[];
      const batchSize = 1000;
      for (int i = 0; i < messages.length; i += batchSize) {
        final end = (i + batchSize < messages.length)
            ? i + batchSize
            : messages.length;
        for (int j = i; j < end; j++) {
          final msg = messages[j];
          final isSend = msg.isSend == 1;
          final senderName = _resolveSenderDisplayName(
            msg: msg,
            session: session,
            isSend: isSend,
            contactInfo: contactInfo,
            myContactInfo: myContactInfo,
            senderDisplayNames: senderDisplayNames,
            myDisplayName: myDisplayName,
          );
          final senderWxid = _resolveSenderUsername(
            msg: msg,
            session: session,
            isSend: isSend,
            myWxid: myWxid,
          );

          final item = <String, dynamic>{
            'localId': msg.localId,
            'createTime': msg.createTime,
            'formattedTime': msg.formattedCreateTime,
            'type': msg.typeDescription,
            'localType': msg.localType,
            'content': msg.displayContent,
            'isSend': msg.isSend,
            'senderUsername': senderWxid.isEmpty ? null : senderWxid,
            'senderDisplayName': senderName,
            'senderAvatarKey': senderWxid.isEmpty ? null : senderWxid,
            'source': msg.source,
          };

          if (msg.localType == 47) {
            item['emojiMd5'] = msg.emojiMd5;
          }

          messageItems.add(item);
        }

        // 每批处理后报告进度并让出主线程
        onProgress?.call(end, totalMessages, '处理消息数据...');
        await Future.delayed(Duration.zero);
      }

      final data = {
        'session': {
          'wxid': _sanitizeUsername(session.username),
          'nickname':
              contactInfo['nickname'] ??
              session.displayName ??
              session.username,
          'remark': _getRemarkOrAlias(contactInfo),
          'displayName': session.displayName ?? session.username,
          'type': session.typeDescription,
          'lastTimestamp': session.lastTimestamp,
          'messageCount': messages.length,
        },
        'messages': messageItems,
        'avatars': avatars,
        'exportTime': DateTime.now().toIso8601String(),
      };

      onProgress?.call(totalMessages, totalMessages, '编码 JSON...');
      await logger.info(
        'ChatExportService',
        'exportToJson: 开始编码 JSON, 消息数: ${messages.length}',
      );

      final jsonString = const JsonEncoder.withIndent('  ').convert(data);

      await logger.info(
        'ChatExportService',
        'exportToJson: JSON 编码完成, 字符串长度: ${jsonString.length}',
      );

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.json';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) return false;
        filePath = outputFile;
      }

      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      // 使用后台 Isolate 写入文件以避免阻塞 UI
      return await _writeStringInBackground(filePath, jsonString);
    } catch (e, stack) {
      await logger.error('ChatExportService', 'exportToJson 失败: $e\n$stack');
      return false;
    }
  }

  /// 导出聊天记录为 HTML 格式
  /// [onProgress] 进度回调：(当前处理的消息数, 总消息数, 阶段描述)
  Future<bool> exportToHtml(
    ChatSession session,
    List<Message> messages, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
  }) async {
    try {
      final totalMessages = messages.length;
      onProgress?.call(0, totalMessages, '准备元数据...');

      // 获取联系人详细信息
      final contactInfo = await _getContactInfo(session.username);

      // 获取所有发送者的显示名称
      final senderUsernameSet = messages
          .where(
            (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
          )
          .map((m) => m.senderUsername!)
          .toSet();

      final rawMyWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedMyWxid = rawMyWxid.trim();
      if (trimmedMyWxid.isNotEmpty) {
        senderUsernameSet.add(trimmedMyWxid);
      }
      final myWxid = _sanitizeUsername(rawMyWxid);
      if (myWxid.isNotEmpty) {
        senderUsernameSet.add(myWxid);
      }
      final senderUsernames = senderUsernameSet.toList();

      final senderDisplayNames = senderUsernames.isNotEmpty
          ? await _databaseService.getDisplayNames(senderUsernames)
          : <String, String>{};

      final myContactInfo = rawMyWxid.isNotEmpty
          ? await _getContactInfo(rawMyWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(rawMyWxid, myContactInfo);

      onProgress?.call(0, totalMessages, '构建头像索引...');
      final avatars = await _buildAvatarIndex(
        session: session,
        messages: messages,
        contactInfo: contactInfo,
        senderDisplayNames: senderDisplayNames,
        rawMyWxid: rawMyWxid,
        myDisplayName: myDisplayName,
      );

      onProgress?.call(0, totalMessages, '生成 HTML...');
      await logger.info(
        'ChatExportService',
        'exportToHtml: 开始生成 HTML, 消息数: ${messages.length}',
      );

      final html = _generateHtml(
        session,
        messages,
        senderDisplayNames,
        myWxid,
        contactInfo,
        myDisplayName,
        avatars,
      );

      await logger.info(
        'ChatExportService',
        'exportToHtml: HTML 生成完成, 长度: ${html.length}',
      );

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.html';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) return false;
        filePath = outputFile;
      }

      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      // 使用后台 Isolate 写入文件以避免阻塞 UI
      return await _writeStringInBackground(filePath, html);
    } catch (e, stack) {
      await logger.error('ChatExportService', 'exportToHtml 失败: $e\n$stack');
      return false;
    }
  }

  /// 导出聊天记录为 Excel 格式
  /// [onProgress] 进度回调：(当前处理的消息数, 总消息数, 阶段描述)
  Future<bool> exportToExcel(
    ChatSession session,
    List<Message> messages, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
  }) async {
    final Workbook workbook = Workbook();
    final totalMessages = messages.length;
    onProgress?.call(0, totalMessages, '准备工作簿...');
    try {
      // 获取联系人详细信息
      final contactInfo = await _getContactInfo(session.username);

      // 使用或创建工作表
      Worksheet sheet;
      if (workbook.worksheets.count > 0) {
        sheet = workbook.worksheets[0];
        sheet.name = '聊天记录';
      } else {
        sheet = workbook.worksheets.addWithName('聊天记录');
      }
      int currentRow = 1;

      // 添加会话信息行
      _setTextSafe(sheet, currentRow, 1, '会话信息');
      currentRow++;

      _setTextSafe(sheet, currentRow, 1, '微信ID');
      _setTextSafe(sheet, currentRow, 2, _sanitizeUsername(session.username));
      _setTextSafe(sheet, currentRow, 3, '昵称');
      _setTextSafe(sheet, currentRow, 4, contactInfo['nickname'] ?? '');
      _setTextSafe(sheet, currentRow, 5, '备注');
      _setTextSafe(sheet, currentRow, 6, _getRemarkOrAlias(contactInfo));
      currentRow++;

      // 空行
      currentRow++;

      // 设置表头
      _setTextSafe(sheet, currentRow, 1, '序号');
      _setTextSafe(sheet, currentRow, 2, '时间');
      _setTextSafe(sheet, currentRow, 3, '发送者昵称');
      _setTextSafe(sheet, currentRow, 4, '发送者微信ID');
      _setTextSafe(sheet, currentRow, 5, '发送者备注');
      _setTextSafe(sheet, currentRow, 6, '发送者身份');
      _setTextSafe(sheet, currentRow, 7, '消息类型');
      _setTextSafe(sheet, currentRow, 8, '内容');
      currentRow++;

      // 获取所有发送者的显示名称
      final senderUsernameSet = messages
          .where(
            (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
          )
          .map((m) => m.senderUsername!)
          .toSet();

      final rawAccountWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedAccountWxid = rawAccountWxid.trim();
      if (trimmedAccountWxid.isNotEmpty) {
        senderUsernameSet.add(trimmedAccountWxid);
      }
      final currentAccountWxid = _sanitizeUsername(rawAccountWxid);
      if (currentAccountWxid.isNotEmpty) {
        senderUsernameSet.add(currentAccountWxid);
      }
      final senderUsernames = senderUsernameSet.toList();

      final senderDisplayNames = senderUsernames.isNotEmpty
          ? await _databaseService.getDisplayNames(senderUsernames)
          : <String, String>{};

      // 获取所有发送者的详细信息（nickname、remark）
      final senderContactInfos = <String, Map<String, String>>{};
      for (final username in senderUsernames) {
        senderContactInfos[username] = await _getContactInfo(username);
      }

      // 获取当前账户的联系人信息（用于“我”发送的消息）
      final currentAccountInfo = rawAccountWxid.isNotEmpty
          ? await _getContactInfo(rawAccountWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(
        rawAccountWxid,
        currentAccountInfo,
      );
      final avatars = await _buildAvatarIndex(
        session: session,
        messages: messages,
        contactInfo: contactInfo,
        senderDisplayNames: senderDisplayNames,
        rawMyWxid: rawAccountWxid,
        myDisplayName: myDisplayName,
      );
      final sanitizedAccountWxid = currentAccountWxid;
      if (sanitizedAccountWxid.isNotEmpty) {
        senderContactInfos[sanitizedAccountWxid] = currentAccountInfo;
      }
      final rawAccountWxidTrimmed = rawAccountWxid.trim();
      if (rawAccountWxidTrimmed.isNotEmpty) {
        senderContactInfos[rawAccountWxidTrimmed] = currentAccountInfo;
      }

      // 添加数据行
      for (int i = 0; i < messages.length; i++) {
        final msg = messages[i];

        // 确定发送者信息
        String senderRole;
        String senderWxid;
        String senderNickname;
        String senderRemark;

        if (msg.isSend == 1) {
          senderRole = '我';
          senderWxid = sanitizedAccountWxid;
          senderNickname = myDisplayName;
          senderRemark = _getRemarkOrAlias(currentAccountInfo);
        } else if (session.isGroup && msg.senderUsername != null) {
          senderRole = senderDisplayNames[msg.senderUsername] ?? '群成员';
          senderWxid = _sanitizeUsername(msg.senderUsername ?? '');
          final info = senderContactInfos[msg.senderUsername] ?? {};
          senderNickname = _resolvePreferredName(info, fallback: senderRole);
          senderRemark = _getRemarkOrAlias(info);
        } else {
          senderRole = session.displayName ?? session.username;
          senderWxid = _sanitizeUsername(session.username);
          senderNickname = _resolvePreferredName(
            contactInfo,
            fallback: senderRole,
          );
          senderRemark = _getRemarkOrAlias(contactInfo);
        }

        senderWxid = _sanitizeUsername(senderWxid);

        sheet.getRangeByIndex(currentRow, 1).setNumber(i + 1);
        _setTextSafe(sheet, currentRow, 2, msg.formattedCreateTime);
        _setTextSafe(sheet, currentRow, 3, senderNickname);
        _setTextSafe(sheet, currentRow, 4, senderWxid);
        _setTextSafe(sheet, currentRow, 5, senderRemark);
        _setTextSafe(sheet, currentRow, 6, senderRole);
        _setTextSafe(sheet, currentRow, 7, msg.typeDescription);
        _setTextSafe(sheet, currentRow, 8, msg.displayContent);
        currentRow++;

        // 每 500 条报告一次进度
        if ((i + 1) % 500 == 0 || i == messages.length - 1) {
          onProgress?.call(i + 1, totalMessages, '处理消息数据...');
          await Future.delayed(Duration.zero);
        }
      }

      // 自动调整列宽（Syncfusion 使用 1-based 索引）
      sheet.getRangeByIndex(1, 1).columnWidth = 8; // 序号
      sheet.getRangeByIndex(1, 2).columnWidth = 20; // 时间
      sheet.getRangeByIndex(1, 3).columnWidth = 20; // 发送者昵称
      sheet.getRangeByIndex(1, 4).columnWidth = 25; // 发送者微信ID
      sheet.getRangeByIndex(1, 5).columnWidth = 20; // 发送者备注
      sheet.getRangeByIndex(1, 6).columnWidth = 18; // 发送者身份
      sheet.getRangeByIndex(1, 7).columnWidth = 12; // 消息类型
      sheet.getRangeByIndex(1, 8).columnWidth = 50; // 内容

      if (avatars.isNotEmpty) {
        final avatarSheet = workbook.worksheets.addWithName('头像索引');
        _setTextSafe(avatarSheet, 1, 1, '头像ID');
        _setTextSafe(avatarSheet, 1, 2, '显示名称');
        _setTextSafe(avatarSheet, 1, 3, 'Base64');
        int avatarRow = 2;
        avatars.forEach((key, meta) {
          _setTextSafe(avatarSheet, avatarRow, 1, key);
          _setTextSafe(avatarSheet, avatarRow, 2, meta['displayName'] ?? key);
          _setTextSafe(avatarSheet, avatarRow, 3, meta['base64'] ?? '');
          avatarRow++;
        });
        avatarSheet.getRangeByIndex(1, 1).columnWidth = 18;
        avatarSheet.getRangeByIndex(1, 2).columnWidth = 24;
        avatarSheet.getRangeByIndex(1, 3).columnWidth = 80;
      }

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.xlsx';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) {
          workbook.dispose();
          return false;
        }
        filePath = outputFile;
      }

      // 保存工作簿为字节流
      onProgress?.call(totalMessages, totalMessages, '保存工作簿...');
      final List<int> bytes = workbook.saveAsStream();
      workbook.dispose();

      // 使用后台 Isolate 写入文件以避免阻塞 UI
      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      return await _writeBytesInBackground(filePath, Uint8List.fromList(bytes));
    } catch (e) {
      workbook.dispose();
      return false;
    }
  }

  /// 导出聊天记录为 PostgreSQL 格式
  /// [onProgress] 进度回调：(当前处理的消息数, 总消息数, 阶段描述)
  Future<bool> exportToPostgreSQL(
    ChatSession session,
    List<Message> messages, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
  }) async {
    try {
      final totalMessages = messages.length;
      onProgress?.call(0, totalMessages, '准备元数据...');

      // 获取联系人详细信息
      final contactInfo = await _getContactInfo(session.username);

      // 获取所有发送者的显示名称
      final senderUsernameSet = messages
          .where(
            (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
          )
          .map((m) => m.senderUsername!)
          .toSet();

      final rawAccountWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedAccountWxid = rawAccountWxid.trim();
      if (trimmedAccountWxid.isNotEmpty) {
        senderUsernameSet.add(trimmedAccountWxid);
      }
      final currentAccountWxid = _sanitizeUsername(rawAccountWxid);
      if (currentAccountWxid.isNotEmpty) {
        senderUsernameSet.add(currentAccountWxid);
      }
      final senderUsernames = senderUsernameSet.toList();

      final senderDisplayNames = senderUsernames.isNotEmpty
          ? await _databaseService.getDisplayNames(senderUsernames)
          : <String, String>{};

      // 获取所有发送者的详细信息（nickname、remark）
      final senderContactInfos = <String, Map<String, String>>{};
      for (final username in senderUsernames) {
        senderContactInfos[username] = await _getContactInfo(username);
      }

      // 获取当前账户的联系人信息（用于"我"发送的消息）
      final currentAccountInfo = rawAccountWxid.isNotEmpty
          ? await _getContactInfo(rawAccountWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(
        rawAccountWxid,
        currentAccountInfo,
      );
      final sanitizedAccountWxid = currentAccountWxid;
      if (sanitizedAccountWxid.isNotEmpty) {
        senderContactInfos[sanitizedAccountWxid] = currentAccountInfo;
      }
      final rawAccountWxidTrimmed = rawAccountWxid.trim();
      if (rawAccountWxidTrimmed.isNotEmpty) {
        senderContactInfos[rawAccountWxidTrimmed] = currentAccountInfo;
      }

      onProgress?.call(0, totalMessages, '生成 SQL...');
      final buffer = StringBuffer();

      // Add DDL
      buffer.writeln(
        'DROP TABLE IF EXISTS "public"."echotrace"; CREATE TABLE "public"."echotrace" ("id" int4 NOT NULL GENERATED BY DEFAULT AS IDENTITY ( INCREMENT 1 MINVALUE 1 MAXVALUE 2147483647 START 1 CACHE 1 ), "date" date, "time" time(6), "is_send" bool, "content" text COLLATE "pg_catalog"."default", "send_name" varchar(255) COLLATE "pg_catalog"."default", "timestamp" timestamp(6),   CONSTRAINT "echotrace_pkey" PRIMARY KEY ("id") );',
      );
      buffer.writeln();
      buffer.writeln('ALTER TABLE "public"."echotrace" OWNER TO "postgres";');
      buffer.writeln();

      // Add INSERTs
      if (messages.isNotEmpty) {
        buffer.writeln(
          'INSERT INTO "public"."echotrace" ("date", "time", "is_send", "content", "send_name", "timestamp") VALUES',
        );

        for (int i = 0; i < messages.length; i++) {
          final msg = messages[i];

          // 确定发送者信息
          String senderRole;
          String senderNickname;

          if (msg.isSend == 1) {
            senderRole = '我';
            senderNickname = myDisplayName;
          } else if (session.isGroup && msg.senderUsername != null) {
            senderRole = senderDisplayNames[msg.senderUsername] ?? '群成员';
            final info = senderContactInfos[msg.senderUsername] ?? {};
            senderNickname = _resolvePreferredName(info, fallback: senderRole);
          } else {
            senderRole = session.displayName ?? session.username;
            senderNickname = _resolvePreferredName(
              contactInfo,
              fallback: senderRole,
            );
          }

          final dt = DateTime.fromMillisecondsSinceEpoch(msg.createTime * 1000);
          final dateStr =
              '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
          final timeStr =
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
          final isSendBool = msg.isSend == 1 ? 'true' : 'false';
          final contentEscaped = msg.displayContent.replaceAll("'", "''");
          final sendNameEscaped = senderNickname.replaceAll("'", "''");
          final timestampStr = '$dateStr $timeStr';

          buffer.write(
            "('$dateStr', '$timeStr', $isSendBool, '$contentEscaped', '$sendNameEscaped', '$timestampStr')",
          );

          if (i < messages.length - 1) {
            buffer.writeln(',');
          } else {
            buffer.writeln(';');
          }

          // 每 500 条报告一次进度
          if ((i + 1) % 500 == 0 || i == messages.length - 1) {
            onProgress?.call(i + 1, totalMessages, '生成 SQL...');
            await Future.delayed(Duration.zero);
          }
        }
      }

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.sql';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) return false;

        filePath = outputFile;
      }

      // 使用后台 Isolate 写入文件以避免阻塞 UI
      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      return await _writeStringInBackground(filePath, buffer.toString());
    } catch (e) {
      return false;
    }
  }

  /// 流式导出聊天记录为 JSON 格式
  Future<bool> exportToJsonStream(
    ChatSession session, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
    int exportBatchSize = 500,
    int begintimestamp = 0,
    int endTimestamp = 0,
    int totalMessagesHint = 0,
  }) async {
    IOSink? sink;
    try {
      final totalMessages = totalMessagesHint > 0
          ? totalMessagesHint
          : await _safeGetMessageCount(session.username);
      onProgress?.call(0, totalMessages, '准备元数据...');

      final contactInfo = await _getContactInfo(session.username);
      final rawMyWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedMyWxid = rawMyWxid.trim();
      final senderUsernames = <String>{
        if (trimmedMyWxid.isNotEmpty) trimmedMyWxid,
      };
      final myWxid = _sanitizeUsername(rawMyWxid);
      if (myWxid.isNotEmpty) {
        senderUsernames.add(myWxid);
      }

      final senderDisplayNames = <String, String>{};

      final myContactInfo = rawMyWxid.isNotEmpty
          ? await _getContactInfo(rawMyWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(rawMyWxid, myContactInfo);

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.json';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) return false;
        filePath = outputFile;
      }

      final file = File(filePath);
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      sink = file.openWrite();

      final sessionData = {
        'wxid': _sanitizeUsername(session.username),
        'nickname':
            contactInfo['nickname'] ??
            session.displayName ??
            session.username,
        'remark': _getRemarkOrAlias(contactInfo),
        'displayName': session.displayName ?? session.username,
        'type': session.typeDescription,
        'lastTimestamp': session.lastTimestamp,
        'messageCount': totalMessages,
      };
      final exportTime = DateTime.now().toIso8601String();

      sink.writeln('{');
      sink.writeln('  "session": ${jsonEncode(sessionData)},');
      sink.write('  "messages": [');

      var isFirst = true;
      var processed = 0;
      await _databaseService.exportSessionMessages(
        session.username,
        (batch) async {
          final newUsernames = _collectSenderUsernames(
            batch,
            senderUsernames,
            senderDisplayNames,
          );
          await _ensureSenderDisplayNames(newUsernames, senderDisplayNames);
          for (final msg in batch) {
            final item = _buildJsonMessageItem(
              msg: msg,
              session: session,
              contactInfo: contactInfo,
              myContactInfo: myContactInfo,
              senderDisplayNames: senderDisplayNames,
              rawMyWxid: rawMyWxid,
              myDisplayName: myDisplayName,
              myWxid: myWxid,
            );
            final encoded = jsonEncode(item);
            if (!isFirst) {
              sink!.write(',');
            }
            sink!.write('\n    ');
            sink.write(encoded);
            isFirst = false;
            processed += 1;
          }
          onProgress?.call(processed, totalMessages, '处理消息数据...');
        },
        exportBatchSize: exportBatchSize,
        begintimestamp: begintimestamp,
        endTimestamp: endTimestamp,
      );

      onProgress?.call(totalMessages, totalMessages, '构建头像索引...');
      final avatars = await _buildAvatarIndexFromUsernames(
        session: session,
        senderUsernames: senderUsernames,
        contactInfo: contactInfo,
        senderDisplayNames: senderDisplayNames,
        rawMyWxid: rawMyWxid,
        myDisplayName: myDisplayName,
      );

      sink.write('\n  ],\n');
      sink.writeln('  "avatars": ${jsonEncode(avatars)},');
      sink.writeln('  "exportTime": "$exportTime"');
      sink.writeln('}');

      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      await sink.flush();
      return true;
    } catch (e, stack) {
      await logger.error('ChatExportService', 'exportToJsonStream 失败: $e\n$stack');
      return false;
    } finally {
      await sink?.close();
    }
  }

  /// 流式导出聊天记录为 HTML 格式
  Future<bool> exportToHtmlStream(
    ChatSession session, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
    int exportBatchSize = 500,
    int begintimestamp = 0,
    int endTimestamp = 0,
    int totalMessagesHint = 0,
  }) async {
    IOSink? sink;
    try {
      final totalMessages = totalMessagesHint > 0
          ? totalMessagesHint
          : await _safeGetMessageCount(session.username);
      onProgress?.call(0, totalMessages, '准备元数据...');

      final contactInfo = await _getContactInfo(session.username);
      final rawMyWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedMyWxid = rawMyWxid.trim();
      final senderUsernames = <String>{
        if (trimmedMyWxid.isNotEmpty) trimmedMyWxid,
      };
      final myWxid = _sanitizeUsername(rawMyWxid);
      if (myWxid.isNotEmpty) {
        senderUsernames.add(myWxid);
      }

      final senderDisplayNames = <String, String>{};

      final myContactInfo = rawMyWxid.isNotEmpty
          ? await _getContactInfo(rawMyWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(rawMyWxid, myContactInfo);

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.html';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) return false;
        filePath = outputFile;
      }

      final file = File(filePath);
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      sink = file.openWrite();

      final exportTime = DateTime.now().toString().split('.')[0];
      sink.write(
        _buildHtmlHeaderStream(
          session: session,
          contactInfo: contactInfo,
          totalMessages: totalMessages,
          exportTime: exportTime,
        ),
      );

      var isFirst = true;
      var processed = 0;
      await _databaseService.exportSessionMessages(
        session.username,
        (batch) async {
          final newUsernames = _collectSenderUsernames(
            batch,
            senderUsernames,
            senderDisplayNames,
          );
          await _ensureSenderDisplayNames(newUsernames, senderDisplayNames);
          for (final msg in batch) {
            final item = _buildHtmlMessageData(
              msg: msg,
              session: session,
              senderDisplayNames: senderDisplayNames,
              myWxid: myWxid,
              contactInfo: contactInfo,
              myDisplayName: myDisplayName,
            );
            final encoded = jsonEncode(item);
            if (!isFirst) {
              sink!.write(',');
            }
            sink!.write('\n    ');
            sink.write(encoded);
            isFirst = false;
            processed += 1;
          }
          onProgress?.call(processed, totalMessages, '处理消息数据...');
        },
        exportBatchSize: exportBatchSize,
        begintimestamp: begintimestamp,
        endTimestamp: endTimestamp,
      );

      onProgress?.call(totalMessages, totalMessages, '构建头像索引...');
      final avatars = await _buildAvatarIndexFromUsernames(
        session: session,
        senderUsernames: senderUsernames,
        contactInfo: contactInfo,
        senderDisplayNames: senderDisplayNames,
        rawMyWxid: rawMyWxid,
        myDisplayName: myDisplayName,
      );

      sink.write('\n  ];\n');
      sink.write(_buildHtmlFooterStream(avatars));

      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      await sink.flush();
      return true;
    } catch (e, stack) {
      await logger.error('ChatExportService', 'exportToHtmlStream 失败: $e\n$stack');
      return false;
    } finally {
      await sink?.close();
    }
  }

  /// 流式导出聊天记录为 Excel 格式
  Future<bool> exportToExcelStream(
    ChatSession session, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
    int exportBatchSize = 500,
    int begintimestamp = 0,
    int endTimestamp = 0,
    int totalMessagesHint = 0,
  }) async {
    final Workbook workbook = Workbook();
    try {
      final totalMessages = totalMessagesHint > 0
          ? totalMessagesHint
          : await _safeGetMessageCount(session.username);
      onProgress?.call(0, totalMessages, '准备工作簿...');

      final contactInfo = await _getContactInfo(session.username);

      Worksheet sheet;
      if (workbook.worksheets.count > 0) {
        sheet = workbook.worksheets[0];
        sheet.name = '聊天记录';
      } else {
        sheet = workbook.worksheets.addWithName('聊天记录');
      }
      int currentRow = 1;

      _setTextSafe(sheet, currentRow, 1, '会话信息');
      currentRow++;

      _setTextSafe(sheet, currentRow, 1, '微信ID');
      _setTextSafe(sheet, currentRow, 2, _sanitizeUsername(session.username));
      _setTextSafe(sheet, currentRow, 3, '昵称');
      _setTextSafe(sheet, currentRow, 4, contactInfo['nickname'] ?? '');
      _setTextSafe(sheet, currentRow, 5, '备注');
      _setTextSafe(sheet, currentRow, 6, _getRemarkOrAlias(contactInfo));
      currentRow++;
      currentRow++;

      _setTextSafe(sheet, currentRow, 1, '序号');
      _setTextSafe(sheet, currentRow, 2, '时间');
      _setTextSafe(sheet, currentRow, 3, '发送者昵称');
      _setTextSafe(sheet, currentRow, 4, '发送者微信ID');
      _setTextSafe(sheet, currentRow, 5, '发送者备注');
      _setTextSafe(sheet, currentRow, 6, '发送者身份');
      _setTextSafe(sheet, currentRow, 7, '消息类型');
      _setTextSafe(sheet, currentRow, 8, '内容');
      currentRow++;

      final rawAccountWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedAccountWxid = rawAccountWxid.trim();
      final senderUsernames = <String>{
        if (trimmedAccountWxid.isNotEmpty) trimmedAccountWxid,
      };
      final currentAccountWxid = _sanitizeUsername(rawAccountWxid);
      if (currentAccountWxid.isNotEmpty) {
        senderUsernames.add(currentAccountWxid);
      }

      final senderDisplayNames = <String, String>{};

      final senderContactInfos = <String, Map<String, String>>{};

      final currentAccountInfo = rawAccountWxid.isNotEmpty
          ? await _getContactInfo(rawAccountWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(
        rawAccountWxid,
        currentAccountInfo,
      );
      if (currentAccountWxid.isNotEmpty) {
        senderContactInfos[currentAccountWxid] = currentAccountInfo;
      }
      if (trimmedAccountWxid.isNotEmpty) {
        senderContactInfos[trimmedAccountWxid] = currentAccountInfo;
      }

      var index = 0;
      await _databaseService.exportSessionMessages(
        session.username,
        (batch) async {
          final newUsernames = _collectSenderUsernames(
            batch,
            senderUsernames,
            senderDisplayNames,
          );
          await _ensureSenderDisplayNames(newUsernames, senderDisplayNames);
          await _ensureSenderContactInfos(newUsernames, senderContactInfos);
          for (final msg in batch) {
            index += 1;
            String senderRole;
            String senderWxid;
            String senderNickname;
            String senderRemark;

            if (msg.isSend == 1) {
              senderRole = '我';
              senderWxid = currentAccountWxid;
              senderNickname = myDisplayName;
              senderRemark = _getRemarkOrAlias(currentAccountInfo);
            } else if (session.isGroup && msg.senderUsername != null) {
              senderRole = senderDisplayNames[msg.senderUsername] ?? '群成员';
              senderWxid = _sanitizeUsername(msg.senderUsername ?? '');
              final info = senderContactInfos[msg.senderUsername] ?? {};
              senderNickname = _resolvePreferredName(info, fallback: senderRole);
              senderRemark = _getRemarkOrAlias(info);
            } else {
              senderRole = session.displayName ?? session.username;
              senderWxid = _sanitizeUsername(session.username);
              senderNickname = _resolvePreferredName(
                contactInfo,
                fallback: senderRole,
              );
              senderRemark = _getRemarkOrAlias(contactInfo);
            }

            senderWxid = _sanitizeUsername(senderWxid);

            sheet.getRangeByIndex(currentRow, 1).setNumber(index.toDouble());
            _setTextSafe(sheet, currentRow, 2, msg.formattedCreateTime);
            _setTextSafe(sheet, currentRow, 3, senderNickname);
            _setTextSafe(sheet, currentRow, 4, senderWxid);
            _setTextSafe(sheet, currentRow, 5, senderRemark);
            _setTextSafe(sheet, currentRow, 6, senderRole);
            _setTextSafe(sheet, currentRow, 7, msg.typeDescription);
            _setTextSafe(sheet, currentRow, 8, msg.displayContent);
            currentRow++;
          }

          if (index % 500 == 0) {
            onProgress?.call(index, totalMessages, '处理消息数据...');
          }
        },
        exportBatchSize: exportBatchSize,
        begintimestamp: begintimestamp,
        endTimestamp: endTimestamp,
      );
      onProgress?.call(index, totalMessages, '处理消息数据...');

      final avatars = await _buildAvatarIndexFromUsernames(
        session: session,
        senderUsernames: senderUsernames,
        contactInfo: contactInfo,
        senderDisplayNames: senderDisplayNames,
        rawMyWxid: rawAccountWxid,
        myDisplayName: myDisplayName,
      );

      sheet.getRangeByIndex(1, 1).columnWidth = 8;
      sheet.getRangeByIndex(1, 2).columnWidth = 20;
      sheet.getRangeByIndex(1, 3).columnWidth = 20;
      sheet.getRangeByIndex(1, 4).columnWidth = 25;
      sheet.getRangeByIndex(1, 5).columnWidth = 20;
      sheet.getRangeByIndex(1, 6).columnWidth = 18;
      sheet.getRangeByIndex(1, 7).columnWidth = 12;
      sheet.getRangeByIndex(1, 8).columnWidth = 50;

      if (avatars.isNotEmpty) {
        final avatarSheet = workbook.worksheets.addWithName('头像索引');
        _setTextSafe(avatarSheet, 1, 1, '头像ID');
        _setTextSafe(avatarSheet, 1, 2, '显示名称');
        _setTextSafe(avatarSheet, 1, 3, 'Base64');
        int avatarRow = 2;
        avatars.forEach((key, meta) {
          _setTextSafe(avatarSheet, avatarRow, 1, key);
          _setTextSafe(avatarSheet, avatarRow, 2, meta['displayName'] ?? key);
          _setTextSafe(avatarSheet, avatarRow, 3, meta['base64'] ?? '');
          avatarRow++;
        });
        avatarSheet.getRangeByIndex(1, 1).columnWidth = 18;
        avatarSheet.getRangeByIndex(1, 2).columnWidth = 24;
        avatarSheet.getRangeByIndex(1, 3).columnWidth = 80;
      }

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.xlsx';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) {
          workbook.dispose();
          return false;
        }
        filePath = outputFile;
      }

      onProgress?.call(index, totalMessages, '保存工作簿...');
      final List<int> bytes = workbook.saveAsStream();
      workbook.dispose();

      onProgress?.call(index, totalMessages, '写入文件...');
      return await _writeBytesInBackground(filePath, Uint8List.fromList(bytes));
    } catch (e, stack) {
      workbook.dispose();
      await logger.error('ChatExportService', 'exportToExcelStream 失败: $e\n$stack');
      return false;
    }
  }

  /// 流式导出聊天记录为 PostgreSQL 格式
  Future<bool> exportToPostgreSQLStream(
    ChatSession session, {
    String? filePath,
    void Function(int current, int total, String stage)? onProgress,
    int exportBatchSize = 500,
    int begintimestamp = 0,
    int endTimestamp = 0,
    int totalMessagesHint = 0,
  }) async {
    IOSink? sink;
    try {
      final totalMessages = totalMessagesHint > 0
          ? totalMessagesHint
          : await _safeGetMessageCount(session.username);
      onProgress?.call(0, totalMessages, '准备元数据...');

      final contactInfo = await _getContactInfo(session.username);
      final rawAccountWxid = _databaseService.currentAccountWxid ?? '';
      final trimmedAccountWxid = rawAccountWxid.trim();
      final senderUsernames = <String>{
        if (trimmedAccountWxid.isNotEmpty) trimmedAccountWxid,
      };
      final currentAccountWxid = _sanitizeUsername(rawAccountWxid);
      if (currentAccountWxid.isNotEmpty) {
        senderUsernames.add(currentAccountWxid);
      }

      final senderDisplayNames = <String, String>{};

      final senderContactInfos = <String, Map<String, String>>{};

      final currentAccountInfo = rawAccountWxid.isNotEmpty
          ? await _getContactInfo(rawAccountWxid)
          : <String, String>{};
      final myDisplayName = await _buildMyDisplayName(
        rawAccountWxid,
        currentAccountInfo,
      );
      if (currentAccountWxid.isNotEmpty) {
        senderContactInfos[currentAccountWxid] = currentAccountInfo;
      }
      if (trimmedAccountWxid.isNotEmpty) {
        senderContactInfos[trimmedAccountWxid] = currentAccountInfo;
      }

      if (filePath == null) {
        final suggestedName =
            '${session.displayName ?? session.username}_聊天记录_${DateTime.now().millisecondsSinceEpoch}.sql';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '保存聊天记录',
          fileName: suggestedName,
        );
        if (outputFile == null) return false;
        filePath = outputFile;
      }

      final file = File(filePath);
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      sink = file.openWrite();

      sink.writeln(
        'DROP TABLE IF EXISTS "public"."echotrace"; CREATE TABLE "public"."echotrace" ("id" int4 NOT NULL GENERATED BY DEFAULT AS IDENTITY ( INCREMENT 1 MINVALUE 1 MAXVALUE 2147483647 START 1 CACHE 1 ), "date" date, "time" time(6), "is_send" bool, "content" text COLLATE "pg_catalog"."default", "send_name" varchar(255) COLLATE "pg_catalog"."default", "timestamp" timestamp(6),   CONSTRAINT "echotrace_pkey" PRIMARY KEY ("id") );',
      );
      sink.writeln();
      sink.writeln('ALTER TABLE "public"."echotrace" OWNER TO "postgres";');
      sink.writeln();

      if (totalMessages > 0) {
        sink.writeln(
          'INSERT INTO "public"."echotrace" ("date", "time", "is_send", "content", "send_name", "timestamp") VALUES',
        );
      }

      var processed = 0;
      var isFirst = true;
      await _databaseService.exportSessionMessages(
        session.username,
        (batch) async {
          final newUsernames = _collectSenderUsernames(
            batch,
            senderUsernames,
            senderDisplayNames,
          );
          await _ensureSenderDisplayNames(newUsernames, senderDisplayNames);
          await _ensureSenderContactInfos(newUsernames, senderContactInfos);
          for (final msg in batch) {
            String senderRole;
            String senderNickname;

            if (msg.isSend == 1) {
              senderRole = '我';
              senderNickname = myDisplayName;
            } else if (session.isGroup && msg.senderUsername != null) {
              senderRole = senderDisplayNames[msg.senderUsername] ?? '群成员';
              final info = senderContactInfos[msg.senderUsername] ?? {};
              senderNickname = _resolvePreferredName(info, fallback: senderRole);
            } else {
              senderRole = session.displayName ?? session.username;
              senderNickname = _resolvePreferredName(
                contactInfo,
                fallback: senderRole,
              );
            }

            final dt = DateTime.fromMillisecondsSinceEpoch(
              msg.createTime * 1000,
            );
            final dateStr =
                '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
            final timeStr =
                '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
            final isSendBool = msg.isSend == 1 ? 'true' : 'false';
            final contentEscaped = msg.displayContent.replaceAll("'", "''");
            final sendNameEscaped = senderNickname.replaceAll("'", "''");
            final timestampStr = '$dateStr $timeStr';

            final line =
                "('$dateStr', '$timeStr', $isSendBool, '$contentEscaped', '$sendNameEscaped', '$timestampStr')";
            if (!isFirst) {
              sink!.writeln(',');
            }
            sink!.write(line);
            isFirst = false;
            processed += 1;
          }
          onProgress?.call(processed, totalMessages, '生成 SQL...');
        },
        exportBatchSize: exportBatchSize,
        begintimestamp: begintimestamp,
        endTimestamp: endTimestamp,
      );

      if (totalMessages > 0) {
        sink.writeln(';');
      }

      await sink.flush();
      onProgress?.call(totalMessages, totalMessages, '写入文件...');
      return true;
    } catch (e, stack) {
      await logger.error(
        'ChatExportService',
        'exportToPostgreSQLStream 失败: $e\n$stack',
      );
      return false;
    } finally {
      await sink?.close();
    }
  }

  /// 生成 HTML 内容
  String _generateHtml(
    ChatSession session,
    List<Message> messages,
    Map<String, String> senderDisplayNames,
    String myWxid,
    Map<String, String> contactInfo,
    String myDisplayName,
    Map<String, Map<String, String>> avatarIndex,
  ) {
    final buffer = StringBuffer();

    // 构建消息数据
    final messagesData = messages.map((msg) {
      final msgDate = DateTime.fromMillisecondsSinceEpoch(
        msg.createTime * 1000,
      );
      final isSend = msg.isSend == 1;

      String senderName = '';
      if (!isSend && session.isGroup && msg.senderUsername != null) {
        senderName = senderDisplayNames[msg.senderUsername] ?? '群成员';
      } else if (!isSend) {
        senderName = _resolvePreferredName(
          contactInfo,
          fallback: session.displayName ?? session.username,
        );
      } else {
        senderName = myDisplayName;
      }
      final avatarKey = _resolveSenderUsername(
        msg: msg,
        session: session,
        isSend: isSend,
        myWxid: myWxid,
      );

      return {
        'date':
            '${msgDate.year}-${msgDate.month.toString().padLeft(2, '0')}-${msgDate.day.toString().padLeft(2, '0')}',
        'time':
            '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}:${msgDate.second.toString().padLeft(2, '0')}',
        'isSend': isSend,
        'content': msg.displayContent,
        'senderName': senderName,
        'timestamp': msg.createTime,
        'avatarKey': avatarKey.isEmpty ? null : avatarKey,
      };
    }).toList();

    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln('<html lang="zh-CN">');
    buffer.writeln('<head>');
    buffer.writeln('  <meta charset="UTF-8">');
    buffer.writeln(
      '  <meta name="viewport" content="width=device-width, initial-scale=1.0">',
    );
    buffer.writeln(
      '  <title>${_escapeHtml(session.displayName ?? session.username)} - 聊天记录</title>',
    );
    buffer.writeln('  <style>');
    buffer.writeln(_getHtmlStyles());
    buffer.writeln('  </style>');
    buffer.writeln('</head>');
    buffer.writeln('<body>');
    buffer.writeln('  <div class="container">');
    buffer.writeln('    <div class="header">');
    buffer.writeln('      <div class="header-main">');
    buffer.writeln(
      '        <h1>${_escapeHtml(session.displayName ?? session.username)}</h1>',
    );

    // 添加详细信息菜单按钮
    final nickname = contactInfo['nickname'] ?? '';
    final remark = _getRemarkOrAlias(contactInfo);
    final sanitizedSessionWxid = _sanitizeUsername(session.username);
    final hasDetails =
        nickname.isNotEmpty ||
        remark.isNotEmpty ||
        sanitizedSessionWxid.isNotEmpty;

    if (hasDetails) {
      buffer.writeln(
        '        <button class="info-menu-btn" id="info-menu-btn" type="button" title="查看详细信息">',
      );
      buffer.writeln(
        '          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">',
      );
      buffer.writeln('            <circle cx="12" cy="12" r="1"></circle>');
      buffer.writeln('            <circle cx="12" cy="5" r="1"></circle>');
      buffer.writeln('            <circle cx="12" cy="19" r="1"></circle>');
      buffer.writeln('          </svg>');
      buffer.writeln('        </button>');
      buffer.writeln('      </div>');

      // 详细信息下拉菜单
      buffer.writeln('      <div class="info-menu" id="info-menu">');
      buffer.writeln('        <div class="info-menu-content">');
      if (sanitizedSessionWxid.isNotEmpty) {
        buffer.writeln('          <div class="info-item">');
        buffer.writeln('            <span class="info-label">微信ID</span>');
        buffer.writeln(
          '            <span class="info-value">${_escapeHtml(sanitizedSessionWxid)}</span>',
        );
        buffer.writeln('          </div>');
      }
      if (nickname.isNotEmpty) {
        buffer.writeln('          <div class="info-item">');
        buffer.writeln('            <span class="info-label">昵称</span>');
        buffer.writeln(
          '            <span class="info-value">${_escapeHtml(nickname)}</span>',
        );
        buffer.writeln('          </div>');
      }
      if (remark.isNotEmpty) {
        buffer.writeln('          <div class="info-item">');
        buffer.writeln('            <span class="info-label">备注</span>');
        buffer.writeln(
          '            <span class="info-value">${_escapeHtml(remark)}</span>',
        );
        buffer.writeln('          </div>');
      }
      buffer.writeln('        </div>');
      buffer.writeln('      </div>');
    } else {
      buffer.writeln('      </div>');
    }

    buffer.writeln('      <div class="info">');
    buffer.writeln('        <span>${session.typeDescription}</span>');
    buffer.writeln('        <span>共 ${messages.length} 条消息</span>');
    buffer.writeln(
      '        <span>导出时间: ${DateTime.now().toString().split('.')[0]}</span>',
    );
    buffer.writeln('      </div>');
    buffer.writeln('    </div>');
    buffer.writeln('    <div class="messages" id="messages-container">');
    buffer.writeln('      <div class="loading">正在加载消息...</div>');
    buffer.writeln('    </div>');
    buffer.writeln(
      '    <div class="scroll-to-bottom" id="scroll-to-bottom" title="回到底部">↓</div>',
    );
    buffer.writeln('  </div>');

    // 将消息数据嵌入为JSON
    buffer.writeln('  <script>');
    buffer.writeln('    const messagesData = ${jsonEncode(messagesData)};');
    buffer.writeln('    const avatarIndex = ${jsonEncode(avatarIndex)};');
    buffer.writeln('    const INITIAL_BATCH = 100; // 首次加载最新100条');
    buffer.writeln('    const BATCH_SIZE = 200; // 后续每批200条');
    buffer.writeln('    let loadedStart = messagesData.length; // 从末尾开始加载');
    buffer.writeln('    let isLoading = false;');
    buffer.writeln('    let allLoaded = false;');
    buffer.writeln('    ');
    buffer.writeln('    function createMessageElement(msg, showDate) {');
    buffer.writeln('      const fragment = document.createDocumentFragment();');
    buffer.writeln('      ');
    buffer.writeln('      // 日期分隔符');
    buffer.writeln('      if (showDate) {');
    buffer.writeln('        const dateSep = document.createElement("div");');
    buffer.writeln('        dateSep.className = "date-separator";');
    buffer.writeln('        dateSep.textContent = msg.date;');
    buffer.writeln('        fragment.appendChild(dateSep);');
    buffer.writeln('      }');
    buffer.writeln('      ');
    buffer.writeln('      // 消息项');
    buffer.writeln('      const messageItem = document.createElement("div");');
    buffer.writeln(
      '      messageItem.className = msg.isSend ? "message-item sent" : "message-item received";',
    );
    buffer.writeln('      ');
    buffer.writeln('      // 发送者名称');
    buffer.writeln('      if (msg.senderName) {');
    buffer.writeln('        const senderName = document.createElement("div");');
    buffer.writeln('        senderName.className = "sender-name";');
    buffer.writeln('        senderName.textContent = msg.senderName;');
    buffer.writeln('        messageItem.appendChild(senderName);');
    buffer.writeln('      }');
    buffer.writeln('      ');
    buffer.writeln('      // 消息气泡');
    buffer.writeln('      const bubble = document.createElement("div");');
    buffer.writeln('      bubble.className = "message-bubble";');
    buffer.writeln('      ');
    buffer.writeln('      const content = document.createElement("div");');
    buffer.writeln('      content.className = "content";');
    buffer.writeln('      content.textContent = msg.content;');
    buffer.writeln('      bubble.appendChild(content);');
    buffer.writeln('      ');
    buffer.writeln('      const time = document.createElement("div");');
    buffer.writeln('      time.className = "time";');
    buffer.writeln('      time.textContent = msg.time;');
    buffer.writeln('      bubble.appendChild(time);');
    buffer.writeln('      ');
    buffer.writeln('      messageItem.appendChild(bubble);');
    buffer.writeln('      fragment.appendChild(messageItem);');
    buffer.writeln('      ');
    buffer.writeln('      return fragment;');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function loadInitialMessages() {');
    buffer.writeln(
      '      const container = document.getElementById("messages-container");',
    );
    buffer.writeln(
      '      const loading = container.querySelector(".loading");',
    );
    buffer.writeln('      if (loading) loading.remove();');
    buffer.writeln('      ');
    buffer.writeln('      // 加载最新的消息');
    buffer.writeln(
      '      const start = Math.max(0, messagesData.length - INITIAL_BATCH);',
    );
    buffer.writeln('      const fragment = document.createDocumentFragment();');
    buffer.writeln('      let lastDate = null;');
    buffer.writeln('      ');
    buffer.writeln('      for (let i = start; i < messagesData.length; i++) {');
    buffer.writeln('        const msg = messagesData[i];');
    buffer.writeln('        const showDate = msg.date !== lastDate;');
    buffer.writeln(
      '        fragment.appendChild(createMessageElement(msg, showDate));',
    );
    buffer.writeln('        lastDate = msg.date;');
    buffer.writeln('      }');
    buffer.writeln('      ');
    buffer.writeln('      container.appendChild(fragment);');
    buffer.writeln('      loadedStart = start;');
    buffer.writeln('      allLoaded = loadedStart === 0;');
    buffer.writeln('      ');
    buffer.writeln('      // 立即滚动到底部');
    buffer.writeln('      container.scrollTop = container.scrollHeight;');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function loadMoreMessages() {');
    buffer.writeln('      if (isLoading || allLoaded) return;');
    buffer.writeln('      ');
    buffer.writeln('      isLoading = true;');
    buffer.writeln(
      '      const container = document.getElementById("messages-container");',
    );
    buffer.writeln('      const oldHeight = container.scrollHeight;');
    buffer.writeln('      const oldScroll = container.scrollTop;');
    buffer.writeln('      ');
    buffer.writeln('      // 加载更早的消息');
    buffer.writeln(
      '      const start = Math.max(0, loadedStart - BATCH_SIZE);',
    );
    buffer.writeln('      const fragment = document.createDocumentFragment();');
    buffer.writeln('      let lastDate = null;');
    buffer.writeln('      ');
    buffer.writeln('      for (let i = start; i < loadedStart; i++) {');
    buffer.writeln('        const msg = messagesData[i];');
    buffer.writeln('        const showDate = msg.date !== lastDate;');
    buffer.writeln(
      '        fragment.appendChild(createMessageElement(msg, showDate));',
    );
    buffer.writeln('        lastDate = msg.date;');
    buffer.writeln('      }');
    buffer.writeln('      ');
    buffer.writeln(
      '      container.insertBefore(fragment, container.firstChild);',
    );
    buffer.writeln('      loadedStart = start;');
    buffer.writeln('      allLoaded = loadedStart === 0;');
    buffer.writeln('      ');
    buffer.writeln('      // 保持滚动位置');
    buffer.writeln(
      '      container.scrollTop = oldScroll + (container.scrollHeight - oldHeight);',
    );
    buffer.writeln('      isLoading = false;');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    // 滚动监听');
    buffer.writeln(
      '    const scrollBtn = document.getElementById("scroll-to-bottom");',
    );
    buffer.writeln(
      '    const messagesContainer = document.getElementById("messages-container");',
    );
    buffer.writeln('    ');
    buffer.writeln('    messagesContainer.addEventListener("scroll", () => {');
    buffer.writeln('      // 接近顶部时加载更多历史消息');
    buffer.writeln(
      '      if (messagesContainer.scrollTop < 200 && !allLoaded) {',
    );
    buffer.writeln('        loadMoreMessages();');
    buffer.writeln('      }');
    buffer.writeln('      ');
    buffer.writeln('      // 显示/隐藏回到底部按钮');
    buffer.writeln(
      '      const isBottom = messagesContainer.scrollHeight - messagesContainer.scrollTop <= messagesContainer.clientHeight + 100;',
    );
    buffer.writeln(
      '      scrollBtn.style.display = isBottom ? "none" : "flex";',
    );
    buffer.writeln('    });');
    buffer.writeln('    ');
    buffer.writeln('    scrollBtn.addEventListener("click", () => {');
    buffer.writeln(
      '      messagesContainer.scrollTo({ top: messagesContainer.scrollHeight, behavior: "smooth" });',
    );
    buffer.writeln('    });');
    buffer.writeln('    ');
    buffer.writeln('    // 详细信息菜单控制');
    buffer.writeln('    function toggleInfoMenu() {');
    buffer.writeln('      const menu = document.getElementById("info-menu");');
    buffer.writeln('      if (!menu) return;');
    buffer.writeln('      menu.classList.toggle("show");');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function hideInfoMenu() {');
    buffer.writeln('      const menu = document.getElementById("info-menu");');
    buffer.writeln('      if (menu) {');
    buffer.writeln('        menu.classList.remove("show");');
    buffer.writeln('      }');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    // 点击外部关闭菜单');
    buffer.writeln('    document.addEventListener("click", (e) => {');
    buffer.writeln('      const menu = document.getElementById("info-menu");');
    buffer.writeln(
      '      const btn = document.getElementById("info-menu-btn");',
    );
    buffer.writeln(
      '      if (menu && btn && !menu.contains(e.target) && !btn.contains(e.target)) {',
    );
    buffer.writeln('        menu.classList.remove("show");');
    buffer.writeln('      }');
    buffer.writeln('    });');
    buffer.writeln('    ');
    buffer.writeln(
      '    const infoMenuBtn = document.getElementById("info-menu-btn");',
    );
    buffer.writeln('    if (infoMenuBtn) {');
    buffer.writeln('      infoMenuBtn.addEventListener("click", (event) => {');
    buffer.writeln('        event.stopPropagation();');
    buffer.writeln('        toggleInfoMenu();');
    buffer.writeln('      });');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    // 初始加载');
    buffer.writeln('    window.addEventListener("DOMContentLoaded", () => {');
    buffer.writeln('      loadInitialMessages();');
    buffer.writeln('    });');
    buffer.writeln('  </script>');
    buffer.writeln('</body>');
    buffer.writeln('</html>');

    return buffer.toString();
  }

  Set<String> _collectSenderUsernames(
    List<Message> batch,
    Set<String> senderUsernames,
    Map<String, String> senderDisplayNames,
  ) {
    final newUsernames = <String>{};
    for (final msg in batch) {
      final username = msg.senderUsername;
      if (username == null || username.trim().isEmpty) {
        continue;
      }
      senderUsernames.add(username);
      if (!senderDisplayNames.containsKey(username)) {
        newUsernames.add(username);
      }
    }
    return newUsernames;
  }

  Future<void> _ensureSenderDisplayNames(
    Set<String> newUsernames,
    Map<String, String> senderDisplayNames,
  ) async {
    if (newUsernames.isEmpty) return;
    try {
      final names = await _databaseService.getDisplayNames(
        newUsernames.toList(),
      );
      senderDisplayNames.addAll(names);
    } catch (_) {}
  }

  Future<void> _ensureSenderContactInfos(
    Set<String> newUsernames,
    Map<String, Map<String, String>> senderContactInfos,
  ) async {
    if (newUsernames.isEmpty) return;
    final futures = <Future<void>>[];
    for (final username in newUsernames) {
      if (senderContactInfos.containsKey(username)) continue;
      futures.add(
        _getContactInfo(username).then((info) {
          senderContactInfos[username] = info;
        }),
      );
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  Future<Map<String, Map<String, String>>> _buildAvatarIndexFromUsernames({
    required ChatSession session,
    required Set<String> senderUsernames,
    required Map<String, String> contactInfo,
    required Map<String, String> senderDisplayNames,
    required String rawMyWxid,
    required String myDisplayName,
  }) async {
    final targets = <String>{
      session.username,
      rawMyWxid,
      ...senderUsernames,
    }..removeWhere((u) => u.trim().isEmpty);

    if (targets.isEmpty) return {};

    final avatarUrls = await _databaseService.getAvatarUrls(targets.toList());
    if (avatarUrls.isEmpty) {
      return {};
    }

    final base64ByKey = <String, String>{};
    for (final entry in avatarUrls.entries) {
      final key = _sanitizeUsername(entry.key);
      if (key.isEmpty) continue;
      final encoded = await _loadAvatarBase64(entry.value);
      if (encoded != null && encoded.isNotEmpty) {
        base64ByKey[key] = encoded;
      }
    }

    if (base64ByKey.isEmpty) {
      return {};
    }

    final nameByKey = <String, String>{};
    void assignName(String username, String value) {
      final key = _sanitizeUsername(username);
      if (key.isEmpty || nameByKey.containsKey(key)) return;
      final trimmed = value.trim();
      nameByKey[key] = trimmed.isEmpty ? key : trimmed;
    }

    assignName(
      session.username,
      _resolvePreferredName(
        contactInfo,
        fallback: session.displayName ?? session.username,
      ),
    );
    if (rawMyWxid.trim().isNotEmpty) {
      assignName(rawMyWxid, myDisplayName);
    }
    senderDisplayNames.forEach((username, display) {
      assignName(username, display);
    });
    base64ByKey.keys
        .where((key) => !nameByKey.containsKey(key))
        .forEach((key) => nameByKey[key] = key);

    final merged = <String, Map<String, String>>{};
    base64ByKey.forEach((key, value) {
      merged[key] = {'displayName': nameByKey[key] ?? key, 'base64': value};
    });

    return merged;
  }

  Map<String, dynamic> _buildJsonMessageItem({
    required Message msg,
    required ChatSession session,
    required Map<String, String> contactInfo,
    required Map<String, String> myContactInfo,
    required Map<String, String> senderDisplayNames,
    required String rawMyWxid,
    required String myDisplayName,
    required String myWxid,
  }) {
    final isSend = msg.isSend == 1;
    final senderName = _resolveSenderDisplayName(
      msg: msg,
      session: session,
      isSend: isSend,
      contactInfo: contactInfo,
      myContactInfo: myContactInfo,
      senderDisplayNames: senderDisplayNames,
      myDisplayName: myDisplayName,
    );
    final senderWxid = _resolveSenderUsername(
      msg: msg,
      session: session,
      isSend: isSend,
      myWxid: myWxid,
    );

    final item = <String, dynamic>{
      'localId': msg.localId,
      'createTime': msg.createTime,
      'formattedTime': msg.formattedCreateTime,
      'type': msg.typeDescription,
      'localType': msg.localType,
      'content': msg.displayContent,
      'isSend': msg.isSend,
      'senderUsername': senderWxid.isEmpty ? null : senderWxid,
      'senderDisplayName': senderName,
      'senderAvatarKey': senderWxid.isEmpty ? null : senderWxid,
      'source': msg.source,
    };

    if (msg.localType == 47) {
      item['emojiMd5'] = msg.emojiMd5;
    }

    return item;
  }

  Map<String, dynamic> _buildHtmlMessageData({
    required Message msg,
    required ChatSession session,
    required Map<String, String> senderDisplayNames,
    required String myWxid,
    required Map<String, String> contactInfo,
    required String myDisplayName,
  }) {
    final msgDate = DateTime.fromMillisecondsSinceEpoch(
      msg.createTime * 1000,
    );
    final isSend = msg.isSend == 1;

    String senderName = '';
    if (!isSend && session.isGroup && msg.senderUsername != null) {
      senderName = senderDisplayNames[msg.senderUsername] ?? '群成员';
    } else if (!isSend) {
      senderName = _resolvePreferredName(
        contactInfo,
        fallback: session.displayName ?? session.username,
      );
    } else {
      senderName = myDisplayName;
    }
    final avatarKey = _resolveSenderUsername(
      msg: msg,
      session: session,
      isSend: isSend,
      myWxid: myWxid,
    );

    return {
      'date':
          '${msgDate.year}-${msgDate.month.toString().padLeft(2, '0')}-${msgDate.day.toString().padLeft(2, '0')}',
      'time':
          '${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}:${msgDate.second.toString().padLeft(2, '0')}',
      'isSend': isSend,
      'content': msg.displayContent,
      'senderName': senderName,
      'timestamp': msg.createTime,
      'avatarKey': avatarKey.isEmpty ? null : avatarKey,
    };
  }

  String _buildHtmlHeaderStream({
    required ChatSession session,
    required Map<String, String> contactInfo,
    required int totalMessages,
    required String exportTime,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln('<html lang="zh-CN">');
    buffer.writeln('<head>');
    buffer.writeln('  <meta charset="UTF-8">');
    buffer.writeln(
      '  <meta name="viewport" content="width=device-width, initial-scale=1.0">',
    );
    buffer.writeln(
      '  <title>${_escapeHtml(session.displayName ?? session.username)} - 聊天记录</title>',
    );
    buffer.writeln('  <style>');
    buffer.writeln(_getHtmlStyles());
    buffer.writeln('  </style>');
    buffer.writeln('</head>');
    buffer.writeln('<body>');
    buffer.writeln('  <div class="container">');
    buffer.writeln('    <div class="header">');
    buffer.writeln('      <div class="header-main">');
    buffer.writeln(
      '        <h1>${_escapeHtml(session.displayName ?? session.username)}</h1>',
    );

    final nickname = contactInfo['nickname'] ?? '';
    final remark = _getRemarkOrAlias(contactInfo);
    final sanitizedSessionWxid = _sanitizeUsername(session.username);
    final hasDetails =
        nickname.isNotEmpty ||
        remark.isNotEmpty ||
        sanitizedSessionWxid.isNotEmpty;

    if (hasDetails) {
      buffer.writeln(
        '        <button class="info-menu-btn" id="info-menu-btn" type="button" title="查看详细信息">',
      );
      buffer.writeln(
        '          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">',
      );
      buffer.writeln('            <circle cx="12" cy="12" r="1"></circle>');
      buffer.writeln('            <circle cx="12" cy="5" r="1"></circle>');
      buffer.writeln('            <circle cx="12" cy="19" r="1"></circle>');
      buffer.writeln('          </svg>');
      buffer.writeln('        </button>');
      buffer.writeln('      </div>');
      buffer.writeln('      <div class="info-menu" id="info-menu">');
      buffer.writeln('        <div class="info-menu-content">');
      if (sanitizedSessionWxid.isNotEmpty) {
        buffer.writeln('          <div class="info-item">');
        buffer.writeln('            <span class="info-label">微信ID</span>');
        buffer.writeln(
          '            <span class="info-value">${_escapeHtml(sanitizedSessionWxid)}</span>',
        );
        buffer.writeln('          </div>');
      }
      if (nickname.isNotEmpty) {
        buffer.writeln('          <div class="info-item">');
        buffer.writeln('            <span class="info-label">昵称</span>');
        buffer.writeln(
          '            <span class="info-value">${_escapeHtml(nickname)}</span>',
        );
        buffer.writeln('          </div>');
      }
      if (remark.isNotEmpty) {
        buffer.writeln('          <div class="info-item">');
        buffer.writeln('            <span class="info-label">备注</span>');
        buffer.writeln(
          '            <span class="info-value">${_escapeHtml(remark)}</span>',
        );
        buffer.writeln('          </div>');
      }
      buffer.writeln('        </div>');
      buffer.writeln('      </div>');
    } else {
      buffer.writeln('      </div>');
    }

    buffer.writeln('      <div class="info">');
    buffer.writeln('        <span>${session.typeDescription}</span>');
    buffer.writeln('        <span>共 $totalMessages 条消息</span>');
    buffer.writeln('        <span>导出时间: $exportTime</span>');
    buffer.writeln('      </div>');
    buffer.writeln('    </div>');
    buffer.writeln('    <div class="messages" id="messages-container">');
    buffer.writeln('      <div class="loading">正在加载消息...</div>');
    buffer.writeln('    </div>');
    buffer.writeln(
      '    <div class="scroll-to-bottom" id="scroll-to-bottom" title="回到底部">↓</div>',
    );
    buffer.writeln('  </div>');
    buffer.writeln('  <script>');
    buffer.writeln('    const messagesData = [');
    return buffer.toString();
  }

  String _buildHtmlFooterStream(Map<String, Map<String, String>> avatarIndex) {
    final buffer = StringBuffer();
    buffer.writeln('    const avatarIndex = ${jsonEncode(avatarIndex)};');
    buffer.writeln('    const INITIAL_BATCH = 100; // 首次加载最新100条');
    buffer.writeln('    const BATCH_SIZE = 200; // 后续每批200条');
    buffer.writeln('    let loadedStart = messagesData.length; // 从末尾开始加载');
    buffer.writeln('    let isLoading = false;');
    buffer.writeln('    let allLoaded = false;');
    buffer.writeln('    ');
    buffer.writeln('    function createMessageElement(msg, showDate) {');
    buffer.writeln('      const fragment = document.createDocumentFragment();');
    buffer.writeln('      if (showDate) {');
    buffer.writeln('        const dateDivider = document.createElement("div");');
    buffer.writeln('        dateDivider.className = "date-divider";');
    buffer.writeln('        dateDivider.textContent = msg.date;');
    buffer.writeln('        fragment.appendChild(dateDivider);');
    buffer.writeln('      }');
    buffer.writeln('      const messageEl = document.createElement("div");');
    buffer.writeln(
      '      messageEl.className = `message \${msg.isSend ? "sent" : "received"}`;',
    );
    buffer.writeln(
      '      const avatarHtml = msg.avatarKey && avatarIndex[msg.avatarKey] ?',
    );
    buffer.writeln(
      '        `<div class="avatar"><img src="data:image/png;base64,\${avatarIndex[msg.avatarKey].base64}" alt="\${avatarIndex[msg.avatarKey].displayName}"/></div>` :',
    );
    buffer.writeln('        `<div class="avatar placeholder"></div>`;');
    buffer.writeln(
      '      messageEl.innerHTML = `\${avatarHtml}<div class="bubble"><div class="sender">\${msg.senderName}</div><div class="content">\${msg.content}</div><div class="time">\${msg.time}</div></div>`;',
    );
    buffer.writeln('      fragment.appendChild(messageEl);');
    buffer.writeln('      return fragment;');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function renderMessages(start, end, toTop = true) {');
    buffer.writeln('      const container = document.getElementById("messages-container");');
    buffer.writeln('      if (!container) return;');
    buffer.writeln('      const fragment = document.createDocumentFragment();');
    buffer.writeln('      let lastDate = null;');
    buffer.writeln('      for (let i = start; i < end; i++) {');
    buffer.writeln('        const msg = messagesData[i];');
    buffer.writeln('        const showDate = msg.date !== lastDate;');
    buffer.writeln('        lastDate = msg.date;');
    buffer.writeln('        fragment.appendChild(createMessageElement(msg, showDate));');
    buffer.writeln('      }');
    buffer.writeln('      if (toTop) {');
    buffer.writeln('        container.insertBefore(fragment, container.firstChild);');
    buffer.writeln('      } else {');
    buffer.writeln('        container.appendChild(fragment);');
    buffer.writeln('      }');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function loadInitialMessages() {');
    buffer.writeln('      const container = document.getElementById("messages-container");');
    buffer.writeln('      if (!container) return;');
    buffer.writeln('      container.innerHTML = "";');
    buffer.writeln(
      '      const start = Math.max(0, messagesData.length - INITIAL_BATCH);',
    );
    buffer.writeln('      renderMessages(start, messagesData.length, false);');
    buffer.writeln('      loadedStart = start;');
    buffer.writeln('      if (start === 0) allLoaded = true;');
    buffer.writeln('      const scrollToBottomBtn = document.getElementById("scroll-to-bottom");');
    buffer.writeln('      if (scrollToBottomBtn) {');
    buffer.writeln('        scrollToBottomBtn.classList.remove("visible");');
    buffer.writeln('      }');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function loadMoreMessages() {');
    buffer.writeln('      if (isLoading || allLoaded) return;');
    buffer.writeln('      isLoading = true;');
    buffer.writeln('      const container = document.getElementById("messages-container");');
    buffer.writeln('      if (!container) return;');
    buffer.writeln('      const scrollHeightBefore = container.scrollHeight;');
    buffer.writeln('      const newStart = Math.max(0, loadedStart - BATCH_SIZE);');
    buffer.writeln('      renderMessages(newStart, loadedStart, true);');
    buffer.writeln('      loadedStart = newStart;');
    buffer.writeln('      if (newStart === 0) allLoaded = true;');
    buffer.writeln('      const scrollHeightAfter = container.scrollHeight;');
    buffer.writeln(
      '      container.scrollTop += scrollHeightAfter - scrollHeightBefore;',
    );
    buffer.writeln('      isLoading = false;');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function toggleInfoMenu() {');
    buffer.writeln('      const menu = document.getElementById("info-menu");');
    buffer.writeln('      if (!menu) return;');
    buffer.writeln('      menu.classList.toggle("show");');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function handleScroll() {');
    buffer.writeln('      const container = document.getElementById("messages-container");');
    buffer.writeln('      if (!container) return;');
    buffer.writeln('      if (container.scrollTop < 200 && !allLoaded) {');
    buffer.writeln('        loadMoreMessages();');
    buffer.writeln('      }');
    buffer.writeln('      const scrollToBottomBtn = document.getElementById("scroll-to-bottom");');
    buffer.writeln('      if (scrollToBottomBtn) {');
    buffer.writeln(
      '        const isBottom = container.scrollHeight - container.scrollTop <= container.clientHeight + 100;',
    );
    buffer.writeln('        scrollToBottomBtn.classList.toggle("visible", !isBottom);');
    buffer.writeln('      }');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    function scrollToBottom() {');
    buffer.writeln('      const container = document.getElementById("messages-container");');
    buffer.writeln('      if (!container) return;');
    buffer.writeln(
      '      container.scrollTo({ top: container.scrollHeight, behavior: "smooth" });',
    );
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    document.addEventListener("click", (e) => {');
    buffer.writeln('      const menu = document.getElementById("info-menu");');
    buffer.writeln(
      '      const btn = document.getElementById("info-menu-btn");',
    );
    buffer.writeln(
      '      if (menu && btn && !menu.contains(e.target) && !btn.contains(e.target)) {',
    );
    buffer.writeln('        menu.classList.remove("show");');
    buffer.writeln('      }');
    buffer.writeln('    });');
    buffer.writeln('    ');
    buffer.writeln(
      '    const infoMenuBtn = document.getElementById("info-menu-btn");',
    );
    buffer.writeln('    if (infoMenuBtn) {');
    buffer.writeln('      infoMenuBtn.addEventListener("click", (event) => {');
    buffer.writeln('        event.stopPropagation();');
    buffer.writeln('        toggleInfoMenu();');
    buffer.writeln('      });');
    buffer.writeln('    }');
    buffer.writeln('    ');
    buffer.writeln('    window.addEventListener("DOMContentLoaded", () => {');
    buffer.writeln('      loadInitialMessages();');
    buffer.writeln('      const container = document.getElementById("messages-container");');
    buffer.writeln('      if (container) {');
    buffer.writeln('        container.addEventListener("scroll", handleScroll);');
    buffer.writeln('      }');
    buffer.writeln('      const scrollToBottomBtn = document.getElementById("scroll-to-bottom");');
    buffer.writeln('      if (scrollToBottomBtn) {');
    buffer.writeln('        scrollToBottomBtn.addEventListener("click", scrollToBottom);');
    buffer.writeln('      }');
    buffer.writeln('    });');
    buffer.writeln('  </script>');
    buffer.writeln('</body>');
    buffer.writeln('</html>');
    return buffer.toString();
  }

  Future<Map<String, Map<String, String>>> _buildAvatarIndex({
    required ChatSession session,
    required List<Message> messages,
    required Map<String, String> contactInfo,
    required Map<String, String> senderDisplayNames,
    required String rawMyWxid,
    required String myDisplayName,
  }) async {
    final targets = <String>{
      session.username,
      rawMyWxid,
      ...messages.map((m) => m.senderUsername).whereType<String>(),
    }..removeWhere((u) => u.trim().isEmpty);

    if (targets.isEmpty) return {};

    final avatarUrls = await _databaseService.getAvatarUrls(targets.toList());
    if (avatarUrls.isEmpty) {
      return {};
    }

    final base64ByKey = <String, String>{};
    for (final entry in avatarUrls.entries) {
      final key = _sanitizeUsername(entry.key);
      if (key.isEmpty) continue;
      final encoded = await _loadAvatarBase64(entry.value);
      if (encoded != null && encoded.isNotEmpty) {
        base64ByKey[key] = encoded;
      }
    }

    if (base64ByKey.isEmpty) {
      return {};
    }

    final nameByKey = <String, String>{};
    void assignName(String username, String value) {
      final key = _sanitizeUsername(username);
      if (key.isEmpty || nameByKey.containsKey(key)) return;
      final trimmed = value.trim();
      nameByKey[key] = trimmed.isEmpty ? key : trimmed;
    }

    assignName(
      session.username,
      _resolvePreferredName(
        contactInfo,
        fallback: session.displayName ?? session.username,
      ),
    );
    if (rawMyWxid.trim().isNotEmpty) {
      assignName(rawMyWxid, myDisplayName);
    }
    senderDisplayNames.forEach((username, display) {
      assignName(username, display);
    });
    base64ByKey.keys
        .where((key) => !nameByKey.containsKey(key))
        .forEach((key) => nameByKey[key] = key);

    final merged = <String, Map<String, String>>{};
    base64ByKey.forEach((key, value) {
      merged[key] = {'displayName': nameByKey[key] ?? key, 'base64': value};
    });

    return merged;
  }

  Future<String?> _loadAvatarBase64(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;

    final cached = _avatarBase64CacheByUrl[trimmed];
    if (cached != null) return cached;

    if (trimmed.startsWith('data:')) {
      final parts = trimmed.split(',');
      if (parts.length >= 2) {
        final payload = parts.sublist(1).join(',');
        _avatarBase64CacheByUrl[trimmed] = payload;
        return payload;
      }
    }

    final resolvedPath = trimmed.startsWith('file://')
        ? PathUtils.fromUri(trimmed)
        : trimmed;
    try {
      final file = File(resolvedPath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final encoded = base64Encode(bytes);
        _avatarBase64CacheByUrl[trimmed] = encoded;
        return encoded;
      }
    } catch (_) {}

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      HttpClient? client;
      try {
        final uri = Uri.parse(trimmed);
        client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 10));
        final response = await request.close().timeout(
          const Duration(seconds: 12),
        );
        if (response.statusCode == 200) {
          final builder = BytesBuilder();
          await for (final chunk in response) {
            builder.add(chunk);
          }
          final bytes = builder.takeBytes();
          if (bytes.isNotEmpty) {
            final encoded = base64Encode(bytes);
            _avatarBase64CacheByUrl[trimmed] = encoded;
            return encoded;
          }
        }
      } catch (_) {
        // 忽略远程获取错误，继续返回空字符串
      } finally {
        client?.close(force: true);
      }
    }

    _avatarBase64CacheByUrl[trimmed] = '';
    return '';
  }

  Future<int> _safeGetMessageCount(String sessionId) async {
    try {
      return await _databaseService.getMessageCount(sessionId);
    } catch (_) {
      return 0;
    }
  }


  String _sanitizeForExcel(String? value) {
    if (value == null || value.isEmpty) {
      return '';
    }

    // XML 1.0 valid chars: #x9 | #xA | #xD | #x20-#xD7FF | #xE000-#xFFFD | #x10000-#x10FFFF
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      if (rune == 0x9 || rune == 0xA || rune == 0xD) {
        buffer.writeCharCode(rune);
        continue;
      }
      final inBasicPlane = rune >= 0x20 && rune <= 0xD7FF;
      final inSupplementary = rune >= 0xE000 && rune <= 0xFFFD;
      final inAstral = rune >= 0x10000 && rune <= 0x10FFFF;
      if (inBasicPlane || inSupplementary || inAstral) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  void _setTextSafe(Worksheet sheet, int row, int column, String? value) {
    sheet.getRangeByIndex(row, column).setText(_sanitizeForExcel(value));
  }

  Future<String> _buildMyDisplayName(
    String myWxid,
    Map<String, String> myContactInfo,
  ) async {
    final trimmedWxid = myWxid.trim();
    final sanitizedWxid = _sanitizeUsername(myWxid);
    final fallbackBase = sanitizedWxid.isNotEmpty
        ? sanitizedWxid
        : (trimmedWxid.isNotEmpty ? trimmedWxid : '我');
    final preferred = _resolvePreferredName(
      myContactInfo,
      fallback: fallbackBase,
    );

    if (preferred != fallbackBase || sanitizedWxid.isEmpty) {
      return preferred;
    }

    try {
      final candidates = <String>{trimmedWxid, sanitizedWxid}
        ..removeWhere((c) => c.isEmpty);

      if (candidates.isEmpty) {
        return preferred;
      }

      final names = await _databaseService.getDisplayNames(candidates.toList());
      for (final candidate in candidates) {
        final resolved = names[candidate];
        if (resolved != null && resolved.trim().isNotEmpty) {
          return resolved.trim();
        }
      }
    } catch (_) {}

    await _logMissingDisplayName(
      myWxid,
      isSelf: true,
      details: 'contact/userinfo/getDisplayNames 均未匹配到昵称/备注',
    );

    return preferred;
  }

  String _resolveSenderDisplayName({
    required Message msg,
    required ChatSession session,
    required bool isSend,
    required Map<String, String> contactInfo,
    required Map<String, String> myContactInfo,
    required Map<String, String> senderDisplayNames,
    required String myDisplayName,
  }) {
    if (isSend) {
      return myDisplayName;
    }

    if (session.isGroup) {
      final groupSender = msg.senderUsername;
      if (groupSender != null && groupSender.isNotEmpty) {
        final display = senderDisplayNames[groupSender];
        if (display != null && display.trim().isNotEmpty) {
          return display;
        }
      }
      return '群成员';
    }

    return _resolvePreferredName(
      contactInfo,
      fallback: session.displayName ?? session.username,
    );
  }

  String _resolveSenderUsername({
    required Message msg,
    required ChatSession session,
    required bool isSend,
    required String myWxid,
  }) {
    String candidate = '';

    if (isSend) {
      if (myWxid.isNotEmpty) {
        candidate = myWxid;
      } else if (msg.senderUsername != null && msg.senderUsername!.isNotEmpty) {
        candidate = msg.senderUsername!;
      } else {
        candidate = session.username;
      }
    } else if (session.isGroup) {
      candidate = msg.senderUsername?.isNotEmpty == true
          ? msg.senderUsername!
          : session.username;
    } else {
      candidate = session.username;
    }

    return _sanitizeUsername(candidate);
  }

  String _sanitizeUsername(String input) {
    final normalized = input.replaceAll(
      RegExp(r'[\u00A0\u2000-\u200B\u202F\u205F\u3000]'),
      ' ',
    );
    final trimmed = normalized.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.replaceAll(
      RegExp(r'[\s\u00A0\u2000-\u200B\u202F\u205F\u3000]+'),
      '_',
    );
  }

  String _resolvePreferredName(
    Map<String, String> info, {
    required String fallback,
  }) {
    final remark = info['remark'];
    if (_hasMeaningfulValue(remark)) {
      return remark!;
    }

    final nickname = info['nickname'];
    if (_hasMeaningfulValue(nickname)) {
      return nickname!;
    }

    final alias = info['alias'];
    if (_hasMeaningfulValue(alias)) {
      return alias!;
    }
    return fallback;
  }

  String _getRemarkOrAlias(Map<String, String> info) {
    final remark = info['remark'];
    if (_hasMeaningfulValue(remark)) {
      return remark!;
    }
    final nickname = info['nickname'];
    if (_hasMeaningfulValue(nickname)) {
      return nickname!;
    }
    final alias = info['alias'];
    if (_hasMeaningfulValue(alias)) {
      return alias!;
    }
    return '';
  }

  Future<bool> exportContactsToExcel({
    String? directoryPath,
    String? filePath,
    List<ContactRecord>? contacts,
    bool includeStrangers = false,
    bool includeChatroomParticipants = false,
  }) async {
    final Workbook workbook = Workbook();
    try {
      final contactList =
          contacts ??
          await _databaseService.getAllContacts(
            includeStrangers: includeStrangers,
            includeChatroomParticipants: includeChatroomParticipants,
          );

      if (contactList.isEmpty) {
        workbook.dispose();
        return false;
      }

      Worksheet sheet;
      if (workbook.worksheets.count > 0) {
        sheet = workbook.worksheets[0];
        sheet.name = '通讯录';
      } else {
        sheet = workbook.worksheets.addWithName('通讯录');
      }

      int currentRow = 1;
      _setTextSafe(sheet, currentRow, 1, '序号');
      _setTextSafe(sheet, currentRow, 2, '昵称');
      _setTextSafe(sheet, currentRow, 3, '微信ID');
      _setTextSafe(sheet, currentRow, 4, '备注');
      _setTextSafe(sheet, currentRow, 5, '微信号');
      currentRow++;

      for (int i = 0; i < contactList.length; i++) {
        final record = contactList[i];
        final contact = record.contact;
        final nickname = contact.nickName.isNotEmpty
            ? contact.nickName
            : contact.displayName;
        sheet.getRangeByIndex(currentRow, 1).setNumber(i + 1);
        _setTextSafe(sheet, currentRow, 2, nickname);
        _setTextSafe(sheet, currentRow, 3, contact.username);
        _setTextSafe(sheet, currentRow, 4, contact.remark);
        _setTextSafe(sheet, currentRow, 5, contact.alias);
        currentRow++;
      }

      sheet.getRangeByIndex(1, 1).columnWidth = 8;
      sheet.getRangeByIndex(1, 2).columnWidth = 22;
      sheet.getRangeByIndex(1, 3).columnWidth = 26;
      sheet.getRangeByIndex(1, 4).columnWidth = 22;
      sheet.getRangeByIndex(1, 5).columnWidth = 18;

      String? resolvedFilePath = filePath;
      if (resolvedFilePath == null) {
        if (directoryPath != null && directoryPath.isNotEmpty) {
          final fileName = '通讯录_${DateTime.now().millisecondsSinceEpoch}.xlsx';
          resolvedFilePath = PathUtils.join(directoryPath, fileName);
        } else {
          final suggestedName =
              '通讯录_${DateTime.now().millisecondsSinceEpoch}.xlsx';
          final outputFile = await FilePicker.platform.saveFile(
            dialogTitle: '保存通讯录',
            fileName: suggestedName,
          );
          if (outputFile == null) {
            workbook.dispose();
            return false;
          }
          resolvedFilePath = outputFile;
        }
      }

      final List<int> bytes = workbook.saveAsStream();
      workbook.dispose();

      // 使用后台 Isolate 写入文件以避免阻塞 UI
      return await _writeBytesInBackground(
        resolvedFilePath,
        Uint8List.fromList(bytes),
      );
    } catch (e) {
      workbook.dispose();
      return false;
    }
  }

  /// 获取 HTML 样式
  String _getHtmlStyles() {
    return '''
      * {
        margin: 0;
        padding: 0;
        box-sizing: border-box;
      }
      
      body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Helvetica Neue", Arial, sans-serif;
        background: linear-gradient(to bottom, #f7f8fa 0%, #e8eaf0 100%);
        color: #1a1a1a;
        line-height: 1.6;
        min-height: 100vh;
      }
      
      .container {
        max-width: 900px;
        margin: 0 auto;
        background: transparent;
        min-height: 100vh;
        padding: 20px;
      }
      
      .header {
        background: linear-gradient(135deg, #09c269 0%, #07b961 50%, #06ae56 100%);
        color: white;
        padding: 32px 28px;
        border-radius: 16px;
        text-align: center;
        box-shadow: 0 8px 24px rgba(7, 193, 96, 0.25), 0 4px 8px rgba(0, 0, 0, 0.08);
        margin-bottom: 24px;
        position: relative;
        overflow: hidden;
      }
      
      .header::before {
        content: '';
        position: absolute;
        top: -50%;
        right: -20%;
        width: 200px;
        height: 200px;
        background: rgba(255, 255, 255, 0.1);
        border-radius: 50%;
        filter: blur(40px);
      }
      
      .header::after {
        content: '';
        position: absolute;
        bottom: -30%;
        left: -10%;
        width: 150px;
        height: 150px;
        background: rgba(255, 255, 255, 0.08);
        border-radius: 50%;
        filter: blur(30px);
      }
      
      .header-main {
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 12px;
        position: relative;
        z-index: 1;
        margin-bottom: 12px;
      }

      .header h1 {
        font-size: 26px;
        font-weight: 600;
        letter-spacing: 0.5px;
        margin: 0;
      }

      .info-menu-btn {
        background: rgba(255, 255, 255, 0.2);
        border: none;
        border-radius: 50%;
        width: 36px;
        height: 36px;
        display: flex;
        align-items: center;
        justify-content: center;
        cursor: pointer;
        transition: all 0.3s ease;
        color: white;
        backdrop-filter: blur(10px);
      }

      .info-menu-btn:hover {
        background: rgba(255, 255, 255, 0.3);
        transform: scale(1.05);
      }

      .info-menu-btn:active {
        transform: scale(0.95);
      }

      .info-menu {
        position: absolute;
        top: 100%;
        right: 20px;
        margin-top: 8px;
        background: white;
        border-radius: 12px;
        box-shadow: 0 8px 24px rgba(0, 0, 0, 0.15);
        opacity: 0;
        visibility: hidden;
        transform: translateY(-10px);
        transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
        z-index: 1000;
        min-width: 280px;
      }

      .info-menu.show {
        opacity: 1;
        visibility: visible;
        transform: translateY(0);
      }

      .info-menu-content {
        padding: 16px;
      }

      .info-item {
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding: 12px;
        border-radius: 8px;
        transition: background 0.2s ease;
      }

      .info-item:hover {
        background: rgba(7, 193, 96, 0.05);
      }

      .info-item:not(:last-child) {
        border-bottom: 1px solid rgba(0, 0, 0, 0.05);
      }

      .info-label {
        font-size: 13px;
        font-weight: 600;
        color: #666;
        margin-right: 16px;
      }

      .info-value {
        font-size: 14px;
        color: #333;
        font-weight: 500;
        text-align: right;
        word-break: break-all;
      }
      
      .header .info {
        display: flex;
        justify-content: center;
        align-items: center;
        gap: 20px;
        font-size: 14px;
        opacity: 0.95;
        flex-wrap: wrap;
        position: relative;
        z-index: 1;
      }
      
      .header .info span {
        display: inline-flex;
        align-items: center;
        background: rgba(255, 255, 255, 0.15);
        padding: 6px 14px;
        border-radius: 20px;
        backdrop-filter: blur(10px);
        gap: 6px;
        transition: all 0.3s ease;
      }
      
      .header .info span:hover {
        background: rgba(255, 255, 255, 0.22);
        transform: translateY(-1px);
      }
      
      .header .info span::before {
        content: '';
        width: 4px;
        height: 4px;
        background: currentColor;
        border-radius: 50%;
        opacity: 0.8;
      }

      .messages {
        background: white;
        padding: 28px 24px;
        border-radius: 16px;
        box-shadow: 0 2px 12px rgba(0, 0, 0, 0.06);
        min-height: 400px;
        max-height: calc(100vh - 200px);
        overflow-y: auto;
        position: relative;
      }
      
      .loading {
        text-align: center;
        padding: 40px;
        color: #999;
        font-size: 14px;
      }
      
      .scroll-to-bottom {
        position: fixed;
        bottom: 40px;
        right: 40px;
        width: 48px;
        height: 48px;
        background: linear-gradient(135deg, #09c269 0%, #07b961 100%);
        color: white;
        border-radius: 50%;
        display: none;
        align-items: center;
        justify-content: center;
        font-size: 24px;
        cursor: pointer;
        box-shadow: 0 4px 16px rgba(7, 193, 96, 0.35);
        transition: all 0.3s ease;
        z-index: 1000;
        user-select: none;
      }
      
      .scroll-to-bottom:hover {
        transform: translateY(-3px);
        box-shadow: 0 6px 24px rgba(7, 193, 96, 0.45);
      }
      
      .scroll-to-bottom:active {
        transform: translateY(-1px);
      }
      
      .date-separator {
        text-align: center;
        color: #8c8c8c;
        font-size: 13px;
        margin: 28px 0;
        padding: 8px 16px;
        display: inline-block;
        background: linear-gradient(135deg, rgba(0, 0, 0, 0.04) 0%, rgba(0, 0, 0, 0.06) 100%);
        border-radius: 20px;
        position: relative;
        left: 50%;
        transform: translateX(-50%);
        font-weight: 500;
        letter-spacing: 0.3px;
        backdrop-filter: blur(10px);
      }
      
      .message-item {
        margin-bottom: 20px;
        display: flex;
        flex-direction: column;
        animation: slideIn 0.4s cubic-bezier(0.34, 1.56, 0.64, 1);
      }
      
      @keyframes slideIn {
        from {
          opacity: 0;
          transform: translateY(15px) scale(0.95);
        }
        to {
          opacity: 1;
          transform: translateY(0) scale(1);
        }
      }
      
      .message-item.sent {
        align-items: flex-end;
      }
      
      .message-item.received {
        align-items: flex-start;
      }
      
      .sender-name {
        font-size: 13px;
        color: #666;
        margin-bottom: 8px;
        padding: 0 14px;
        font-weight: 500;
      }
      
      .message-bubble {
        max-width: 68%;
        min-width: 80px;
        padding: 12px 16px;
        position: relative;
        word-break: break-word;
        transition: transform 0.2s ease, box-shadow 0.2s ease;
      }
      
      .message-bubble:hover {
        transform: translateY(-2px);
      }
      
      .sent .message-bubble {
        background: linear-gradient(135deg, #a0f47c 0%, #95ec69 100%);
        color: #1a1a1a;
        border-radius: 18px 18px 4px 18px;
        box-shadow: 0 3px 12px rgba(149, 236, 105, 0.3), 0 1px 3px rgba(0, 0, 0, 0.1);
      }
      
      .sent .message-bubble:hover {
        box-shadow: 0 6px 20px rgba(149, 236, 105, 0.4), 0 2px 6px rgba(0, 0, 0, 0.12);
      }
      
      .sent .message-bubble::after {
        content: '';
        position: absolute;
        right: -7px;
        bottom: 8px;
        width: 0;
        height: 0;
        border-left: 8px solid #95ec69;
        border-top: 6px solid transparent;
        border-bottom: 6px solid transparent;
        filter: drop-shadow(2px 2px 2px rgba(0, 0, 0, 0.08));
      }
      
      .received .message-bubble {
        background: linear-gradient(135deg, #ffffff 0%, #fafafa 100%);
        color: #1a1a1a;
        border-radius: 18px 18px 18px 4px;
        box-shadow: 0 3px 12px rgba(0, 0, 0, 0.08), 0 1px 3px rgba(0, 0, 0, 0.06);
        border: 1px solid rgba(0, 0, 0, 0.04);
      }
      
      .received .message-bubble:hover {
        box-shadow: 0 6px 20px rgba(0, 0, 0, 0.12), 0 2px 6px rgba(0, 0, 0, 0.08);
      }
      
      .received .message-bubble::after {
        content: '';
        position: absolute;
        left: -7px;
        bottom: 8px;
        width: 0;
        height: 0;
        border-right: 8px solid #ffffff;
        border-top: 6px solid transparent;
        border-bottom: 6px solid transparent;
        filter: drop-shadow(-2px 2px 2px rgba(0, 0, 0, 0.06));
      }
      
      .content {
        font-size: 15px;
        line-height: 1.6;
        word-wrap: break-word;
        white-space: pre-wrap;
        letter-spacing: 0.2px;
      }
      
      .time {
        font-size: 11px;
        margin-top: 8px;
        font-weight: 500;
        text-align: right;
        letter-spacing: 0.3px;
      }
      
      .sent .time {
        color: rgba(0, 0, 0, 0.45);
      }
      
      .received .time {
        color: rgba(0, 0, 0, 0.4);
      }
      
      @media print {
        body {
          background: white;
        }
        
        .container {
          padding: 0;
        }
        
        .header {
          box-shadow: none;
          border-radius: 0;
        }
        
        .messages {
          box-shadow: none;
          border-radius: 0;
          max-height: none;
          overflow: visible;
        }
        
        .message-item {
          page-break-inside: avoid;
          animation: none;
        }
        
        .message-bubble {
          box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1) !important;
        }
        
        .scroll-to-bottom {
          display: none !important;
        }
      }
      
      @media (max-width: 768px) {
        .container {
          padding: 12px;
          max-width: 100%;
        }
        
        .header {
          padding: 24px 20px;
          border-radius: 12px;
          margin-bottom: 16px;
        }
        
        .header h1 {
          font-size: 22px;
        }
        
        .messages {
          padding: 20px 16px;
          border-radius: 12px;
          max-height: calc(100vh - 160px);
        }
        
        .message-bubble {
          max-width: 80%;
        }
        
        .date-separator {
          font-size: 12px;
          padding: 6px 12px;
        }
        
        .scroll-to-bottom {
          bottom: 20px;
          right: 20px;
          width: 44px;
          height: 44px;
          font-size: 20px;
        }
      }
      
      @media (prefers-color-scheme: dark) {
        body {
          background: linear-gradient(to bottom, #1a1a1a 0%, #0f0f0f 100%);
        }
        
        .messages {
          background: #2a2a2a;
          box-shadow: 0 2px 12px rgba(0, 0, 0, 0.4);
        }
        
        .loading {
          color: #666;
        }
        
        .received .message-bubble {
          background: linear-gradient(135deg, #3a3a3a 0%, #333333 100%);
          color: #e8e8e8;
          border-color: rgba(255, 255, 255, 0.1);
        }
        
        .received .message-bubble::after {
          border-right-color: #3a3a3a;
        }
        
        .sender-name {
          color: #999;
        }
        
        .date-separator {
          color: #999;
          background: linear-gradient(135deg, rgba(255, 255, 255, 0.08) 0%, rgba(255, 255, 255, 0.12) 100%);
        }
        
        .sent .time,
        .received .time {
          color: rgba(255, 255, 255, 0.5);
        }
      }
    ''';
  }

  /// HTML 转义
  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  /// 获取联系人详细信息（nickname、remark）
  Future<Map<String, String>> _getContactInfo(String username) async {
    final result = <String, String>{};

    try {
      final contactDbPath = await _databaseService.getContactDatabasePath();
      if (contactDbPath == null) {
        return result;
      }

      final contactFile = File(contactDbPath);
      if (!await contactFile.exists()) {
        return result;
      }

      final contactDb = await databaseFactoryFfi.openDatabase(contactDbPath);

      try {
        final candidates = <String>{
          username.trim(),
          _sanitizeUsername(username),
        }..removeWhere((c) => c.isEmpty);

        final tables = ['contact', 'stranger'];

        for (final table in tables) {
          for (final candidate in candidates) {
            final maps = await contactDb.query(
              table,
              columns: ['nick_name', 'remark', 'alias'],
              where: 'username = ?',
              whereArgs: [candidate],
              limit: 1,
            );

            if (maps.isNotEmpty) {
              final map = maps.first;
              final nickName = _normalizeDisplayField(
                map['nick_name'] as String?,
              );
              final remark = _normalizeDisplayField(map['remark'] as String?);
              final alias = _normalizeDisplayField(map['alias'] as String?);

              if (_hasMeaningfulValue(remark)) {
                result['remark'] = remark;
              }

              if (_hasMeaningfulValue(alias)) {
                result['alias'] = alias;
              }

              if (_hasMeaningfulValue(nickName)) {
                result['nickname'] = nickName;
              }

              if (result.isNotEmpty) {
                return result;
              }
            }
          }
        }

        if (result.isEmpty && _isCurrentAccount(username)) {
          final selfInfo = await _getSelfInfoFromUserInfo(contactDb);
          if (selfInfo.isNotEmpty) {
            result.addAll(selfInfo);
            return result;
          }
        }
      } finally {
        await contactDb.close();
      }
    } catch (e) {
      // 查询失败时返回空map
    }

    if (result.isEmpty) {
      final isSelf = _isCurrentAccount(username);
      await _logMissingDisplayName(
        username,
        isSelf: isSelf,
        details: isSelf
            ? 'contact/stranger/userinfo 表无匹配记录'
            : 'contact/stranger 表无匹配记录',
      );
    }

    return result;
  }

  bool _isCurrentAccount(String username) {
    final myWxid = _databaseService.currentAccountWxid;
    if (myWxid == null) return false;
    final normalizedInput = _sanitizeUsername(username);
    final normalizedCurrent = _sanitizeUsername(myWxid);
    if (normalizedInput.isEmpty || normalizedCurrent.isEmpty) return false;
    return normalizedInput == normalizedCurrent;
  }

  Future<Map<String, String>> _getSelfInfoFromUserInfo(
    Database contactDb,
  ) async {
    final info = <String, String>{};
    try {
      final tableExists = await contactDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='userinfo' LIMIT 1",
      );
      if (tableExists.isEmpty) {
        return info;
      }

      final rows = await contactDb.query('userinfo');
      if (rows.isEmpty) {
        return info;
      }

      String? nickname;
      String? remark;
      String? alias;

      for (final row in rows) {
        final key = _extractUserInfoKey(row);
        final value = _extractUserInfoValue(row);
        if (value == null || value.isEmpty) continue;

        final normalizedValue = _normalizeDisplayField(value);
        if (!_hasMeaningfulValue(normalizedValue)) continue;

        final lowerKey = key?.toString().toLowerCase() ?? '';
        if (lowerKey.contains('remark') || lowerKey.contains('displayname')) {
          remark ??= normalizedValue;
        } else if (lowerKey.contains('alias')) {
          alias ??= normalizedValue;
        } else if (lowerKey.contains('nick') ||
            lowerKey.contains('name') ||
            lowerKey == '2') {
          nickname ??= normalizedValue;
        }

        if (nickname != null && (remark != null || alias != null)) {
          break;
        }
      }

      if (alias != null) {
        info['alias'] = alias;
      }
      if (remark != null) {
        info['remark'] = remark;
      }
      if (nickname != null) {
        info['nickname'] = nickname;
      }
    } catch (_) {}

    return info;
  }

  dynamic _extractUserInfoKey(Map<String, Object?> row) {
    for (final key in ['id', 'type', 'item', 'key']) {
      if (row.containsKey(key) && row[key] != null) {
        return row[key];
      }
    }
    return null;
  }

  String? _extractUserInfoValue(Map<String, Object?> row) {
    for (final key in ['value', 'Value', 'content', 'data']) {
      final v = row[key];
      if (v is String && v.trim().isNotEmpty) {
        return v.trim();
      }
    }
    return null;
  }

  Future<void> _logMissingDisplayName(
    String username, {
    required bool isSelf,
    required String details,
  }) async {
    final normalized = _sanitizeUsername(username);
    if (normalized.isEmpty) return;
    if (!_missingDisplayNameLog.add('$normalized|$isSelf')) {
      return;
    }

    final baseReason = isSelf
        ? '未在 contact/stranger/userinfo 表找到当前账号的昵称/备注，已回退为 wxid'
        : '未在 contact/stranger 表找到联系人显示名，已回退为 wxid';

    await logger.warning(
      'ChatExportService',
      '$baseReason: $normalized，原因: $details',
    );
  }

  bool _hasMeaningfulValue(String? value) {
    if (value == null) return false;
    if (value.isEmpty) return false;
    final stripped = value.replaceAll(RegExp(r'[ \t\r\n]'), '');
    return stripped.isNotEmpty;
  }

  String _normalizeDisplayField(String? value) {
    if (value == null) return '';
    return value
        .replaceAll(RegExp(r'^[ \t\r\n]+'), '')
        .replaceAll(RegExp(r'[ \t\r\n]+$'), '');
  }
}

