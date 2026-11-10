// 实时预览组件：真实画面，两条链路自动切换。
//
// 为什么不再用 Image.network：
//   SS 的二进制/流端点（GetSnapshot、VideoStreaming/Stream）要求
//   Cookie: id=<sid>; did=<did>，而 Image.network 走独立 HttpClient、
//   不带会话 Cookie，DSM 会返回 HTTP 465 + {"error":{"code":400}}。
//   现在统一走 SynoClient 的 Dio 链路（带 Cookie、证书策略、可读诊断）。
//
// 模式：
//   1) MJPEG 连续流（NAS 返回 StmKey 时）——真正的连续画面；
//      出错或 6 秒无帧自动降级；
//   2) Camera/GetSnapshot 快照轮询 ——保底，多版本/多参数回退。
//
// 流畅度（修复实时画面卡顿）：
//   - 每帧只更新 ValueNotifier + 局部画面区（RepaintBoundary 隔离），
//     不再 setState 重建整个组件树；
//   - Image.memory 指定 cacheWidth 按显示尺寸解码下采样，避免按原始
//     1080p/4K 分辨率逐帧解码；
//   - MjpegStreamClient 限制帧率，网络快于解码时丢过期帧；
//   - 多画面网格可关闭连续流（allowStream），避免 N 路流并发解码堆积；
//   - 快照轮询改为「本次完成后再排下一次」，不与网络往返重叠。
//
// 所有失败显示真实 HTTP 状态 / DSM 错误码，绝不显示占位假画面。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/network/mjpeg_stream.dart';
import '../core/network/syno_api.dart';
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
    this.allowStream = true,
    this.maxFps = 20,
  });

  final Camera camera;
  final BoxFit fit;
  final bool paused;

  /// 多画面网格可置 false，强制走低开销的快照轮询。
  final bool allowStream;

  /// 连续流上限帧率；多画面时调低可显著降低解码压力。
  final int maxFps;

  @override
  State<LiveSnapshot> createState() => _LiveSnapshotState();
}

class _LiveSnapshotState extends State<LiveSnapshot> {
  StreamSubscription<Uint8List>? _sub;
  Timer? _pollTimer;
  Timer? _watchdog;
  bool _polling = false;

  /// 每帧只更新它，画面区局部重绘，不触发整棵组件树重建。
  final ValueNotifier<Uint8List?> _frames = ValueNotifier<Uint8List?>(null);
  String? _error;
  String? _fallbackNote;
  bool _busy = false;
  bool _streamMode = true;
  int _pollSeconds = 2;
  String _modeLabel = '快照';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  @override
  void didUpdateWidget(covariant LiveSnapshot old) {
    super.didUpdateWidget(old);
    if (old.camera.id != widget.camera.id) {
      _frames.value = null; // 切摄像机不留旧画面
    }
    if (old.camera.id != widget.camera.id ||
        old.paused != widget.paused ||
        old.allowStream != widget.allowStream ||
        old.maxFps != widget.maxFps) {
      _start();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pollTimer?.cancel();
    _watchdog?.cancel();
    _frames.dispose();
    super.dispose();
  }

  void _reset() {
    _sub?.cancel();
    _sub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    _polling = false;
    _busy = false;
    _fallbackNote = null;
    _error = null;
    // 不清空上一帧：配置变更重启时画面不黑一下。
  }

  void _start() {
    _reset();
    if (widget.paused) {
      if (mounted) setState(() {});
      return;
    }
    final state = context.read<AppState>();
    _streamMode = state.prefs.streamMode;
    _pollSeconds = state.prefs.pollSeconds;
    if (widget.allowStream && _streamMode && widget.camera.canStream) {
      _startStream(state);
    } else {
      _startPolling(state);
    }
  }

  void _startPolling(AppState state) {
    _modeLabel = '快照';
    _polling = true;
    _poll(state);
  }

  Future<void> _poll(AppState state) async {
    if (_busy || !_polling || !mounted) return;
    _busy = true;
    try {
      final bytes = await state.snapshotBytes(widget.camera);
      if (mounted) {
        _frames.value = Uint8List.fromList(bytes);
        if (_error != null) setState(() => _error = null);
      }
    } catch (e) {
      // 会话失效：上报全局恢复闭环，不再无意义地反复重试快照。
      if (needsReLoginError(e)) {
        state.reportSessionExpired();
        return;
      }
      if (mounted) setState(() => _error = '$e');
    } finally {
      _busy = false;
      // 完成后再排下一次：不与网络往返重叠，避免请求排队导致画面滞后。
      if (_polling && mounted) {
        _pollTimer = Timer(Duration(seconds: _pollSeconds), () => _poll(state));
      }
    }
  }

  void _startStream(AppState state) {
    _modeLabel = '连续流';
    final client = MjpegStreamClient(
      url: state.liveStreamUrl(widget.camera),
      cookie: state.cookieHeader,
      maxFps: widget.maxFps,
    );
    _sub = client.frames().listen(
      (Uint8List frame) {
        if (!mounted) return;
        _watchdog?.cancel();
        _frames.value = frame;
        // 只有从错误恢复时才需要一次 setState，正常帧不重建组件树。
        if (_error != null && mounted) setState(() => _error = null);
      },
      onError: (Object e) {
        if (!mounted) return;
        // MJPEG 的 465 是会话失效，不要降级成会同样报 465 的快照轮询。
        if (needsReLoginError(e)) {
          state.reportSessionExpired();
          return;
        }
        _fallbackToPolling(state, '连续流失败：$e');
      },
      cancelOnError: true,
    );
    // 流挂着但一直不出帧时也要降级，避免永久黑屏。
    _watchdog = Timer(const Duration(seconds: 6), () {
      if (!mounted || _frames.value != null || _sub == null) return;
      _fallbackToPolling(state, '连续流 6 秒内未返回画面');
    });
  }

  void _fallbackToPolling(AppState state, String reason) {
    _sub?.cancel();
    _sub = null;
    _watchdog?.cancel();
    _watchdog = null;
    _fallbackNote = reason;
    _startPolling(state);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    // 设置页修改刷新间隔 / 画面模式后，所有预览组件立即按新配置重启。
    final poll = state.prefs.pollSeconds;
    final mode = state.prefs.streamMode;
    if (poll != _pollSeconds || mode != _streamMode) {
      _pollSeconds = poll;
      _streamMode = mode;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    }

    if (!state.isLoggedIn) return _placeholder('未登录');
    if (!widget.camera.isOnline) {
      return _placeholder('摄像机已停用');
    }
    if (_frames.value == null && _error != null) {
      final fv = classifyFailure(_error);
      return _ErrorTile(
        message: fv.title,
        detail: '${fv.advice}\n$_error\n${state.mediaDiagnostic}',
        onRetry: () {
          setState(() => _error = null);
          _start();
        },
      );
    }
    if (_frames.value == null) {
      return Container(
        color: const Color(0xFF22262F),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(height: 8),
            Text('正在获取 $_modeLabel画面…',
                style: const TextStyle(fontSize: 10, color: Colors.white54)),
          ],
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          child: RepaintBoundary(
            child: _FrameView(notifier: _frames, fit: widget.fit),
          ),
        ),
        if (_fallbackNote != null)
          Positioned(
            left: 6,
            bottom: 6,
            child: _chip('$_modeLabel模式 · ${_shortNote(_fallbackNote!)}',
                AppColors.amber),
          ),
        if (_error != null)
          Positioned(
            right: 6,
            top: 6,
            child: _chip('刷新失败，点此重试', AppColors.red),
          ),
      ],
    );
  }

  String _shortNote(String s) {
    final t = s.replaceAll('\n', ' ');
    return t.length > 26 ? '${t.substring(0, 26)}…' : t;
  }

  Widget _chip(String text, Color color) => GestureDetector(
        onTap: _error == null ? null : () => _start(),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
              color: Colors.black54, borderRadius: BorderRadius.circular(5)),
          child: Text(text, style: TextStyle(fontSize: 8.5, color: color)),
        ),
      );

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

/// 画面区独立子树：每帧只重建这一小块；按显示宽度下采样解码，
/// gaplessPlayback 保证换帧不清空画面（不闪黑）。
class _FrameView extends StatelessWidget {
  const _FrameView({required this.notifier, required this.fit});

  final ValueNotifier<Uint8List?> notifier;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final dpr = MediaQuery.of(context).devicePixelRatio;
          var cacheWidth = (constraints.maxWidth * dpr).round();
          if (cacheWidth <= 0) cacheWidth = 960;
          if (cacheWidth < 320) cacheWidth = 320;
          if (cacheWidth > 1920) cacheWidth = 1920;
          return ValueListenableBuilder<Uint8List?>(
            valueListenable: notifier,
            builder: (BuildContext context, Uint8List? frame, Widget? _) {
              if (frame == null) return const SizedBox.shrink();
              return Image.memory(
                frame,
                fit: fit,
                gaplessPlayback: true,
                cacheWidth: cacheWidth,
                filterQuality: FilterQuality.low,
              );
            },
          );
        },
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
            const SizedBox(height: 3),
            Text(
              detail.length > 150 ? '${detail.substring(0, 150)}…' : detail,
              textAlign: TextAlign.center,
              maxLines: 3,
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
