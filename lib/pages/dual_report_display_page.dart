import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import '../models/advanced_analytics_data.dart';
import '../widgets/annual_report/animated_components.dart';

/// 双人报告展示页面
class DualReportDisplayPage extends StatefulWidget {
  final Map<String, dynamic> reportData;

  const DualReportDisplayPage({
    super.key,
    required this.reportData,
  });

  @override
  State<DualReportDisplayPage> createState() => _DualReportDisplayPageState();
}

class _DualReportDisplayPageState extends State<DualReportDisplayPage> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  late List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _buildPages();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _buildPages() {
    // 显示完整的报告页面
    _pages = [
      _buildCoverPage(),
      _buildBasicStatsPage(),
      _buildInitiativePage(),
      _buildConversationBalancePage(),
      _buildIntimacyCalendarPage(),
      _buildLongestStreakPage(),
      _buildEndingPage(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: RawKeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        autofocus: true,
        onKey: (event) {
          if (event is RawKeyDownEvent) {
            if (event.logicalKey.keyLabel == 'Arrow Right' || 
                event.logicalKey.keyLabel == 'Arrow Down') {
              if (_currentPage < _pages.length - 1) {
                _pageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              }
            } else if (event.logicalKey.keyLabel == 'Arrow Left' || 
                       event.logicalKey.keyLabel == 'Arrow Up') {
              if (_currentPage > 0) {
                _pageController.previousPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              }
            }
          }
        },
        child: Stack(
          children: [
            Listener(
              onPointerSignal: (pointerSignal) {
                if (pointerSignal is PointerScrollEvent) {
                  if (pointerSignal.scrollDelta.dy > 0) {
                    if (_currentPage < _pages.length - 1) {
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    }
                  } else if (pointerSignal.scrollDelta.dy < 0) {
                    if (_currentPage > 0) {
                      _pageController.previousPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    }
                  }
                }
              },
              child: PageView(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                onPageChanged: (index) {
                  setState(() => _currentPage = index);
                },
                children: _pages,
              ),
            ),
            
            // 页码指示器
            Positioned(
              right: 20,
              top: 0,
              bottom: 0,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(_pages.length, (index) {
                    return Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      width: 8,
                      height: index == _currentPage ? 24 : 8,
                      decoration: BoxDecoration(
                        color: index == _currentPage 
                            ? const Color(0xFF07C160) 
                            : Colors.grey[300],
                        borderRadius: BorderRadius.circular(4),
                      ),
                    );
                  }),
                ),
              ),
            ),
            
            // 关闭按钮
            Positioned(
              top: 40,
              right: 40,
              child: IconButton(
                icon: const Icon(Icons.close, size: 28),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 封面页
  Widget _buildCoverPage() {
    final friendName = widget.reportData['friendDisplayName'] as String? ?? '好友';
    final year = widget.reportData['filterYear'] as int?;
    final yearText = year != null ? '$year年' : '历史以来';
    
    return Container(
      color: const Color(0xFF07C160),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FadeInText(
                text: '双人报告',
                style: const TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 40),
              FadeInText(
                text: '你 & $friendName',
                delay: const Duration(milliseconds: 500),
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 20),
              FadeInText(
                text: yearText,
                delay: const Duration(milliseconds: 800),
                style: TextStyle(
                  fontSize: 20,
                  color: Colors.white.withOpacity(0.9),
                ),
              ),
              const SizedBox(height: 80),
              FadeInText(
                text: '滑动鼠标 / 方向键翻页',
                delay: const Duration(milliseconds: 1200),
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: 10),
              FadeInText(
                text: '← →',
                delay: const Duration(milliseconds: 1400),
                style: TextStyle(
                  fontSize: 24,
                  color: Colors.white.withOpacity(0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 基础统计页
  Widget _buildBasicStatsPage() {
    final total = widget.reportData['totalMessages'] as int? ?? 0;
    final sent = widget.reportData['sentMessages'] as int? ?? 0;
    final received = widget.reportData['receivedMessages'] as int? ?? 0;
    
    final firstChatTimeStr = widget.reportData['firstChatTime'] as String?;
    final firstChatTime = firstChatTimeStr != null ? DateTime.parse(firstChatTimeStr) : null;
    
    int? daysSinceFirstChat;
    if (firstChatTime != null) {
      daysSinceFirstChat = DateTime.now().difference(firstChatTime).inDays;
    }
    
    return Container(
      color: Colors.white,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = constraints.maxHeight;
            final width = constraints.maxWidth;
            final titleSize = height > 700 ? 28.0 : 24.0;
            final numberSize = height > 700 ? 48.0 : 40.0;
            final textSize = height > 700 ? 16.0 : 14.0;
            
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: width * 0.1,
                vertical: height * 0.08,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FadeInText(
                    text: '你们的故事',
                    style: TextStyle(
                      fontSize: titleSize,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF07C160),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: height * 0.08),
                  
                  if (daysSinceFirstChat != null) ...[
                    FadeInText(
                      text: '认识了',
                      delay: const Duration(milliseconds: 300),
                      style: TextStyle(fontSize: textSize, color: Colors.grey[600]),
                    ),
                    SizedBox(height: height * 0.02),
                    SlideInCard(
                      delay: const Duration(milliseconds: 500),
                      child: Text(
                        '$daysSinceFirstChat',
                        style: TextStyle(
                          fontSize: numberSize,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF07C160),
                        ),
                      ),
                    ),
                    SizedBox(height: height * 0.01),
                    FadeInText(
                      text: '天',
                      delay: const Duration(milliseconds: 700),
                      style: TextStyle(fontSize: textSize, color: Colors.grey[600]),
                    ),
                    SizedBox(height: height * 0.06),
                  ],
                  
                  FadeInText(
                    text: '交换了',
                    delay: const Duration(milliseconds: 900),
                    style: TextStyle(fontSize: textSize, color: Colors.grey[600]),
                  ),
                  SizedBox(height: height * 0.02),
                  SlideInCard(
                    delay: const Duration(milliseconds: 1100),
                    child: Text(
                      '$total',
                      style: TextStyle(
                        fontSize: numberSize,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF07C160),
                      ),
                    ),
                  ),
                  SizedBox(height: height * 0.01),
                  FadeInText(
                    text: '条消息',
                    delay: const Duration(milliseconds: 1300),
                    style: TextStyle(fontSize: textSize, color: Colors.grey[600]),
                  ),
                  SizedBox(height: height * 0.06),
                  
                  Container(
                    padding: EdgeInsets.all(width * 0.05),
                    decoration: BoxDecoration(
                      color: Colors.grey[50],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Column(
                          children: [
                            FadeInText(
                              text: '你发',
                              delay: const Duration(milliseconds: 1500),
                              style: TextStyle(fontSize: textSize - 2, color: Colors.grey[600]),
                            ),
                            SizedBox(height: 8),
                            FadeInText(
                              text: '$sent',
                              delay: const Duration(milliseconds: 1700),
                              style: TextStyle(
                                fontSize: textSize + 4,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF07C160),
                              ),
                            ),
                          ],
                        ),
                        Container(height: 50, width: 1, color: Colors.grey[300]),
                        Column(
                          children: [
                            FadeInText(
                              text: 'TA回',
                              delay: const Duration(milliseconds: 1500),
                              style: TextStyle(fontSize: textSize - 2, color: Colors.grey[600]),
                            ),
                            SizedBox(height: 8),
                            FadeInText(
                              text: '$received',
                              delay: const Duration(milliseconds: 1700),
                              style: TextStyle(
                                fontSize: textSize + 4,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF07C160),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // 主动性页面
  Widget _buildInitiativePage() {
    final friendName = widget.reportData['friendDisplayName'] as String? ?? '好友';
    final initiatedByMe = widget.reportData['initiatedByMe'] as int? ?? 0;
    final initiatedByFriend = widget.reportData['initiatedByFriend'] as int? ?? 0;
    final total = initiatedByMe + initiatedByFriend;
    
    if (total == 0) {
      return Container(
        color: Colors.white,
        child: const Center(child: Text('暂无数据')),
      );
    }
    
    final myRate = (initiatedByMe / total * 100).toStringAsFixed(1);
    final friendRate = (initiatedByFriend / total * 100).toStringAsFixed(1);
    
    return Container(
      color: Colors.white,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = constraints.maxHeight;
            final width = constraints.maxWidth;
            final titleSize = height > 700 ? 28.0 : 24.0;
            final textSize = height > 700 ? 16.0 : 14.0;
            
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: width * 0.1,
                vertical: height * 0.08,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FadeInText(
                    text: '谁更主动？',
                    style: TextStyle(
                      fontSize: titleSize,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF07C160),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: height * 0.08),
                  
                  FadeInText(
                    text: '每天第一条消息',
                    delay: const Duration(milliseconds: 300),
                    style: TextStyle(fontSize: textSize, color: Colors.grey[600]),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: height * 0.06),
                  
                  // 主动性对比
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            FadeInText(
                              text: '你',
                              delay: const Duration(milliseconds: 500),
                              style: TextStyle(fontSize: textSize, color: Colors.grey[700]),
                            ),
                            SizedBox(height: height * 0.03),
                            SlideInCard(
                              delay: const Duration(milliseconds: 700),
                              child: Text(
                                '$myRate%',
                                style: TextStyle(
                                  fontSize: titleSize + 4,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF07C160),
                                ),
                              ),
                            ),
                            SizedBox(height: height * 0.02),
                            FadeInText(
                              text: '$initiatedByMe 天',
                              delay: const Duration(milliseconds: 900),
                              style: TextStyle(fontSize: textSize - 2, color: Colors.grey[500]),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: width * 0.1),
                      Expanded(
                        child: Column(
                          children: [
                            FadeInText(
                              text: friendName,
                              delay: const Duration(milliseconds: 500),
                              style: TextStyle(fontSize: textSize, color: Colors.grey[700]),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            SizedBox(height: height * 0.03),
                            SlideInCard(
                              delay: const Duration(milliseconds: 700),
                              child: Text(
                                '$friendRate%',
                                style: TextStyle(
                                  fontSize: titleSize + 4,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF07C160),
                                ),
                              ),
                            ),
                            SizedBox(height: height * 0.02),
                            FadeInText(
                              text: '$initiatedByFriend 天',
                              delay: const Duration(milliseconds: 900),
                              style: TextStyle(fontSize: textSize - 2, color: Colors.grey[500]),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // 对话天平页
  Widget _buildConversationBalancePage() {
    final balanceJson = widget.reportData['conversationBalance'];
    if (balanceJson == null) {
      return Container(
        color: Colors.white,
        child: const Center(child: Text('暂无数据')),
      );
    }
    
    final balance = ConversationBalance.fromJson(balanceJson);
    
    return Container(
      color: Colors.white,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = constraints.maxHeight;
            final width = constraints.maxWidth;
            final titleSize = height > 700 ? 28.0 : 24.0;
            final textSize = height > 700 ? 16.0 : 14.0;
            
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: width * 0.1,
                vertical: height * 0.08,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FadeInText(
                    text: '对话天平',
                    style: TextStyle(
                      fontSize: titleSize,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF07C160),
                    ),
                  ),
                  SizedBox(height: height * 0.06),
                  
                  // 消息数对比
                  Container(
                    padding: EdgeInsets.all(width * 0.06),
                    decoration: BoxDecoration(
                      color: Colors.grey[50],
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              FadeInText(
                                text: '你发送',
                                delay: const Duration(milliseconds: 300),
                                style: TextStyle(fontSize: textSize, color: Colors.grey[600]),
                              ),
                              SizedBox(height: 12),
                              FadeInText(
                                text: '${balance.sentCount}',
                                delay: const Duration(milliseconds: 500),
                                style: TextStyle(
                                  fontSize: textSize + 8,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF07C160),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(height: 60, width: 1, color: Colors.grey[300]),
                        Expanded(
                          child: Column(
                            children: [
                              FadeInText(
                                text: 'TA发送',
                                delay: const Duration(milliseconds: 300),
                                style: TextStyle(fontSize: textSize, color: Colors.grey[600]),
                              ),
                              SizedBox(height: 12),
                              FadeInText(
                                text: '${balance.receivedCount}',
                                delay: const Duration(milliseconds: 500),
                                style: TextStyle(
                                  fontSize: textSize + 8,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF07C160),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // 亲密度日历页（简化版）
  Widget _buildIntimacyCalendarPage() {
    final calendarJson = widget.reportData['intimacyCalendar'];
    if (calendarJson == null) {
      return Container(
        color: Colors.white,
        child: const Center(child: Text('暂无数据')),
      );
    }
    
    final calendar = IntimacyCalendar.fromJson(calendarJson);
    
    // 找出最活跃的月份
    int maxCount = 0;
    String? maxMonth;
    for (final entry in calendar.monthlyData.entries) {
      if (entry.value > maxCount) {
        maxCount = entry.value;
        maxMonth = entry.key;
      }
    }
    
    return Container(
      color: Colors.white,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = constraints.maxHeight;
            final width = constraints.maxWidth;
            final titleSize = height > 700 ? 28.0 : 24.0;
            final textSize = height > 700 ? 16.0 : 14.0;
            
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: width * 0.1,
                vertical: height * 0.08,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FadeInText(
                    text: '亲密度',
                    style: TextStyle(
                      fontSize: titleSize,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF07C160),
                    ),
                  ),
                  SizedBox(height: height * 0.08),
                  
                  if (maxMonth != null) ...[
                    FadeInText(
                      text: '你们聊得最多的月份',
                      delay: const Duration(milliseconds: 300),
                      style: TextStyle(fontSize: textSize, color: Colors.grey[600]),
                    ),
                    SizedBox(height: height * 0.04),
                    SlideInCard(
                      delay: const Duration(milliseconds: 600),
                      child: Text(
                        maxMonth,
                        style: TextStyle(
                          fontSize: titleSize + 4,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF07C160),
                        ),
                      ),
                    ),
                    SizedBox(height: height * 0.03),
                    FadeInText(
                      text: '$maxCount 条消息',
                      delay: const Duration(milliseconds: 900),
                      style: TextStyle(fontSize: textSize, color: Colors.grey[600]),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // 最长连聊页
  Widget _buildLongestStreakPage() {
    final streakData = widget.reportData['longestStreak'];
    if (streakData == null || streakData['days'] == 0) {
      return Container(
        color: Colors.white,
        child: const Center(child: Text('暂无连续聊天记录')),
      );
    }
    
    final days = streakData['days'] as int;
    final startDate = streakData['startDate'] as String?;
    final endDate = streakData['endDate'] as String?;
    
    return Container(
      color: Colors.white,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = constraints.maxHeight;
            final width = constraints.maxWidth;
            final titleSize = height > 700 ? 28.0 : 24.0;
            final numberSize = height > 700 ? 64.0 : 52.0;
            final textSize = height > 700 ? 16.0 : 14.0;
            
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: width * 0.1,
                vertical: height * 0.08,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FadeInText(
                    text: '最长连聊',
                    style: TextStyle(
                      fontSize: titleSize,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF07C160),
                    ),
                  ),
                  SizedBox(height: height * 0.08),
                  
                  FadeInText(
                    text: '你们连续聊了',
                    delay: const Duration(milliseconds: 300),
                    style: TextStyle(fontSize: textSize, color: Colors.grey[600]),
                  ),
                  SizedBox(height: height * 0.04),
                  SlideInCard(
                    delay: const Duration(milliseconds: 600),
                    child: Text(
                      '$days',
                      style: TextStyle(
                        fontSize: numberSize,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF07C160),
                      ),
                    ),
                  ),
                  SizedBox(height: height * 0.02),
                  FadeInText(
                    text: '天',
                    delay: const Duration(milliseconds: 800),
                    style: TextStyle(fontSize: textSize, color: Colors.grey[600]),
                  ),
                  
                  if (startDate != null && endDate != null) ...[
                    SizedBox(height: height * 0.06),
                    FadeInText(
                      text: '${startDate.split('T').first} 至',
                      delay: const Duration(milliseconds: 1000),
                      style: TextStyle(fontSize: textSize - 2, color: Colors.grey[500]),
                    ),
                    SizedBox(height: height * 0.01),
                    FadeInText(
                      text: endDate.split('T').first,
                      delay: const Duration(milliseconds: 1200),
                      style: TextStyle(fontSize: textSize - 2, color: Colors.grey[500]),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }


  // 结束页
  Widget _buildEndingPage() {
    final friendName = widget.reportData['friendDisplayName'] as String? ?? '好友';
    
    return Container(
      color: const Color(0xFF07C160),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 60),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FadeInText(
                  text: '感谢有你',
                  style: const TextStyle(
                    fontSize: 42,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 60),
                SlideInCard(
                  delay: const Duration(milliseconds: 600),
                  child: Container(
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.3),
                        width: 2,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          friendName,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          '感谢你陪我走过的每一天',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.white.withOpacity(0.9),
                            height: 1.6,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 60),
                FadeInText(
                  text: '让我们继续前行',
                  delay: const Duration(milliseconds: 1200),
                  style: TextStyle(
                    fontSize: 20,
                    color: Colors.white.withOpacity(0.8),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

