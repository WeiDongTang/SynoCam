// 通知：事件列表（按类型着色图标）、未读标记、免打扰、推送设置。
// 对齐定稿 A 原型 v-alert。
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../widgets/app_icon.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  bool _dnd = false;
  late bool _readAll;

  @override
  void initState() {
    super.initState();
    _readAll = false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const _Header('通知', '3 条未读 · 今日 12 条'),
            _filterChips(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text('今天',
                      style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.3,
                          color: AppColors.faint,
                          fontWeight: FontWeight.w600)),
                  GestureDetector(
                    onTap: () => setState(() => _readAll = true),
                    child: const Text('全部已读',
                        style: TextStyle(fontSize: 11, color: AppColors.blue)),
                  ),
                ],
              ),
            ),
            Expanded(child: _list(context)),
            _settingsGroup(context),
          ],
        ),
      ),
    );
  }

  Widget _filterChips() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: <String>['全部', '未读 3', '告警', '门禁', '智能分析', '系统']
              .asMap()
              .entries
              .map((e) => Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: ChoiceChip(
                      label: Text(e.value),
                      selected: e.key == 0,
                      showCheckmark: false,
                      onSelected: (_) {},
                      labelStyle: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: e.key == 0 ? Colors.white : AppColors.sub),
                      selectedColor: AppColors.ink,
                      backgroundColor: AppColors.card,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
                      side: BorderSide(
                          color: e.key == 0 ? AppColors.ink : AppColors.line),
                    ),
                  ))
              .toList(),
        ),
      );

  Widget _list(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      children: _demo.map((e) => _eventTile(e)).toList(),
    );
  }

  Widget _eventTile(_Ev e) {
    final read = _readAll || !e.unread;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: BadgeIcon(e.icon,
            tone: read ? IconTone.neutral : e.tone, boxSize: 38, iconSize: 18),
        title: Text(e.title,
            style:
                const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        subtitle: Text(e.detail,
            style: TextStyle(fontSize: 10, color: AppColors.faint)),
        trailing: read
            ? null
            : Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                    color: AppColors.blue, shape: BoxShape.circle)),
      ),
    );
  }

  Widget _settingsGroup(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Card(
          child: Column(
            children: <Widget>[
              ListTile(
                leading: const BadgeIcon(AppIcons.moon, tone: IconTone.amber),
                title: const Text('免打扰',
                    style:
                        TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                subtitle: Text('Do Not Disturb · 时段与临时静音',
                    style: TextStyle(fontSize: 11, color: AppColors.sub)),
                trailing: Switch(
                    value: _dnd, onChanged: (v) => setState(() => _dnd = v)),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const BadgeIcon(AppIcons.notifications),
                title: const Text('推送设置',
                    style:
                        TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                subtitle: Text('事件类型 · 静音时长',
                    style: TextStyle(fontSize: 11, color: AppColors.sub)),
                trailing: const AppIcon(AppIcons.chevron, size: 16),
                onTap: () {},
              ),
            ],
          ),
        ),
      );

  static final List<_Ev> _demo = <_Ev>[
    _Ev('后院 #03 检测到人员出现', '14:32 · 移动侦测', AppIcons.alert, IconTone.red, true),
    _Ev('车库 #02 门禁被开启', '13:10 · 门禁事件', AppIcons.door, IconTone.amber, true),
    _Ev('智能分析：车牌识别', '11:48 · Deep Video Analytics', AppIcons.sparkles,
        IconTone.blue, true),
    _Ev('NAS-01 磁盘健康警告', '09:05 · 系统', AppIcons.cpu, IconTone.blue, false),
    _Ev('前门 #01 网络恢复', '昨日 22:40 · 系统', AppIcons.server, IconTone.blue, false),
  ];
}

class _Ev {
  const _Ev(this.title, this.detail, this.icon, this.tone, this.unread);
  final String title;
  final String detail;
  final IconData icon;
  final IconTone tone;
  final bool unread;
}

class _Header extends StatelessWidget {
  const _Header(this.title, this.subtitle);
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title,
                style:
                    const TextStyle(fontSize: 29, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(subtitle,
                style: TextStyle(fontSize: 12, color: AppColors.sub)),
          ],
        ),
      );
}
