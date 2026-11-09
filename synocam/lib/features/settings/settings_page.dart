// 设置：首页模式地图、安全(密码锁/FaceID/AirPlay)、播放与解码、设备管理、登出。
// 对齐定稿 A 原型 v-set。所有图标走 BadgeIcon 统一系统。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _passcode = true;
  bool _biometric = true;
  bool _airplay = false;
  bool _hwDecode = true;
  bool _pip = true;
  bool _smartTimeline = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 26),
          children: <Widget>[
            const _Header('设置', '账户 · 安全 · 播放 · 管理'),
            const _Section('首页模式 · 按位置自动布防'),
            _map(),
            const _Section('安全'),
            _group(<Widget>[
              _toggleRow(AppIcons.lock, IconTone.blue, '密码锁', '4 位 · 超时重验',
                  _passcode, (v) => setState(() => _passcode = v)),
              _toggleRow(AppIcons.faceId, IconTone.blue, 'Face ID / 指纹',
                  '生物识别解锁', _biometric, (v) => setState(() => _biometric = v)),
              _toggleRow(AppIcons.airplay, IconTone.blue, 'AirPlay 镜像',
                  '整屏 / 仅视频', _airplay, (v) => setState(() => _airplay = v)),
            ]),
            const _Section('播放与解码'),
            _group(<Widget>[
              _toggleRow(AppIcons.bolt, IconTone.blue, '硬件解码', 'H.264 / H.265',
                  _hwDecode, (v) => setState(() => _hwDecode = v)),
              _toggleRow(AppIcons.pip, IconTone.blue, '悬浮播放器', '离开页面持续播放', _pip,
                  (v) => setState(() => _pip = v)),
              _toggleRow(
                  AppIcons.timeline,
                  IconTone.blue,
                  'Smart Timeline',
                  '按滚动速度缩放',
                  _smartTimeline,
                  (v) => setState(() => _smartTimeline = v)),
            ]),
            const _Section('设备与管理'),
            _group(<Widget>[
              _linkRow(
                  AppIcons.cameras, IconTone.blue, '摄像机管理', '添加 / 编辑 / 启停设备'),
              _linkRow(
                  AppIcons.license, IconTone.blue, '许可证', '8 / 10 路已用 · 离线管理'),
              _linkRow(
                  AppIcons.moon, IconTone.blue, '推送与免打扰', 'Do Not Disturb'),
              _linkRow(AppIcons.shield, IconTone.blue, '受信连接', '3 个已信任'),
              _linkRow(AppIcons.server, IconTone.blue, '账户与服务器',
                  'admin · NAS-01 · SS 9.2'),
            ]),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () => context.read<AppState>().logout(),
              icon:
                  const AppIcon(AppIcons.power, size: 16, color: AppColors.red),
              label: const Text('退出登录', style: TextStyle(color: AppColors.red)),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  side: const BorderSide(color: AppColors.line)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _map() => Container(
        height: 168,
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: const LinearGradient(
              colors: <Color>[Color(0xFFDDE6E0), Color(0xFFCBD8CE)]),
        ),
        child: Stack(
          children: <Widget>[
            Center(
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.blue.withOpacity(.08),
                  border: Border.all(
                      color: AppColors.blue.withOpacity(.5),
                      style: BorderStyle.solid),
                ),
              ),
            ),
            Center(
              child: Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                    color: AppColors.blue, shape: BoxShape.circle),
              ),
            ),
            Positioned(
              left: 13,
              bottom: 11,
              child: Text.rich(TextSpan(
                style: const TextStyle(fontSize: 10, color: Color(0xFF2C3A33)),
                children: <TextSpan>[
                  const TextSpan(text: '家 · 半径 '),
                  TextSpan(
                      text: '200m',
                      style: TextStyle(
                          color: AppColors.blue, fontWeight: FontWeight.w700)),
                  const TextSpan(text: ' · 延迟 '),
                  TextSpan(
                      text: '1min',
                      style: TextStyle(
                          color: AppColors.blue, fontWeight: FontWeight.w700)),
                ],
              )),
            ),
          ],
        ),
      );

  Widget _group(List<Widget> children) =>
      Card(child: Column(children: children));

  Widget _toggleRow(IconData icon, IconTone tone, String title, String subtitle,
          bool value, ValueChanged<bool> onChanged) =>
      ListTile(
        leading: BadgeIcon(icon, tone: tone),
        title: Text(title,
            style:
                const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle,
            style: TextStyle(fontSize: 11, color: AppColors.sub)),
        trailing: Switch(value: value, onChanged: onChanged),
      );

  Widget _linkRow(
          IconData icon, IconTone tone, String title, String subtitle) =>
      ListTile(
        leading: BadgeIcon(icon, tone: tone),
        title: Text(title,
            style:
                const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle,
            style: TextStyle(fontSize: 11, color: AppColors.sub)),
        trailing: const AppIcon(AppIcons.chevron, size: 16),
        onTap: () {},
      );
}

class _Section extends StatelessWidget {
  const _Section(this.text);
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

class _Header extends StatelessWidget {
  const _Header(this.title, this.subtitle);
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
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
