// 设置：只展示真实生效的开关与 NAS 真实信息。
// 需要原生能力（生物识别 / AirPlay / 硬件解码播放器）的项目明确标注「当前版本不可用」
// 并禁用，避免用户误以为已开启；原型的假地图、假额度、假账号均已移除。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../core/utils/launcher.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.session;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 26),
          children: <Widget>[
            const _Header('设置', '连接 · 播放 · 诊断'),
            const _Section('当前连接（真实会话）'),
            _group(<Widget>[
              _infoRow(AppIcons.server, 'NAS 地址',
                  s == null ? '未登录' : '${s.host}:${s.port}'),
              _infoRow(AppIcons.faceId, '账号', s?.account ?? '—'),
              _infoRow(AppIcons.shield, '传输',
                  s == null ? '—' : (s.https ? 'HTTPS' : 'HTTP')),
              _infoRow(
                  AppIcons.cameras,
                  '设备数',
                  state.cameraState == LoadState.ready
                      ? '${state.cameras.length} 路'
                      : '未读取'),
              _infoRow(AppIcons.license, '许可证', _license(state)),
            ]),
            const _Section('连接与画面（真实生效）'),
            _group(<Widget>[
              SwitchListTile(
                secondary: const BadgeIcon(AppIcons.shield),
                title: const Text('信任自签名 HTTPS 证书',
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                subtitle: Text(
                    '群晖自签证书默认会导致画面与接口全部失败；开启后放宽证书校验（仅限自有 NAS）',
                    style: TextStyle(fontSize: 11, color: AppColors.sub)),
                value: state.prefs.allowUntrustedCert,
                onChanged: (v) => state.setAllowUntrustedCert(v),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const BadgeIcon(AppIcons.timeline),
                title: const Text('画面刷新间隔',
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                subtitle: Text('当前 ${state.prefs.pollSeconds} 秒 / 帧',
                    style: TextStyle(fontSize: 11, color: AppColors.sub)),
                trailing: DropdownButton<int>(
                  value: state.prefs.pollSeconds,
                  items: <int>[1, 2, 3, 5, 10]
                      .map((v) => DropdownMenuItem<int>(
                          value: v, child: Text('$v s')))
                      .toList(),
                  onChanged: (v) => state.setPollSeconds(v ?? 2),
                  underline: const SizedBox.shrink(),
                ),
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const BadgeIcon(AppIcons.live),
                title: const Text('优先 MJPEG 连续流',
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                subtitle: Text(
                    'NAS 返回流凭证时使用连续画面；不可用或 6 秒无帧自动降级为快照轮询',
                    style: TextStyle(fontSize: 11, color: AppColors.sub)),
                value: state.prefs.streamMode,
                onChanged: (v) => state.setStreamMode(v),
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const BadgeIcon(AppIcons.moon,
                    tone: IconTone.amber),
                title: const Text('免打扰',
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                subtitle: Text('本机事件提醒静音（真实持久化）',
                    style: TextStyle(fontSize: 11, color: AppColors.sub)),
                value: state.prefs.dnd,
                onChanged: (v) => state.setDnd(v),
              ),
            ]),
            const _Section('首页模式（NAS 真实状态）'),
            _homeMode(state),
            const _Section('当前版本未提供的能力'),
            _group(<Widget>[
              _disabledRow(AppIcons.lock, '密码锁 / Face ID',
                  '需接入本机生物识别与安全存储'),
              _disabledRow(AppIcons.airplay, 'AirPlay 镜像',
                  '需原生投屏能力'),
              _disabledRow(AppIcons.pip, '悬浮播放器', '依赖系统画中画能力'),
              _disabledRow(AppIcons.bolt, 'RTSP / H.265 原生播放器',
                  '当前为 MJPEG 连续流与快照轮询；RTSP 解码需原生插件'),
            ]),
            const _Section('管理与诊断'),
            _group(<Widget>[
              _linkRow(AppIcons.refresh, '重新读取 NAS 全部数据',
                  'Camera/List · Event/Query · License',
                  () => state.refreshAll()),
              _linkRow(AppIcons.server, '打开 Surveillance Station 网页端',
                  '添加设备、录像计划、推送通知等高级配置',
                  () => openExternalUrl(context, state.webUiUrl(),
                      label: 'SS 网页端')),
              _linkRow(AppIcons.bolt, '画面链路诊断',
                  '实测 GetSnapshot / Cookie / 流凭证，显示 NAS 真实响应',
                  () => _showMediaDiagnostic(context, state)),
              _linkRow(AppIcons.info, 'API 能力诊断',
                  'SYNO.API.Info 返回 ${state.apiInfo.length} 个接口',
                  () => _showApiInfo(context, state)),
            ]),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () => state.logout(),
              icon: const AppIcon(AppIcons.power, size: 16, color: AppColors.red),
              label: const Text('退出登录',
                  style: TextStyle(color: AppColors.red)),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  side: const BorderSide(color: AppColors.line)),
            ),
            const SizedBox(height: 10),
            Text('提示：若画面/录像为空，请先看对应页面的 DSM 错误码，再到「API 能力诊断」确认 NAS 实际支持的接口。',
                style: TextStyle(fontSize: 10.5, color: AppColors.faint)),
          ],
        ),
      ),
    );
  }

  String _license(AppState state) {
    final l = state.license;
    if (l == null) return '未从 API 读取到';
    for (final k in <String>['maxCam', 'maxCamera', 'max', 'total']) {
      if (l[k] != null) return '${l[k]} 路上限';
    }
    return '已读取（${l.length} 个字段）';
  }

  Widget _homeMode(AppState state) => Card(
        child: state.homeModeSupported
            ? SwitchListTile(
                secondary: const BadgeIcon(AppIcons.location),
                title: const Text('Home Mode',
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                subtitle: Text(
                    state.homeMode ? '已开启（NAS 真实状态）' : '已关闭（NAS 真实状态）',
                    style: TextStyle(fontSize: 11, color: AppColors.sub)),
                value: state.homeMode,
                onChanged: (v) async {
                  try {
                    await state.setHomeMode(v);
                  } catch (e) {
                    // 失败时状态保持原值，下次刷新会重新对齐 NAS。
                    await state.refreshNasInfo();
                  }
                },
              )
            : ListTile(
                leading: const BadgeIcon(AppIcons.location),
                title: const Text('Home Mode',
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                subtitle: Text('该 NAS 未返回 HomeMode/GetInfo 能力，无法在 App 内切换',
                    style: TextStyle(fontSize: 11, color: AppColors.sub)),
              ),
      );

  Future<void> _showMediaDiagnostic(
      BuildContext context, AppState state) async {
    String msg;
    if (!state.isLoggedIn) {
      msg = '尚未登录，请先连接 NAS。';
    } else if (state.cameras.isEmpty) {
      msg = '尚未读取到摄像机，请先点「重新读取 NAS 全部数据」。';
    } else {
      msg = await state.testSnapshot(state.cameras.first);
    }
    if (!context.mounted) return;
    final cam = state.cameras.isEmpty ? null : state.cameras.first;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('画面链路诊断'),
        content: SingleChildScrollView(
          child: Text(
            '$msg\n\n'
            '会话 Cookie：${state.cookieHeader.isEmpty ? '未注入' : '已注入'}\n'
            '流凭证：${cam == null ? '未读取' : (cam.canStream ? '已获取' : '未返回')}\n'
            'NAS API 能力：${state.apiInfo.length} 个接口',
            style: const TextStyle(fontSize: 11.5),
          ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  void _showApiInfo(BuildContext context, AppState state) {
    final entries = state.apiInfo.entries.toList();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('NAS API 能力诊断'),
        content: SizedBox(
          width: double.maxFinite,
          child: entries.isEmpty
              ? const Text('未能读取 SYNO.API.Info。请检查网络、端口与 HTTPS 设置。')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    return ListTile(
                      dense: true,
                      title: Text(e.key,
                          style: const TextStyle(fontSize: 11)),
                      subtitle: Text('path: ${e.value.cgi}',
                          style: const TextStyle(fontSize: 9)),
                      trailing: Text('v${e.value.effectiveVersion()}',
                          style: const TextStyle(fontSize: 11)),
                    );
                  },
                ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  Widget _group(List<Widget> children) =>
      Card(child: Column(children: children));

  Widget _infoRow(IconData icon, String label, String value) => ListTile(
        leading: BadgeIcon(icon),
        title: Text(label,
            style:
                const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        trailing: Text(value,
            style: TextStyle(fontSize: 11.5, color: AppColors.sub)),
        dense: true,
      );

  Widget _disabledRow(IconData icon, String title, String reason) => Opacity(
        opacity: .55,
        child: ListTile(
          leading: BadgeIcon(icon, tone: IconTone.neutral),
          title: Text(title,
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w600)),
          subtitle: Text('当前版本不可用 · $reason',
              style: TextStyle(fontSize: 11, color: AppColors.sub)),
          enabled: false,
        ),
      );

  Widget _linkRow(IconData icon, String title, String subtitle,
          VoidCallback onTap) =>
      ListTile(
        leading: BadgeIcon(icon),
        title: Text(title,
            style:
                const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle,
            style: TextStyle(fontSize: 11, color: AppColors.sub)),
        trailing: const AppIcon(AppIcons.chevron, size: 16),
        onTap: onTap,
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
                style: const TextStyle(
                    fontSize: 29, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(subtitle,
                style: TextStyle(fontSize: 12, color: AppColors.sub)),
          ],
        ),
      );
}
