// 摄像机管理：列表/缩略图切换、搜索、在线筛选、启停、编辑与添加入口。
// 对齐定稿 A 原型 v-cam。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../data/models/camera.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';
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
                '仅 Synology 品牌摄像头可在 App 内添加；第三方 IP 摄像头请先在 Surveillance Station 网页端配置后同步。',
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
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('摄像机',
                    style:
                        TextStyle(fontSize: 29, fontWeight: FontWeight.w700)),
                SizedBox(height: 3),
                Text('管理 · 添加 · 编辑设备',
                    style: TextStyle(fontSize: 12, color: AppColors.sub)),
              ],
            ),
            _circleBtn(
              icon: AppIcons.add,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const CameraAddPage()),
              ),
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
                  hintText: '搜索名称 / IP / 状态',
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
    final list = state.filteredCameras;
    if (list.isEmpty) {
      return Center(
        child: Text('没有匹配的摄像机',
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
              Expanded(
                child: Image.network(
                  state.snapshotUrl(c),
                  fit: BoxFit.cover,
                  color: c.isOnline ? null : Colors.grey,
                  colorBlendMode: c.isOnline ? null : BlendMode.saturation,
                  errorBuilder: (_, __, ___) => Container(
                    color: const Color(0xFF22262F),
                    child: const AppIcon(AppIcons.cameras,
                        size: 28, color: Colors.white24),
                  ),
                ),
              ),
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
                    Text('${c.quality} · ${c.isOnline ? '在线' : '停用'}',
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
                  child: Image.network(state.snapshotUrl(c),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          Container(color: const Color(0xFF22262F))),
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
                  const SizedBox(width: 6),
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
