// 摄像机管理：真实 Camera/List 数据 + 真实启停 + 真实快照预览。
// 搜索/筛选为本地真实过滤；添加入口引导到 SS 网页端（Web API 不支持物理添加）。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/network/syno_api.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../data/models/camera.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/live_snapshot.dart';
import 'camera_add_page.dart';
import 'camera_edit_page.dart';
import '../live/single_view_page.dart';

class CamerasPage extends StatelessWidget {
  const CamerasPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _header(context, state),
            _toolRow(context, state),
            _filters(state),
            Expanded(child: _body(context, state)),
            _addButton(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: Text(
                '摄像机的物理添加/删除需在 Surveillance Station 网页端完成；App 内可改名、启停、调整流质量并实时预览。',
                style: TextStyle(fontSize: 10.5, color: AppColors.faint),
              ),
            ),
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
                const Text('摄像机',
                    style:
                        TextStyle(fontSize: 29, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                    state.cameraState == LoadState.ready
                        ? 'NAS 返回 ${state.cameras.length} 路设备'
                        : '正在读取 NAS 设备列表',
                    style: TextStyle(fontSize: 12, color: AppColors.sub)),
              ],
            ),
            Row(
              children: <Widget>[
                _circleBtn(
                  icon: AppIcons.refresh,
                  onTap: () => state.refreshAll(),
                ),
                const SizedBox(width: 8),
                _circleBtn(
                  icon: AppIcons.add,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const CameraAddPage()),
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _toolRow(BuildContext context, AppState state) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                onChanged: state.setCameraQuery,
                decoration: const InputDecoration(
                  hintText: '搜索名称 / IP / 型号',
                  prefixIcon: AppIcon(AppIcons.search, size: 18),
                  prefixIconConstraints:
                      BoxConstraints(minWidth: 40, minHeight: 40),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _circleBtn(
              icon: state.cameraGridView ? AppIcons.list : AppIcons.tiles,
              onTap: state.toggleCameraView,
            ),
          ],
        ),
      );

  Widget _filters(AppState state) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: <Widget>[
            _filterChip('全部', 'all', state),
            _filterChip('在线', 'on', state),
            _filterChip('离线 / 停用', 'off', state),
          ],
        ),
      );

  Widget _filterChip(String label, String value, AppState state) {
    final selected = state.cameraFilter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => state.setCameraFilter(value),
        showCheckmark: false,
        selectedColor: AppColors.ink,
        backgroundColor: AppColors.card,
        labelStyle: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.sub),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: BorderSide(color: selected ? AppColors.ink : AppColors.line),
      ),
    );
  }

  Widget _body(BuildContext context, AppState state) {
    if (state.cameraState == LoadState.loading ||
        state.cameraState == LoadState.idle) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.cameraState == LoadState.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const AppIcon(AppIcons.alert, size: 30, color: AppColors.red),
              const SizedBox(height: 10),
              Text(state.cameraError ?? '读取失败',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.sub, fontSize: 12.5)),
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
                      : '重试')),
            ],
          ),
        ),
      );
    }
    final list = state.filteredCameras;
    if (list.isEmpty) {
      return Center(
        child: Text(state.cameras.isEmpty ? 'NAS 未返回任何摄像机' : '没有匹配的摄像机',
            style: TextStyle(color: AppColors.faint, fontSize: 13)),
      );
    }
    return RefreshIndicator(
      onRefresh: state.refreshCameras,
      child: state.cameraGridView
          ? _gridView(context, state, list)
          : _listView(context, state, list),
    );
  }

  Widget _gridView(BuildContext context, AppState state, List<Camera> list) =>
      GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: .92,
        ),
        itemCount: list.length,
        itemBuilder: (context, i) => _cameraCard(context, state, list[i]),
      );

  Widget _cameraCard(BuildContext context, AppState state, Camera c) =>
      GestureDetector(
        onTap: () => _openSingle(context, c),
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: LiveSnapshot(camera: c)),
              Padding(
                padding: const EdgeInsets.fromLTRB(11, 9, 11, 11),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(
                        '${c.quality.isEmpty ? (c.model.isEmpty ? '摄像机' : c.model) : c.quality} · ${c.isOnline ? '在线' : '停用'}',
                        style: TextStyle(fontSize: 9, color: AppColors.faint)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _listView(BuildContext context, AppState state, List<Camera> list) =>
      ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        itemCount: list.length,
        itemBuilder: (context, i) {
          final c = list[i];
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              onTap: () => _openSingle(context, c),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: SizedBox(
                  width: 70,
                  height: 48,
                  child: LiveSnapshot(camera: c),
                ),
              ),
              title: Text(c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
              subtitle: Text(
                  '${c.model.isEmpty ? '—' : c.model} · ${c.ip.isEmpty ? '—' : c.ip}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9.5, color: AppColors.faint)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _statusBadge(c.isOnline),
                  Switch(
                    value: c.enabled,
                    onChanged: (v) async {
                      try {
                        await state.toggleCamera(c, v);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(v ? '已在 NAS 启用' : '已在 NAS 停用')));
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text('启停失败：$e')));
                        }
                      }
                    },
                  ),
                  IconButton(
                    icon: const AppIcon(AppIcons.edit,
                        size: 16, color: AppColors.blue),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => CameraEditPage(camera: c)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );

  Widget _statusBadge(bool online) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: online ? AppColors.iconBgGreen : AppColors.iconBgNeutral,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(online ? '在线' : '停用',
            style: TextStyle(
                fontSize: 9, color: online ? AppColors.green : AppColors.sub)),
      );

  void _openSingle(BuildContext context, Camera c) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SingleViewPage(camera: c),
      ));

  Widget _addButton(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const CameraAddPage()),
          ),
          icon: const AppIcon(AppIcons.add, size: 16, color: AppColors.blue),
          label: const Text('添加摄像头'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.blue,
            minimumSize: const Size.fromHeight(46),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            side: const BorderSide(color: AppColors.line),
          ),
        ),
      );

  Widget _circleBtn({required IconData icon, required VoidCallback onTap}) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.line),
          ),
          child: AppIcon(icon, size: 20, color: AppColors.blue),
        ),
      );
}
