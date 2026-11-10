// App 内录像回放页：点击录制事件不再跳浏览器。
//
// 数据链路（全部真实，无演示数据）：
//  1. 首选 SYNO.SurveillanceStation.Recording/Download 取真实片段文件
//     → 写临时文件 → video_player 播放，支持拖动 seek / 倍速 / 暂停；
//  2. 若该 NAS 版本不支持下载或格式不可播，尝试 VideoStreaming/Stream
//     带 startTime/endTime 的 MJPEG 回放流（App 内逐帧显示）；
//  3. 都不支持时展示真实 DSM 诊断与片段信息，绝不伪造画面；
//     「复制链接 / 网页端」只作为用户主动点击的兜底入口。
//
// 说明：公开 SS Web API 的「按时间导出录像」(RangeExport) 是异步任务且要求
// 片段录制完成，无法用于实时拖动；故以片段文件 + 本地播放器实现真实回放。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/network/mjpeg_stream.dart';
import '../../core/network/syno_api.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../core/utils/launcher.dart';
import '../../data/models/camera.dart';
import '../../data/models/media.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';

const List<double> _speeds = <double>[0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0];

/// 回放画面所处阶段。旧实现只有 _error/_loading 两个布尔量，把「录像文件
/// 下载中」「回放流已建立但尚未收到首帧」这两个中间态也当成失败渲染出错误
/// 视图，于是画面出现前会闪过一段错误提示。现在中间态一律显示中性加载态，
/// 只有两条路径都确定失败（failed）才展示错误。
enum _PlaybackPhase { loading, video, streamPending, streamLive, failed }

class PlaybackPage extends StatefulWidget {
  const PlaybackPage({
    super.key,
    required this.recording,
    required this.camera,
  });

  final Recording recording;
  final Camera camera;

  @override
  State<PlaybackPage> createState() => _PlaybackPageState();
}

class _PlaybackPageState extends State<PlaybackPage> {
  VideoPlayerController? _controller;
  StreamSubscription<Uint8List>? _frameSub;
  Uint8List? _mjpegFrame;

  late Recording _active;
  late DateTime _dayStart;
  List<Recording> _clips = <Recording>[];

  _PlaybackPhase _phase = _PlaybackPhase.loading;
  bool _videoReady = false;
  bool _playing = false;
  String? _error;
  String _diagnostic = '';
  String _sourceLabel = '';

  double _fraction = 0; // 24 小时时间轴位置
  double _videoFraction = 0; // 片段内播放进度
  double _speed = 1.0;

  Directory? _tempDir;

  @override
  void initState() {
    super.initState();
    _active = widget.recording;
    final d = widget.recording.startTime;
    _dayStart = DateTime(d.year, d.month, d.day);
    _fraction = TimelineMath.fractionOf(widget.recording.startTime, _dayStart);
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
    _frameSub?.cancel();
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
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
      c.removeListener(_onVideoTick);
      await c.dispose();
    }
    _controller = null;
    _mjpegFrame = null;
    _videoReady = false;
    _playing = false;
    _videoFraction = 0;
  }

  Future<void> _load(AppState state) async {
    setState(() {
      _phase = _PlaybackPhase.loading;
      _error = null;
      _diagnostic = '';
      _sourceLabel = '';
    });
    await _clearMedia();

    // 路径 1：下载真实片段 → App 内播放器（可拖动 seek / 倍速）。
    try {
      final rec = await state.downloadRecording(_active);
      final dir = await Directory.systemTemp.createTemp('synocam_pb_');
      final file = File('${dir.path}/clip${rec.extension}');
      await file.writeAsBytes(rec.bytes, flush: true);
      _tempDir = dir;
      final c = VideoPlayerController.file(file);
      await c.initialize();
      c.addListener(_onVideoTick);
      await c.setPlaybackSpeed(_speed);
      await c.play();
      if (mounted) {
        setState(() {
          _controller = c;
          _videoReady = true;
          _playing = true;
          _phase = _PlaybackPhase.video;
          _sourceLabel = 'NAS 录像文件（${rec.source}）· ${rec.contentType}';
        });
      }
      return;
    } catch (e) {
      // 465 / 登录页 HTML：交回登录页重登，不继续尝试同样会 465 的回放流。
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
      // 路径 1 失败先只记诊断，绝不立刻渲染错误视图：后面还有回放流兜底。
      // 这正是「回放视频闪过一段错误提示」的根因。
      _diagnostic = '录像文件回放失败：$e';
    }

    // 路径 2：MJPEG 回放流（部分 SS 版本支持 startTime/endTime）。
    try {
      final from = _active.startTime.millisecondsSinceEpoch ~/ 1000;
      final to = _active.endTime.millisecondsSinceEpoch ~/ 1000;
      final url =
          state.liveStreamUrl(widget.camera, startTime: from, endTime: to);
      final client = MjpegStreamClient(url: url, cookie: state.cookieHeader);
      var gotFirstFrame = false;
      _frameSub = client.frames().listen(
        (Uint8List frame) {
          gotFirstFrame = true;
          if (mounted) {
            setState(() {
              _mjpegFrame = frame;
              _phase = _PlaybackPhase.streamLive;
            });
          }
        },
        onError: (Object e) {
          // 已经出过画面：偶发断帧只记诊断，不弹错误、也不踢回登录页。
          if (gotFirstFrame) {
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
              _phase = _PlaybackPhase.failed;
            });
          }
        },
        cancelOnError: false,
      );
      if (mounted) {
        setState(() {
          _phase = _PlaybackPhase.streamPending;
          _sourceLabel = 'MJPEG 回放流（startTime=$from, endTime=$to）';
        });
      }
      // 首帧宽限期：流已建立但还没帧时保持中性「正在接收画面」，
      // 10 秒仍无帧才判定失败，避免加载阶段闪错误。
      unawaited(Future<void>.delayed(const Duration(seconds: 10)).then((_) {
        if (!mounted || _phase != _PlaybackPhase.streamPending) return;
        if (_mjpegFrame == null) {
          setState(() {
            _error ??= '回放流在 10 秒内未返回画面';
            _phase = _PlaybackPhase.failed;
          });
        }
      }));
      return;
    } catch (e) {
      _diagnostic += '\n回放流启动失败：$e';
    }

    if (mounted) {
      setState(() {
        _phase = _PlaybackPhase.failed;
        _error = '该 NAS 版本未提供可用的 App 内回放接口';
      });
    }
  }

  void _onVideoTick() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final total = c.value.duration.inSeconds;
    if (total <= 0) return;
    final pos = c.value.position.inSeconds;
    if (mounted) {
      setState(() => _videoFraction = (pos / total).clamp(0.0, 1.0).toDouble());
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

  Future<void> _seekVideo(double v) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    await c.seekTo(c.value.duration * v);
    if (mounted) setState(() => _videoFraction = v);
  }

  Future<void> _onScrubEnd(double v) async {
    final t = TimelineMath.timeAt(v, _dayStart);
    final target = TimelineMath.nearestClip(_clips, t);
    if (target == null) return;
    if (target.id != _active.id) {
      setState(() => _active = target);
      await _load(context.read<AppState>());
      return;
    }
    // 同一片段内拖动：直接 seek 到相对位置。
    if (_videoReady) {
      final total = target.durationSeconds > 0 ? target.durationSeconds : 1;
      final offset = t.difference(target.startTime).inSeconds / total;
      await _seekVideo(offset.clamp(0.0, 1.0).toDouble());
    }
  }

  Future<void> _setSpeed(double v) async {
    setState(() => _speed = v);
    await _controller?.setPlaybackSpeed(v);
  }

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
          _controls(),
          const SizedBox(height: 6),
          const _SectionLabel('片段内进度（可拖动）'),
          Slider(
            value: _videoFraction,
            onChanged:
                _videoReady ? (v) => setState(() => _videoFraction = v) : null,
            onChangeEnd: _videoReady ? (v) => _seekVideo(v) : null,
          ),
          const SizedBox(height: 6),
          const _SectionLabel('今日时间轴 · 拖动定位到任意时刻'),
          _timeline(),
          const SizedBox(height: 14),
          const _SectionLabel('当前片段（NAS 真实事件）'),
          _clipInfo(),
          const SizedBox(height: 12),
          if (_sourceLabel.isNotEmpty) _sourceCard(),
          // 加载 / 等待首帧期间不显示诊断卡片，避免真实录像能播时闪过错误提示。
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
            child: _phaseContent(state),
          ),
        ),
      );

  /// 只有 failed 阶段才渲染错误视图；其余阶段一律是画面或中性加载态。
  Widget _phaseContent(AppState state) {
    switch (_phase) {
      case _PlaybackPhase.loading:
        return _busy('正在从 NAS 读取真实录像片段…');
      case _PlaybackPhase.video:
        final c = _controller;
        return c != null ? VideoPlayer(c) : _busy('正在准备播放器…');
      case _PlaybackPhase.streamPending:
      case _PlaybackPhase.streamLive:
        final frame = _mjpegFrame;
        return frame != null
            ? Image.memory(frame, fit: BoxFit.contain)
            : _busy('正在接收回放画面…');
      case _PlaybackPhase.failed:
        return _errorView(state);
    }
    // 枚举已穷举，此分支理论不可达；保留以满足返回值类型检查。
    return _busy('正在准备画面…');
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
            Text(_short('${fv.advice}\n${state.mediaDiagnostic}'),
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

  Widget _controls() {
    final c = _controller;
    final position = c?.value.position ?? Duration.zero;
    final duration = c?.value.duration ?? Duration.zero;
    final totalSeconds = duration.inSeconds > 0 ? duration.inSeconds : 1;
    return Row(
      children: <Widget>[
        IconButton(
          tooltip: _playing ? '暂停' : '播放',
          icon: AppIcon(_playing ? AppIcons.pause : AppIcons.play,
              size: 22, color: _videoReady ? AppColors.blue : AppColors.faint),
          onPressed: _videoReady ? () => _togglePlay() : null,
        ),
        IconButton(
          tooltip: '后退 10 秒',
          icon: const AppIcon(AppIcons.skipBack, size: 20),
          onPressed: _videoReady
              ? () => _seekVideo((_videoFraction - 10 / totalSeconds)
                  .clamp(0.0, 1.0)
                  .toDouble())
              : null,
        ),
        IconButton(
          tooltip: '前进 10 秒',
          icon: const AppIcon(AppIcons.skipFwd, size: 20),
          onPressed: _videoReady
              ? () => _seekVideo((_videoFraction + 10 / totalSeconds)
                  .clamp(0.0, 1.0)
                  .toDouble())
              : null,
        ),
        const SizedBox(width: 4),
        Text('${_mmss(position)} / ${_mmss(duration)}',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
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

  Widget _timeline() => Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text('00:00',
                  style: TextStyle(fontSize: 10, color: AppColors.faint)),
              Text(
                  '拖动定位到 ${TimelineMath.timeLabel(TimelineMath.timeAt(_fraction, _dayStart))}',
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
                final width = (r.durationSeconds / TimelineMath.secondsPerDay)
                    .clamp(0.004, 1.0)
                    .toDouble();
                return Positioned(
                  left: w * left,
                  width: w * width,
                  top: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onTap: () {
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

  Widget _clipInfo() => Card(
        child: Column(
          children: <Widget>[
            _infoRow('事件 ID', _active.id),
            _infoRow('开始时间', TimelineMath.timeLabel(_active.startTime)),
            _infoRow('时长', _active.durationLabel),
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

  /// 今日片段列表：点任意一条切换到该真实录像片段，全程留在 App 内。
  Widget _clipTile(AppState state, Recording r) => Card(
        margin: const EdgeInsets.only(bottom: 7),
        child: ListTile(
          dense: true,
          leading: const AppIcon(AppIcons.play, size: 17),
          title: Text(r.eventType, style: const TextStyle(fontSize: 12.5)),
          subtitle: Text(
              '${TimelineMath.timeLabel(r.startTime)} · ${r.durationLabel}'
              '${r.locked ? ' · 已锁定' : ''}',
              style: TextStyle(fontSize: 10, color: AppColors.faint)),
          trailing: Text(r.id == _active.id ? '当前' : '切换',
              style: TextStyle(fontSize: 10, color: AppColors.faint)),
          onTap: () {
            if (r.id == _active.id) return;
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
            '以上入口均为用户主动操作；App 默认不会把 API 地址直接丢给浏览器。',
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
