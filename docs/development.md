## 开发者指引 / 架构总览

### 运行时流程
- 入口：`lib/main.dart` 启动时先检测 CLI 参数（无则继续 UI），创建全局 `AppState`（Provider）并渲染 `EchoTraceApp`。
- `AppState` 负责初始化日志、配置、数据库连接（实时/备份）、错误与加载状态、解密进度、头像缓存等。UI 通过 `Consumer<AppState>` 订阅状态。
- `HomePage` 搭配 `Sidebar` 实现主布局，根据 `AppState.currentPage` 切换各业务页面（欢迎、聊天、数据分析、群聊分析、导出、数据管理、设置）。

### 数据与解密
- 数据库读取由 `DatabaseService` 承载，支持两种模式：
  - 备份模式：使用 sqflite 只读连接解密后的 SQLite（session/message/contact）。
  - 实时模式：通过 `wechat_wcdb_native.dart` 调用 Windows DLL 直接读取加密 WCDB。
- 解密：默认使用 Go FFI（`DecryptServiceGo` -> `GoDecryptFFI`），另有 Dart 备份实现；图片解密在 `ImageDecryptService`。
- 配置：`ConfigService` 持久化解密密钥、数据库路径、实时/备份模式、图片密钥、调试开关等。

### 业务服务
- `AnalyticsService` 与高级分析/缓存后台服务负责私聊/全局统计、时间分布、词频、年度/双人报告等。
- `ChatExportService` 负责 JSON/HTML/Excel 导出，页面 `ChatExportPage` 与 CLI 共用。
- 群聊相关能力在 `GroupChatService` 及群聊页面系列（活跃度、成员、媒体统计等）。
- 日志：`LoggerService` 统一 info/debug/warning/error，CLI 也输出到临时文件。

### CLI 导出
- `lib/cli/cli_export_runner.dart` 拦截命令行参数（仅 Windows），初始化 `AppState` 与数据库后批量导出，会话筛选与时间范围与 UI 保持一致。

### 模型与工具
- 核心模型：`ChatSession`、`Message`、`Contact`、`AnalyticsData` 等，位于 `lib/models/`。
- 工具：`path_utils.dart`（路径/特殊字符兼容）、`string_utils.dart`（文本）、`xml_message_parser.dart`（消息 XML 解析）、`batch_processor.dart`（批处理节流）。

### 主要文件和目录
- `lib/main.dart`：应用与 CLI 启动入口，构建主题与全局 Provider。
- `lib/providers/app_state.dart`：全局状态、数据库重连、解密进度、头像缓存。
- `lib/services/database_service.dart`：数据库连接、实时 DLL 访问、跨库消息查询与统计。
- `lib/services/analytics_service.dart` 及 `advanced_analytics_service.dart`：统计分析。
- `lib/services/chat_export_service.dart`：导出实现，供 UI/CLI 复用。
- `lib/services/decrypt_service_go.dart` / `go_decrypt_ffi.dart`：数据库解密。
- `lib/services/config_service.dart`：配置持久化。
- `lib/services/wechat_wcdb_native.dart`：WCDB DLL FFI 封装。
- `lib/pages/`：各个业务页面与布局；`widgets/`：可复用组件（侧边栏、气泡、进度遮罩等）。
- `lib/utils/`：通用工具。

### 构建与调试提示
- 依赖：`flutter pub get`。
- 运行：`flutter run`（桌面需已启用目标平台），或 `flutter build windows/macos/linux`。
- CLI：Windows 上直接运行可执行文件，使用 `-e/--format/--start/--end/--all` 参数导出。
- 日志：App 内部使用 `LoggerService`，CLI 模式附加输出到系统临时目录的 `echotrace_cli.log`。
