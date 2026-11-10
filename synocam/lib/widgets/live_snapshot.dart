// 实时预览组件：真实轮询 SS GetSnapshot。
//
// 为什么不是 MJPEG/RTSP：Flutter 的 Image.network 不支持 multipart/x-mixed-replace
// （MJPEG 流），RTSP 又需要原生播放器插件。SS 官方 Web API 提供 GetSnapshot，
// 以 1–2 秒间隔轮询 JPEG 是纯 Dart 即可落地的「准实时」方案，
// 与 DS Cam 低带宽模式一致；同时保留直播流 URL 供系统播放器打开。
//
// 每次刷新用 _t 时间戳绕过 CDN/浏览器缓存；失败时显示真实错误并允许重试。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_icons.dart';
import '../data/models/camera.dart';
import '../state/app_state.dart';
import '../widgets/app_icon.dart';

class LiveSnapshot extends StatefulWidget {
  const LiveSnapshot({
    super.key,
    required this.camera,
    this.fit = BoxFit.cover,
    this.paused = false,
  });

  final Camera camera;
  final BoxFit fit;
  final bool paused;

  @override
  State<LiveSnapshot> createState() => _LiveSnapshotState();
}

class _LiveSnapshotState extends State<LiveSnapshot> {
  Timer? _timer;
  int _nonce = 0;
  bool _firstLoaded = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant LiveSnapshot old) {
    super.didUpdateWidget(old);
    if (old.camera.id != widget.camera.id || old.paused != widget.paused) {
      _start();
    }
  }

  void _start() {
    _timer?.cancel();
    if (widget.paused) return;
    final seconds = context.read<AppState>().prefs.pollSeconds;
    _timer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (!mounted) return;
      setState(() => _nonce++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.isLoggedIn) {
      return _placeholder('未登录');
    }
    if (!widget.camera.isOnline) {
      return _placeholder('摄像机已停用');
    }
    final url = state.snapshotUrl(widget.camera, nonce: _nonce);
    return Image.network(
      url,
      fit: widget.fit,
      gaplessPlayback: true,
      cacheWidth: 640,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (frame != null) _firstLoaded = true;
        if (wasSynchronouslyLoaded || frame != null) return child;
        return _firstLoaded
            ? child
            : const Center(
                child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              );
      },
      errorBuilder: (context, error, stackTrace) {
        return _ErrorTile(
          message: '画面加载失败',
          detail: '$error',
          onRetry: () => setState(() => _nonce++),
        );
      },
    );
  }

  Widget _placeholder(String text) => Container(
        color: const Color(0xFF22262F),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const AppIcon(AppIcons.cameras, size: 28, color: Colors.white38),
            const SizedBox(height: 6),
            Text(text,
                style: const TextStyle(fontSize: 10, color: Colors.white54)),
          ],
        ),
      );
}

class _ErrorTile extends StatelessWidget {
  const _ErrorTile(
      {required this.message, required this.detail, required this.onRetry});

  final String message;
  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xFF22262F),
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const AppIcon(AppIcons.alert, size: 20, color: AppColors.red),
            const SizedBox(height: 4),
            Text(message,
                style: const TextStyle(fontSize: 10, color: Colors.white70)),
            const SizedBox(height: 2),
            Text(
              detail.length > 90 ? '${detail.substring(0, 90)}…' : detail,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: const TextStyle(fontSize: 8, color: Colors.white38),
            ),
            const SizedBox(height: 5),
            GestureDetector(
              onTap: onRetry,
              child: const Text('重试',
                  style: TextStyle(fontSize: 10, color: AppColors.blue)),
            ),
          ],
        ),
      );
}
