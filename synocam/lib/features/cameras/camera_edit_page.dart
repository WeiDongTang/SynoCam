// 编辑摄像机：只暴露 SS Web API 真实支持的操作（改名 / 启停 / 流质量）。
// 编码、录像模式、预置位等需 SS 网页端配置，明确标注并禁用，不做假保存。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../core/utils/launcher.dart';
import '../../data/models/camera.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/live_snapshot.dart';

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
  late String _quality =
      widget.camera.quality.isEmpty ? '默认' : widget.camera.quality;
  bool _saving = false;

  static const List<String> _qualities = <String>[
    '默认',
    '高',
    '中',
    '低',
  ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final state = context.read<AppState>();
    try {
      final q = _quality == '默认' ? null : _quality;
      await state.saveCamera(widget.camera,
          name: _name.text.trim(), quality: q);
      await state.toggleCamera(widget.camera, _enabled);
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('已保存到 NAS');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('保存失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cam = widget.camera;
    final state = context.watch<AppState>();
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
              child: LiveSnapshot(camera: cam),
            ),
          ),
          const _Section('基本信息 · 可保存到 NAS'),
          _group(<Widget>[
            _textField('名称', _name),
            _toggle('启用', _enabled, (v) => setState(() => _enabled = v)),
            _dropdown('流质量', _quality, _qualities,
                (v) => setState(() => _quality = v!)),
            _readonly('型号', cam.model.isEmpty ? '—' : cam.model),
            _readonly('序列号', cam.serial.isEmpty ? '—' : cam.serial),
            _readonly('IP 地址', cam.ip.isEmpty ? '—' : cam.ip),
            _readonly('状态', cam.isOnline ? '在线' : '已停用'),
            _readonly('编码', cam.codec.isEmpty ? '未返回' : cam.codec),
          ]),
          const _Section('仅可在 Surveillance Station 网页端修改'),
          _group(<Widget>[
            _readonly('录像模式', '按计划在 SS 端配置'),
            _readonly('预置位 / 巡逻', '在 SS 端设置后 App 可调用'),
            _readonly('数字输出 / 音频', 'SS Web API 未提供'),
          ]),
          ListTile(
            leading: const AppIcon(AppIcons.server, size: 18),
            title: const Text('打开 SS 网页端配置',
                style: TextStyle(fontSize: 13, color: AppColors.blue)),
            trailing: const AppIcon(AppIcons.chevron, size: 15),
            onTap: () =>
                openExternalUrl(context, state.webUiUrl(), label: 'SS 网页端'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              'App 内所有可见控件都会真实调用 Synology Web API；无对应接口的参数不做伪实现。',
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
            onPressed: () async {
              try {
                await state.toggleCamera(cam, false);
                if (context.mounted) {
                  _snack('已在 NAS 停用该摄像机');
                  Navigator.of(context).pop();
                }
              } catch (e) {
                _snack('停用失败：$e');
              }
            },
            icon: const AppIcon(AppIcons.power, size: 16, color: AppColors.red),
            label: const Text('停用此摄像机', style: TextStyle(color: AppColors.red)),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                side: const BorderSide(color: AppColors.line)),
          ),
          const SizedBox(height: 6),
          Text('物理删除需在 SS 网页端执行（Web API 不提供）。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10.5, color: AppColors.faint)),
        ],
      ),
    );
  }

  Widget _group(List<Widget> children) =>
      Card(child: Column(children: children));

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
                width: 120,
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
                value: items.contains(value) ? value : items.first,
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
