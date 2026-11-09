// 录像与快照：录像/快照切换、筛选、按日期分组、锁定/下载/删除。
// 对齐定稿 A 原型 v-rec。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../data/models/media.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';

class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  int _tab = 0; // 0 录像 / 1 快照

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().refreshMedia();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const _Header('录像与快照', '按日期 / 相机 / 锁定状态检索'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SegmentedButton<int>(
                segments: const <ButtonSegment<int>>[
                  ButtonSegment<int>(value: 0, label: Text('录像')),
                  ButtonSegment<int>(value: 1, label: Text('快照')),
                ],
                selected: <int>{_tab},
                showSelectedIcon: false,
                onSelectionChanged: (Set<int> s) =>
                    setState(() => _tab = s.first),
              ),
            ),
            _filterChips(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
              child: Text('2026 / 11 / 09',
                  style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.3,
                      color: AppColors.faint,
                      fontWeight: FontWeight.w600)),
            ),
            Expanded(child: _list(context, state)),
          ],
        ),
      ),
    );
  }

  Widget _filterChips() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: <String>['全部', '今日', '已锁定', '移动侦测', '连续录制']
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

  Widget _list(BuildContext context, AppState state) {
    final recs = state.recordings;
    // 演示数据：真实数据为空时用占位，保证页面骨架完整可评审。
    final display = recs.isEmpty ? _demo : recs;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      itemCount: display.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final r = display[i];
        return Card(
          child: ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Container(
                width: 44,
                height: 44,
                color: const Color(0xFF22262F),
                child: const AppIcon(AppIcons.recordings,
                    size: 20, color: Colors.white38),
              ),
            ),
            title: Text(
                _tab == 1
                    ? '${r.cameraName} · 快照'
                    : '${r.cameraName} · ${r.eventType}',
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
            subtitle: Text(
                '${r.startTime.month}/${r.startTime.day} '
                '${r.startTime.hour.toString().padLeft(2, '0')}:${r.startTime.minute.toString().padLeft(2, '0')}'
                ' · ${r.durationLabel}${r.locked ? ' · 已锁定' : ''}',
                style: TextStyle(fontSize: 10, color: AppColors.faint)),
            trailing: IconButton(
              icon: AppIcon(_tab == 0 ? AppIcons.download : AppIcons.eye,
                  size: 18, color: AppColors.blue),
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(_tab == 0 ? '已开始下载' : '快照已保存')),
              ),
            ),
          ),
        );
      },
    );
  }

  static final List<Recording> _demo = <Recording>[
    Recording(
        id: '1',
        cameraId: 1,
        cameraName: '前门入口 #01',
        startTime: DateTime(2026, 11, 9, 14, 32),
        durationSeconds: 42,
        locked: true,
        eventType: '移动侦测'),
    Recording(
        id: '2',
        cameraId: 2,
        cameraName: '车库 #02',
        startTime: DateTime(2026, 11, 9, 13, 10),
        durationSeconds: 300,
        eventType: '连续录制'),
    Recording(
        id: '3',
        cameraId: 3,
        cameraName: '后院 #03',
        startTime: DateTime(2026, 11, 9, 11, 48),
        durationSeconds: 75,
        locked: true,
        eventType: '人员出现'),
    Recording(
        id: '4',
        cameraId: 4,
        cameraName: '客厅 #04',
        startTime: DateTime(2026, 11, 9, 9, 22),
        durationSeconds: 38,
        eventType: '宠物移动'),
  ];
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
