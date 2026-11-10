// 单摄像头页「内嵌回放视口」：拖动预览画面下方的时间轴后，直接在原预览区
// 回放选中时刻，不必跳转到 PlaybackPage。
//
// 数据链路与完整回放页一致，全部为 NAS 真实数据：
//  1. Recording/Download 下载真实片段 → video_player 从「选中时刻 - 片段起点」
//     的偏移起播（这就是「回放的不是选中时刻」的修复点）；
//  2. 失败降级 VideoStreaming/Stream 带 startTime=选中时刻的 MJPEG 回放流；
//  3. 都不支持时展示真实诊断，绝不伪造画面。
//
// 设计要点：
//  - 同一片段内再次拖动只 seek，不重新下载，拖动跟手；
//  - 画面用 ValueNotifier 局部重绘、gaplessPlayback，避免换帧闪烁；
//  - 加载 / 等待首帧期间显示中性态，只有确定失败才显示错误。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/network/mjpeg_stream.dart';
import '../../core/network/syno_api.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/camera.dart';
import '../../data/models/media.dart';
import '../../state/app_state.dart';

enum _Phase { loading, video, streamPending, streamLive, failed }

class InlinePlayback extends StatefulWidget {
  const InlinePlayback({
    super.key,
    required this.camera,
    required this.recording,
    required this.seekTo,
    required this.onExit,
    this.onOpenFull,
  });

  final Camera camera;
  final Recording recording;

  /// 用户在时间轴上选中的绝对时刻（回放必须从这一刻开始）。
  final DateTime seekTo;

  /// 返回实时预览。
  final VoidCallback onExit;

  /// 可选：进入带完整控制条的回放页。
  final VoidCallback? onOpenFull;

  @override
  State<InlinePlayback> createState() => _InlinePlaybackState();
}

class _InlinePlaybackState extends State<InlinePlayback> {
  VideoPlayerController? _controller;
  StreamSubscription<Uint8List>? _frameSub;
  final ValueNotifier<Uint8List?> _frames = ValueNotifier<Uint8List?>(null);
  final ValueNotifier<Duration> _position =
      ValueNotifier<Duration>(Duration.zero);

  _Phase _phase = _Phase.loading;
  bool _playing = false;
  bool _gotFirstFrame = false;
  String? _error;
  String _diagnostic = '';
  String _sourceLabel = '';
  Directory? _tempDir;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(context.read<AppState>());
    });
  }

  @override
  void didUpdateWidget(covariant InlinePlayback old) {
    super.didUpdateWidget(old);
    final clipChanged = old.recording.id != widget.recording.id ||
        old.camera.id != widget.camera.id;
    final seekChanged = old.seekTo != widget.seekTo;
    if (!clipChanged && !seekChanged) return;
    if (!clipChanged && seekChanged) {
      final c = _controller;
      if (c != null && c.value.isInitialized) {
        // 同一片段内再次拖动：直接 seek，避免每次松手都重新下载片段。
        unawaited(_seekToSelected(c));
        return;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(context.read<AppState>());
    });
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    _controller?.removeListener(_tick);
    _controller?.dispose();
    _frames.dispose();
    _position.dispose();
    try {
      _tempDir?.deleteSync(recursive: true);
    } catch (_) {
      // 临时文件清理失败不影响退出。
    }
    super.dispose();
  }

  Future<void> _clearMedia() async {
    _frameSub?.cancel();
    _frameSub = null;
    final c = _controller;
    if (c != null) {
      c.removeListener(_tick);
      await c.dispose();
    }
    _controller = null;
    _frames.value = null;
    _position.value = Duration.zero;
    _gotFirstFrame = false;
    _playing = false;
  }

  /// 把播放器定位到「选中时刻」在片段内的偏移并起播。
  Future<void> _seekToSelected(VideoPlayerController c) async {
    if (!c.value.isInitialized) return;
    var secs = TimelineMath.seekSecondsInClip(widget.recording, widget.seekTo);
    final max = c.value.duration.inSeconds;
    if (max > 0 && secs > max) secs = max;
    final target = Duration(seconds: secs);
    await c.seekTo(target);
    _position.value = target;
    if (!c.value.isPlaying) await c.play();
    if (mounted) setState(() => _playing = true);
  }

  void _tick() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    _position.value = c.value.position;
  }

  Future<void> _load(AppState state) async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
      _diagnostic = '';
      _sourceLabel = '';
    });
    await _clearMedia();

    // 路径 1：下载真实片段 → 从选中时刻起播。
    try {
      final rec = await state.downloadRecording(widget.recording);
      final dir = await Directory.systemTemp.createTemp('synocam_inline_');
      final file = File('${dir.path}/clip${rec.extension}');
      await file.writeAsBytes(rec.bytes, flush: true);
      _tempDir = dir;
      final c = VideoPlayerController.file(file);
      await c.initialize();
      c.addListener(_tick);
      await _seekToSelected(c);
      if (mounted) {
        setState(() {
          _controller = c;
          _phase = _Phase.video;
          _playing = true;
          _sourceLabel = 'NAS 录像文件（${rec.source}）· ${rec.contentType}';
        });
      }
      return;
    } catch (e) {
      if (needsReLoginError(e)) {
        state.reportSessionExpired();
        if (mounted) {
          setState(() {
            _phase = _Phase.failed;
            _error = '登录会话已过期，请重新登录';
            _diagnostic = '$e';
          });
        }
        return;
      }
      // 先只记诊断，后面还有回放流兜底，不立刻渲染错误态。
      _diagnostic = '录像文件回放失败：$e';
    }

    // 路径 2：MJPEG 回放流，startTime 用「选中时刻」而非片段起点。
    try {
      final fromDt = widget.seekTo.isBefore(widget.recording.startTime)
          ? widget.recording.startTime
          : widget.seekTo;
      final from = fromDt.millisecondsSinceEpoch ~/ 1000;
      var to = widget.recording.playbackEndTime.millisecondsSinceEpoch ~/ 1000;
      if (to <= from) to = from + 60;
      final url =
          state.liveStreamUrl(widget.camera, startTime: from, endTime: to);
      final client =
          MjpegStreamClient(url: url, cookie: state.cookieHeader, maxFps: 20);
      _frameSub = client.frames().listen(
        (Uint8List frame) {
          _frames.value = frame;
          if (!_gotFirstFrame) {
            _gotFirstFrame = true;
            if (mounted) setState(() => _phase = _Phase.streamLive);
          }
        },
        onError: (Object e) {
          if (_gotFirstFrame) {
            _diagnostic = '回放流中断：$e';
            return;
          }
          if (needsReLoginError(e)) {
            state.reportSessionExpired();
            return;
          }
          if (mounted) {
            setState(() {
              _error = '回放流不可用：$e';
              _phase = _Phase.failed;
            });
          }
        },
        cancelOnError: false,
      );
      if (mounted) {
        setState(() {
          _phase = _Phase.streamPending;
          _sourceLabel = 'MJPEG 回放流（startTime=$from, endTime=$to）';
        });
      }
      unawaited(Future<void>.delayed(const Duration(seconds: 10)).then((_) {
        if (!mounted || _phase != _Phase.streamPending) return;
        if (_frames.value == null) {
          setState(() {
            _error ??= '回放流在 10 秒内未返回画面';
            _phase = _Phase.failed;
          });
        }
      }));
      return;
    } catch (e) {
      _diagnostic += '\n回放流启动失败：$e';
    }

    if (mounted) {
      setState(() {
        _phase = _Phase.failed;
        _error = '该 NAS 版本未提供可用的 App 内回放接口';
      });
    }
  }

  Future<void> _togglePlay() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.play();
    }
    if (mounted) setState(() => _playing = c.value.isPlaying);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        color: const Color(0xFF101318),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _phaseContent(),
            // 顶部：返回实时 + 完整回放入口。
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: <Widget>[
                  _pill(
                    icon: Icons.arrow_back_ios_new,
                    label: '返回实时',
                    onTap: widget.onExit,
                  ),
                  const Spacer(),
                  _tag('回放 · ${state.timeLabel(widget.seekTo)}', AppColors.red),
                  if (widget.onOpenFull != null) ...<Widget>[
                    const SizedBox(width: 6),
                    _pill(
                      icon: Icons.open_in_new,
                      label: '完整回放',
                      onTap: widget.onOpenFull!,
                    ),
                  ],
                ],
              ),
            ),
            // 底部：播放控制 + 录像真实绝对时刻。
            Positioned(
              left: 10,
              right: 10,
              bottom: 9,
              child: Row(
                children: <Widget>[
                  if (_phase == _Phase.video)
                    GestureDetector(
                      onTap: _togglePlay,
                      child: Icon(
                          _playing ? Icons.pause_circle : Icons.play_circle,
                          size: 26,
                          color: Colors.white),
                    ),
                  const SizedBox(width: 8),
                  Expanded(child: _timeLabel(state)),
                  if (_sourceLabel.isNotEmpty)
                    _tag(_shortSource(_sourceLabel), AppColors.blue),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _phaseContent() {
    switch (_phase) {
      case _Phase.loading:
        return _busy('正在读取该时刻的真实录像…');
      case _Phase.video:
        final c = _controller;
        return c != null ? VideoPlayer(c) : _busy('正在准备播放器…');
      case _Phase.streamPending:
      case _Phase.streamLive:
        return _frames.value != null
            ? _MjpegStage(notifier: _frames)
            : _busy('正在接收回放画面…');
      case _Phase.failed:
        return _errorView();
    }
  }

  Widget _timeLabel(AppState state) => ValueListenableBuilder<Duration>(
        valueListenable: _position,
        builder: (BuildContext context, Duration pos, Widget? _) {
          final label = _phase == _Phase.video
              ? state.timeFull(widget.recording.startTime.add(pos))
              : '${state.timeFull(widget.seekTo)} 起 · '
                  '${widget.recording.playbackDurationSeconds}s';
          return Text('录像 $label',
              style: const TextStyle(fontSize: 10, color: Colors.white));
        },
      );

  String _shortSource(String s) => s.length > 18 ? '${s.substring(0, 18)}…' : s;

  Widget _busy(String text) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(height: 9),
            Text(text,
                style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
          ],
        ),
      );

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 26, color: AppColors.red),
              const SizedBox(height: 7),
              Text(_error ?? '回放不可用',
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontSize: 11.5, color: Colors.white70)),
              const SizedBox(height: 5),
              Text(
                _diagnostic.length > 130
                    ? '${_diagnostic.substring(0, 130)}…'
                    : _diagnostic,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: const TextStyle(fontSize: 8.5, color: Colors.white38),
              ),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => _load(context.read<AppState>()),
                child: const Text('重新读取',
                    style: TextStyle(fontSize: 10.5, color: AppColors.blue)),
              ),
            ],
          ),
        ),
      );

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
            color: Colors.black54, borderRadius: BorderRadius.circular(5)),
        child: Text(text,
            style: TextStyle(
                fontSize: 9, fontWeight: FontWeight.w600, color: color)),
      );

  Widget _pill({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: Colors.black54, borderRadius: BorderRadius.circular(6)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 11, color: Colors.white),
              const SizedBox(width: 4),
              Text(label,
                  style: const TextStyle(fontSize: 9.5, color: Colors.white)),
            ],
          ),
        ),
      );
}

/// MJPEG 回放画面：逐帧局部重绘，gaplessPlayback 保证换帧不清空（不闪烁）。
class _MjpegStage extends StatelessWidget {
  const _MjpegStage({required this.notifier});

  final ValueNotifier<Uint8List?> notifier;

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
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: cacheWidth,
                filterQuality: FilterQuality.low,
              );
            },
          );
        },
      );
}
