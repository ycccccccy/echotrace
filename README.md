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

当我第一次从生成的报告里，看到自己和某个朋友不知不觉间竟聊了上万句话时，内心竟有了一丝触动

我看到深夜里的对话，看到几万句话背后默默的陪伴，看到时间是如何悄无声息地，将一些人带到你的生命里，又将另一些人轻轻推向远方

我们总是在向前走，却很少有机会回头看看

如果这份小小的报告，能让你想起某个很久没联系的朋友，能让你对当下的陪伴心存感激，或者能在某个平凡的午后，给你带来一丝微笑和暖意，那么，这一切就都有了意义

##  一些想法

也许你会问，翻看旧聊天记录有什么意义？

因为记忆会骗人，但数据不会

你可能忘了去年今日你在和谁聊天，忘了某个重要的人是什么时候开始淡出你的生活，也忘了那些看似普通的日子里，其实藏着多少温暖的瞬间

EchoTrace 做的，就是把这些被遗忘的片段重新拼起来。它不会评判你的社交方式，不会告诉你应该和谁联系、和谁断联。它只是安静地呈现：这就是你的这一年，这些就是陪你走过来的人

有时候，我们需要这样一个机会，好好看看自己走过的路

##  如何使用

只需三步，即可在数字的世界中留下属于你的影像

###  **第一步：准备工作**

开始之前，你需要微信的**数据库密钥** 

**工具**：[wx\_key 获取工具 (Windows)](https://github.com/ycccccccy/wx_key/)

**要求**：该工具目前支持 **PC 微信 4.1.x** 版本。你需要先将微信升级到该版本，登录后才能获取密钥

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
- [ ] **情感分析**：通过 AI 分析对话情绪，看看你们的快乐与悲伤曲线
- [ ] **更多可视化图表**：加入更多有趣的统计维度，如“年度词云”、“表情包大战”等

**有任何想法？欢迎通过 [Issues](https://github.com/ycccccccy/echotrace/issues) 告诉我们！**

##  致谢与许可

本项目基于 **MIT 许可** - 你可以自由使用、修改和分发，但需自行承担风险

本项目在开发过程中参考了以下开源项目，特此致谢：

- **[chatlog](https://github.com/sjzar/chatlog)**：感谢该项目为解密微信聊天记录提供了重要思路和参考
- **[WxDatDecrypt](https://github.com/recarto404/WxDatDecrypt)**：感谢该项目为解密微信图片提供了解密方法参考


##  写在最后

如果你正在使用 EchoTrace，我想对你说声谢谢

谢谢你愿意花时间回望，愿意用这样的方式珍视那些对话和陪伴

也许在生成报告的过程中，你会想起某个很久没联系的朋友，也许你会发现某个人一直在默默陪伴，也许你只是会心一笑，感叹时光飞逝

无论如何，希望这个小工具能成为你生命中一个温暖的见证

如果它真的让你有所触动，不妨把它分享给你在意的人

毕竟，能一起回忆的人，才是真正值得珍惜的人

---


<div align="center">

**请负责任地使用本工具，遵守相关法律法规**

时光会走，故事会旧，但有些人值得一直记得

</div>


