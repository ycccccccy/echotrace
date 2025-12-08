# WCDB Native 接口集成指南

本指南旨在帮助开发者通过 `wcdb_api.dll` 高效访问微信本地数据库。我们封装了底层的解密、多库聚合与查询逻辑，你只需调用简单的 C 接口即可获取完整的会话与消息数据。

## 1. 快速集成

### 平台与部署
*   **支持平台**：Windows x64
*   **文件部署**：请将 `wcdb_api.dll` 及其依赖的 `WCDB.dll` 放置在应用程序可加载的目录下。
    *   *推荐*：与可执行文件同级，或放置在 `data/flutter_assets/assets/dll/` 等资源目录。
    *   *加载*：确保您的语言运行时（如 Dart FFI）能通过路径找到该动态库。

### 核心开发约定
在调用接口前，请务必了解以下约定，以避免常见的内存泄漏或逻辑错误：

1.  **状态码 (`wcdb_status`)**
    *   所有接口均返回整型状态码。
    *   `0`：操作成功。
    *   `< 0`：操作失败（如参数错误、解密失败等）。

2.  **内存管理 (Critical)**
    *   **规则**：凡是 DLL 通过指针参数（`char**`）返回的字符串数据，使用完毕后**必须**调用 `wcdb_free_string` 进行释放。
    *   **后果**：忽略此步骤将导致严重的内存泄漏。

3.  **数据格式**
    *   复杂数据结构（如消息列表、联系人信息）均以 **UTF-8 JSON 字符串** 形式返回，便于跨语言解析。

---

## 2. 接口详解

### 2.1 生命周期管理
在使用任何业务功能前，请确保环境已初始化。

*   **初始化**
    ```c
    wcdb_status wcdb_init();
    ```
    加载日志缓冲与内部状态。可重复调用，但在进程启动时调用一次即可。

*   **清理**
    ```c
    wcdb_status wcdb_shutdown();
    ```
    清理所有内部状态并强制关闭所有未关闭的账号句柄。建议在进程退出前调用。

### 2.2 账号连接
一切数据操作均基于“账号句柄”。

*   **打开账号**
    ```c
    wcdb_status wcdb_open_account(const char* session_db_path, const char* hex_key, wcdb_handle* out_handle);
    ```
    *   `session_db_path`: 核心数据库路径（`db_storage`）。
        *   *智能查找*：DLL 会自动在同级目录下查找并挂载关联的 `message_*.db` 和 `contact*.db`，无需手动指定。
    *   `hex_key`: 64位十六进制密钥。
    *   `out_handle`: 成功时，此指针将接收一个非零的句柄值。

*   **关闭账号**
    ```c
    wcdb_status wcdb_close_account(wcdb_handle handle);
    ```
    释放该账号占用的所有数据库连接资源。

### 2.3 数据查询
以下接口均需要有效的 `wcdb_handle`。

#### 会话列表
```c
wcdb_status wcdb_get_sessions(wcdb_handle handle, char** out_json);
```
*   返回包含所有聊天会话的 JSON 数组。若找不到会话表，将返回包含 `_error` 字段的 JSON 用于诊断。

#### 消息记录
```c
wcdb_status wcdb_get_messages(wcdb_handle handle, const char* username, int32_t limit, int32_t offset, char** out_json);
```
*   **功能**：获取指定用户（`username`）的消息记录。
*   **特性**：内部自动扫描所有分库（`message_*.db`），按 `sort_seq` 或时间戳降序排序，并执行分页。
*   **返回**：JSON 数组，包含消息详情及 `computed_is_send`（是否发送方）等辅助字段。

#### 消息统计
```c
wcdb_status wcdb_get_message_count(wcdb_handle handle, const char* username, int32_t* out_count);
```
*   快速获取指定会话的消息总数。

#### 联系人信息
```c
// 批量获取昵称
wcdb_status wcdb_get_display_names(wcdb_handle handle, const char* usernames_json, char** out_json);

// 批量获取头像 URL
wcdb_status wcdb_get_avatar_urls(wcdb_handle handle, const char* usernames_json, char** out_json);
```
*   **入参**：`usernames_json` 为 JSON 字符串数组，如 `["wxid_a", "wxid_b"]`。
*   **返回**：JSON 对象，Key 为 `username`，Value 为对应信息。

### 2.4 群聊工具
```c
// 获取群成员数量
wcdb_status wcdb_get_group_member_count(wcdb_handle handle, const char* chatroom_id, int32_t* out_count);

// 获取群成员列表（含头像信息）
wcdb_status wcdb_get_group_members(wcdb_handle handle, const char* chatroom_id, char** out_json);
```

### 2.5 调试与诊断
```c
wcdb_status wcdb_get_logs(char** out_json);
```
*   当接口返回错误或数据为空时，调用此接口获取内部运行日志。日志包含详细的路径检查、解密尝试和 SQL 错误信息，是排查问题的首选工具。
*   **注意**：同样需要调用 `wcdb_free_string` 释放日志字符串。

---

## 3. 调用示例 (C/C++ 伪代码)

```c
// 1. 全局初始化
wcdb_init();

wcdb_handle handle = 0;
const char* db_path = "C:\\Users\\...\\Msg\\MicroMsg.db";
const char* key = "a1b2...e8f9"; // 64位密钥

// 2. 打开账号
if (wcdb_open_account(db_path, key, &handle) == 0) {
    
    // 3. 获取会话列表
    char* sessions_json = NULL;
    if (wcdb_get_sessions(handle, &sessions_json) == 0) {
        printf("Sessions: %s\n", sessions_json);
        wcdb_free_string(sessions_json); // 记得释放！
    }

    // 4. 获取某个会话的消息
    char* msgs_json = NULL;
    // 获取最新 50 条
    if (wcdb_get_messages(handle, "wxid_target", 50, 0, &msgs_json) == 0) {
        printf("Messages: %s\n", msgs_json);
        wcdb_free_string(msgs_json); // 记得释放！
    }

    // 5. 关闭账号
    wcdb_close_account(handle);
} else {
    // 打开失败，查看日志
    char* logs = NULL;
    wcdb_get_logs(&logs);
    printf("Error Logs: %s\n", logs);
    wcdb_free_string(logs);
}

// 6. 全局清理
wcdb_shutdown();
```

## 4. 常见问题排查

*   **返回 -2 (密钥错误)**：请检查密钥是否为 64 位十六进制字符串。DLL 内部会尝试多种页大小（4096/1024），若均失败则返回此错误。
*   **找不到消息**：确保 `session_db_path` 所在的目录下存在 `message_1.db` 等文件。DLL 依赖相对路径查找分库。
*   **多线程安全**：建议在应用层对同一个 `wcdb_handle` 的操作进行加锁（Mutex），不同 `wcdb_handle` 之间互不影响。
