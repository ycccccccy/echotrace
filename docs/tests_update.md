# 测试补充说明（当前版本 基于2.3.12）

## 已新增的测试文件（仅 test/ 与 integration_test/）
- utils：`test/utils/path_utils_test.dart`（从根目录迁移）、`string_utils_test.dart`、`xml_message_parser_test.dart`、`batch_processor_test.dart`、`cpu_info_test.dart`
- models：`test/models/message_test.dart`、`chat_session_test.dart`、`analytics_data_test.dart`、`advanced_analytics_data_test.dart`
- services：
  - 配置/日志：`test/services/config_service_test.dart`、`logger_service_test.dart`
  - 导出：`test/services/chat_export_service_test.dart`（JSON/HTML/Excel，基于假联系人库与假数据库服务）
  - 数据库：`test/services/database_service_test.dart`（备份模式基础连接/缺失文件），`test/services/analytics_service_test.dart`、`test/services/advanced_analytics_service_test.dart`
  - 其他：`decrypt_service_test.dart`、`group_chat_service_test.dart`、`media_decrypt_service_test.dart`、`wxid_scan_service_test.dart`、`relationship_analyzers_test.dart`
- CLI：`test/cli/cli_export_runner_test.dart`（参数解析），`test/cli/cli_export_runner_full_test.dart`（注入假服务跑 json/html/excel 分支）
- Widgets：`test/widgets/app_smoke_test.dart`（从根目录迁移）、`test/widgets/shimmer_loading_test.dart`、`test/widgets/sidebar_test.dart`
- 集成：`integration_test/flow_import_to_export_test.dart`（假联系人库 + 假数据库服务导出 JSON）
- 保留原有：`test/path_utils_test.dart` 等。

## 覆盖现状
- 覆盖了工具函数、模型、配置、日志、导出三格式、统计（假实现）、群聊统计、媒体解密假实现、关系分析、CLI 参数与全流程（基于注入的假服务）、部分小组件。
- 集成测试以假数据模拟导出链路，不依赖真实微信数据库/媒体。

### 具体功能对应的测试
- 路径/文本/解析工具：`test/utils/path_utils_test.dart`（路径规范化/长路径前缀/UNC/盘符大写等）、`string_utils_test.dart`、`xml_message_parser_test.dart`、`batch_processor_test.dart`、`cpu_info_test.dart`
- 数据模型：`test/models/message_test.dart`（文本/语音时长/撤回/引用）、`chat_session_test.dart`、`analytics_data_test.dart`、`advanced_analytics_data_test.dart`
- 配置/日志：`test/services/config_service_test.dart`、`logger_service_test.dart`
- 导出服务：`test/services/chat_export_service_test.dart`（JSON/HTML/Excel 基于假联系人库 + 假数据库服务）
- 数据库服务：`test/services/database_service_test.dart`（备份模式连接与缺失文件）
- 统计服务：`test/services/analytics_service_test.dart`（假聚合）、`advanced_analytics_service_test.dart`（热力图/年过滤/对话平衡）
- 其他服务：`decrypt_service_test.dart`（基类/备份/假实现）、`group_chat_service_test.dart`、`media_decrypt_service_test.dart`、`wxid_scan_service_test.dart`、`relationship_analyzers_test.dart`
- CLI：`test/cli/cli_export_runner_test.dart`（参数解析）、`test/cli/cli_export_runner_full_test.dart`（注入假服务覆盖 json/html/excel 全流程）
- Widgets：`test/widgets/shimmer_loading_test.dart`、`test/widgets/sidebar_test.dart`
- 集成：`integration_test/flow_import_to_export_test.dart`（假联系人库 + 假数据库服务导出 JSON；CLI `-h`）

## 仍缺少的真实场景（需额外依赖/样本）
- DatabaseService 实时模式（WCDB DLL）及完整查询链路。
- 导出服务在真实解密数据库/媒体上的端到端（含大体积/异常媒体）。
- 页面级 Widget 交互（聊天/分析/导出/设置等）和年度报告 golden，需要 mock 服务 + 消息/资产。
- 高级统计排名/语言风格等在真实消息样本上的校验。

## 运行测试
在项目根执行：
```
cd "C:\Users\echotrace-main (1)\echotrace-main"（你的本地项目源码位置下）
$env:PATH="$env:USERPROFILE\dev\flutter_windows_3.38.5-stable\flutter\bin;$env:PATH"
flutter test
```
如需单独文件，可指定 `flutter test <path>`。首次可能下载依赖，若超时可重试。
