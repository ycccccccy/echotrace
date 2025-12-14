# EchoTrace

EchoTrace 是一个**完全本地**的微信聊天记录导出、分析与年度报告生成工具。它可以解密你的微信聊天记录并保存在本地离线查看，也可以将其导出为HTML等与朋友分享，还可以根据你的聊天记录为你生成独一无二的分析报告❤️

---

<p align="center">
  <img src="echotrace.png" alt="EchoTrace 功能演示" width="80%">
</p>

---

<p align="center">
<a href="https://github.com/ycccccccy/echotrace/stargazers">
<img src="https://img.shields.io/github/stars/ycccccccy/echotrace?style=flat-square" alt="Stargazers">
</a>
<a href="https://github.com/ycccccccy/echotrace/network/members">
<img src="https://img.shields.io/github/forks/ycccccccy/echotrace?style=flat-square" alt="Forks">
</a>
<a href="https://github.com/ycccccccy/echotrace/issues">
<img src="https://img.shields.io/github/issues/ycccccccy/echotrace?style=flat-square" alt="Issues">
</a>
<a href="https://github.com/ycccccccy/echotrace/blob/main/LICENSE">
<img src="https://img.shields.io/github/license/ycccccccy/echotrace?style=flat-square" alt="License">
</a>
</p>

##  EchoTrace 为何而来

我想知道，这些年来，时间都带我遇见了谁，又留下了些什么

从生成的报告里，看到自己和某个朋友不知不觉间竟聊了上万句话，看到深夜里和朋友的互相倾诉，看到几万句话背后默默的陪伴，看到时间是如何悄无声息地，将一些人带到你的生命里，又将另一些人轻轻推向远方

我们总是在向前走，却很少有机会回头看看

如果这份小小的报告，能让你想起某个很久没联系的朋友，能让你对当下的陪伴心存感激，或者能在某个平凡的午后，给你带来一丝微笑和暖意，那么，这一切就都有了意义

##  如何使用

只需三步，即可在数字的世界中留下属于你的影像

###  **第一步：准备工作**

开始之前，你需要微信的**数据库密钥** 

**工具**：[wx\_key 获取工具 (Windows)](https://github.com/ycccccccy/wx_key/)

**要求**：该工具目前支持 **PC 微信 4.0.x.x** 版本。你需要先将微信升级到该版本，登录后才能获取密钥

对于图片的两个密钥也是在这个应用内获取，取得密钥后填入设置内对应区域即可


###  **第二步：配置与解密**

1.  前往 [Release](https://github.com/ycccccccy/echotrace/releases) 下载最新版本的echotrace.zip，解压后运行exe文件
2.  打开 EchoTrace，进入 **设置** 页面
3.  填入你在上一步获取的 **密钥**
4.  点击 **自动检测数据库位置**，然后保存配置
5.  切换到 **数据管理** 页面，点击 **批量解密**，程序会自动开始工作。请耐心等待，直到处理完成

如果你的电脑上没有足够的聊天记录，也可以从手机中导入到电脑后再解密数据库，效果是一样的

###  **第三步：查看报告**

解密完成后，进入 **数据分析** 页面，即可开始探索你的年度报告、好友报告和详细聊天记录了

###  Windows 命令行导出

在 Windows 上可直接使用命令行导出聊天记录（需要先在应用内完成密钥配置并解密数据库）：

```powershell
# 将所有会话按指定格式导出到目标目录
echotrace.exe -e C:\Exports --format html --all

# 按日期范围导出（默认 JSON）
echotrace.exe -e C:\Exports --start 2024-01-01 --end 2024-12-31
```

参数说明：

- `-e <目录>` 必填，导出目录
- `--format json|html|excel` 选填，默认 `json`
- `--start YYYY-MM-DD` / `--end YYYY-MM-DD` 选填，指定时间范围
- `--all` 忽略时间范围，导出全部

##  面向开发者 

如果你想从源码构建或为项目贡献代码，请遵循以下步骤：

```bash
# 1. 克隆项目到本地
git clone https://github.com/ycccccccy/echotrace.git
cd echotrace

# 2. 安装项目依赖
flutter pub get

# 3. 运行应用（调试模式）
flutter run

# 4. 打包可执行文件 (以 Windows 为例)
flutter build windows
```

更多架构、文件职责、调试与 CLI 说明，请阅读 [开发者指引](docs/development.md)。

关于实时模式的实现可阅读 [模块调用文档](docs/wcdb_realtime.md)

##  未来计划

我们正在努力让 EchoTrace 变得更好，未来计划实现以下功能：

- [ ] **更丰富的消息支持**：解析并展示语音、视频、文件和表情包
- [ ] **情感分析**：通过 AI 分析对话情绪，看看你们的快乐与悲伤曲线
- [ ] **更多可视化图表**：加入更多有趣的统计维度，如“年度词云”、“表情包大战”等

**有任何想法？欢迎通过 [Issues](https://github.com/ycccccccy/echotrace/issues) 告诉我们！**

##  致谢与许可

本项目基于 **MIT 许可** - 你可以自由使用、修改和分发，但需自行承担风险

本项目在开发过程中参考了以下开源项目，特此致谢：

- **[chatlog](https://github.com/sjzar/chatlog)**：感谢该项目为解密微信聊天记录提供了重要思路和参考
- **[WxDatDecrypt](https://github.com/recarto404/WxDatDecrypt)**：感谢该项目为解密微信图片提供了解密方法参考


##  写在最后

也许在生成报告的过程中，你会想起某个很久没联系的朋友，也许你会发现某个人一直在默默陪伴，也许你只是会心一笑，感叹时光飞逝

无论如何，希望这个小工具能成为你生命中一个温暖的见证

如果它真的让你有所触动，不妨把它分享给你在意的人

只要好友还在，我们还记得彼此

总有一天，我们会再次相见

---

##  Star History

<div align="center">
  <a href="https://star-history.com/#ycccccccy/echotrace&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=ycccccccy/echotrace&type=Date&theme=dark" />
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=ycccccccy/echotrace&type=Date" />
      <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=ycccccccy/echotrace&type=Date" />
    </picture>
  </a>
</div>


<div align="center">

---

**请负责任地使用本工具，遵守相关法律法规**

比起沉浸在回忆里，也许珍惜眼前的人会更重要一点

</div>


