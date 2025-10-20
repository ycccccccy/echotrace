import 'package:flutter/material.dart';
import '../../services/annual_report_cache_service.dart';

/// 年份选择器组件
class YearSelectorWidget extends StatefulWidget {
  final List<int> availableYears;
  final int? selectedYear; // null 表示"历史以来"（默认选中）
  final Function(int? year) onYearSelected;
  final VoidCallback onConfirm;

  const YearSelectorWidget({
    super.key,
    required this.availableYears,
    required this.selectedYear,
    required this.onYearSelected,
    required this.onConfirm,
  });

  @override
  State<YearSelectorWidget> createState() => _YearSelectorWidgetState();
}

class _YearSelectorWidgetState extends State<YearSelectorWidget> {
  final Map<int?, bool> _cachedStatus = {};

  @override
  void initState() {
    super.initState();
    _loadCachedStatus();
  }

  Future<void> _loadCachedStatus() async {
    // 检查"历史以来"是否已缓存
    _cachedStatus[null] = await AnnualReportCacheService.hasReport(null);
    
    // 检查各年份是否已缓存
    for (final year in widget.availableYears) {
      _cachedStatus[year] = await AnnualReportCacheService.hasReport(year);
    }
    
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    const wechatGreen = Color(0xFF07C160);
    
    return Container(
      color: const Color(0xFFF5F5F5), // 与应用背景一致
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '选择报告时间范围',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '选择你想要查看的年度报告',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 32),
              
              // "历史以来"选项（默认选中）
              _buildYearCard(
                year: null,
                label: '历史以来',
                subtitle: '查看全部数据',
                isSelected: widget.selectedYear == null,
                isCached: _cachedStatus[null] ?? false,
              ),
              
              // 只有当有具体年份时才显示年份列表
              if (widget.availableYears.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Text(
                  '或选择具体年份',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                
                // 年份列表
                Expanded(
                  child: ListView.builder(
                    itemCount: widget.availableYears.length,
                    itemBuilder: (context, index) {
                      final year = widget.availableYears[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12.0),
                        child: _buildYearCard(
                          year: year,
                          label: '$year 年',
                          subtitle: '查看 $year 年的数据',
                          isSelected: widget.selectedYear == year,
                          isCached: _cachedStatus[year] ?? false,
                        ),
                      );
                    },
                  ),
                ),
              ] else
                const Spacer(),
              
              // 确认按钮（默认启用，因为"历史以来"默认选中）
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: widget.onConfirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: wechatGreen,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    '生成个人年度报告',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildYearCard({
    required int? year,
    required String label,
    required String subtitle,
    required bool isSelected,
    required bool isCached,
  }) {
    return GestureDetector(
      onTap: () => widget.onYearSelected(year),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF07C160).withOpacity(0.1) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? const Color(0xFF07C160) : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: [
            if (isSelected)
              BoxShadow(
                color: const Color(0xFF07C160).withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
          ],
        ),
        child: Row(
          children: [
            // 选中指示器
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? const Color(0xFF07C160) : Colors.grey,
                  width: 2,
                ),
                color: isSelected ? const Color(0xFF07C160) : Colors.transparent,
              ),
              child: isSelected
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 16),
            
            // 年份信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? const Color(0xFF07C160) : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 14,
                      color: isSelected ? const Color(0xFF00A868) : Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
            
            // 缓存状态标记
            if (isCached)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.green.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle, size: 16, color: Colors.green.shade700),
                    const SizedBox(width: 4),
                    Text(
                      '已生成',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.green.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

