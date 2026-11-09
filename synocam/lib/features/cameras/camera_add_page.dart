// 添加摄像头：自动发现 / 二维码配网 / 手动添加 三种方式 + 许可证额度提示。
// 对齐定稿 A 原型 p-add。
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../widgets/app_icon.dart';

class CameraAddPage extends StatefulWidget {
  const CameraAddPage({super.key});

  @override
  State<CameraAddPage> createState() => _CameraAddPageState();
}

class _CameraAddPageState extends State<CameraAddPage>
    with SingleTickerProviderStateMixin {
  int _tab = 0;
  final Set<int> _selected = <int>{};

  static const List<_FoundDevice> _found = <_FoundDevice>[
    _FoundDevice('Synology BC500', 'SNS-2341-0093', '192.168.1.120'),
    _FoundDevice('Synology TC500', 'SNS-2341-4471', '192.168.1.121'),
    _FoundDevice('Synology CC400W', 'SNS-2341-8820', '192.168.1.122'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('添加摄像头'),
        leading: IconButton(
          icon: const AppIcon(AppIcons.back, size: 20, color: AppColors.blue),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text('8 / 10 路',
                  style: TextStyle(fontSize: 12, color: AppColors.faint)),
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<int>(
              segments: const <ButtonSegment<int>>[
                ButtonSegment<int>(value: 0, label: Text('自动发现')),
                ButtonSegment<int>(value: 1, label: Text('二维码配网')),
                ButtonSegment<int>(value: 2, label: Text('手动添加')),
              ],
              selected: <int>{_tab},
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle:
                    WidgetStateProperty.all(const TextStyle(fontSize: 12)),
              ),
              onSelectionChanged: (Set<int> s) =>
                  setState(() => _tab = s.first),
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: <Widget>[
                _discover(context),
                _qr(context),
                _manual(context),
              ][_tab],
            ),
          ),
        ],
      ),
    );
  }

  Widget _discover(BuildContext context) => ListView(
        key: const ValueKey<int>(0),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 26),
        children: <Widget>[
          _sectionRow('局域网内发现的设备', '重新扫描', () {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('已重新扫描局域网')));
          }),
          Card(
            child: Column(
              children: List<Widget>.generate(_found.length, (i) {
                final d = _found[i];
                final checked = _selected.contains(i);
                return ListTile(
                  onTap: () => setState(
                      () => checked ? _selected.remove(i) : _selected.add(i)),
                  leading: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: checked ? AppColors.blue : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(
                          color: checked ? AppColors.blue : AppColors.line),
                    ),
                    child: checked
                        ? const AppIcon(AppIcons.check,
                            size: 14, color: Colors.white)
                        : null,
                  ),
                  title: Text(d.model,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: Text('${d.sn} · ${d.ip}',
                      style: TextStyle(fontSize: 10, color: AppColors.faint)),
                  trailing: _badge('未添加'),
                );
              }),
            ),
          ),
          const SizedBox(height: 12),
          _note(
              '自动发现仅列出同一局域网内尚未添加的 Synology 品牌摄像头。无线型号需开启蓝牙；若设备无法连接 Surveillance Station，可尝试 Smart Connection 自动配置端口转发。'),
          _primary('添加所选设备${_selected.isEmpty ? '' : ' (${_selected.length})'}',
              AppIcons.add, () {
            if (_selected.isEmpty) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('请先选择要添加的设备')));
              return;
            }
            Navigator.of(context).pop();
          }),
        ],
      );

  Widget _qr(BuildContext context) => ListView(
        key: const ValueKey<int>(1),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 26),
        children: <Widget>[
          _scanBox(),
          const _Section('无线配置'),
          _group(<Widget>[
            _input('Wi-Fi', 'Home_5G'),
            _dropdown('加密方式', 'WPA3-Personal', <String>[
              'WPA3-Personal',
              'WPA2-Personal',
              'WPA-Personal',
              '无'
            ]),
            _input('密码', '••••••••', obscure: true),
            _toggle('DHCP', true),
          ]),
          _note(
              '支持隐藏 SSID 手动输入、静态 IP 等网络细节调整。第三方摄像头请在 Surveillance Station 网页端添加。'),
          _primary('开始配网并添加', AppIcons.wifi, () {
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('摄像头已通过二维码配网添加')));
          }),
        ],
      );

  Widget _manual(BuildContext context) => ListView(
        key: const ValueKey<int>(2),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 26),
        children: <Widget>[
          const _Section('设备信息'),
          _group(<Widget>[
            _input('名称', '新摄像头 #10'),
            _input('IP / 域名', '192.168.1.130'),
            _input('端口', '80'),
            _dropdown('品牌', 'Synology', <String>['Synology', 'ONVIF', '其他']),
            _input('账号', 'admin'),
            _input('密码', '••••••', obscure: true),
            _toggle('启用 HTTPS', false),
          ]),
          _note('添加后可在「编辑摄像机」中调整流质量、预置位与录像模式。许可证剩余 2 路。'),
          _primary('添加', AppIcons.check, () {
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('摄像头已手动添加')));
          }),
        ],
      );

  Widget _scanBox() => Container(
        height: 150,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.blue.withOpacity(.5)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const AppIcon(AppIcons.qr, size: 38, color: AppColors.blue),
            const SizedBox(height: 8),
            Text('扫描摄像头机身或包装上的二维码',
                style: TextStyle(fontSize: 12, color: AppColors.sub)),
          ],
        ),
      );

  Widget _sectionRow(String title, String action, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 9),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(title.toUpperCase(),
                style: TextStyle(
                    fontSize: 10, letterSpacing: 1.3, color: AppColors.faint)),
            GestureDetector(
              onTap: onTap,
              child: Row(
                children: <Widget>[
                  const AppIcon(AppIcons.refresh,
                      size: 13, color: AppColors.blue),
                  const SizedBox(width: 3),
                  Text(action,
                      style:
                          const TextStyle(fontSize: 11, color: AppColors.blue)),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _badge(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
            color: AppColors.iconBgGreen,
            borderRadius: BorderRadius.circular(6)),
        child: Text(text,
            style: const TextStyle(fontSize: 9, color: AppColors.green)),
      );

  Widget _group(List<Widget> children) =>
      Card(child: Column(children: children));

  Widget _input(String label, String value, {bool obscure = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: <Widget>[
            SizedBox(
                width: 82,
                child: Text(label, style: const TextStyle(fontSize: 13))),
            Expanded(
              child: TextFormField(
                initialValue: value,
                obscureText: obscure,
                textAlign: TextAlign.right,
                decoration: const InputDecoration(
                    filled: false, border: InputBorder.none, isDense: true),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      );

  Widget _dropdown(String label, String value, List<String> items) => Padding(
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
                onChanged: (_) {},
                isExpanded: true,
                alignment: AlignmentDirectional.centerEnd,
                underline: const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      );

  Widget _toggle(String label, bool initial) => _ToggleRow(label, initial);

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Text(text,
            style:
                TextStyle(fontSize: 11, color: AppColors.faint, height: 1.5)),
      );

  Widget _primary(String label, IconData icon, VoidCallback onTap) =>
      FilledButton.icon(
        onPressed: onTap,
        icon: AppIcon(icon, size: 16, color: Colors.white),
        label: Text(label),
        style: FilledButton.styleFrom(
            backgroundColor: AppColors.blue,
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12))),
      );
}

class _ToggleRow extends StatefulWidget {
  const _ToggleRow(this.label, this.initial);
  final String label;
  final bool initial;
  @override
  State<_ToggleRow> createState() => _ToggleRowState();
}

class _ToggleRowState extends State<_ToggleRow> {
  late bool _value = widget.initial;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: <Widget>[
            SizedBox(
                width: 82,
                child:
                    Text(widget.label, style: const TextStyle(fontSize: 13))),
            const Spacer(),
            Switch(value: _value, onChanged: (v) => setState(() => _value = v)),
          ],
        ),
      );
}

class _FoundDevice {
  const _FoundDevice(this.model, this.sn, this.ip);
  final String model;
  final String sn;
  final String ip;
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
