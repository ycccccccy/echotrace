/// 年度报告文案配置
///
/// 记录并管理年度报告中的每一句文字。
/// 我们相信，每一次对话都值得被认真对待。
/// 注释中的 [显示效果] 会说明文案在页面上的呈现方式。
class AnnualReportTexts {
  // ========== 封面页 ==========
  // [显示效果] 顶部灰色小标题
  static const coverTitle = '时光留痕';

  // [显示效果] 中间大标题，绿色
  // 完整显示："2024年 聊天年度报告" 或 "历史以来 聊天年度报告"
  static const coverSubtitle = '聊天年度报告';

  // [显示效果] 中部诗句第一行
  static const coverPoem1 = '每一条消息背后';

  // [显示效果] 中部诗句第二行
  // 完整显示：
  // "每一条消息背后
  //  都藏着一段真实的心情"
  static const coverPoem2 = '都藏着一段独特的心情';

  // [显示效果] 底部灰色提示文字
  static const coverHint = '滑动鼠标或按方向键，回顾这段时光';

  // [显示效果] 底部方向键符号
  static const coverArrows = '←  →';

  // ========== 开场页 ==========
  // [显示效果] "在2024年里" 或 "在这段时光里"
  static const introPrefix = '在';
  static const introSuffix = '里';

  // [显示效果] "你与 15 位好友"
  static const introWithFriends = '你与 ';
  static const introFriendsUnit = ' 位好友';

  // [显示效果] 中间连接词
  // 完整显示：
  // "在2024年里
  //  你与 15 位好友
  //  有过
  //  12345 次对话"
  static const introExchanged = '有过';
  static const introMessagesUnit = ' 次对话';

  // 开场评语（根据消息数量动态生成）
  // [显示效果] 底部的温馨寄语，根据消息总数显示不同文案
  // 示例：消息数 > 50000 时显示：
  // "无数次对话，编织了你们共享的时光
  //  也刻画出彼此成长的模样"
  static String getOpeningComment(int messages) {
    if (messages > 50000) {
      return '无数次对话，编织了你们共享的时光\n也刻画出彼此成长的模样';
    } else if (messages > 20000) {
      return '这些看似零碎的片段，拼凑出了一个完整的故事\n一个关于生活，也关于你们的故事';
    } else if (messages > 10000) {
      return '重要的不是说了多少\n而是在需要的时候，你们都在';
    } else if (messages > 5000) {
      return '每一次敞开心扉的分享\n都让心与心的距离，又拉近了一点';
    } else {
      return '真正的朋友，也许话不多\n但每一次交流，都沉淀着特别的意义';
    }
  }

  // ========== 年度挚友 ==========
  // [显示效果] 页面标题
  static const friendshipTitle = '年度挚友';

  // [显示效果] 开场白
  // 完整显示：
  // "在这一年里
  //  张三
  //  和你聊得最多
  //  共 12345 条消息"
  static const friendshipIntro = '在这一年里';
  static const friendshipMostChats = '和你聊得最多';
  static const friendshipMessagesUnit = ' 共'; // 配合数字显示 "共 12345 条消息"

  // [显示效果] 左右两栏的标题
  // 左栏显示："你发出的"
  // 右栏显示："TA发来的"
  static const friendshipYouSendTo = '你发出的';
  static const friendshipWhoSendsYou = 'TA发来的';

  // [显示效果] 左右两栏显示消息数量
  // 示例："1234 条"
  static const friendshipMessagesCount = ' 条';

  // [显示效果] 显示对方回复数量
  // 左栏示例："TA回复 567 条"
  // 右栏示例："你回复 890 条"
  static const friendshipTheyReply = 'TA回复 ';
  static const friendshipYouReply = '你回复 ';

  // [显示效果] 显示发送/接收比例
  // 示例："发送比例 2.18"
  static const friendshipRatio = '发送比例 ';

  // [显示效果] 底部寄语
  static const friendshipClosing = '得不到的永远在骚动\n被偏爱的都有恃无恐';

  // ========== 双向奔赴 ==========
  // [显示效果] 页面标题
  static const mutualTitle = '双向奔赴';

  // [显示效果] 副标题
  static const mutualSubtitle = '好的关系，是彼此回应的默契';

  // [显示效果] 左右对比显示
  // 完整显示：
  // "你发出        ⇄        TA回应
  //  1234                 1198
  //  条                   条
  //
  //  互动比例 1.03"
  static const mutualYouSent = '你发出';
  static const mutualTheySent = 'TA回应';
  static const mutualMessagesUnit = '条';
  static const mutualRatioPrefix = '互动比例 ';

  // [显示效果] 底部温馨寄语
  static const mutualClosing = '你来我往间的平衡，是一种无需多言的默契';

  // ========== 社交主动性 ==========
  // [显示效果] 页面标题
  static const socialTitle = '社交主动性';

  // [显示效果] 副标题
  static const socialSubtitle = '总有人先开口，每一段故事，都从一句话开始';

  // [显示效果] 百分比后的单位文字
  // 完整显示："你们 72.5% 的对话，由你发起"
  static const socialInitiatedUnit = ' 的对话，由你发起';

  // 社交主动性评语（根据主动率动态生成）
  // [显示效果] 根据主动率显示不同故事
  // 示例 rate=0.75（75%）时显示：
  // "和 张三 聊天时
  //  你更习惯做那个开启话题的人
  //
  //  因为在乎，所以主动
  //  感谢那个愿意先开口的你"
  static String getSocialStory(String friendName, double rate) {
    if (rate > 0.7) {
      return '和 $friendName 聊天时\n你更习惯做那个开启话题的人\n\n因为在乎，所以主动\n感谢那个愿意先开口的你';
    } else if (rate > 0.5) {
      return '你和 $friendName 之间\n谁先开口，似乎并不重要\n\n因为你们总有说不完的话题\n这是一种难得的默契';
    } else {
      return '在与 $friendName 的对话里\n你常常是那个被惦记的人\n\nTA总是带着生活里的点滴来找你\n这份主动，是一份特别的关心';
    }
  }

  // ========== 聊天巅峰日 ==========
  // [显示效果] 页面标题
  static const peakDayTitle = '难忘的一天';

  // [显示效果] 日期描述
  // 完整显示：
  // "2024-05-20
  //  这一天，你们聊了
  //  1234 条消息"
  static const peakDayThisDay = '这一天，你们说了';
  static const peakDayMessagesUnit = ' 句话';

  // [显示效果] 最多聊天的好友
  // 完整显示：
  // "其中和 张三
  //  聊了 567 条"
  static const peakDayWithFriend = '其中和 ';
  static const peakDayChatted = '高达 ';
  static const peakDayChattedUnit = ' 条';

  // 巅峰日评语（根据消息数动态生成）
  // [显示效果] 底部温馨评语，根据当天消息数显示不同内容
  // 示例 count=1500 时显示不同的情感故事
  static String getPeakDayComment(int count) {
    if (count > 1000) {
      return '那一天一定有什么特别的事发生\n让你们话多到停不下来\n也许是开心，也许是陪伴\n总之，那是值得记住的一天';
    } else if (count > 500) {
      return '有些话题就是聊不完\n关于彼此的一切\n都值得用那么多文字去诉说\n这就是珍惜的模样';
    } else if (count > 200) {
      return '那一天的你们，格外话多\n每一条消息都闪闪发光\n因为那是心意相通的表现';
    } else {
      return '偶尔的热烈\n就足以温暖整个平凡的日子\n感谢有TA的陪伴';
    }
  }

  // ========== 连续打卡 ==========
  // [显示效果] 页面标题
  static const checkInTitle = '最长连续聊天';

  // [显示效果] 副标题
  static const checkInSubtitle = '有一种关心，叫每日如常';

  // [显示效果] 天数单位
  // 完整显示：
  // "张三
  //  连续 30 天
  //  2024-01-01 至 2024-01-30"
  static const checkInDaysUnit = ' 天';
  static const checkInDateRange = ' 至 ';

  // [显示效果] 底部温馨寄语
  static const checkInClosing = '那段时间，TA的陪伴从未缺席\n那段时光，TA的陪伴温暖而绵长';

  // ========== 聊天巅峰日页==========
  // [显示效果] 第一句：日期单独显示
  static const peakDayDateStandalone = '日期';

  // [显示效果] 第二句：消息总数
  static const peakDayYouChatted = '你们说了 ';
  static const peakDayMessagesCount = ' 句话';

  // [显示效果] 第三句：好友信息
  static const peakDayWithFriendPrefix = '其中与 ';
  static const peakDayWithFriendSuffix = ' 高达 ';
  static const peakDayWithFriendMessagesUnit = ' 条';

  // ========== 生活节奏 ==========
  // [显示效果] 页面标题
  static const activityTitle = '你的聊天习惯';

  // [显示效果] 副标题
  static const activitySubtitle = '有些时刻，你格外喜欢与人交流';

  // [显示效果] 时间描述
  // 完整显示：
  // "每天的
  //  14:00 左右
  //  似乎是你最活跃的时候"
  static const activityEveryday = '每天的';

  // [显示效果] 底部温馨寄语
  static const activityClosing = '似乎是你最活跃的时候\n这是属于你的节奏\n也是你与世界连接的方式';

  // ========== 深夜密友 ==========
  // [显示效果] 页面标题（紫色）
  static const midnightTitle = '深夜长谈';

  // [显示效果] 副标题
  static const midnightSubtitle = '有些话，只适合在夜里说';

  // [显示效果] 深夜聊天描述
  // 完整显示：
  // "张三
  //  聊了
  //  123 条消息"

  // [显示效果] 时间范围说明
  // 完整显示：
  // "在深夜 0:00 - 6:00
  //  你和 张三
  //  聊了
  //  123 条消息
  //  占你深夜消息的 45.6%"
  static const midnightTimeRange = '在深夜 0:00 - 6:00';
  static const midnightChattedWith = '你和';
  static const midnightChattedPrefix = '说过';
  static const midnightMessagesUnit = ' 句话';
  static const midnightPercentagePrefix = '占你深夜消息的 ';
  static const midnightPercentageSuffix = '%';

  // [显示效果] 底部温馨寄语
  static const midnightClosing = '当世界沉入梦乡，思绪却开始翻涌\n很高兴，还有人愿意陪你聊聊';

  // ========== 秒回速度 ==========
  // [显示效果] 页面标题
  static const responseTitle = '回应的速度';

  // [显示效果] 副标题
  static const responseSubtitle = '在乎的人，总是回得很快';

  // [显示效果] 两个部分的小标题
  // 上半部分："回复你最快的人"
  // 下半部分："你回复最快的人"
  static const responseWhoRepliesYou = '回复你最快的人';
  static const responseYouReplyWho = '你回复最快的人';

  // [显示效果] 平均响应时间前缀
  // 完整显示："平均 2.5 分钟"
  static const responseAvgPrefix = '平均 ';

  // [显示效果] 两个部分的底部寄语
  static const responseClosing1 = 'TA总是第一时间给你回应\n这份在意，让人心安';
  static const responseClosing2 = '而对TA的消息，你也总会放下手边的一切\n这份关系，值得被用心回应';

  // ========== 曾经的好朋友页 ==========

  static const formerFriendTitle = '曾经的好朋友';

  // [显示效果] 副标题
  static const formerFriendSubtitle = '这些年来，时间都带我遇见了谁，又留下了些什么?';

  // [显示效果] 开场白前缀
  // 完整显示："还记得吗，那段时间"
  static const formerFriendRemember = '还记得和';

  // [显示效果] 那段时间里的天数
  static const formerFriendInDaysPrefix = '那 ';
  static const formerFriendInDaysSuffix = ' 天里，你们聊了 ';
  static const formerFriendInDaysCount = ' 天';

  // [显示效果] 消息总数前缀
  static const formerFriendTotalPrefix = '一共 ';
  static const formerFriendTotalSuffix = ' 条消息';

  static const formerFriendToDate = ' 到 ';

  // [显示效果] 转折文案
  // [显示效果] 没有联系的天数描述
  // 完整显示："已经 123 天没有联系了"
  static const formerFriendButNow = '但现在';
  static const formerFriendNoContactPrefix = '你们已经 ';
  static const formerFriendNoContactSuffix = ' 天没有联系了';

  // [显示效果] 后续情况描述
  // 完整显示："距离那段时光已经过去了 333 天
  //          你们只发了 81759 条消息
  //          平均每天 245.52 条"
  static const formerFriendSinceThen = '距离那段时光已经过去了 ';
  static const formerFriendOnlySent = '你们只发了 ';
  static const formerFriendAvgPerDay = '平均每天 ';

  // [显示效果] 底部温馨寄语
  static const formerFriendClosing = '时间悄无声息地将某些人带到你的生命里\n又将某些人轻轻推向远方';

  // [显示效果] 无数据时的提示
  static const formerFriendNoData = '暂无数据';
  static const formerFriendInsufficientData = '聊天记录不足';
  static const formerFriendInsufficientDataDetail = '所有好友的聊天记录都不足14天\n无法进行分析';
  static const formerFriendNoQualified = '未找到符合条件的好友';
  static const formerFriendAllGoodRelations = '所有好友都保持着良好的联系';

  // ========== 结束页 ==========
  // [显示效果] 标题后缀
  // 完整显示："2024年的故事" 或 "这段时光的故事"
  static const endingTitleSuffix = '的故事';

  // [显示效果] 副标题
  static const endingSubtitle = '就这样，定格在时光里';

  // [显示效果] 统计数据单位
  // 完整显示：
  // "12345
  //  条消息
  //
  //  98
  //  位好友"
  static const endingMessagesUnit = '条消息';
  static const endingFriendsUnit = '位好友';

  // [显示效果] 两段诗句
  static const endingPoem1 = '我们总是在向前走，却很少有机会回头看看';
  static const endingPoem2 =
      '如果这份小小的报告，能让你想起某个很久没联系的朋友，能让你对当下的陪伴心存感激\n或者能在某个平凡的午后，给你带来一丝微笑和暖意\n那么，这一切就都有了意义';

  // [显示效果] 底部爱心符号
  static const endingHeart = '♡';

  // ========== 通用文本 ==========
  // [显示效果] 无数据时的提示
  static const noData = '暂无记录';

  // [显示效果] 加载中提示
  static const loading = '正在整理回忆...';

  // [显示效果] 年份后缀，如 "2024年"
  static const yearSuffix = '年';

  // [显示效果] 历史模式的文案
  static const historyText = '这段时光';
  static const historyAllTime = '历史以来';
}
