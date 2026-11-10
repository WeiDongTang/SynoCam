// 录像：真实 SYNO.SurveillanceStation.Event / Query 数据。
// 支持真实筛选、按真实日期分组、真实锁定/解锁/删除、用系统播放器打开真实录像流。
// 无任何静态演示数据：加载失败显示 DSM 错误码，空结果显示真实空态。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../core/utils/launcher.dart';
import '../../data/models/media.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';

class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  int _tab = 0; // 0 录像 / 1 快照说明
  int _filter = 0;
  bool _busy = false;

  static const List<String> _filters = <String>[
    '全部',
    '今日',
    '已锁定',
    '移动侦测',
    '连续录制',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().refreshMedia();
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  List<Recording> _applyFilter(List<Recording> all) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return all.where((r) {
      switch (_filter) {
        case 1:
          return !r.startTime.isBefore(today);
        case 2:
          return r.locked;
        case 3:
          return r.eventType == '移动侦测';
        case 4:
          return r.eventType == '连续录制';
        default:
          return true;
      }
    }).toList();
  }

  Future<void> _toggleLock(AppState state, Recording r) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await state.setRecordingLocked(r, !r.locked);
      _snack(r.locked ? '已解锁' : '已锁定（NAS 已确认）');
    } catch (e) {
      _snack('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(AppState state, Recording r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除录像片段'),
        content: Text('将从 NAS 删除「${r.cameraName} · ${r.eventType}」，不可撤销。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除',
                  style: TextStyle(color: AppColors.red))),
        ],
      ),
    );
    if (ok != true) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await state.deleteRecording(r);
      _snack('已从 NAS 删除');
    } catch (e) {
      _snack('删除失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final recs = _applyFilter(state.recordings);
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Header('录像与快照',
                state.mediaState == LoadState.ready
                    ? 'NAS 返回 ${state.recordings.length} 条真实录像事件'
                    : '检索 NAS 上的真实录像事件'),
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
            if (_tab == 0) _filterChips(),
            Expanded(
              child: _tab == 1
                  ? _snapshotGuide(context, state)
                  : _body(context, state, recs),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChips() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: List<Widget>.generate(_filters.length, (i) => Padding(
                padding: const EdgeInsets.only(right: 7),
                child: ChoiceChip(
                  label: Text(_filters[i]),
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
              )).toList(),
        ),
      );

  Widget _body(BuildContext context, AppState state, List<Recording> recs) {
    if (state.mediaState == LoadState.loading ||
        state.mediaState == LoadState.idle) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.mediaState == LoadState.error) {
      return _notice(
        state.mediaError ?? '录像读取失败',
        '该错误来自 NAS 的真实响应（Event/Query）。请确认账号具备录像查看权限。',
        () => state.refreshMedia(),
      );
    }
    if (recs.isEmpty) {
      return _notice(
        state.recordings.isEmpty ? 'NAS 暂无录像片段' : '当前筛选条件下没有录像',
        '不会产生任何占位数据；录像由 Surveillance Station 按计划生成。',
        () => state.refreshMedia(),
      );
    }

    // 按真实日期分组。
    final groups = <String, List<Recording>>{};
    for (final r in recs) {
      groups.putIfAbsent(r.dateLabel, () => <Recording>[]).add(r);
    }
    return RefreshIndicator(
      onRefresh: state.refreshMedia,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        itemCount: groups.length,
        itemBuilder: (context, gi) {
          final date = groups.keys.elementAt(gi);
          final items = groups[date]!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
                child: Text(date,
                    style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.3,
                        color: AppColors.faint,
                        fontWeight: FontWeight.w600)),
              ),
              ...items.map((r) => _tile(context, state, r)),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(BuildContext context, AppState state, Recording r) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: const BadgeIcon(AppIcons.recordings, tone: IconTone.blue),
          title: Text('${r.cameraName} · ${r.eventType}',
              style:
                  const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          subtitle: Text(
              '${r.startTime.hour.toString().padLeft(2, '0')}:${r.startTime.minute.toString().padLeft(2, '0')}'
              ' · ${r.durationLabel}${r.locked ? ' · 已锁定' : ''}'
              '${r.codec.isEmpty ? '' : ' · ${r.codec}'}',
              style: TextStyle(fontSize: 10, color: AppColors.faint)),
          trailing: PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'play':
                  openExternalUrl(
                      context, state.recordingDownloadUrl(r),
                      label: '录像片段');
                  break;
                case 'copy':
                  copyToClipboard(
                      context, state.recordingDownloadUrl(r),
                      label: '真实录像链接已复制');
                  break;
                case 'lock':
                  _toggleLock(state, r);
                  break;
                case 'delete':
                  _delete(state, r);
                  break;
              }
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                  value: 'play', child: Text('用系统播放器打开')),
              const PopupMenuItem<String>(
                  value: 'copy', child: Text('复制真实下载链接')),
              PopupMenuItem<String>(
                  value: 'lock',
                  child: Text(r.locked ? '解锁片段' : '锁定片段')),
              const PopupMenuItem<String>(
                  value: 'delete', child: Text('从 NAS 删除')),
            ],
          ),
          onTap: () => openExternalUrl(
              context, state.recordingDownloadUrl(r),
              label: '录像片段'),
        ),
      );

  /// 快照不是 SS 的历史列表，而是即时抓图；明确引导到真实入口。
  Widget _snapshotGuide(BuildContext context, AppState state) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const AppIcon(AppIcons.snapshot, size: 36, color: AppColors.blue),
              const SizedBox(height: 14),
              const Text('快照为实时抓图',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                'Surveillance Station 不提供「历史快照列表」API。请进入「实时画面」→ 单画面 → 点击「快照」，'
                'App 会调用 Camera/GetSnapshot 从 NAS 抓取当前真实画面。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: AppColors.sub),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(title,
                    style: const TextStyle(
                        fontSize: 29, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 3),
            Text(subtitle, style: TextStyle(fontSize: 12, color: AppColors.sub)),
          ],
        ),
      );
}
