// 实时多画面：1 / 1×2 / 2×2 / 3×3 布局切换 + 点击进入单画面。
// 画面来自真实 SS GetSnapshot 轮询，摄像机数量/在线状态来自真实 Camera/List。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/network/syno_api.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../data/models/camera.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/live_snapshot.dart';
import 'single_view_page.dart';

class LivePage extends StatelessWidget {
  const LivePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _header(context, state),
            _layoutSeg(state),
            Expanded(child: _grid(context, state)),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, AppState state) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('实时画面',
                    style:
                        TextStyle(fontSize: 29, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                  state.cameraState == LoadState.ready
                      ? '${state.cameras.length} 路摄像机 · '
                          '${state.cameras.where((c) => c.isOnline).length} 在线'
                      : state.cameraState == LoadState.loading
                          ? '正在读取 NAS 摄像机列表…'
                          : '尚未获取摄像机列表',
                  style: TextStyle(fontSize: 12, color: AppColors.sub),
                ),
              ],
            ),
            IconButton(
              onPressed: () => state.refreshAll(),
              icon: const AppIcon(AppIcons.refresh, size: 20),
            ),
          ],
        ),
      );

  Widget _layoutSeg(AppState state) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: SegmentedButton<int>(
          segments: const <ButtonSegment<int>>[
            ButtonSegment<int>(value: 1, label: Text('单画面')),
            ButtonSegment<int>(value: 2, label: Text('1×2')),
            ButtonSegment<int>(value: 4, label: Text('2×2')),
            ButtonSegment<int>(value: 9, label: Text('3×3')),
          ],
          selected: <int>{state.gridCount},
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
          ),
          onSelectionChanged: (Set<int> s) => state.setGridCount(s.first),
        ),
      );

  Widget _grid(BuildContext context, AppState state) {
    if (state.cameraState == LoadState.loading ||
        state.cameraState == LoadState.idle) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.cameraState == LoadState.error) {
      return _errorView(context, state);
    }
    final cams = state.cameras.take(state.gridCount).toList();
    if (cams.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const AppIcon(AppIcons.cameras, size: 34, color: AppColors.faint),
              const SizedBox(height: 12),
              Text('NAS 未返回任何摄像机',
                  style: TextStyle(color: AppColors.sub, fontSize: 13)),
              const SizedBox(height: 6),
              Text(
                '请确认账号具备 Surveillance Station 权限、摄像机已在 SS 中启用且许可证有效。',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.faint, fontSize: 11),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => state.refreshCameras(),
                icon: const AppIcon(AppIcons.refresh,
                    size: 16, color: Colors.white),
                label: const Text('重新读取'),
              ),
            ],
          ),
        ),
      );
    }
    final cols = state.gridCount == 1 || state.gridCount == 2
        ? 1
        : state.gridCount == 4
            ? 2
            : 3;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: state.gridCount == 9 ? 4 / 3 : 16 / 10,
      ),
      itemCount: cams.length,
      itemBuilder: (context, i) => LiveTile(
        camera: cams[i],
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => SingleViewPage(camera: cams[i]),
        )),
      ),
    );
  }

  Widget _errorView(BuildContext context, AppState state) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const AppIcon(AppIcons.alert, size: 32, color: AppColors.red),
              const SizedBox(height: 10),
              Text(state.cameraError ?? '加载失败',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.sub, fontSize: 13)),
              const SizedBox(height: 6),
              Text(classifyFailure(state.cameraError).advice,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.faint, fontSize: 11)),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: classifyFailure(state.cameraError).needsReLogin
                    ? () => state.reportSessionExpired()
                    : () => state.refreshCameras(),
                icon: const AppIcon(AppIcons.refresh,
                    size: 16, color: Colors.white),
                label: Text(classifyFailure(state.cameraError).needsReLogin
                    ? '重新登录'
                    : '重试'),
              ),
            ],
          ),
        ),
      );
}

class LiveTile extends StatelessWidget {
  const LiveTile({
    super.key,
    required this.camera,
    required this.onTap,
  });

  final Camera camera;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            LiveSnapshot(camera: camera),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Color(0x55000000),
                    Colors.transparent,
                    Colors.transparent,
                    Color(0x99000000),
                  ],
                  stops: <double>[0, .26, .58, 1],
                ),
              ),
            ),
            if (camera.isOnline)
              Positioned(top: 9, left: 10, child: _liveBadge()),
            if (camera.quality.isNotEmpty)
              Positioned(top: 9, right: 10, child: _chip(camera.quality)),
            Positioned(
              left: 11,
              right: 11,
              bottom: 9,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Expanded(
                    child: Text(camera.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                  ),
                  Text(
                    '${TimeOfDay.now().hour.toString().padLeft(2, '0')}:'
                    '${TimeOfDay.now().minute.toString().padLeft(2, '0')}',
                    style:
                        const TextStyle(fontSize: 8.5, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _liveBadge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
            color: Colors.black38, borderRadius: BorderRadius.circular(5)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                    color: AppColors.red, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            const Text('LIVE',
                style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
          ],
        ),
      );

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
            color: Colors.black38, borderRadius: BorderRadius.circular(5)),
        child: Text(text,
            style: const TextStyle(fontSize: 8.5, color: Colors.white)),
      );
}

List<int> get supportedLayouts => AppConfig.gridLayouts;
