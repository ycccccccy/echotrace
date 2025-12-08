// WCDB DLL FFI 封装：加载 Windows 动态库，提供实时获取会话/消息/头像等原生接口
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

/// C 接口类型定义
typedef _WcdbInitNative = Int32 Function();
typedef _WcdbInitDart = int Function();

typedef _WcdbShutdownNative = Int32 Function();
typedef _WcdbShutdownDart = int Function();

typedef _WcdbOpenAccountNative = Int32 Function(
  Pointer<Utf8> sessionDbPath,
  Pointer<Utf8> hexKey,
  Pointer<Int64> outHandle,
);
typedef _WcdbOpenAccountDart = int Function(
  Pointer<Utf8> sessionDbPath,
  Pointer<Utf8> hexKey,
  Pointer<Int64> outHandle,
);

typedef _WcdbCloseAccountNative = Int32 Function(Int64 handle);
typedef _WcdbCloseAccountDart = int Function(int handle);

typedef _WcdbFreeStringNative = Void Function(Pointer<Utf8> ptr);
typedef _WcdbFreeStringDart = void Function(Pointer<Utf8> ptr);

typedef _WcdbGetSessionsNative = Int32 Function(
  Int64 handle,
  Pointer<Pointer<Utf8>> outJson,
);
typedef _WcdbGetSessionsDart = int Function(
  int handle,
  Pointer<Pointer<Utf8>> outJson,
);

typedef _WcdbGetMessagesNative = Int32 Function(
  Int64 handle,
  Pointer<Utf8> username,
  Int32 limit,
  Int32 offset,
  Pointer<Pointer<Utf8>> outJson,
);
typedef _WcdbGetMessagesDart = int Function(
  int handle,
  Pointer<Utf8> username,
  int limit,
  int offset,
  Pointer<Pointer<Utf8>> outJson,
);

typedef _WcdbGetMessageCountNative = Int32 Function(
  Int64 handle,
  Pointer<Utf8> username,
  Pointer<Int32> outCount,
);
typedef _WcdbGetMessageCountDart = int Function(
  int handle,
  Pointer<Utf8> username,
  Pointer<Int32> outCount,
);

typedef _WcdbGetDisplayNamesNative = Int32 Function(
  Int64 handle,
  Pointer<Utf8> usernamesJson,
  Pointer<Pointer<Utf8>> outJson,
);
typedef _WcdbGetDisplayNamesDart = int Function(
  int handle,
  Pointer<Utf8> usernamesJson,
  Pointer<Pointer<Utf8>> outJson,
);

typedef _WcdbGetAvatarUrlsNative = Int32 Function(
  Int64 handle,
  Pointer<Utf8> usernamesJson,
  Pointer<Pointer<Utf8>> outJson,
);
typedef _WcdbGetAvatarUrlsDart = int Function(
  int handle,
  Pointer<Utf8> usernamesJson,
  Pointer<Pointer<Utf8>> outJson,
);

typedef _WcdbGetGroupMemberCountNative = Int32 Function(
  Int64 handle,
  Pointer<Utf8> chatroomId,
  Pointer<Int32> outCount,
);
typedef _WcdbGetGroupMemberCountDart = int Function(
  int handle,
  Pointer<Utf8> chatroomId,
  Pointer<Int32> outCount,
);

typedef _WcdbGetGroupMembersNative = Int32 Function(
  Int64 handle,
  Pointer<Utf8> chatroomId,
  Pointer<Pointer<Utf8>> outJson,
);
typedef _WcdbGetGroupMembersDart = int Function(
  int handle,
  Pointer<Utf8> chatroomId,
  Pointer<Pointer<Utf8>> outJson,
);

typedef _WcdbGetLogsNative = Int32 Function(Pointer<Pointer<Utf8>> outJson);
typedef _WcdbGetLogsDart = int Function(Pointer<Pointer<Utf8>> outJson);

/// WCDB 原生接口封装
class WeChatWCDBNative {
  static bool _initialized = false;

  static _WcdbInitDart? _init;
  static _WcdbShutdownDart? _shutdown;
  static _WcdbOpenAccountDart? _openAccount;
  static _WcdbCloseAccountDart? _closeAccount;
  static _WcdbFreeStringDart? _freeString;
  static _WcdbGetSessionsDart? _getSessions;
  static _WcdbGetMessagesDart? _getMessages;
  static _WcdbGetMessageCountDart? _getMessageCount;
  static _WcdbGetDisplayNamesDart? _getDisplayNames;
  static _WcdbGetAvatarUrlsDart? _getAvatarUrls;
  static _WcdbGetGroupMemberCountDart? _getGroupMemberCount;
  static _WcdbGetGroupMembersDart? _getGroupMembers;
  static _WcdbGetLogsDart? _getLogs;

  static bool initialize() {
    if (_initialized) return true;

    try {
      if (!Platform.isWindows) {
        // 当前仅支持 Windows
        return false;
      }

      // 优先加载我们自编译的封装 dll，避免误加载官方 wcdb.dll 无导出符号
      final dllNames = <String>[
        'wcdb_api.dll',
        'wcdb.dll',
      ];

      DynamicLibrary? lib;

      final possiblePaths = <String>[];
      // 可执行文件所在目录
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final assetDllDir = path.join(
        exeDir,
        'data',
        'flutter_assets',
        'assets',
        'dll',
      );

      for (final name in dllNames) {
        possiblePaths.addAll([
          path.join(assetDllDir, name),
          path.join(exeDir, name),
          path.join(exeDir, 'data', name),
        ]);
      }

      const retryCount = 3;
      const retryDelayMs = 300;
      for (int attempt = 0; attempt < retryCount && lib == null; attempt++) {
        for (final p in possiblePaths) {
          try {
            lib = DynamicLibrary.open(p);
          } catch (e) {
            lib = null;
            continue;
          }
          // 尝试加载符号；失败则换下一个路径
          try {
            _init = lib
                .lookup<NativeFunction<_WcdbInitNative>>('wcdb_init')
                .asFunction();
            _shutdown = lib
                .lookup<NativeFunction<_WcdbShutdownNative>>('wcdb_shutdown')
                .asFunction();
            _openAccount = lib
                .lookup<NativeFunction<_WcdbOpenAccountNative>>(
                  'wcdb_open_account',
                )
                .asFunction();
            _closeAccount = lib
                .lookup<NativeFunction<_WcdbCloseAccountNative>>(
                  'wcdb_close_account',
                )
                .asFunction();
            _freeString = lib
                .lookup<NativeFunction<_WcdbFreeStringNative>>('wcdb_free_string')
                .asFunction();
            _getSessions = lib
                .lookup<NativeFunction<_WcdbGetSessionsNative>>(
                  'wcdb_get_sessions',
                )
                .asFunction();
            _getMessages = lib
                .lookup<NativeFunction<_WcdbGetMessagesNative>>(
                  'wcdb_get_messages',
                )
                .asFunction();
            _getMessageCount = lib
                .lookup<NativeFunction<_WcdbGetMessageCountNative>>(
                  'wcdb_get_message_count',
                )
                .asFunction();
            _getDisplayNames = lib
                .lookup<NativeFunction<_WcdbGetDisplayNamesNative>>(
                  'wcdb_get_display_names',
                )
                .asFunction();
            _getAvatarUrls = lib
                .lookup<NativeFunction<_WcdbGetAvatarUrlsNative>>(
                  'wcdb_get_avatar_urls',
                )
                .asFunction();
            _getGroupMemberCount = lib
                .lookup<NativeFunction<_WcdbGetGroupMemberCountNative>>(
                  'wcdb_get_group_member_count',
                )
                .asFunction();
            _getGroupMembers = lib
                .lookup<NativeFunction<_WcdbGetGroupMembersNative>>(
                  'wcdb_get_group_members',
                )
                .asFunction();
            _getLogs = lib
                .lookup<NativeFunction<_WcdbGetLogsNative>>('wcdb_get_logs')
                .asFunction();
            // 符号全部加载成功才跳出
            break;
          } catch (e) {
            lib = null;
            _init = null;
            _shutdown = null;
            _openAccount = null;
            _closeAccount = null;
            _freeString = null;
            _getSessions = null;
            _getMessages = null;
            _getMessageCount = null;
            _getDisplayNames = null;
            _getAvatarUrls = null;
            _getGroupMemberCount = null;
            _getGroupMembers = null;
            _getLogs = null;
            continue;
          }
        }
        if (lib == null && attempt < retryCount - 1) {
          
          sleep(const Duration(milliseconds: retryDelayMs));
        }
      }

      if (lib == null) {
        
        return false;
      }


      final initResult = _init!();
      if (initResult != 0) {
        
        return false;
      }

      _initialized = true;
      
      return true;
    } catch (e) {
      
      return false;
    }
  }

  static void shutdown() {
    if (!_initialized) return;
    try {
      _shutdown?.call();
    } catch (_) {}
    _initialized = false;
  }

  static int? openAccount(String sessionDbPath, String hexKey) {
    if (!_initialized && !initialize()) {
      
      return null;
    }

    final pathPtr = sessionDbPath.toNativeUtf8();
    final keyPtr = hexKey.toNativeUtf8();
    final handlePtr = calloc<Int64>();

    try {
      if (_openAccount == null) {
        
        return null;
      }

      final result = _openAccount!(pathPtr, keyPtr, handlePtr);
      if (result != 0) {
        
        return null;
      }
      final handle = handlePtr.value;
      return handle > 0 ? handle : null;
    } finally {
      calloc.free(pathPtr);
      calloc.free(keyPtr);
      calloc.free(handlePtr);
    }
  }

  static void closeAccount(int handle) {
    if (!_initialized) return;
    try {
      _closeAccount?.call(handle);
    } catch (_) {}
  }

  static List<Map<String, dynamic>> getSessions(int handle) {
    if (!_initialized && !initialize()) {
      return [];
    }
    final outPtr = calloc<Pointer<Utf8>>();
    try {
      final result = _getSessions!(handle, outPtr);
      if (result != 0) {
        return [];
      }
      final ptr = outPtr.value;
      if (ptr == nullptr) {
        return [];
      }
      final jsonStr = ptr.toDartString();
      _freeString!(ptr);
      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        return decoded
            .cast<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    } finally {
      calloc.free(outPtr);
    }
  }

  static List<Map<String, dynamic>> getMessages(
    int handle,
    String username, {
    int limit = 50,
    int offset = 0,
  }) {
    if (!_initialized && !initialize()) {
      return [];
    }
    final userPtr = username.toNativeUtf8();
    final outPtr = calloc<Pointer<Utf8>>();
    try {
      final result = _getMessages!(
        handle,
        userPtr,
        limit,
        offset,
        outPtr,
      );
      if (result != 0) {
        return [];
      }
      final ptr = outPtr.value;
      if (ptr == nullptr) return [];
      final jsonStr = ptr.toDartString();
      _freeString!(ptr);
      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        return decoded
            .cast<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    } finally {
      calloc.free(userPtr);
      calloc.free(outPtr);
    }
  }

  static int getMessageCount(int handle, String username) {
    if (!_initialized && !initialize()) {
      return 0;
    }
    final userPtr = username.toNativeUtf8();
    final countPtr = calloc<Int32>();
    try {
      final result = _getMessageCount!(handle, userPtr, countPtr);
      if (result != 0) {
        return 0;
      }
      return countPtr.value;
    } catch (_) {
      return 0;
    } finally {
      calloc.free(userPtr);
      calloc.free(countPtr);
    }
  }

  static Map<String, String> getDisplayNames(
    int handle,
    List<String> usernames,
  ) {
    if (!_initialized && !initialize()) {
      return {};
    }
    final jsonStr = jsonEncode(usernames);
    final jsonPtr = jsonStr.toNativeUtf8();
    final outPtr = calloc<Pointer<Utf8>>();
    try {
      final result = _getDisplayNames!(handle, jsonPtr, outPtr);
      if (result != 0) return {};
      final ptr = outPtr.value;
      if (ptr == nullptr) return {};
      final outJson = ptr.toDartString();
      _freeString!(ptr);
      final decoded = jsonDecode(outJson);
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      }
      return {};
    } catch (_) {
      return {};
    } finally {
      calloc.free(jsonPtr);
      calloc.free(outPtr);
    }
  }

  static Map<String, String> getAvatarUrls(
    int handle,
    List<String> usernames,
  ) {
    if (!_initialized && !initialize()) {
      return {};
    }
    final jsonStr = jsonEncode(usernames);
    final jsonPtr = jsonStr.toNativeUtf8();
    final outPtr = calloc<Pointer<Utf8>>();
    try {
      final result = _getAvatarUrls!(handle, jsonPtr, outPtr);
      if (result != 0) return {};
      final ptr = outPtr.value;
      if (ptr == nullptr) return {};
      final outJson = ptr.toDartString();
      _freeString!(ptr);
      final decoded = jsonDecode(outJson);
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      }
      return {};
    } catch (_) {
      return {};
    } finally {
      calloc.free(jsonPtr);
      calloc.free(outPtr);
    }
  }

  static int getGroupMemberCount(int handle, String chatroomId) {
    if (!_initialized && !initialize()) {
      return 0;
    }
    final roomPtr = chatroomId.toNativeUtf8();
    final countPtr = calloc<Int32>();
    try {
      final result = _getGroupMemberCount!(handle, roomPtr, countPtr);
      if (result != 0) return 0;
      return countPtr.value;
    } catch (_) {
      return 0;
    } finally {
      calloc.free(roomPtr);
      calloc.free(countPtr);
    }
  }

  static List<Map<String, dynamic>> getGroupMembers(
    int handle,
    String chatroomId,
  ) {
    if (!_initialized && !initialize()) {
      return [];
    }
    final roomPtr = chatroomId.toNativeUtf8();
    final outPtr = calloc<Pointer<Utf8>>();
    try {
      final result = _getGroupMembers!(handle, roomPtr, outPtr);
      if (result != 0) return [];
      final ptr = outPtr.value;
      if (ptr == nullptr) return [];
      final jsonStr = ptr.toDartString();
      _freeString!(ptr);
      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        return decoded
            .cast<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    } finally {
      calloc.free(roomPtr);
      calloc.free(outPtr);
    }
  }

  /// 获取原生端日志
  static List<String> getNativeLogs() {
    if (!_initialized && !initialize()) {
      return [];
    }
    final outPtr = calloc<Pointer<Utf8>>();
    try {
      final result = _getLogs?.call(outPtr) ?? -1;
      if (result != 0) return [];
      final ptr = outPtr.value;
      if (ptr == nullptr) return [];
      final jsonStr = ptr.toDartString();
      _freeString?.call(ptr);
      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
      return [];
    } catch (_) {
      return [];
    } finally {
      calloc.free(outPtr);
    }
  }
}
