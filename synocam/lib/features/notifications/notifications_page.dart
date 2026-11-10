// 通知：数据来自 NAS 真实 Event/Query 事件（录像/告警记录）。
// 移动端推送由 DSM「通知服务」配置，SS Web API 不提供 App 内推送开关，
// 因此这里明确引导到 SS 网页端，不伪造开关与事件。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../core/utils/launcher.dart';
import '../../data/models/media.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  int _filter = 0;
  static const List<String> _filters = <String>[
    '全部',
    '未读',
    '移动侦测',
    '告警',
    '连续录制',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().refreshMedia();
    });
  }

  List<SurveillanceEvent> _apply(
      List<SurveillanceEvent> all, Set<String> readIds) {
    return all.where((e) {
      switch (_filter) {
        case 1:
          return !readIds.contains(e.id);
        case 2:
          return e.type == 'motion';
        case 3:
          return e.type == 'alarm';
        case 4:
          return e.type == 'continuous';
        default:
          return true;
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final readIds = state.readEventIds;
    final list = _apply(state.events, readIds);
    final unread = state.events.where((e) => !readIds.contains(e.id)).length;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Header('通知',
                state.mediaState == LoadState.ready
                    ? 'NAS 真实事件 ${state.events.length} 条 · $unread 条未读'
                    : '读取 NAS 上的真实事件'),
            _filterChips(unread),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text('事件记录',
                      style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.3,
                          color: AppColors.faint,
                          fontWeight: FontWeight.w600)),
                  GestureDetector(
                    onTap: state.events.isEmpty
                        ? null
                        : () async {
                            await state.markAllEventsRead();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('已在本机标记全部已读')));
                            }
                          },
                    child: Text('全部已读',
                        style: TextStyle(
                            fontSize: 11,
                            color: state.events.isEmpty
                                ? AppColors.faint
                                : AppColors.blue)),
                  ),
                ],
              ),
            ),
            Expanded(child: _list(context, state, list, readIds)),
            _settingsGroup(context, state),
          ],
        ),
      ),
    );
  }

  Widget _filterChips(int unread) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: List<Widget>.generate(_filters.length, (i) {
            final label = i == 1 ? '未读 $unread' : _filters[i];
            return Padding(
              padding: const EdgeInsets.only(right: 7),
              child: ChoiceChip(
                label: Text(label),
                selected: i == _filter,
                showCheckmark: false,
                onSelected: (_) => setState(() => _filter = i),
                labelStyle: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: i == _filter ? Colors.white : AppColors.sub),
                selectedColor: AppColors.ink,
                backgroundColor: AppColors.card,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                side: BorderSide(
                    color: i == _filter ? AppColors.ink : AppColors.line),
              ),
            );
          }).toList(),
        ),
      );

  Widget _list(BuildContext context, AppState state,
      List<SurveillanceEvent> list, Set<String> readIds) {
    if (state.mediaState == LoadState.loading ||
        state.mediaState == LoadState.idle) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.mediaState == LoadState.error) {
      return _notice(state.mediaError ?? '事件读取失败',
          '错误来自 NAS 真实响应，请检查账号的 Surveillance Station 权限。',
          () => state.refreshMedia());
    }
    if (list.isEmpty) {
      return _notice(
          state.events.isEmpty ? 'NAS 暂无事件记录' : '当前筛选条件下没有事件',
          '不会产生任何演示数据；事件由 Surveillance Station 在录像/告警时生成。',
          () => state.refreshMedia());
    }
    return RefreshIndicator(
      onRefresh: state.refreshMedia,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        itemCount: list.length,
        itemBuilder: (context, i) {
          final e = list[i];
          final read = readIds.contains(e.id);
          return _eventTile(context, state, e, read);
        },
      ),
    );
  }

  Widget _eventTile(BuildContext context, AppState state,
      SurveillanceEvent e, bool read) {
    final meta = _meta(e.type);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () async {
          await state.markEventRead(e.id);
        },
        leading: BadgeIcon(meta.icon,
            tone: read ? IconTone.neutral : meta.tone,
            boxSize: 38,
            iconSize: 18),
        title: Text(e.title,
            style:
                const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        subtitle: Text(
            '${_time(e.time)} · ${e.detail}',
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

  String _time(DateTime t) =>
      '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  _Meta _meta(String type) {
    switch (type) {
      case 'motion':
        return const _Meta(AppIcons.alert, IconTone.red);
      case 'alarm':
        return const _Meta(AppIcons.door, IconTone.amber);
      case 'manual':
        return const _Meta(AppIcons.snapshot, IconTone.blue);
      case 'external':
        return const _Meta(AppIcons.cpu, IconTone.blue);
      default:
        return const _Meta(AppIcons.recordings, IconTone.blue);
    }
  }

  Widget _settingsGroup(BuildContext context, AppState state) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Card(
          child: Column(
            children: <Widget>[
              ListTile(
                leading: const BadgeIcon(AppIcons.moon, tone: IconTone.amber),
                title: const Text('免打扰',
                    style:
                        TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                subtitle: Text('本机提醒静音（不影响 NAS 端事件记录）',
                    style: TextStyle(fontSize: 11, color: AppColors.sub)),
                trailing: Switch(
                    value: state.prefs.dnd,
                    onChanged: (v) => state.setDnd(v)),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const BadgeIcon(AppIcons.notifications),
                title: const Text('推送通知设置',
                    style:
                        TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                subtitle: Text('需在 DSM 通知服务中配置邮件 / 短信 / 移动推送',
                    style: TextStyle(fontSize: 11, color: AppColors.sub)),
                trailing: const AppIcon(AppIcons.chevron, size: 16),
                onTap: () => openExternalUrl(context, state.webUiUrl(),
                    label: 'DSM 网页端'),
              ),
            ],
          ),
        ),
      );

  Widget _notice(String title, String detail, VoidCallback onRetry) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const AppIcon(AppIcons.info, size: 30, color: AppColors.faint),
              const SizedBox(height: 12),
              Text(title,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: AppColors.sub)),
              const SizedBox(height: 6),
              Text(detail,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: AppColors.faint)),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const AppIcon(AppIcons.refresh,
                    size: 16, color: Colors.white),
                label: const Text('重新读取'),
              ),
            ],
          ),
        ),
      );
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
                style: const TextStyle(
                    fontSize: 29, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(subtitle, style: TextStyle(fontSize: 12, color: AppColors.sub)),
          ],
        ),
      );
}

/// 事件图标与色调（避免使用 Dart 3 record，保证在 Dart 2.17+ 均可解析）。
class _Meta {
  const _Meta(this.icon, this.tone);
  final IconData icon;
  final IconTone tone;
}
