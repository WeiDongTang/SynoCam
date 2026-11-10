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
// 所有失败显示真实 HTTP 状态 / DSM 错误码，绝不显示占位假画面。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/network/mjpeg_stream.dart';
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
  StreamSubscription<Uint8List>? _sub;
  Timer? _pollTimer;
  Timer? _watchdog;

  Uint8List? _frame;
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
    if (old.camera.id != widget.camera.id || old.paused != widget.paused) {
      _start();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pollTimer?.cancel();
    _watchdog?.cancel();
    super.dispose();
  }

  void _reset() {
    _sub?.cancel();
    _sub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    _fallbackNote = null;
    _error = null;
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
    if (_streamMode && widget.camera.canStream) {
      _startStream(state);
    } else {
      _startPolling(state);
    }
  }

  void _startPolling(AppState state) {
    _modeLabel = '快照';
    _pollTimer = Timer.periodic(
        Duration(seconds: _pollSeconds), (_) => _poll(state));
    _poll(state);
  }

  Future<void> _poll(AppState state) async {
    if (_busy || !mounted) return;
    _busy = true;
    try {
      final bytes = await state.snapshotBytes(widget.camera);
      if (mounted) {
        setState(() {
          _frame = Uint8List.fromList(bytes);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _busy = false;
    }
  }

  void _startStream(AppState state) {
    _modeLabel = '连续流';
    final client = MjpegStreamClient(
      url: state.liveStreamUrl(widget.camera),
      cookie: state.cookieHeader,
    );
    _sub = client.frames().listen(
      (Uint8List frame) {
        if (!mounted) return;
        _watchdog?.cancel();
        setState(() {
          _frame = frame;
          _error = null;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        _fallbackToPolling(state, '连续流失败：$e');
      },
      cancelOnError: true,
    );
    // 流挂着但一直不出帧时也要降级，避免永久黑屏。
    _watchdog = Timer(const Duration(seconds: 6), () {
      if (!mounted || _frame != null || _sub == null) return;
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
    if (_frame == null && _error != null) {
      return _ErrorTile(
        message: '画面加载失败',
        detail: '$_error\n${state.mediaDiagnostic}',
        onRetry: () {
          setState(() => _error = null);
          _start();
        },
      );
    }
    if (_frame == null) {
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
        Image.memory(_frame!, fit: widget.fit, gaplessPlayback: true),
        if (_fallbackNote != null)
          Positioned(
            left: 6,
            bottom: 6,
            child: _chip('$_modeLabel模式 · ${_shortNote(_fallbackNote!)}',
                AppColors.amber),
          ),
        if (_error != null && _frame != null)
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
          child: Text(text,
              style: TextStyle(fontSize: 8.5, color: color)),
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
