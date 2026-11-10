// 单摄像头页「内嵌回放视口」：拖动预览画面下方的时间轴后，直接在原预览区
// 回放选中时刻的真实 NAS 画面，不必跳转到 PlaybackPage。
//
// 数据链路（全部真实，绝不把实时画面冒充回放）：
//  1. Recording/Download 以「cameraId + startTime(选中时刻) + stopTime」
//     请求该时刻起的真实录像 → video_player 从头播（按 id 下载整段时 seek
//     到「选中时刻 - 片段起点」）；
//  2. 失败时用按时刻历史帧接口取那一刻的真实历史快照（非实时画面）；
//  3. 都失败展示真实诊断。旧实现降级到 VideoStreaming/Stream 实时流，导致
//     拖动到任何时刻都只看到实时画面，已从根上删除。
//
// 全屏：复用同一个 controller，支持左右滑动快进快退 / 长按 3x 快进。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/network/syno_api.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/camera.dart';
import '../../data/models/media.dart';
import '../../state/app_state.dart';
import '../../widgets/fullscreen_stage.dart';

enum _Phase { loading, video, frame, failed }

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
  final ValueNotifier<Uint8List?> _frame = ValueNotifier<Uint8List?>(null);
  final ValueNotifier<Duration> _position =
      ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<bool> _playingValue = ValueNotifier<bool>(false);

  _Phase _phase = _Phase.loading;
  String? _error;
  String _diagnostic = '';
  String _sourceLabel = '';
  String _frameTimeLabel = '';
  double _speed = 1.0;
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
    // 每次选中时刻 / 片段变化都重新按该时刻加载真实数据，
    // 保证「拖动到哪就回放哪」，而不是留在旧片段里 seek 或播实时画面。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(context.read<AppState>());
    });
  }

  @override
  void dispose() {
    _controller?.removeListener(_tick);
    _controller?.dispose();
    _frame.dispose();
    _position.dispose();
    _playingValue.dispose();
    try {
      _tempDir?.deleteSync(recursive: true);
    } catch (_) {
      // 临时文件清理失败不影响退出。
    }
    super.dispose();
  }

  Future<void> _clearMedia() async {
    final c = _controller;
    if (c != null) {
      c.removeListener(_tick);
      await c.dispose();
    }
    _controller = null;
    _frame.value = null;
    _position.value = Duration.zero;
    _playingValue.value = false;
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
      _frameTimeLabel = '';
    });
    await _clearMedia();

    // 路径 1：下载从选中时刻开始的真实录像 → 从头播。
    try {
      final rec =
          await state.downloadRecording(widget.recording, at: widget.seekTo);
      final dir = await Directory.systemTemp.createTemp('synocam_inline_');
      final file = File('${dir.path}/clip${rec.extension}');
      await file.writeAsBytes(rec.bytes, flush: true);
      _tempDir = dir;
      final c = VideoPlayerController.file(file);
      await c.initialize();
      c.addListener(_tick);
      await c.setPlaybackSpeed(_speed);
      await _seekToFileStart(c, rec.startsAt);
      if (mounted) {
        setState(() {
          _controller = c;
          _phase = _Phase.video;
          _playingValue.value = true;
          _sourceLabel = 'NAS 真实录像（${rec.source}）· ${rec.contentType}';
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
      _diagnostic = '录像文件回放失败：$e';
    }

    // 路径 2：按时刻真实历史帧（非实时画面）。
    await _loadHistoryFrame(state, widget.seekTo);
  }

  Future<void> _seekToFileStart(
      VideoPlayerController c, DateTime? startsAt) async {
    if (!c.value.isInitialized) return;
    var secs = 0;
    if (startsAt != null) {
      secs = widget.seekTo.difference(startsAt).inSeconds;
    } else {
      secs = TimelineMath.seekSecondsInClip(widget.recording, widget.seekTo);
    }
    final max = c.value.duration.inSeconds;
    if (secs < 0) secs = 0;
    if (max > 0 && secs > max) secs = max;
    final target = Duration(seconds: secs);
    _position.value = target;
    if (secs > 0) await c.seekTo(target);
    if (!c.value.isPlaying) await c.play();
  }

  Future<void> _loadHistoryFrame(AppState state, DateTime at) async {
    try {
      final bytes = await state.recordingFrameAt(widget.camera, at);
      if (mounted) {
        setState(() {
          _frame.value = Uint8List.fromList(bytes);
          _phase = _Phase.frame;
          _sourceLabel = 'NAS 历史帧（按时刻录像快照）';
          _frameTimeLabel = state.timeFull(at);
        });
      }
      return;
    } catch (e) {
      if (needsReLoginError(e)) {
        state.reportSessionExpired();
        return;
      }
      _diagnostic += '\n按时刻历史帧失败：$e';
    }
    if (mounted) {
      setState(() {
        _phase = _Phase.failed;
        _error = '无法回放该时刻的真实录像';
      });
    }
  }

  Future<void> _seekBy(AppState state, int seconds) async {
    final c = _controller;
    if (_phase == _Phase.video && c != null && c.value.isInitialized) {
      final cur = c.value.position + Duration(seconds: seconds);
      final dur = c.value.duration;
      final target =
          cur < Duration.zero ? Duration.zero : (cur > dur ? dur : cur);
      await c.seekTo(target);
      _position.value = target;
      return;
    }
    // 历史帧路径：切到相邻时刻重新取真实历史帧。
    final at = widget.seekTo.add(Duration(seconds: seconds));
    setState(() {
      _phase = _Phase.loading;
      _frame.value = null;
    });
    await _loadHistoryFrame(state, at);
  }

  Future<void> _setSpeed(double v) async {
    _speed = v;
    await _controller?.setPlaybackSpeed(v);
  }

  Future<void> _togglePlay() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.play();
    }
    _playingValue.value = c.value.isPlaying;
  }

  void _openFullscreen(AppState state) {
    FullscreenStage.show(
      context,
      title: '回放 · ${widget.camera.name} · ${state.timeFull(widget.seekTo)}',
      controls: FullscreenControls(
        seekBy: (int s) => _seekBy(state, s),
        setSpeed: (double v) => _setSpeed(v),
        togglePlay: () => _togglePlay(),
        currentSpeed: () => _speed,
        position: _position,
        duration: _controller?.value.duration,
        playing: _playingValue,
      ),
      video: _fullscreenVideo(),
    );
  }

  Widget _fullscreenVideo() => ValueListenableBuilder<Uint8List?>(
        valueListenable: _frame,
        builder: (BuildContext context, Uint8List? frame, Widget? _) {
          final c = _controller;
          if (_phase == _Phase.video && c != null) return VideoPlayer(c);
          if (frame != null) {
            return Image.memory(frame,
                fit: BoxFit.contain, gaplessPlayback: true);
          }
          return const SizedBox.shrink();
        },
      );

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
            // 顶部：返回实时 + 全屏 + 完整回放入口。
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
                  const SizedBox(width: 6),
                  _iconPill(
                      Icons.fullscreen, '全屏', () => _openFullscreen(state)),
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
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _playingValue,
                        builder:
                            (BuildContext context, bool playing, Widget? _) =>
                                Icon(
                                    playing
                                        ? Icons.pause_circle
                                        : Icons.play_circle,
                                    size: 26,
                                    color: Colors.white),
                      ),
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
      case _Phase.frame:
        return _FrameStage(notifier: _frame);
      case _Phase.failed:
        return _errorView();
    }
  }

  Widget _timeLabel(AppState state) => ValueListenableBuilder<Duration>(
        valueListenable: _position,
        builder: (BuildContext context, Duration pos, Widget? _) {
          final label = _phase == _Phase.video
              ? state.timeFull(widget.recording.startTime.add(pos))
              : (_frameTimeLabel.isNotEmpty
                  ? _frameTimeLabel
                  : state.timeFull(widget.seekTo));
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

  Widget _iconPill(IconData icon, String tooltip, VoidCallback onTap) =>
      Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
                color: Colors.black54, borderRadius: BorderRadius.circular(6)),
            child: Icon(icon, size: 14, color: Colors.white),
          ),
        ),
      );
}

/// 历史帧画面：逐帧局部重绘，gaplessPlayback 保证换帧不清空（不闪烁）。
class _FrameStage extends StatelessWidget {
  const _FrameStage({required this.notifier});

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
                fit: BoxFit.contain,
                gaplessPlayback: true,
                cacheWidth: cacheWidth,
                filterQuality: FilterQuality.low,
              );
            },
          );
        },
      );
}
