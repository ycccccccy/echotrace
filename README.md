# EchoTrace

> 每一条消息，都是穿越时光的回声

EchoTrace 是一个**本地、安全**的微信聊天记录导出、分析与年度报告生成工具。它能将你电脑里那些被加密隐藏的对话，变成一份份生动的回忆报告，帮你从数据中发现与朋友间被遗忘的时光宝藏

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

微信承载了我们太多的故事——深夜的长谈、朋友的玩笑、日常的问候。但这些记忆都被锁在难以访问的加密数据库中，我们只能在手机的小屏幕上艰难地回溯

EchoTrace 让你挣脱这些束缚，让你能清晰地回顾所有对话，还能从数据中发现被忽略的细节

**你的数据，应该为你讲述属于你自己的故事**

##  如何使用

只需三步，即可在数字的世界中留下属于你的影像

###  **第一步：准备工作**

开始之前，你需要微信的**数据库密钥** 

**工具**：[wx\_key 获取工具 (Windows)](https://github.com/ycccccccy/wx_key/)

**要求**：该工具目前支持 **PC 微信 4.1.x** 版本。你需要先将微信升级到该版本，登录后才能获取密钥

对于图片的两个密钥也是在这个应用内获取，取得密钥后填入设置内对应区域即可


###  **第二步：配置与解密**

1.  前往 Release 下载最新版本的Zip，解压后运行exe文件
2.  打开 EchoTrace，进入 **设置** 页面
3.  填入你在上一步获取的 **密钥**
4.  点击 **自动检测数据库位置**，然后保存配置
5.  切换到 **数据管理** 页面，点击 **批量解密**，程序会自动开始工作。请耐心等待，直到处理完成

如果你的电脑上没有足够的聊天记录，也可以从手机中导入到电脑后再解密数据库，效果是一样的

###  **第三步：查看报告**

解密完成后，进入 **数据分析** 页面，即可开始探索你的年度报告、好友报告和详细聊天记录了

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

##  未来计划

我们正在努力让 EchoTrace 变得更好，未来计划实现以下功能：

- [ ] **更丰富的消息支持**：解析并展示语音、视频、文件和表情包
- [ ] **导出与分享**：将生成的报告导出为图片或 PDF，方便你分享给朋友。
- [ ] **情感分析**：通过 AI 分析对话情绪，看看你们的快乐与悲伤曲线
- [ ] **更多可视化图表**：加入更多有趣的统计维度，如“年度词云”、“表情包大战”等

**有任何想法？欢迎通过 [Issues](https://github.com/ycccccccy/echotrace/issues) 告诉我们！**

##  重要声明

*    **数据安全**：本项目为**纯本地工具**，你的所有数据（包括密钥和聊天记录）都只存在于你自己的电脑上，请放心使用
*    **合法使用**：本工具仅供个人用于备份和回顾自己的历史数据。**严禁用于侵犯他人隐私或任何非法用途**，使用者需自行承担所有风险
*    **兼容性**：目前主要针对微信 PC 4.x 版本的加密方式。不同版本的微信可能导致解密失败

##  致谢与许可

本项目基于 **MIT 许可** - 你可以自由使用、修改和分发，但需自行承担风险

做这个项目的初衷其实很简单：我想知道，这些年来，时间都带我遇见了谁，又留下了些什么

当我第一次从生成的报告里，看到自己和某个朋友不知不觉间竟聊了上万句话时，内心竟有了一丝触动

我看到深夜里的对话，看到几万句话背后默默的陪伴，看到时间是如何悄无声息地，将某些人带到你的生命里，又将某些人轻轻推向远方

我们总是在向前走，却很少有机会回头看看

如果 EchoTrace 的这份小小报告，能让你想起某个很久没联系的朋友，能让你对当下的陪伴心存感激，或者能在某个平凡的午后，给你带来一丝微笑和暖意，那么，这一切就都有了意义

愿我们都能在回望时，发现自己曾被温柔地爱着

---

*我们终将在某个时刻回首，感谢自己曾如此用心地记录下每一次相遇与告别*
