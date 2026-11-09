// 实时多画面：1 / 1×2 / 2×2 / 3×3 布局切换 + 点击进入单画面。
// 对齐定稿 A 原型的布局段控件与画面 OSD（LIVE / 画质 / 名称 / 时间）。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../data/models/camera.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';
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
                  '${state.cameras.length} 路摄像机 · '
                  '${state.cameras.where((c) => c.isOnline).length} 在线',
                  style: TextStyle(fontSize: 12, color: AppColors.sub),
                ),
              ],
            ),
            IconButton(
              onPressed: () => state.refreshCameras(),
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
    if (state.cameraState == LoadState.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.cameraState == LoadState.error) {
      return _errorView(context, state);
    }
    final cams = state.cameras.take(state.gridCount).toList();
    if (cams.isEmpty) {
      return Center(
        child: Text('暂无摄像机，请先在「摄像机」中添加',
            style: TextStyle(color: AppColors.faint, fontSize: 13)),
      );
    }
    final cols = state.gridCount == 1
        ? 1
        : state.gridCount == 2
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
        thumbnailUrl: state.snapshotUrl(cams[i]),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => SingleViewPage(camera: cams[i]),
        )),
      ),
    );
  }

  Widget _errorView(BuildContext context, AppState state) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const AppIcon(AppIcons.alert, size: 32, color: AppColors.red),
            const SizedBox(height: 10),
            Text(state.error ?? '加载失败',
                style: TextStyle(color: AppColors.sub, fontSize: 13)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => state.refreshCameras(),
              icon: const AppIcon(AppIcons.refresh,
                  size: 16, color: Colors.white),
              label: const Text('重试'),
            ),
          ],
        ),
      );
}

class LiveTile extends StatelessWidget {
  const LiveTile({
    super.key,
    required this.camera,
    required this.thumbnailUrl,
    required this.onTap,
  });

  final Camera camera;
  final String thumbnailUrl;
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
            // 快照轮询等价于预览帧；生产环境替换为 RTSP/原生播放器。
            Image.network(
              thumbnailUrl,
              fit: BoxFit.cover,
              color: camera.isOnline ? null : Colors.grey,
              colorBlendMode: camera.isOnline ? null : BlendMode.saturation,
              errorBuilder: (_, __, ___) => Container(
                color: const Color(0xFF22262F),
                alignment: Alignment.center,
                child: const AppIcon(AppIcons.cameras,
                    size: 28, color: Colors.white38),
              ),
            ),
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
              Positioned(
                top: 9,
                left: 10,
                child: _liveBadge(),
              ),
            Positioned(
              top: 9,
              right: 10,
              child: _chip(camera.quality),
            ),
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

// 供测试/预览复用的布局常量。
List<int> get supportedLayouts => AppConfig.gridLayouts;
