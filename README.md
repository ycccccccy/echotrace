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

> [!TIP]
> 如果导出聊天记录后，想深入分析聊天内容可以试试 [ChatLab](https://chatlab.fun/)

##  快速开始

面向新手的使用教程见 [此文档](docs/beginner_guide.md)

##  EchoTrace 为何而来

我想知道，这些年来，时间都带我遇见了谁，又留下了些什么

从生成的报告里，看到自己和某个朋友不知不觉间竟聊了上万句话，看到深夜里和朋友的互相倾诉，看到几万句话背后默默的陪伴，看到时间是如何悄无声息地，将一些人带到你的生命里，又将另一些人轻轻推向远方

我们总是在向前走，却很少有机会回头看看

如果这份小小的报告，能让你想起某个很久没联系的朋友，能让你对当下的陪伴心存感激，或者能在某个平凡的午后，给你带来一丝微笑和暖意，那么，这一切就都有了意义


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

- [✅] **更丰富的消息支持**：解析并展示语音、图片和表情包
- [ ] **更多可视化图表**：加入更多有趣的统计维度，如“年度词云”、“表情包大战”等

双人年度报告：
- [✅] **基本的统计信息**：两人最开始的聊天日期，以及年度统计
- [ ] **消息类型统计**： 通过雷达图来反应两个人发送的消息类型（语音、图片、视频、文件、表情包、文本）的多少，以及两个人各自发了多少条消息
- [ ] **聊天时段分布**：统计两个人在一天中最常发微信的时间，以及一年中发送消息的热点图
- [ ] **词云统计**：统计两个人最长发送的词语
- [ ] **年度报告总结**：总结出两人的聊天报告 生成简短的图片


**有任何想法？欢迎通过 [Issues](https://github.com/ycccccccy/echotrace/issues) 告诉我们！**

##  致谢与许可

本项目基于 **MIT 许可** - 你可以自由使用、修改和分发，但需自行承担风险

本项目在开发过程中参考了以下开源项目，特此致谢：

- **[chatlog](https://github.com/sjzar/chatlog)**：感谢该项目为解密微信聊天记录提供了重要思路和参考
- **[WxDatDecrypt](https://github.com/recarto404/WxDatDecrypt)**：感谢该项目为解密微信图片提供了解密方法参考
- **[@sai595870682](https://github.com/sai595870682)**：感谢该用户提供了内联图片与语音解析的思路



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


