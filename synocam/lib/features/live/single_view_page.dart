// 单画面：真实实时预览 + 真实快照 + 真实 PTZ/预置位/巡逻 + 可拖动录像时间轴。
// 点击任意录制事件或拖动时间轴后，都在 App 内打开 PlaybackPage 回放，不再跳浏览器。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/network/syno_api.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../core/utils/launcher.dart';
import '../../data/models/camera.dart';
import '../../data/models/media.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/live_clock.dart';
import '../../widgets/live_snapshot.dart';
import '../cameras/camera_edit_page.dart';
import '../playback/playback_page.dart';

class SingleViewPage extends StatefulWidget {
  const SingleViewPage({super.key, required this.camera});

  final Camera camera;

  @override
  State<SingleViewPage> createState() => _SingleViewPageState();
}

class _SingleViewPageState extends State<SingleViewPage> {
  bool _busy = false;
  double _scrubFraction = 0;
  bool _scrubReady = false;
  List<Map<String, dynamic>> _presets = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPresets());
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _run(Future<void> Function() op, String label) async {
    setState(() => _busy = true);
    try {
      await op();
      _snack('$label：NAS 已响应');
    } on SynoException catch (e) {
      _snack('$label 失败：${e.diagnostic}');
    } catch (e) {
      _snack('$label 失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadPresets() async {
    if (!mounted) return;
    final state = context.read<AppState>();
    if (!widget.camera.ptzCapable) return;
    try {
      final list = await state.listPresets(widget.camera.id);
      if (mounted) setState(() => _presets = list);
    } catch (_) {
      // 该摄像机/版本不支持预置位列表，保留空态即可。
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cam = widget.camera;
    return Scaffold(
      appBar: AppBar(
        title: Text(cam.name),
        leading: IconButton(
          icon: const AppIcon(AppIcons.back, size: 20, color: AppColors.blue),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: <Widget>[
          IconButton(
            icon: const AppIcon(AppIcons.refresh,
                size: 20, color: AppColors.blue),
            onPressed: () => state.refreshAll(),
          ),
          IconButton(
            icon: const AppIcon(AppIcons.edit, size: 20, color: AppColors.blue),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => CameraEditPage(camera: cam),
            )),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 26),
        children: <Widget>[
          _bigImage(context, state, cam),
          const SizedBox(height: 10),
          _streamActions(context, state, cam),
          const SectionLabel('快捷操作'),
          _actions(context, state, cam),
          const SectionLabel('云台控制 · PTZ'),
          _ptz(context, state, cam),
          const SectionLabel('今日录像（可拖动时间轴回放）'),
          _timeline(context, state, cam),
          const SectionLabel('设备信息'),
          _deviceInfo(cam),
        ],
      ),
    );
  }

  Widget _bigImage(BuildContext context, AppState state, Camera cam) =>
      ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              LiveSnapshot(camera: cam),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Color(0x47000000),
                      Colors.transparent,
                      Colors.transparent,
                      Color(0x99000000),
                    ],
                    stops: <double>[0, .24, .55, 1],
                  ),
                ),
              ),
              Positioned(
                top: 11,
                left: 12,
                right: 12,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    _osdChip('● LIVE', AppColors.red),
                    _osdChip(cam.codec.isEmpty ? '实时预览' : cam.codec, null),
                  ],
                ),
              ),
              Positioned(
                left: 13,
                right: 13,
                bottom: 11,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text(cam.name,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                    LiveClock(
                      offsetMinutes: state.timeOffsetMinutes,
                      style:
                          const TextStyle(fontSize: 10, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _osdChip(String text, Color? dot) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: Colors.black38, borderRadius: BorderRadius.circular(6)),
        child: Text(text,
            style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: dot ?? Colors.white)),
      );

  Widget _streamActions(BuildContext context, AppState state, Camera cam) {
    final clips = state.recordings.where((r) => r.cameraId == cam.id).toList();
    return Row(
      children: <Widget>[
        Expanded(
          child: OutlinedButton.icon(
            onPressed: clips.isEmpty
                ? null
                : () => _openPlayback(context, cam, clips.first),
            icon: const AppIcon(AppIcons.play, size: 16, color: AppColors.blue),
            label: Text(clips.isEmpty ? '今日暂无录像片段' : '打开录像回放（App 内）'),
            style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.blue,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11))),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: '复制 RTSP 地址',
          onPressed: () => copyToClipboard(context, state.rtspUrl(cam),
              label: 'RTSP 地址已复制（可粘贴到支持 RTSP 的播放器）'),
          icon: const AppIcon(AppIcons.more, size: 20),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context, AppState state, Camera cam) {
    final items = <_Action>[
      const _Action(AppIcons.snapshot, '快照'),
      const _Action(AppIcons.zoom, '变焦+'),
      const _Action(AppIcons.target, '预置位'),
      const _Action(AppIcons.patrol, '巡逻'),
      const _Action(AppIcons.mic, '对讲'),
      const _Action(AppIcons.mute, '音频'),
    ];
    return GridView.count(
      crossAxisCount: 6,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: items
          .map((a) => _ActionButton(
                action: a,
                enabled: !_busy && a.label != '对讲' && a.label != '音频',
                onTap: () => _onAction(context, state, cam, a.label),
              ))
          .toList(),
    );
  }

  void _onAction(
      BuildContext context, AppState state, Camera cam, String label) {
    switch (label) {
      case '快照':
        _run(() async {
          final bytes = await state.takeSnapshot(cam);
          if (!context.mounted) return;
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('实时快照'),
              content: Image.memory(Uint8List.fromList(bytes)),
              actions: <Widget>[
                TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('关闭')),
              ],
            ),
          );
        }, '快照');
        break;
      case '变焦+':
        _run(() => state.ptzZoom(cam.id, 'in'), '变焦');
        break;
      case '预置位':
        _showPresets(context, state, cam);
        break;
      case '巡逻':
        _run(() => state.runPatrol(cam.id), '巡逻');
        break;
      // 对讲 / 音频：SS Web API 不提供双向音频与音频流，按钮已禁用。
      default:
        break;
    }
  }

  Future<void> _showPresets(
      BuildContext context, AppState state, Camera cam) async {
    if (_presets.isEmpty) {
      _snack('该摄像机未返回预置位（PTZ 能力或 API 版本限制）');
      return;
    }
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择预置位'),
        children: _presets.map((p) {
          final id = (p['id'] ?? p['presetId'] ?? 0) as num? ?? 0;
          final name = '${p['name'] ?? p['presetName'] ?? '预置位 $id'}';
          return SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(id.toInt()),
            child: Text(name),
          );
        }).toList(),
      ),
    );
    if (chosen != null) {
      await _run(() => state.goPreset(cam.id, chosen), '转到预置位');
    }
  }

  void _openPlayback(BuildContext context, Camera cam, Recording r) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlaybackPage(recording: r, camera: cam),
    ));
  }

  Widget _ptz(BuildContext context, AppState state, Camera cam) {
    void move(String dir) => _run(() => state.ptzMove(cam.id, dir), '云台 $dir');
    return Row(
      children: <Widget>[
        _ptzPad(move, cam.ptzCapable),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            children: <Widget>[
              _infoChip('PTZ 能力', cam.ptzCapable ? '支持' : '不支持'),
              _infoChip('预置位', '${_presets.length} 个（来自 NAS）'),
              _infoChip('状态', cam.isOnline ? '在线' : '已停用'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _ptzPad(void Function(String) move, bool enabled) => Container(
        width: 146,
        height: 146,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const RadialGradient(
              colors: <Color>[Colors.white, Color(0xFFECEEF2)]),
          border: Border.all(color: AppColors.line),
        ),
        child: Stack(
          children: <Widget>[
            _padBtn(
                Alignment.topCenter, AppIcons.up, () => move('up'), enabled),
            _padBtn(Alignment.bottomCenter, AppIcons.down, () => move('down'),
                enabled),
            _padBtn(Alignment.centerLeft, AppIcons.left, () => move('left'),
                enabled),
            _padBtn(Alignment.centerRight, AppIcons.right, () => move('right'),
                enabled),
            Center(
              child: IconButton(
                icon: const AppIcon(AppIcons.target,
                    size: 22, color: AppColors.blue),
                onPressed: enabled ? () => move('home') : null,
              ),
            ),
          ],
        ),
      );

  Widget _padBtn(
          Alignment align, IconData icon, VoidCallback onTap, bool enabled) =>
      Align(
        alignment: align,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: InkResponse(
            onTap: enabled ? onTap : null,
            radius: 22,
            child: AppIcon(icon, size: 22),
          ),
        ),
      );

  Widget _infoChip(String label, String value) => Container(
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(label, style: TextStyle(fontSize: 12, color: AppColors.sub)),
            Flexible(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );

  /// 今日录像时间轴：可拖动定位，点击色块/列表项进入 App 内回放。
  Widget _timeline(BuildContext context, AppState state, Camera cam) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final clips = state.recordings
        .where((r) => r.cameraId == cam.id && !r.startTime.isBefore(todayStart))
        .toList();

    if (!_scrubReady && clips.isNotEmpty) {
      _scrubFraction =
          TimelineMath.fractionOf(clips.first.startTime, todayStart);
      _scrubReady = true;
    }

    if (state.mediaState == LoadState.error) {
      final err = state.mediaError ?? '录像读取失败';
      return _notice('$err\n${classifyFailure(state.mediaError).advice}',
          onRetry: () => state.refreshMedia());
    }
    if (state.mediaState == LoadState.loading) {
      return const Center(
          child: Padding(
        padding: EdgeInsets.all(16),
        child: CircularProgressIndicator(),
      ));
    }
    if (clips.isEmpty) {
      return _notice('今日该摄像机暂无录像片段（数据来自 NAS 真实查询）',
          onRetry: () => state.refreshMedia());
    }

    final t = TimelineMath.timeAt(_scrubFraction, todayStart);
    final hit =
        TimelineMath.clipAt(clips, t) ?? TimelineMath.nearestClip(clips, t);

    return Column(
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text('00:00',
                style: TextStyle(fontSize: 10, color: AppColors.faint)),
            Text('拖动定位 ${state.timeLabel(t)}',
                style:
                    const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            Text('24:00',
                style: TextStyle(fontSize: 10, color: AppColors.faint)),
          ],
        ),
        Slider(
          value: _scrubFraction,
          onChanged: (v) => setState(() => _scrubFraction = v),
        ),
        _clipTrack(context, cam, clips, todayStart),
        const SizedBox(height: 10),
        _scrubCard(context, state, cam, t, hit),
        const SizedBox(height: 10),
        ...clips.take(8).map((r) => _clipTile(context, state, cam, r)),
        const SizedBox(height: 6),
        Text(
          '拖动时间轴定位到任意时刻，点「回放」进入 App 内播放器；'
          '色块与列表项也可直接打开对应片段（不再跳转浏览器）。',
          style: TextStyle(fontSize: 10.5, color: AppColors.faint),
        ),
      ],
    );
  }

  Widget _clipTrack(BuildContext context, Camera cam, List<Recording> clips,
          DateTime dayStart) =>
      LayoutBuilder(
        builder: (BuildContext ctx, BoxConstraints constraints) {
          final w = constraints.maxWidth;
          return Container(
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.line),
            ),
            child: Stack(
              children: clips.map((r) {
                final left = TimelineMath.fractionOf(r.startTime, dayStart);
                final width =
                    (r.playbackDurationSeconds / TimelineMath.secondsPerDay)
                        .clamp(0.004, 1.0)
                        .toDouble();
                return Positioned(
                  left: w * left,
                  width: w * width,
                  top: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onTap: () => _openPlayback(context, cam, r),
                    child: Container(
                      decoration: BoxDecoration(
                        color: (r.eventType == '移动侦测' || r.eventType == '告警输入')
                            ? AppColors.red.withOpacity(.35)
                            : AppColors.green.withOpacity(.3),
                        border: Border(
                          left: BorderSide(
                              color: r.eventType == '移动侦测'
                                  ? AppColors.red
                                  : AppColors.green),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        },
      );

  Widget _scrubCard(BuildContext context, AppState state, Camera cam,
          DateTime t, Recording? hit) =>
      Card(
        child: ListTile(
          leading: const BadgeIcon(AppIcons.timeline, tone: IconTone.blue),
          title: Text('定位到 ${state.timeLabel(t)}',
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          subtitle: Text(
              hit == null
                  ? '该时刻附近无录像片段'
                  : '最近片段：${hit.eventType} · ${hit.durationLabel}',
              style: TextStyle(fontSize: 10.5, color: AppColors.faint)),
          trailing: FilledButton.icon(
            onPressed:
                hit == null ? null : () => _openPlayback(context, cam, hit),
            icon: const AppIcon(AppIcons.play, size: 14, color: Colors.white),
            label: const Text('回放', style: TextStyle(fontSize: 11)),
          ),
        ),
      );

  Widget _clipTile(
          BuildContext context, AppState state, Camera cam, Recording r) =>
      Card(
        margin: const EdgeInsets.only(bottom: 7),
        child: ListTile(
          dense: true,
          leading: const AppIcon(AppIcons.play, size: 17),
          title: Text(r.eventType, style: const TextStyle(fontSize: 12.5)),
          subtitle: Text(
              '${state.timeShort(r.startTime)} · ${r.durationLabel}'
              '${r.locked ? ' · 已锁定' : ''}',
              style: TextStyle(fontSize: 10, color: AppColors.faint)),
          trailing: const AppIcon(AppIcons.chevron, size: 15),
          onTap: () => _openPlayback(context, cam, r),
        ),
      );

  Widget _notice(String msg, {required VoidCallback onRetry}) {
    final relogin = classifyFailure(msg).needsReLogin;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        children: <Widget>[
          Text(msg,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.sub)),
          const SizedBox(height: 10),
          TextButton.icon(
              onPressed: relogin
                  ? () => context.read<AppState>().reportSessionExpired()
                  : onRetry,
              icon: const AppIcon(AppIcons.refresh, size: 15),
              label: Text(relogin ? '重新登录' : '重新读取')),
        ],
      ),
    );
  }

  Widget _deviceInfo(Camera cam) => Card(
        child: Column(
          children: <Widget>[
            _infoRow(
                AppIcons.cameras, cam.model.isEmpty ? '—' : cam.model, '型号'),
            _infoRow(AppIcons.server, cam.ip.isEmpty ? '—' : cam.ip, 'IP 地址'),
            _infoRow(
                AppIcons.info, cam.serial.isEmpty ? '—' : cam.serial, '序列号'),
            _infoRow(AppIcons.power, cam.isOnline ? '已启用' : '已停用', '状态'),
            _infoRow(
                AppIcons.shield, cam.canStream ? '已获取流凭证' : '未返回流凭证', '直播流'),
          ],
        ),
      );

  Widget _infoRow(IconData icon, String value, String label) => ListTile(
        leading: BadgeIcon(icon, boxSize: 30, iconSize: 15),
        title: Text(value,
            style:
                const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        subtitle: Text(label, style: const TextStyle(fontSize: 11)),
        dense: true,
      );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 9),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.3,
                color: AppColors.faint,
                fontWeight: FontWeight.w600)),
      );
}

class _Action {
  const _Action(this.icon, this.label);
  final IconData icon;
  final String label;
}

class _ActionButton extends StatelessWidget {
  const _ActionButton(
      {required this.action, required this.onTap, this.enabled = true});
  final _Action action;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: enabled ? 1 : .42,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(13),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: AppColors.line),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                AppIcon(action.icon, size: 20),
                const SizedBox(height: 4),
                Text(action.label,
                    style: TextStyle(fontSize: 8, color: AppColors.faint)),
              ],
            ),
          ),
        ),
      );
}
