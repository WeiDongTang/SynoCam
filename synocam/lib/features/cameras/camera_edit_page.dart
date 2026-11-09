// 编辑摄像机：名称 / 启停 / 流质量 / 编码 / 录像模式 / 删除 / 保存。
// 型号、序列号、IP 由 SS 管理只读展示（对齐官方边界，App 内不可改）。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../data/models/camera.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';

class CameraEditPage extends StatefulWidget {
  const CameraEditPage({super.key, required this.camera});
  final Camera camera;

  @override
  State<CameraEditPage> createState() => _CameraEditPageState();
}

class _CameraEditPageState extends State<CameraEditPage> {
  late final TextEditingController _name =
      TextEditingController(text: widget.camera.name);
  late bool _enabled = widget.camera.enabled;
  late String _quality = widget.camera.quality;
  String _codec = 'H.265';
  String _recordMode = '连续录制 + 移动侦测';
  bool _saving = false;

  static const List<String> _qualities = <String>[
    '4MP · 高',
    '2K · 中',
    '1080P · 低'
  ];
  static const List<String> _codecs = <String>['H.265', 'H.264', 'MJPEG'];
  static const List<String> _modes = <String>[
    '连续录制 + 移动侦测',
    '仅移动侦测',
    '按计划',
  ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final q = _quality.split(' ').first; // 4MP / 2K / 1080P
    await context.read<AppState>().saveCamera(
          widget.camera,
          name: _name.text.trim(),
          quality: q,
        );
    await context.read<AppState>().toggleCamera(widget.camera, _enabled);
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('摄像机信息已保存')),
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除此摄像机'),
        content: Text('将移除「${widget.camera.name}」，此操作不可撤销。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除', style: TextStyle(color: AppColors.red))),
        ],
      ),
    );
    if (ok == true) {
      // SS 的删除属网页端高危操作；App 内以停用代替物理删除（对齐官方）。
      await context.read<AppState>().toggleCamera(widget.camera, false);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已停用该摄像机（删除请在 SS 网页端执行）')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cam = widget.camera;
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑摄像机'),
        leading: IconButton(
          icon: const AppIcon(AppIcons.back, size: 20, color: AppColors.blue),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存',
                style: TextStyle(
                    color: AppColors.blue, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 26),
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                context.read<AppState>().snapshotUrl(cam),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                    color: const Color(0xFF22262F),
                    child: const AppIcon(AppIcons.cameras,
                        size: 40, color: Colors.white24)),
              ),
            ),
          ),
          const _Section('基本信息'),
          _group(<Widget>[
            _textField('名称', _name),
            _toggle('启用', _enabled, (v) => setState(() => _enabled = v)),
            _readonly('型号', cam.model.isEmpty ? '—' : cam.model),
            _readonly('序列号', cam.serial.isEmpty ? '—' : cam.serial),
            _readonly('IP 地址', cam.ip.isEmpty ? '—' : cam.ip),
            _readonly('状态', cam.isOnline ? '在线' : '已停用'),
          ]),
          const _Section('视频与流'),
          _group(<Widget>[
            _dropdown('流质量', _quality, _qualities,
                (v) => setState(() => _quality = v!)),
            _dropdown(
                '编码', _codec, _codecs, (v) => setState(() => _codec = v!)),
            _toggle('数字输出', true, (_) {}),
          ]),
          const _Section('录像'),
          _group(<Widget>[
            _dropdown('录像模式', _recordMode, _modes,
                (v) => setState(() => _recordMode = v!)),
            _linkRow('预置位 / 巡逻', '4 个'),
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              '型号、序列号、IP 等由 Surveillance Station 管理，高级参数请在网页端修改。App 内可调整名称、启停、流质量与录像模式。',
              style: TextStyle(fontSize: 11, color: AppColors.faint),
            ),
          ),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const AppIcon(AppIcons.check, size: 16, color: Colors.white),
            label: const Text('保存更改'),
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.blue,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _delete,
            icon:
                const AppIcon(AppIcons.delete, size: 16, color: AppColors.red),
            label: const Text('删除此摄像机', style: TextStyle(color: AppColors.red)),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                side: const BorderSide(color: AppColors.line)),
          ),
        ],
      ),
    );
  }

  Widget _group(List<Widget> children) => Card(
        child: Column(children: children),
      );

  Widget _textField(String label, TextEditingController controller) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: <Widget>[
            SizedBox(
                width: 82,
                child: Text(label, style: const TextStyle(fontSize: 13))),
            Expanded(
              child: TextField(
                controller: controller,
                textAlign: TextAlign.right,
                decoration: const InputDecoration(
                    filled: false, border: InputBorder.none, isDense: true),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      );

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: <Widget>[
            SizedBox(
                width: 82,
                child: Text(label, style: const TextStyle(fontSize: 13))),
            const Spacer(),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      );

  Widget _readonly(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: <Widget>[
            SizedBox(
                width: 82,
                child: Text(label, style: const TextStyle(fontSize: 13))),
            Expanded(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11.5, color: AppColors.faint)),
            ),
          ],
        ),
      );

  Widget _dropdown(String label, String value, List<String> items,
          ValueChanged<String?> onChanged) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          children: <Widget>[
            SizedBox(
                width: 82,
                child: Text(label, style: const TextStyle(fontSize: 13))),
            Expanded(
              child: DropdownButton<String>(
                value: value,
                items: items
                    .map((s) => DropdownMenuItem<String>(
                        value: s,
                        child: Text(s, style: const TextStyle(fontSize: 12))))
                    .toList(),
                onChanged: onChanged,
                isExpanded: true,
                alignment: AlignmentDirectional.centerEnd,
                underline: const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      );

  Widget _linkRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: <Widget>[
            SizedBox(
                width: 120,
                child: Text(label, style: const TextStyle(fontSize: 13))),
            const Spacer(),
            Text(value,
                style: TextStyle(fontSize: 11.5, color: AppColors.faint)),
            const SizedBox(width: 4),
            const AppIcon(AppIcons.chevron, size: 14),
          ],
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 9),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.3,
                color: AppColors.faint,
                fontWeight: FontWeight.w600)),
      );
}
