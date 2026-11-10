// 添加摄像头：Surveillance Station Web API 不提供「局域网发现 / 二维码配网 /
// 物理添加摄像头」的公开接口（这些是 DS Cam 通过 SS 内部私有通道完成的）。
// 因此本页不再伪造设备列表与成功提示，而是给出真实可执行的路径：
// 打开 SS 网页端添加 → 回到 App 同步真实列表。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../core/utils/launcher.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';

class CameraAddPage extends StatelessWidget {
  const CameraAddPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final used = state.cameras.length;
    final max = _licenseMax(state.license);
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
              child: Text(
                max == null ? '$used 路已用' : '$used / $max 路',
                style: TextStyle(fontSize: 12, color: AppColors.faint),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 26),
        children: <Widget>[
          _hero(),
          const SizedBox(height: 18),
          const _Section('为什么 App 内不能直接添加'),
          _note('添加摄像头需要在 NAS 上完成设备搜索、品牌/协议匹配、许可证占用与录像参数初始化。'
              'Synology 公开的 Surveillance Station Web API 只提供对「已添加设备」的查询与控制，'
              '不提供物理添加接口；局域网发现与二维码配网属于 SS 内部私有协议。'
              '此前版本里的设备列表与「添加成功」提示均为界面演示，现已移除。'),
          const SizedBox(height: 10),
          const _Section('真实可执行的操作'),
          _actionCard(
            context,
            icon: AppIcons.server,
            title: '在 Surveillance Station 网页端添加',
            subtitle: 'IP 摄像头 → 新增 → 按向导完成配置',
            onTap: () => openExternalUrl(context, state.webUiUrl(),
                label: 'Surveillance Station 网页端'),
          ),
          _actionCard(
            context,
            icon: AppIcons.refresh,
            title: '同步 NAS 上的最新设备列表',
            subtitle: '调用 Camera/List 重新读取真实设备',
            onTap: () async {
              await state.refreshCameras();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(state.cameraState == LoadState.ready
                        ? '已同步，NAS 返回 ${state.cameras.length} 路设备'
                        : '同步失败：${state.cameraError ?? '未知错误'}')));
              }
            },
          ),
          const SizedBox(height: 14),
          _licenseHint(used, max),
        ],
      ),
    );
  }

  Widget _hero() => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.blueSoft,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: <Widget>[
            const AppIcon(AppIcons.cameras, size: 40, color: AppColors.blue),
            const SizedBox(height: 12),
            const Text('摄像头由 NAS 统一管理',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              '在网页端完成后，App 会自动读取并展示真实设备、真实画面与真实录像。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.sub),
            ),
          ],
        ),
      );

  Widget _actionCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) =>
      Card(
        margin: const EdgeInsets.only(bottom: 9),
        child: ListTile(
          leading: BadgeIcon(icon),
          title: Text(title,
              style:
                  const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          subtitle: Text(subtitle,
              style: TextStyle(fontSize: 11, color: AppColors.sub)),
          trailing: const AppIcon(AppIcons.chevron, size: 16),
          onTap: onTap,
        ),
      );

  Widget _licenseHint(int used, int? max) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: <Widget>[
            const AppIcon(AppIcons.license, size: 20, color: AppColors.blue),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                max == null
                    ? '当前 NAS 返回 $used 路设备；许可证额度未从 API 读取到，可在 SS 网页端查看。'
                    : '许可证：$used / $max 路已用${used >= max ? '，额度已满，需先移除设备或增购许可证' : ''}。',
                style: TextStyle(fontSize: 11.5, color: AppColors.sub),
              ),
            ),
          ],
        ),
      );

  int? _licenseMax(Map<String, dynamic>? license) {
    if (license == null) return null;
    for (final k in <String>[
      'maxCam',
      'maxCamera',
      'max',
      'total',
      'licenseNum'
    ]) {
      final v = license[k];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
    }
    return null;
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 9),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.3,
                color: AppColors.faint,
                fontWeight: FontWeight.w600)),
      );
}

// 复用包内说明组件样式。
Widget _note(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: Text(text,
          style: TextStyle(fontSize: 11.5, color: AppColors.sub, height: 1.6)),
    );
