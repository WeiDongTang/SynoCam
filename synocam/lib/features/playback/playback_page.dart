// App 内录像回放页：回放「用户选中的绝对时刻」的真实 NAS 画面。
//
// 数据链路（全部真实，绝不把实时画面冒充回放）：
//  1. SYNO.SurveillanceStation.Recording/Download 以「cameraId + startTime
//     (选中时刻) + stopTime」请求该时刻起的真实录像 → video_player 从头播；
//     若 NAS 只支持按事件 id 下载整段，则 seek 到「选中时刻 - 片段起点」；
//  2. 录像文件下载 / 播放器初始化失败时，用 Recording/GetSnapshot 等按时刻
//     历史帧接口取「那一刻的真实历史快照」（静帧，明确标注，非实时画面）；
//  3. 都失败时展示真实 DSM 诊断，绝不降级到 VideoStreaming/Stream 实时流
//     ——旧实现正是用它加被忽略的 startTime/endTime 冒充回放，导致用户拖动
//     到任何时刻都只看到实时画面。
//
// 全屏：复用同一个 video_player controller 进入沉浸式全屏，支持左右滑动
// 快进快退、长按 3x 快进、双击暂停；退出后原页面继续播放，不重连不黑屏。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/network/syno_api.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../core/utils/launcher.dart';
import '../../data/models/camera.dart';
import '../../data/models/media.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/fullscreen_stage.dart';

const List<double> _speeds = <double>[0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0];

/// loading / video / frame(历史帧) / failed。中间态一律中性加载，只有确定
/// 失败才显示错误——避免真实录像能播时闪过错误提示。
enum _PlaybackPhase { loading, video, frame, failed }

class PlaybackPage extends StatefulWidget {
  const PlaybackPage({
    super.key,
    required this.recording,
    required this.camera,
    this.seekTo,
  });

  final Recording recording;
  final Camera camera;

  /// 用户在时间轴上选中的绝对时刻。回放必须从这一刻开始，而不是片段开头。
  final DateTime? seekTo;

  @override
  State<PlaybackPage> createState() => _PlaybackPageState();
}

class _PlaybackPageState extends State<PlaybackPage> {
  VideoPlayerController? _controller;

  /// 视频进度 / 位置 / 播放状态都只更新 notifier，画面区与进度条局部重绘，
  /// 绝不重建整页（这是「一秒闪一次」的根因）。
  final ValueNotifier<double> _videoProgress = ValueNotifier<double>(0);
  final ValueNotifier<Duration> _videoPosition =
      ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<bool> _playingValue = ValueNotifier<bool>(false);

  /// 按时刻历史帧（录像文件不可用时的真实兜底，非实时画面）。
  final ValueNotifier<Uint8List?> _frame = ValueNotifier<Uint8List?>(null);

  late Recording _active;
  late DateTime _dayStart;
  List<Recording> _clips = <Recording>[];

  /// 本次加载要定位到的绝对时刻（随拖动 / 点选变化）。
  late DateTime _seekTarget;

  _PlaybackPhase _phase = _PlaybackPhase.loading;
  bool _videoReady = false;
  String? _error;
  String _diagnostic = '';
  String _sourceLabel = '';
  String _frameTimeLabel = '';

  double _fraction = 0; // 24 小时时间轴位置
  double _speed = 1.0;

  Directory? _tempDir;

  @override
  void initState() {
    super.initState();
    _active = widget.recording;
    final d = widget.recording.startTime;
    _dayStart = DateTime(d.year, d.month, d.day);
    _seekTarget = widget.seekTo ?? widget.recording.startTime;
    _fraction = TimelineMath.fractionOf(_seekTarget, _dayStart);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<AppState>();
      _clips = state.recordings
          .where((r) =>
              r.cameraId == widget.camera.id &&
              !r.startTime.isBefore(_dayStart) &&
              r.startTime.isBefore(_dayStart.add(const Duration(days: 1))))
          .toList();
      _load(state);
    });
  }

  @override
  void dispose() {
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
    _frame.dispose();
    _videoProgress.dispose();
    _videoPosition.dispose();
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
      c.removeListener(_onVideoTick);
      await c.dispose();
    }
    _controller = null;
    _frame.value = null;
    _videoProgress.value = 0;
    _videoPosition.value = Duration.zero;
    _playingValue.value = false;
    _videoReady = false;
  }

  Future<void> _load(AppState state) async {
    setState(() {
      _phase = _PlaybackPhase.loading;
      _error = null;
      _diagnostic = '';
      _sourceLabel = '';
      _frameTimeLabel = '';
    });
    await _clearMedia();

    // 路径 1：下载「从选中时刻开始」的真实录像 → App 内播放器。
    try {
      final rec = await state.downloadRecording(_active, at: _seekTarget);
      final dir = await Directory.systemTemp.createTemp('synocam_pb_');
      final file = File('${dir.path}/clip${rec.extension}');
      await file.writeAsBytes(rec.bytes, flush: true);
      _tempDir = dir;
      final c = VideoPlayerController.file(file);
      await c.initialize();
      c.addListener(_onVideoTick);
      await c.setPlaybackSpeed(_speed);
      // rec.startsAt 是文件内容的真实起点：按时间段下载成功时就是选中时刻，
      // 从头播即为选中画面；按事件 id 下载整段时是片段起点，需 seek 偏移。
      await _seekToFileStart(c, rec.startsAt);
      if (mounted) {
        setState(() {
          _controller = c;
          _videoReady = true;
          _playingValue.value = true;
          _phase = _PlaybackPhase.video;
          _sourceLabel = 'NAS 真实录像（${rec.source}）· ${rec.contentType}';
        });
      }
      return;
    } catch (e) {
      if (needsReLoginError(e)) {
        state.reportSessionExpired();
        if (mounted) {
          setState(() {
            _phase = _PlaybackPhase.failed;
            _error = '登录会话已过期，请重新登录';
            _diagnostic = '$e';
          });
        }
        return;
      }
      // 路径 1 失败先只记诊断，后面还有历史帧兜底，不立刻渲染错误视图。
      _diagnostic = '录像文件回放失败：$e';
    }

    // 路径 2：按选中时刻取 NAS 真实历史帧（不是实时画面）。
    await _loadHistoryFrame(state, _seekTarget);
  }

  /// 把播放器定位到文件里对应「选中时刻」的位置。
  Future<void> _seekToFileStart(
      VideoPlayerController c, DateTime? startsAt) async {
    if (!c.value.isInitialized) return;
    var secs = 0;
    if (startsAt != null) {
      secs = _seekTarget.difference(startsAt).inSeconds;
    } else {
      secs = TimelineMath.seekSecondsInClip(_active, _seekTarget);
    }
    final max = c.value.duration.inSeconds;
    if (secs < 0) secs = 0;
    if (max > 0 && secs > max) secs = max;
    final target = Duration(seconds: secs);
    _videoPosition.value = target;
    if (secs > 0) await c.seekTo(target);
    if (!c.value.isPlaying) await c.play();
  }

  /// 取「选中时刻」的真实历史帧。失败则展示真实诊断，绝不回退实时流。
  Future<void> _loadHistoryFrame(AppState state, DateTime at) async {
    try {
      final bytes = await state.recordingFrameAt(widget.camera, at);
      if (mounted) {
        setState(() {
          _frame.value = Uint8List.fromList(bytes);
          _phase = _PlaybackPhase.frame;
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
        _phase = _PlaybackPhase.failed;
        _error = '无法回放该时刻的真实录像';
      });
    }
  }

  /// 全屏手势的相对 seek：视频路径在播放器内定位；历史帧路径则切到相邻
  /// 时刻重新取真实历史帧（同样是「快进快退」，且始终不是实时画面）。
  Future<void> _seekBy(AppState state, int seconds) async {
    final c = _controller;
    if (_videoReady && c != null && c.value.isInitialized) {
      final cur = c.value.position + Duration(seconds: seconds);
      final dur = c.value.duration;
      final target =
          cur < Duration.zero ? Duration.zero : (cur > dur ? dur : cur);
      await c.seekTo(target);
      _videoPosition.value = target;
      return;
    }
    final next = _seekTarget.add(Duration(seconds: seconds));
    _seekTarget = next;
    setState(() {
      _phase = _PlaybackPhase.loading;
      _frame.value = null;
    });
    await _loadHistoryFrame(state, next);
  }

  Future<void> _setSpeed(double v) async {
    setState(() => _speed = v);
    await _controller?.setPlaybackSpeed(v);
  }

  /// 播放进度回调：只更新 notifier，绝不 setState 重建整页画面。
  void _onVideoTick() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    _videoPosition.value = c.value.position;
    final total = c.value.duration.inSeconds;
    if (total > 0) {
      _videoProgress.value =
          (c.value.position.inSeconds / total).clamp(0.0, 1.0).toDouble();
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
    _playingValue.value = c.value.isPlaying;
  }

  Future<void> _seekVideo(double v) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    _videoProgress.value = v;
    await c.seekTo(c.value.duration * v);
  }

  Future<void> _onScrubEnd(double v) async {
    final t = TimelineMath.timeAt(v, _dayStart);
    final target =
        TimelineMath.clipAt(_clips, t) ?? TimelineMath.nearestClip(_clips, t);
    if (target == null) return;
    _seekTarget = t;
    setState(() {
      _active = target;
      _fraction = v;
    });
    // 每次拖动都重新按「选中的绝对时刻」加载真实数据，保证画面与时刻一致。
    await _load(context.read<AppState>());
  }

  /// 打开沉浸式全屏（复用当前画面，不重新初始化 controller）。
  void _openFullscreen(AppState state) {
    FullscreenStage.show(
      context,
      title: '回放 · ${widget.camera.name} · ${state.timeFull(_seekTarget)}',
      controls: FullscreenControls(
        seekBy: (int s) => _seekBy(state, s),
        setSpeed: (double v) => _setSpeed(v),
        togglePlay: () => _togglePlay(),
        currentSpeed: () => _speed,
        position: _videoPosition,
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
          if (_phase == _PlaybackPhase.video && c != null) {
            return VideoPlayer(c);
          }
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
    return Scaffold(
      appBar: AppBar(
        title: Text('回放 · ${widget.camera.name}'),
        leading: IconButton(
          icon: const AppIcon(AppIcons.back, size: 20, color: AppColors.blue),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '全屏播放（可滑动快进快退）',
            icon: const Icon(Icons.fullscreen, color: AppColors.blue),
            onPressed: () => _openFullscreen(state),
          ),
          IconButton(
            tooltip: '重新加载片段',
            icon: const AppIcon(AppIcons.refresh,
                size: 20, color: AppColors.blue),
            onPressed: () => _load(state),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: <Widget>[
          _videoArea(state),
          const SizedBox(height: 10),
          _controls(state),
          const SizedBox(height: 6),
          const _SectionLabel('片段内进度（可拖动）'),
          ValueListenableBuilder<double>(
            valueListenable: _videoProgress,
            builder: (BuildContext context, double progress, Widget? _) =>
                Slider(
              value: progress,
              onChanged: _videoReady ? (v) => _videoProgress.value = v : null,
              onChangeEnd: _videoReady ? (v) => _seekVideo(v) : null,
            ),
          ),
          const SizedBox(height: 6),
          const _SectionLabel('今日时间轴 · 拖动定位到任意时刻'),
          _timeline(state),
          const SizedBox(height: 14),
          const _SectionLabel('当前片段（NAS 真实事件）'),
          _clipInfo(state),
          const SizedBox(height: 12),
          if (_sourceLabel.isNotEmpty) _sourceCard(),
          if (_phase == _PlaybackPhase.failed) _diagnosticCard(state),
          const SizedBox(height: 14),
          _SectionLabel('今日录像片段（${_clips.length} 条）'),
          ..._clips.take(12).map((r) => _clipTile(state, r)),
          const SizedBox(height: 12),
          _fallbackActions(state),
        ],
      ),
    );
  }

  Widget _videoArea(AppState state) => ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            color: const Color(0xFF101318),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _phaseContent(state),
                if (_phase == _PlaybackPhase.video ||
                    _phase == _PlaybackPhase.frame)
                  Positioned(top: 9, right: 10, child: _timeOsd(state)),
                // 画面区右下角全屏按钮（用户最容易找到的位置）。
                Positioned(
                  right: 9,
                  bottom: 9,
                  child: Material(
                    color: Colors.black45,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _openFullscreen(state),
                      child: const Padding(
                        padding: EdgeInsets.all(7),
                        child: Icon(Icons.fullscreen,
                            size: 20, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  /// 画面上叠加「录像真实绝对时间」，而不只是 00:05 这类相对时长。
  Widget _timeOsd(AppState state) => ValueListenableBuilder<Duration>(
        valueListenable: _videoPosition,
        builder: (BuildContext context, Duration pos, Widget? _) {
          final label = _phase == _PlaybackPhase.video
              ? state.timeFull(_active.startTime.add(pos))
              : (_frameTimeLabel.isNotEmpty
                  ? _frameTimeLabel
                  : state.timeFull(_seekTarget));
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
                color: Colors.black54, borderRadius: BorderRadius.circular(5)),
            child: Text(
              '录像 $label',
              style: const TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white),
            ),
          );
        },
      );

  Widget _phaseContent(AppState state) {
    switch (_phase) {
      case _PlaybackPhase.loading:
        return _busy('正在从 NAS 读取该时刻的真实录像…');
      case _PlaybackPhase.video:
        final c = _controller;
        return c != null ? VideoPlayer(c) : _busy('正在准备播放器…');
      case _PlaybackPhase.frame:
        return _FrameStage(notifier: _frame);
      case _PlaybackPhase.failed:
        return _errorView(state);
    }
  }

  Widget _busy(String text) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(height: 10),
            Text(text,
                style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
      );

  Widget _errorView(AppState state) {
    final fv = classifyFailure(_error);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const AppIcon(AppIcons.alert, size: 28, color: AppColors.red),
            const SizedBox(height: 8),
            Text(_error ?? '回放不可用',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 6),
            Text(
                _short('该时刻为 ${state.timeFull(_seekTarget)}；未展示实时画面。\n'
                    '${fv.advice}\n${state.mediaDiagnostic}'),
                textAlign: TextAlign.center,
                maxLines: 3,
                style: const TextStyle(fontSize: 9, color: Colors.white38)),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: fv.needsReLogin
                  ? () => state.reportSessionExpired()
                  : () => _load(state),
              child: Text(fv.needsReLogin ? '重新登录' : '重新读取'),
            ),
          ],
        ),
      ),
    );
  }

  String _short(String s) => s.length > 160 ? '${s.substring(0, 160)}…' : s;

  Widget _controls(AppState state) {
    final c = _controller;
    final duration = c?.value.duration ?? Duration.zero;
    return Row(
      children: <Widget>[
        IconButton(
          tooltip: '全屏',
          icon: const Icon(Icons.fullscreen, color: AppColors.blue),
          onPressed: () => _openFullscreen(state),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: _playingValue,
          builder: (BuildContext context, bool playing, Widget? _) =>
              IconButton(
            tooltip: playing ? '暂停' : '播放',
            icon: AppIcon(playing ? AppIcons.pause : AppIcons.play,
                size: 22,
                color: _videoReady ? AppColors.blue : AppColors.faint),
            onPressed: _videoReady ? () => _togglePlay() : null,
          ),
        ),
        IconButton(
          tooltip: '后退 10 秒',
          icon: const AppIcon(AppIcons.skipBack, size: 20),
          onPressed: () => _seekBy(state, -10),
        ),
        IconButton(
          tooltip: '前进 10 秒',
          icon: const AppIcon(AppIcons.skipFwd, size: 20),
          onPressed: () => _seekBy(state, 10),
        ),
        const SizedBox(width: 4),
        ValueListenableBuilder<Duration>(
          valueListenable: _videoPosition,
          builder: (BuildContext context, Duration pos, Widget? _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                _videoReady
                    ? state.timeLabel(_active.startTime.add(pos))
                    : state.timeLabel(_seekTarget),
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              Text('${_mmss(pos)} / ${_mmss(duration)}',
                  style:
                      const TextStyle(fontSize: 9.5, color: AppColors.faint)),
            ],
          ),
        ),
        const Spacer(),
        DropdownButton<double>(
          value: _speeds.contains(_speed) ? _speed : 1.0,
          items: _speeds
              .map((v) => DropdownMenuItem<double>(
                  value: v,
                  child: Text('${v}x', style: const TextStyle(fontSize: 11))))
              .toList(),
          onChanged: _videoReady ? (v) => _setSpeed(v ?? 1.0) : null,
          underline: const SizedBox.shrink(),
        ),
      ],
    );
  }

  String _mmss(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _timeline(AppState state) => Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text('00:00',
                  style: TextStyle(fontSize: 10, color: AppColors.faint)),
              Text(
                  '拖动定位到 ${state.timeLabel(TimelineMath.timeAt(_fraction, _dayStart))}',
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600)),
              Text('24:00',
                  style: TextStyle(fontSize: 10, color: AppColors.faint)),
            ],
          ),
          Slider(
            value: _fraction,
            onChanged: (v) => setState(() => _fraction = v),
            onChangeEnd: (v) => _onScrubEnd(v),
          ),
          _clipTrack(),
        ],
      );

  Widget _clipTrack() => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final w = constraints.maxWidth;
          return Container(
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.line),
            ),
            child: Stack(
              children: _clips.map((r) {
                final left = TimelineMath.fractionOf(r.startTime, _dayStart);
                final width =
                    (r.playbackDurationSeconds / TimelineMath.secondsPerDay)
                        .clamp(0.004, 1.0)
                        .toDouble();
                return Positioned(
                  left: w * left,
                  width: w * width,
                  top: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onTap: () {
                      _seekTarget = r.startTime;
                      setState(() {
                        _active = r;
                        _fraction = left;
                      });
                      _load(context.read<AppState>());
                    },
                    child: Container(
                      color: r.id == _active.id
                          ? AppColors.blue.withOpacity(.75)
                          : (r.eventType == '移动侦测'
                              ? AppColors.red.withOpacity(.35)
                              : AppColors.green.withOpacity(.3)),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        },
      );

  Widget _clipInfo(AppState state) => Card(
        child: Column(
          children: <Widget>[
            _infoRow('事件 ID', _active.id),
            _infoRow('开始时间', state.timeFull(_active.startTime)),
            _infoRow('结束时间', state.timeFull(_active.playbackEndTime)),
            _infoRow('时长', _active.durationLabel),
            _infoRow('回放跨度', '${_active.playbackDurationSeconds} 秒'),
            _infoRow('定位时刻', state.timeFull(_seekTarget)),
            _infoRow('类型', _active.eventType),
            _infoRow('状态', _active.locked ? '已锁定' : '未锁定'),
          ],
        ),
      );

  Widget _infoRow(String label, String value) => ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        title:
            Text(label, style: TextStyle(fontSize: 11.5, color: AppColors.sub)),
        trailing: Text(value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      );

  Widget _clipTile(AppState state, Recording r) => Card(
        margin: const EdgeInsets.only(bottom: 7),
        child: ListTile(
          dense: true,
          leading: const AppIcon(AppIcons.play, size: 17),
          title: Text(r.eventType, style: const TextStyle(fontSize: 12.5)),
          subtitle: Text(
              '${state.timeShort(r.startTime)} · ${r.durationLabel}'
              '${r.locked ? ' · 已锁定' : ''}',
              style: TextStyle(fontSize: 10, color: AppColors.faint)),
          trailing: Text(r.id == _active.id ? '当前' : '切换',
              style: TextStyle(fontSize: 10, color: AppColors.faint)),
          onTap: () {
            if (r.id == _active.id) return;
            _seekTarget = r.startTime;
            setState(() {
              _active = r;
              _fraction = TimelineMath.fractionOf(r.startTime, _dayStart);
            });
            _load(state);
          },
        ),
      );

  Widget _sourceCard() => Card(
        color: AppColors.cardAlt,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              const AppIcon(AppIcons.info, size: 16, color: AppColors.blue),
              const SizedBox(width: 8),
              Expanded(
                child: Text('画面来源：$_sourceLabel',
                    style: TextStyle(fontSize: 10.5, color: AppColors.sub)),
              ),
            ],
          ),
        ),
      );

  Widget _diagnosticCard(AppState state) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Card(
          color: AppColors.cardAlt,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('真实诊断（来自 NAS 响应）',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(_diagnostic.isEmpty ? state.mediaDiagnostic : _diagnostic,
                    style: TextStyle(fontSize: 10.5, color: AppColors.sub)),
                const SizedBox(height: 6),
                Text(
                    '会话 Cookie ${state.cookieHeader.isEmpty ? '未注入' : '已注入'}'
                    ' · NAS API ${state.apiInfo.length} 个',
                    style: TextStyle(fontSize: 10, color: AppColors.faint)),
              ],
            ),
          ),
        ),
      );

  Widget _fallbackActions(AppState state) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            '以上入口均为用户主动操作；App 默认不会把 API 地址直接丢给浏览器，'
            '也不会用实时画面冒充回放。',
            style: TextStyle(fontSize: 10, color: AppColors.faint),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => copyToClipboard(
                context, state.recordingDownloadUrl(_active),
                label: '真实录像链接已复制'),
            icon: const AppIcon(AppIcons.download, size: 16),
            label: const Text('复制真实录像链接'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () =>
                openExternalUrl(context, state.webUiUrl(), label: 'SS 网页端'),
            icon: const AppIcon(AppIcons.server, size: 16),
            label: const Text('在 Surveillance Station 网页端回放'),
          ),
        ],
      );
}

/// 历史帧画面：独立子树逐帧局部重绘，gaplessPlayback 保证换帧不清空画面。
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.2,
                color: AppColors.faint,
                fontWeight: FontWeight.w600)),
      );
}
