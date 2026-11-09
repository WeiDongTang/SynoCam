// 单画面：大画面 + 快捷操作(快照/对讲/变焦/预置位/巡逻/静音) + PTZ 云台
// + 时间轴回放(变速/关键帧) + 设备信息 + 编辑入口。对齐定稿 A 原型 p-single。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../data/models/camera.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';
import '../cameras/camera_edit_page.dart';

class SingleViewPage extends StatefulWidget {
  const SingleViewPage({super.key, required this.camera});

  final Camera camera;

  @override
  State<SingleViewPage> createState() => _SingleViewPageState();
}

class _SingleViewPageState extends State<SingleViewPage> {
  double _speed = 1.0;
  bool _muted = false;
  bool _playing = true;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cam = widget.camera;
    return Scaffold(
      appBar: AppBar(
        title: const Text('单画面'),
        leading: IconButton(
          icon: const AppIcon(AppIcons.back, size: 20, color: AppColors.blue),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: <Widget>[
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
          _bigImage(state, cam),
          const SectionLabel('快捷操作'),
          _actions(context, state, cam),
          const SectionLabel('云台控制 · PTZ'),
          _ptz(context, state, cam),
          const SectionLabel('时间轴回放'),
          _timeline(state, cam),
          const SectionLabel('设备信息'),
          _deviceInfo(cam),
        ],
      ),
    );
  }

  Widget _bigImage(AppState state, Camera cam) => ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Image.network(
                state.snapshotUrl(cam),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: const Color(0xFF22262F),
                  alignment: Alignment.center,
                  child: const AppIcon(AppIcons.cameras,
                      size: 40, color: Colors.white24),
                ),
              ),
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
                    _osdChip('${cam.codec} · ${cam.quality}', null),
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
                    Text(TimeOfDay.now().format(context),
                        style: const TextStyle(
                            fontSize: 10, color: Colors.white70)),
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

  Widget _actions(BuildContext context, AppState state, Camera cam) {
    final items = <_Action>[
      const _Action(AppIcons.snapshot, '快照'),
      const _Action(AppIcons.mic, '对讲'),
      const _Action(AppIcons.zoom, '变焦'),
      const _Action(AppIcons.target, '预置位'),
      const _Action(AppIcons.patrol, '巡逻'),
      _Action(_muted ? AppIcons.mute : AppIcons.mic, '静音'),
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
                onTap: () => _onAction(context, state, cam, a.label),
              ))
          .toList(),
    );
  }

  void _onAction(
      BuildContext context, AppState state, Camera cam, String label) {
    if (label == '静音') setState(() => _muted = !_muted);
    if (label == '巡逻') {
      state.ptzMove(cam.id, 'patrol');
    }
    if (label == '预置位') {
      state.goPreset(cam.id, 2);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('$label 已触发'), duration: const Duration(seconds: 1)),
    );
  }

  Widget _ptz(BuildContext context, AppState state, Camera cam) {
    Future<void> move(String dir) async {
      try {
        // CameraRepository.ptzMove 经 state 暴露的门面调用（见 AppState）。
        await state.ptzMove(cam.id, dir);
      } catch (_) {}
    }

    return Row(
      children: <Widget>[
        _ptzPad(move),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            children: <Widget>[
              _infoChip('预置位', 'P2 · 停车场'),
              _infoChip('码率', '2.4 Mbps'),
              _infoChip('状态', cam.isOnline ? '直播中' : '离线'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _ptzPad(Future<void> Function(String) move) => Container(
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
            _padBtn(Alignment.topCenter, AppIcons.up, () => move('up')),
            _padBtn(Alignment.bottomCenter, AppIcons.down, () => move('down')),
            _padBtn(Alignment.centerLeft, AppIcons.left, () => move('left')),
            _padBtn(Alignment.centerRight, AppIcons.right, () => move('right')),
            Center(
              child: IconButton(
                icon: const AppIcon(AppIcons.target,
                    size: 22, color: AppColors.blue),
                onPressed: () => move('home'),
              ),
            ),
          ],
        ),
      );

  Widget _padBtn(Alignment align, IconData icon, VoidCallback onTap) => Align(
        alignment: align,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: InkResponse(
            onTap: onTap,
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
            Text(value,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _timeline(AppState state, Camera cam) {
    cam;
    return Column(
      children: <Widget>[
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.line),
          ),
          child: Stack(
            children: <Widget>[
              _seg(4, 18, AppColors.green.withOpacity(.26), Colors.green),
              _seg(30, 6, AppColors.red.withOpacity(.28), Colors.red),
              _seg(42, 24, AppColors.green.withOpacity(.26), Colors.green),
              _seg(72, 5, AppColors.red.withOpacity(.28), Colors.red),
              _seg(80, 14, AppColors.green.withOpacity(.26), Colors.green),
              Positioned(
                left: MediaQuery.of(context).size.width * .58 - 32,
                top: -3,
                bottom: -3,
                child: Container(width: 2, color: AppColors.blue),
              ),
            ],
          ),
        ),
        const SizedBox(height: 7),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text('今日 00:00',
                style: TextStyle(fontSize: 10, color: AppColors.faint)),
            Text('14:32',
                style: TextStyle(fontSize: 10, color: AppColors.faint)),
            Text('24:00',
                style: TextStyle(fontSize: 10, color: AppColors.faint)),
          ],
        ),
        const SizedBox(height: 9),
        Row(
          children: <Widget>[
            _tlBtn(AppIcons.skipBack, () {}),
            _tlBtn(_playing ? AppIcons.pause : AppIcons.play,
                () => setState(() => _playing = !_playing)),
            _tlBtn(AppIcons.skipFwd, () {}),
            const SizedBox(width: 7),
            _speedChip(),
            const Spacer(),
            _keyframeChip(),
          ],
        ),
      ],
    );
  }

  Widget _seg(double left, double width, Color bg, Color border) => Positioned(
        left: (MediaQuery.of(context).size.width - 32) * left / 100,
        width: (MediaQuery.of(context).size.width - 32) * width / 100,
        top: 0,
        bottom: 0,
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            border: Border(left: BorderSide(color: border.withOpacity(.6))),
          ),
        ),
      );

  Widget _tlBtn(IconData icon, VoidCallback onTap) => Container(
        width: 38,
        height: 34,
        margin: const EdgeInsets.only(right: 7),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: AppColors.line),
        ),
        child: IconButton(
          padding: EdgeInsets.zero,
          icon: AppIcon(icon, size: 16),
          onPressed: onTap,
        ),
      );

  Widget _speedChip() => GestureDetector(
        onTap: () {
          final speeds = AppConfig.playbackSpeeds;
          final i = speeds.indexOf(_speed);
          setState(() => _speed = speeds[(i + 1) % speeds.length]);
        },
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.blueSoft,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: AppColors.blue),
          ),
          child: Text('$_speed×',
              style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.blue,
                  fontWeight: FontWeight.w600)),
        ),
      );

  Widget _keyframeChip() => Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: <Widget>[
            const AppIcon(AppIcons.keyframe, size: 14),
            const SizedBox(width: 5),
            Text('关键帧', style: TextStyle(fontSize: 10, color: AppColors.sub)),
          ],
        ),
      );

  Widget _deviceInfo(Camera cam) => Card(
        child: Column(
          children: <Widget>[
            _infoRow(
                AppIcons.cameras, cam.model.isEmpty ? '—' : cam.model, '型号'),
            _infoRow(AppIcons.server, cam.ip.isEmpty ? '—' : cam.ip, 'IP 地址'),
            _infoRow(
                AppIcons.info, cam.serial.isEmpty ? '—' : cam.serial, '序列号'),
            _infoRow(AppIcons.power, cam.isOnline ? '已启用' : '已停用', '状态'),
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
  const _ActionButton({required this.action, required this.onTap});
  final _Action action;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
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
      );
}
