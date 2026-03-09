import 'package:flutter/material.dart';

/// 图书馆助手页面 — 极简风格，与"学习中心"视觉体系统一
/// 设计规范：
///   背景 #F5F5F5 | 卡片 #FFFFFF | 圆角 12px | 阴影 0 1px 4px rgba(0,0,0,0.06)
///   字色：标题 #111111，副标题 #999999，说明 #666666
///   图标：线性风格，颜色 #333333
///   按钮：胶囊形，背景 #F0F0F0，文字 #333333
class LibraryAssistantScreen extends StatefulWidget {
  const LibraryAssistantScreen({super.key});

  @override
  State<LibraryAssistantScreen> createState() => _LibraryAssistantScreenState();
}

class _LibraryAssistantScreenState extends State<LibraryAssistantScreen> {
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ─── 颜色常量 ─────────────────────────────────────
  static const Color _bg = Color(0xFFF5F5F5);
  static const Color _card = Color(0xFFFFFFFF);
  static const Color _textPrimary = Color(0xFF111111);
  static const Color _textSecondary = Color(0xFF666666);
  static const Color _textMuted = Color(0xFF999999);
  static const Color _iconColor = Color(0xFF333333);
  static const Color _pillBg = Color(0xFFF0F0F0);
  static const Color _tagBg = Color(0xFFEEEEEE);

  static const BoxDecoration _cardDecoration = BoxDecoration(
    color: _card,
    borderRadius: BorderRadius.all(Radius.circular(12)),
    boxShadow: [
      BoxShadow(
        color: Color(0x0F000000), // rgba(0,0,0,0.06)
        blurRadius: 4,
        offset: Offset(0, 1),
      ),
    ],
  );

  // ─── 数据 ─────────────────────────────────────────
  final List<_FuncCard> _funcCards = const [
    _FuncCard(
      icon: Icons.menu_book_outlined,
      title: '我的借阅',
      value: '3',
      unit: '本在借',
      tag: '1天后到期',
    ),
    _FuncCard(
      icon: Icons.chair_outlined,
      title: '座位预约',
      value: '2',
      unit: '个时段',
      tag: '今日有效',
    ),
    _FuncCard(
      icon: Icons.bookmark_border_outlined,
      title: '图书预定',
      value: '1',
      unit: '本待取',
      tag: '可取书',
    ),
    _FuncCard(
      icon: Icons.bar_chart_outlined,
      title: '阅读报告',
      value: '28',
      unit: '天阅读',
      tag: '本月',
    ),
  ];

  final List<_Notice> _notices = const [
    _Notice(
      tag: '通知',
      title: '图书馆国庆节放假公告',
      date: '09-28',
    ),
    _Notice(
      tag: '活动',
      title: '第十二届读书月征文活动开始报名',
      date: '09-25',
    ),
    _Notice(
      tag: '通知',
      title: '新到馆资源：Nature 2024 合订本',
      date: '09-20',
    ),
  ];

  final List<_Book> _books = const [
    _Book(title: '人类简史', author: 'Yuval Noah Harari', category: '历史'),
    _Book(title: '深度学习', author: 'Ian Goodfellow', category: '技术'),
    _Book(title: '穷查理宝典', author: 'Charlie Munger', category: '商业'),
  ];

  // ─── Build ─────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 16),
                    _buildSearchBar(),
                    const SizedBox(height: 24),
                    _buildFuncGrid(),
                    const SizedBox(height: 24),
                    _buildSectionHeader('馆内公告', 'ANNOUNCEMENTS'),
                    const SizedBox(height: 12),
                    _buildNoticeList(),
                    const SizedBox(height: 24),
                    _buildSectionHeader('图书推荐', 'RECOMMENDATIONS'),
                    const SizedBox(height: 12),
                    _buildBookList(),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── 顶部导航 ──────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      color: _card,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Row(
        children: [
          // 线性书本图标
          const Icon(Icons.local_library_outlined, color: _iconColor, size: 22),
          const SizedBox(width: 8),
          const Text(
            '图书馆助手',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: _textPrimary,
              letterSpacing: 0.2,
            ),
          ),
          const Spacer(),
          // 通知图标
          _IconBtn(
            icon: Icons.notifications_none_outlined,
            onTap: () {},
          ),
          const SizedBox(width: 8),
          // 个人图标
          _IconBtn(
            icon: Icons.person_outline_rounded,
            onTap: () {},
          ),
        ],
      ),
    );
  }

  // ─── 搜索栏 ────────────────────────────────────────
  Widget _buildSearchBar() {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          const Icon(Icons.search_outlined, color: _textMuted, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(
                fontSize: 14,
                color: _textPrimary,
              ),
              decoration: const InputDecoration(
                hintText: '搜索书名、作者、ISBN...',
                hintStyle: TextStyle(
                  fontSize: 14,
                  color: _textMuted,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          const SizedBox(width: 14),
        ],
      ),
    );
  }

  // ─── 2×2 功能卡片 ──────────────────────────────────
  Widget _buildFuncGrid() {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.35,
      children: _funcCards.map(_buildFuncCard).toList(),
    );
  }

  Widget _buildFuncCard(_FuncCard c) {
    return GestureDetector(
      onTap: () {},
      child: Container(
        decoration: _cardDecoration,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 线性图标（无彩色背景）
            Icon(c.icon, color: _iconColor, size: 22),
            const SizedBox(height: 8),
            // 大号黑色数字
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  c.value,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: _textPrimary,
                    height: 1.0,
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  c.unit,
                  style: const TextStyle(
                    fontSize: 12,
                    color: _textSecondary,
                  ),
                ),
              ],
            ),
            const Spacer(),
            // 底部：标题 + 浅灰标签
            Row(
              children: [
                Expanded(
                  child: Text(
                    c.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // 浅灰色胶囊标签（替换彩色标签）
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: _tagBg,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    c.tag,
                    style: const TextStyle(
                      fontSize: 10,
                      color: _textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─── 模块标题（中文 + 英文副标题）──────────────────
  Widget _buildSectionHeader(String zh, String en) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          zh,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: _textPrimary,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          en,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: _textMuted,
            letterSpacing: 0.8,
          ),
        ),
        const Spacer(),
        // "查看全部"灰色文字
        GestureDetector(
          onTap: () {},
          child: const Text(
            '查看全部',
            style: TextStyle(
              fontSize: 13,
              color: _textMuted,
            ),
          ),
        ),
      ],
    );
  }

  // ─── 公告列表 ──────────────────────────────────────
  Widget _buildNoticeList() {
    return Container(
      decoration: _cardDecoration,
      child: Column(
        children: List.generate(_notices.length, (i) {
          final n = _notices[i];
          final isLast = i == _notices.length - 1;
          return Column(
            children: [
              _buildNoticeItem(n),
              if (!isLast)
                const Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: Color(0xFFF0F0F0),
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildNoticeItem(_Notice n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          // 简洁圆角文字标签（统一浅灰）
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _tagBg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              n.tag,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: _textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 标题
          Expanded(
            child: Text(
              n.title,
              style: const TextStyle(
                fontSize: 14,
                color: _textPrimary,
                height: 1.4,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          // 日期
          Text(
            n.date,
            style: const TextStyle(
              fontSize: 12,
              color: _textMuted,
            ),
          ),
        ],
      ),
    );
  }

  // ─── 图书推荐列表 ──────────────────────────────────
  Widget _buildBookList() {
    return Column(
      children: _books.map((b) => _buildBookItem(b)).toList(),
    );
  }

  Widget _buildBookItem(_Book b) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: _cardDecoration,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // 书籍封面占位（线框风格）
            Container(
              width: 48,
              height: 64,
              decoration: BoxDecoration(
                color: _pillBg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(
                Icons.menu_book_outlined,
                color: _textMuted,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            // 书目信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    b.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: _textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    b.author,
                    style: const TextStyle(
                      fontSize: 13,
                      color: _textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 分类胶囊标签
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _tagBg,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      b.category,
                      style: const TextStyle(
                        fontSize: 11,
                        color: _textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 借阅按钮（浅灰胶囊）
            GestureDetector(
              onTap: () {},
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: _pillBg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '借阅',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _textPrimary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 辅助 Widget ────────────────────────────────────────

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFFF0F0F0),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: const Color(0xFF333333), size: 20),
      ),
    );
  }
}

// ─── 数据模型 ────────────────────────────────────────────

class _FuncCard {
  const _FuncCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.unit,
    required this.tag,
  });

  final IconData icon;
  final String title;
  final String value;
  final String unit;
  final String tag;
}

class _Notice {
  const _Notice({
    required this.tag,
    required this.title,
    required this.date,
  });

  final String tag;
  final String title;
  final String date;
}

class _Book {
  const _Book({
    required this.title,
    required this.author,
    required this.category,
  });

  final String title;
  final String author;
  final String category;
}
