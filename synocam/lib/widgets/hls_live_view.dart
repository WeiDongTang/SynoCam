// HLS 实时画面：优先群晖 VideoStream(format=hls)，由系统播放器硬件解码，
// 比 MJPEG 逐帧 JPEG 软解码明显流畅。
//
// 该 CGI 属群晖未公开接口，不同 SS 版本可用性不一，因此这里严格遵循
// 「探测成功才启用、任何失败自动回退」：Open 失败、初始化失败、播放异常
// 一律渲染调用方传入的 fallback（原有 MJPEG 组件），绝不黑屏、绝不留
// 一个坏掉的播放器占位。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../data/models/camera.dart';
import '../state/app_state.dart';

class HlsLiveView extends StatefulWidget {
  const HlsLiveView({
    super.key,
    required this.camera,
    required this.fallback,
    this.enabled = true,
  });

  final Camera camera;
  final Widget fallback;

  /// 关闭时直接渲染 fallback（用户可在画面上手动切回 MJPEG）。
  final bool enabled;

  @override
  State<HlsLiveView> createState() => _HlsLiveViewState();
}

class _HlsLiveViewState extends State<HlsLiveView> {
  VideoPlayerController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _setup();
    });
  }

  @override
  void didUpdateWidget(covariant HlsLiveView old) {
    super.didUpdateWidget(old);
    if (old.camera.id != widget.camera.id || old.enabled != widget.enabled) {
      _release();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _setup();
      });
    }
  }

  Future<void> _setup() async {
    if (!widget.enabled) return;
    final AppState state;
    try {
      state = context.read<AppState>();
    } catch (_) {
      return;
    }
    VideoPlayerController? c;
    try {
      final opened = await state.openHlsStream(widget.camera);
      if (!opened) return; // 静默回退 MJPEG
      final url = state.hlsStreamUrl(widget.camera);
      // 群晖二进制/流端点要求 Cookie: id=<sid>; did=<did>，
      // 否则 DSM 返回 HTTP 465。原生播放器不会自动带会话 Cookie。
      c = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: <String, String>{
          if (state.cookieHeader.isNotEmpty) 'Cookie': state.cookieHeader,
        },
      );
      await c.initialize();
      // 群晖视频流不含音轨；声音由独立 AudioStream 播放，避免重复。
      await c.setVolume(0.0);
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _ready = true;
      });
    } catch (_) {
      try {
        if (c != null) await c.dispose();
      } catch (_) {
        // 清理失败不影响回退。
      }
      // 保留 fallback，不覆盖画面。
    }
  }

  void _release() {
    _controller?.dispose();
    _controller = null;
    _ready = false;
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (!widget.enabled || !_ready || c == null || !c.value.isInitialized) {
      return widget.fallback;
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Center(
          child: AspectRatio(
            aspectRatio: c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9,
            child: VideoPlayer(c),
          ),
        ),
        const Positioned(
          right: 10,
          bottom: 34,
          child: IgnorePointer(
            child: Text('HLS 流畅模式',
                style: TextStyle(fontSize: 9, color: Colors.white54)),
          ),
        ),
      ],
    );
  }
}
