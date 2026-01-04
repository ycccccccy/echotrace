import 'dart:ffi';
import 'dart:io';
import 'dart:async';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:path/path.dart' as path;
import 'package:file_picker/file_picker.dart';
import 'wx_key_logger.dart';

class DllDownloadResult {
  final bool success;
  final String? dllPath;
  final DllDownloadError? error;

  DllDownloadResult.success(this.dllPath)
      : success = true,
        error = null;

  DllDownloadResult.failure(this.error)
      : success = false,
        dllPath = null;
}

enum DllDownloadError {
  networkError,
  versionNotFound,
  fileError,
}

class DllInjector {
  static List<int>? _topWindowHandlesCollector;
  static List<_ChildWindowInfo>? _childWindowCollector;
  static int? _topWindowTargetPid;
  static const List<String> _readyComponentTexts = [
    '聊天',
    '登录',
    '账号',
  ];
  static const List<String> _readyComponentClassMarkers = [
    'WeChat',
    'Weixin',
    'TXGuiFoundation',
    'Qt5',
    'ChatList',
    'MainWnd',
    'BrowserWnd',
    'ListView',
  ];
  static const int _readyChildCountThreshold = 14;

  static List<int> findProcessIds(String processName) {
    final pidsFound = <int>[];
    final processIds = calloc<DWORD>(1024);
    final cb = calloc<DWORD>();

    try {
      if (EnumProcesses(processIds, 1024 * sizeOf<DWORD>(), cb) == 0) {
        return [];
      }

      final count = cb.value ~/ sizeOf<DWORD>();
      for (int i = 0; i < count; i++) {
        final pid = processIds[i];
        if (pid == 0) continue;

        final hProcess = OpenProcess(
          PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
          FALSE,
          pid,
        );
        if (hProcess != 0) {
          final moduleName = calloc<Uint16>(MAX_PATH);
          try {
            if (GetModuleBaseName(hProcess, 0, moduleName.cast(), MAX_PATH) >
                0) {
              final currentName = String.fromCharCodes(
                moduleName.asTypedList(MAX_PATH).takeWhile((c) => c != 0),
              );
              if (currentName.toLowerCase() ==
                  processName.toLowerCase()) {
                pidsFound.add(pid);
              }
            }
          } finally {
            free(moduleName);
          }
          CloseHandle(hProcess);
        }
      }
    } finally {
      free(processIds);
      free(cb);
    }
    return pidsFound;
  }

  static bool isProcessRunning(String processName) {
    return findProcessIds(processName).isNotEmpty;
  }

  /// 从注册表获取微信安装路径
  static String? _getWeChatPathFromRegistry() {
    final uninstallPath = _findWeChatFromUninstall();
    if (uninstallPath != null) {
      return uninstallPath;
    }

    final appPath = _findWeChatFromAppPaths();
    if (appPath != null) {
      return appPath;
    }

    final tencentPath = _findWeChatFromTencentRegistry();
    if (tencentPath != null) {
      return tencentPath;
    }

    return null;
  }

  static String? _findWeChatFromScoop() {
    final userProfile = Platform.environment['USERPROFILE'];
    final scoopHome =
        Platform.environment['SCOOP'] ?? Platform.environment['SCOOP_HOME'];
    final possibleRoots = [
      if (scoopHome != null && scoopHome.isNotEmpty) scoopHome,
      if (userProfile != null && userProfile.isNotEmpty)
        path.join(userProfile, 'scoop'),
    ];

    const appNames = ['wechat', 'weixin'];
    const exeNames = ['WeChat.exe', 'Weixin.exe'];
    const subDirs = ['', 'WeChat', 'Weixin'];

    for (final root in possibleRoots) {
      for (final appName in appNames) {
        for (final subDir in subDirs) {
          for (final exeName in exeNames) {
            final exePath = path.join(
              root,
              'apps',
              appName,
              'current',
              subDir,
              exeName,
            );
            if (File(exePath).existsSync()) {
              return exePath;
            }
          }
        }
      }
    }

    return null;
  }

  static String? _findWeChatFromUninstall() {
    final uninstallKeys = [
      r'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
      r'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    ];

    final rootKeys = [HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER];

    for (final rootKey in rootKeys) {
      for (final uninstallKey in uninstallKeys) {
        final result = _searchUninstallKey(rootKey, uninstallKey);
        if (result != null) {
          return result;
        }
      }
    }

    return null;
  }

  static String? _searchUninstallKey(int rootKey, String keyPath) {
    final phkResult = calloc<HKEY>();

    try {
      if (RegOpenKeyEx(
            rootKey,
            keyPath.toNativeUtf16(),
            0,
            KEY_READ,
            phkResult,
          ) !=
          ERROR_SUCCESS) {
        return null;
      }

      var index = 0;
      final subKeyName = calloc<Uint16>(256);

      while (true) {
        final subKeyNameLength = calloc<DWORD>();
        subKeyNameLength.value = 256;

        final result = RegEnumKeyEx(
          phkResult.value,
          index,
          subKeyName.cast(),
          subKeyNameLength,
          nullptr,
          nullptr,
          nullptr,
          nullptr,
        );

        free(subKeyNameLength);

        if (result != ERROR_SUCCESS) {
          break;
        }

        final subKeyNameStr = String.fromCharCodes(
          subKeyName.asTypedList(256).takeWhile((c) => c != 0),
        );

        if (subKeyNameStr.toLowerCase().contains('wechat') ||
            subKeyNameStr.toLowerCase().contains('weixin') ||
            subKeyNameStr.toLowerCase().contains('tencent')) {
          final fullPath = '$keyPath\\$subKeyNameStr';
          final wechatPath = _readInstallLocationFromKey(rootKey, fullPath);

          if (wechatPath != null) {
            free(subKeyName);
            RegCloseKey(phkResult.value);
            return wechatPath;
          }
        }

        index++;
      }

      free(subKeyName);
      RegCloseKey(phkResult.value);
    } finally {
      free(phkResult);
    }

    return null;
  }

  static String? _readInstallLocationFromKey(int rootKey, String keyPath) {
    final phkResult = calloc<HKEY>();

    try {
      if (RegOpenKeyEx(
            rootKey,
            keyPath.toNativeUtf16(),
            0,
            KEY_READ,
            phkResult,
          ) !=
          ERROR_SUCCESS) {
        return null;
      }

      final valueNames = [
        'InstallLocation',
        'InstallPath',
        'DisplayIcon',
        'UninstallString',
        'InstallDir',
      ];

      for (final valueName in valueNames) {
        final result = _queryRegistryValue(phkResult.value, valueName);
        if (result != null && result.isNotEmpty) {
          var exePath = result;

          if (valueName == 'UninstallString' || valueName == 'DisplayIcon') {
            exePath = exePath.split(',')[0].trim();
            exePath = exePath.replaceAll('"', '');
          }

          if (exePath.toLowerCase().endsWith('.exe')) {
            if (File(exePath).existsSync()) {
              RegCloseKey(phkResult.value);
              return exePath;
            }
            final dir = path.dirname(exePath);
            final weixinPath = path.join(dir, 'Weixin.exe');
            if (File(weixinPath).existsSync()) {
              RegCloseKey(phkResult.value);
              return weixinPath;
            }
            final wechatPath = path.join(dir, 'WeChat.exe');
            if (File(wechatPath).existsSync()) {
              RegCloseKey(phkResult.value);
              return wechatPath;
            }
          } else {
            final weixinPath = path.join(exePath, 'Weixin.exe');
            if (File(weixinPath).existsSync()) {
              RegCloseKey(phkResult.value);
              return weixinPath;
            }
          }
        }
      }

      RegCloseKey(phkResult.value);
    } catch (e) {
      // 忽略
    } finally {
      free(phkResult);
    }

    return null;
  }

  static String? _findWeChatFromAppPaths() {
    final appNames = ['WeChat.exe', 'Weixin.exe'];
    final rootKeys = [HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER];

    for (final rootKey in rootKeys) {
      for (final appName in appNames) {
        final keyPath =
            'SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\$appName';
        final phkResult = calloc<HKEY>();

        try {
          if (RegOpenKeyEx(
                rootKey,
                keyPath.toNativeUtf16(),
                0,
                KEY_READ,
                phkResult,
              ) ==
              ERROR_SUCCESS) {
            final result = _queryRegistryValue(phkResult.value, '');
            RegCloseKey(phkResult.value);

            if (result != null &&
                result.isNotEmpty &&
                File(result).existsSync()) {
              return result;
            }
          }
        } catch (e) {
          // 忽略
        } finally {
          free(phkResult);
        }
      }
    }

    return null;
  }

  static String? _findWeChatFromTencentRegistry() {
    final keyPaths = [
      r'Software\Tencent\WeChat',
      r'Software\Tencent\bugReport\WeChatWindows',
      r'Software\WOW6432Node\Tencent\WeChat',
      r'Software\Tencent\Weixin',
    ];

    final valueNames = ['InstallPath', 'Install', 'Path', 'InstallDir'];

    for (final keyPath in keyPaths) {
      final phkResult = calloc<HKEY>();

      try {
        if (RegOpenKeyEx(
              HKEY_CURRENT_USER,
              keyPath.toNativeUtf16(),
              0,
              KEY_READ,
              phkResult,
            ) ==
            ERROR_SUCCESS) {
          for (final valueName in valueNames) {
            final result = _queryRegistryValue(phkResult.value, valueName);
            if (result != null) {
              RegCloseKey(phkResult.value);
              return result;
            }
          }
          RegCloseKey(phkResult.value);
        }

        if (RegOpenKeyEx(
              HKEY_LOCAL_MACHINE,
              keyPath.toNativeUtf16(),
              0,
              KEY_READ,
              phkResult,
            ) ==
            ERROR_SUCCESS) {
          for (final valueName in valueNames) {
            final result = _queryRegistryValue(phkResult.value, valueName);
            if (result != null) {
              RegCloseKey(phkResult.value);
              return result;
            }
          }
          RegCloseKey(phkResult.value);
        }
      } catch (e) {
        // 忽略错误
      } finally {
        free(phkResult);
      }
    }

    return null;
  }

  static String? _queryRegistryValue(int hKey, String valueName) {
    final lpType = calloc<DWORD>();
    final lpcbData = calloc<DWORD>();

    try {
      if (RegQueryValueEx(
            hKey,
            valueName.toNativeUtf16(),
            nullptr,
            lpType,
            nullptr,
            lpcbData,
          ) ==
          ERROR_SUCCESS) {
        if (lpType.value == REG_SZ || lpType.value == REG_EXPAND_SZ) {
          final buffer = calloc<Uint8>(lpcbData.value);

          try {
            if (RegQueryValueEx(
                  hKey,
                  valueName.toNativeUtf16(),
                  nullptr,
                  lpType,
                  buffer,
                  lpcbData,
                ) ==
                ERROR_SUCCESS) {
              final result = String.fromCharCodes(
                buffer
                    .cast<Uint16>()
                    .asTypedList(lpcbData.value ~/ 2)
                    .takeWhile((c) => c != 0),
              );

              if (result.isNotEmpty) {
                if (result.toLowerCase().endsWith('.exe')) {
                  return result;
                } else {
                  final weixinPath = path.join(result, 'Weixin.exe');
                  if (File(weixinPath).existsSync()) {
                    return weixinPath;
                  }
                  return result;
                }
              }
            }
          } finally {
            free(buffer);
          }
        }
      }
    } catch (e) {
      // 忽略错误
    } finally {
      free(lpType);
      free(lpcbData);
    }

    return null;
  }

  static Future<String?> getWeChatDirectory() async {
    final wechatPath = _getWeChatPathFromRegistry() ?? _findWeChatFromScoop();

    if (wechatPath != null) {
      final wechatFile = File(wechatPath);
      if (wechatFile.existsSync()) {
        final directory = path.dirname(wechatPath);
        return directory;
      }
    }

    final drives = ['C', 'D', 'E', 'F'];
    final commonPaths = [
      r'\Program Files\Tencent\WeChat\WeChat.exe',
      r'\Program Files (x86)\Tencent\WeChat\WeChat.exe',
      r'\Program Files\Tencent\Weixin\Weixin.exe',
      r'\Program Files (x86)\Tencent\Weixin\Weixin.exe',
    ];

    for (final drive in drives) {
      for (final commonPath in commonPaths) {
        final fullPath = '$drive:$commonPath';
        final wechatFile = File(fullPath);
        if (wechatFile.existsSync()) {
          final directory = path.dirname(fullPath);
          return directory;
        }
      }
    }

    return null;
  }

  static Future<String?> getWeChatVersion() async {
    try {
      final wechatDir = await getWeChatDirectory();
      if (wechatDir == null) return null;

      final dir = Directory(wechatDir);
      final entities = dir.listSync();

      for (var entity in entities) {
        if (entity is Directory) {
          final dirName = path.basename(entity.path);
          final versionRegex = RegExp(r'^4\.\d+\.\d+\.\d+$');
          if (versionRegex.hasMatch(dirName)) {
            return dirName;
          }
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  static Future<String?> selectDllFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: '请选择DLL文件',
        type: FileType.custom,
        allowedExtensions: ['dll'],
      );

      if (result != null && result.files.isNotEmpty) {
        final file = File(result.files.first.path!);
        if (await file.exists()) {
          return result.files.first.path;
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  static bool killWeChatProcesses() {
    try {
      final pids = findProcessIds('Weixin.exe');

      if (pids.isEmpty) {
        return true;
      }

      for (var pid in pids) {
        final hProcess = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
        if (hProcess != 0) {
          TerminateProcess(hProcess, 0);
          CloseHandle(hProcess);
        }
      }

      Future.delayed(const Duration(seconds: 1));
      return true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> launchWeChat() async {
    try {
      String? wechatPath;

      final wechatDir = await getWeChatDirectory();
      if (wechatDir != null) {
        final weixinPath = path.join(wechatDir, 'Weixin.exe');
        final wechatExePath = path.join(wechatDir, 'WeChat.exe');

        if (await File(weixinPath).exists()) {
          wechatPath = weixinPath;
        } else if (await File(wechatExePath).exists()) {
          wechatPath = wechatExePath;
        }
      }

      wechatPath ??= _getWeChatPathFromRegistry() ?? _findWeChatFromScoop();

      if (wechatPath == null || !await File(wechatPath).exists()) {
        final drives = ['C', 'D', 'E', 'F'];
        final pathPatterns = [
          r'\Program Files\Tencent\WeChat\WeChat.exe',
          r'\Program Files (x86)\Tencent\WeChat\WeChat.exe',
          r'\Program Files\Tencent\Weixin\Weixin.exe',
          r'\Program Files (x86)\Tencent\Weixin\Weixin.exe',
        ];

        for (final drive in drives) {
          for (final pattern in pathPatterns) {
            final fullPath = '$drive:$pattern';
            if (await File(fullPath).exists()) {
              wechatPath = fullPath;
              break;
            }
          }
          if (wechatPath != null && await File(wechatPath).exists()) {
            break;
          }
        }
      }

      if (wechatPath == null || !await File(wechatPath).exists()) {
        return false;
      }

      // ignore: unused_local_variable
      final process = await Process.start(
        wechatPath,
        [],
        mode: ProcessStartMode.detached,
      );

      await Future.delayed(const Duration(seconds: 2));

      final isRunning = isProcessRunning('Weixin.exe');
      return isRunning;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> waitForWeChatWindow({int maxWaitSeconds = 10}) async {
    for (int i = 0; i < maxWaitSeconds * 2; i++) {
      await Future.delayed(const Duration(milliseconds: 500));

      final mainPid = findMainWeChatPid();
      if (mainPid != null) {
        return true;
      }
    }

    return false;
  }

  static Future<bool> waitForWeChatWindowComponents({
    int maxWaitSeconds = 25,
  }) async {
    final deadline = DateTime.now().add(Duration(seconds: maxWaitSeconds));
    int attemptCount = 0;

    while (DateTime.now().isBefore(deadline)) {
      attemptCount++;
      final mainPid = findMainWeChatPid();
      if (mainPid == null) {
        await WxKeyLogger.info('第$attemptCount次检测: 未找到微信主窗口PID');
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      await WxKeyLogger.info('第$attemptCount次检测: 找到微信主窗口PID=$mainPid');
      final handles = _findWechatWindowHandles(targetPid: mainPid);

      if (handles.isEmpty) {
        await WxKeyLogger.warning('第$attemptCount次检测: 未枚举到微信窗口句柄');
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      await WxKeyLogger.info('第$attemptCount次检测: 找到${handles.length}个微信窗口句柄');

      for (final handle in handles) {
        final children = _collectChildWindowInfos(handle);
        _logWechatComponentSnapshot(handle, children);

        if (_hasReadyComponents(children)) {
          await WxKeyLogger.success(
            '检测到微信界面组件已加载完毕 (窗口句柄: $handle, 子窗口数: ${children.length})',
          );
          return true;
        }
      }

      await Future.delayed(const Duration(milliseconds: 500));
    }

    await WxKeyLogger.warning('等待微信界面组件超时(已等待$maxWaitSeconds秒)，但窗口可能已就绪');
    return true;
  }

  static List<int> _findWechatWindowHandles({required int targetPid}) {
    final handles = <int>[];
    _topWindowHandlesCollector = handles;
    _topWindowTargetPid = targetPid;
    EnumWindows(
      Pointer.fromFunction<WNDENUMPROC>(_enumWechatTopWindowProc, 0),
      0,
    );
    _topWindowHandlesCollector = null;
    _topWindowTargetPid = null;
    return handles;
  }

  static int _enumWechatTopWindowProc(int hWnd, int lParam) {
    final collector = _topWindowHandlesCollector;
    final targetPid = _topWindowTargetPid;
    if (collector == null) {
      return 0;
    }

    if (IsWindowVisible(hWnd) == 0) {
      return 1;
    }

    final titleLen = GetWindowTextLength(hWnd);
    if (titleLen == 0) {
      return 1;
    }

    final titleBuffer = calloc<Uint16>(titleLen + 1);
    GetWindowText(hWnd, titleBuffer.cast(), titleLen + 1);
    final title = String.fromCharCodes(
      titleBuffer
          .cast<Uint16>()
          .asTypedList(titleLen + 1)
          .takeWhile((c) => c != 0),
    );
    free(titleBuffer);

    final normalizedTitle = title.trim();
    final normalizedTitleLower = normalizedTitle.toLowerCase();
    final isWeChatTitle = normalizedTitle == '微信' ||
        normalizedTitleLower == 'wechat' ||
        normalizedTitleLower == 'weixin';
    if (!isWeChatTitle) {
      return 1;
    }

    final pidPtr = calloc<DWORD>();
    GetWindowThreadProcessId(hWnd, pidPtr);
    final windowPid = pidPtr.value;
    free(pidPtr);

    if (targetPid != null && windowPid != targetPid) {
      return 1;
    }

    collector.add(hWnd);

    return 1;
  }

  static List<_ChildWindowInfo> _collectChildWindowInfos(int parentHwnd) {
    final children = <_ChildWindowInfo>[];
    _childWindowCollector = children;
    EnumChildWindows(
      parentHwnd,
      Pointer.fromFunction<WNDENUMPROC>(_enumChildWindowProc, 0),
      0,
    );
    _childWindowCollector = null;
    return children;
  }

  static int _enumChildWindowProc(int hWnd, int lParam) {
    final collector = _childWindowCollector;
    if (collector == null) {
      return 0;
    }

    final titleLen = GetWindowTextLength(hWnd);
    final titleBuffer = calloc<Uint16>(titleLen + 1);
    String title = '';
    if (titleLen > 0) {
      GetWindowText(hWnd, titleBuffer.cast(), titleLen + 1);
      title = String.fromCharCodes(
        titleBuffer
            .cast<Uint16>()
            .asTypedList(titleLen + 1)
            .takeWhile((c) => c != 0),
      );
    }
    free(titleBuffer);

    final classBuffer = calloc<Uint16>(256);
    final classLen = GetClassName(hWnd, classBuffer.cast(), 256);
    final className = classLen > 0
        ? String.fromCharCodes(
            classBuffer.cast<Uint16>().asTypedList(classLen),
          )
        : '';
    free(classBuffer);

    collector.add(_ChildWindowInfo(hWnd, title.trim(), className.trim()));
    return 1;
  }

  static bool _hasReadyComponents(List<_ChildWindowInfo> children) {
    if (children.isEmpty) {
      return true;
    }

    var classMatchCount = 0;
    var titleMatchCount = 0;
    var hasValidClassName = false;

    for (final child in children) {
      final normalizedTitle = child.title.replaceAll(RegExp(r'\s+'), '');
      if (normalizedTitle.isNotEmpty) {
        for (final marker in _readyComponentTexts) {
          if (normalizedTitle.contains(marker)) {
            return true;
          }
        }
        titleMatchCount++;
      }

      final className = child.className;
      if (className.isNotEmpty) {
        if (_readyComponentClassMarkers
            .any((marker) => className.contains(marker))) {
          return true;
        }
        if (className.length > 5) {
          classMatchCount++;
          hasValidClassName = true;
        }
      }
    }

    if (classMatchCount >= 3 || titleMatchCount >= 2) {
      return true;
    }

    if (children.length >= _readyChildCountThreshold) {
      return true;
    }

    if (hasValidClassName && children.length >= 5) {
      return true;
    }

    return true;
  }

  static void _logWechatComponentSnapshot(
    int hwnd,
    List<_ChildWindowInfo> children,
  ) {
    if (children.isEmpty) {
      return;
    }

    final snapshot = children
        .take(6)
        .map((child) {
          final title = child.title.isEmpty ? '<空标题>' : child.title;
          final cls = child.className.isEmpty ? '<无类名>' : child.className;
          return '$cls:$title';
        })
        .join(' | ');

    WxKeyLogger.info('微信窗口 $hwnd 子窗口(${children.length}) 快照: $snapshot');
  }

  static int? findMainWeChatPid() {
    final enumWindowsProc =
        Pointer.fromFunction<WNDENUMPROC>(_enumWindowsProc, 0);
    final pidsPtr = calloc<Pointer<Int32>>();
    pidsPtr.value = calloc<Int32>(100);

    for (int i = 0; i < 100; i++) {
      pidsPtr.value[i] = 0;
    }

    try {
      EnumWindows(enumWindowsProc, pidsPtr.address);

      final pids = <int>[];
      for (int i = 0; i < 100; i++) {
        final pid = pidsPtr.value[i];
        if (pid == 0) break;
        pids.add(pid);
      }

      if (pids.isNotEmpty) {
        return pids.first;
      } else {
        return null;
      }
    } finally {
      free(pidsPtr.value);
      free(pidsPtr);
    }
  }

  static int _enumWindowsProc(int hWnd, int lParam) {
    try {
      final processId = calloc<DWORD>();
      GetWindowThreadProcessId(hWnd, processId);

      final titleLength = GetWindowTextLength(hWnd);
      if (titleLength > 0) {
        final titleBuffer = calloc<Uint16>(titleLength + 1);
        GetWindowText(hWnd, titleBuffer.cast(), titleLength + 1);
        final title = String.fromCharCodes(
          titleBuffer.asTypedList(titleLength + 1).takeWhile((c) => c != 0),
        );
        free(titleBuffer);

        final titleLower = title.toLowerCase();
        if (title.contains('微信') ||
            titleLower.contains('wechat') ||
            titleLower.contains('weixin')) {
          final pidsPtr = Pointer<Pointer<Int32>>.fromAddress(lParam);
          final pids = pidsPtr.value;
          for (int i = 0; i < 100; i++) {
            if (pids[i] == 0) {
              pids[i] = processId.value;
              break;
            }
          }
        }
      }

      free(processId);
      return 1;
    } catch (e) {
      return 1;
    }
  }

  static String getLastErrorMessage() {
    final errorCode = GetLastError();
    if (errorCode == 0) return '';

    final buffer = calloc<Uint16>(256);
    FormatMessage(
      FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr,
      errorCode,
      0,
      buffer.cast(),
      256,
      nullptr,
    );

    final message = String.fromCharCodes(
      buffer.asTypedList(256).takeWhile((c) => c != 0),
    );
    free(buffer);
    return message;
  }
}

class _ChildWindowInfo {
  _ChildWindowInfo(this.hwnd, this.title, this.className);

  final int hwnd;
  final String title;
  final String className;
}

