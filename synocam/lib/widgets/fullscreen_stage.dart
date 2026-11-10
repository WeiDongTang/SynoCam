// 通用全屏画面舞台：所有画面窗口共用同一个全屏入口。
//
// 交互（对齐用户诉求）：
//  - 进入全屏后隐藏状态栏 / 导航栏（沉浸式），画面铺满；右上角常驻退出按钮；
//  - 左右滑动：按位移换算秒数，浮层实时显示「快进 +Ns / 快退 -Ns」，
//    松手执行相对 seek（仅回放可用，实时画面给出明确提示，绝不假装有反应）；
//  - 长按：临时 3x 倍速快进，松开恢复原速；
//  - 双击：播放 / 暂停切换；单击：显示 / 隐藏控制条；
//  - 控制条提供退出、播放/暂停、±10 秒、倍速（回放时）。
//
// 关键约束：复用调用方已初始化的 video_player controller，绝不在这里重新
// 初始化或 dispose（controller 生命周期归原页面 State）。全屏只是把同一个
// 画面 widget 放到沉浸式全屏布局里，退出后原页面继续播放、不黑屏、不重连。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 回放类画面暴露给全屏舞台的控制能力；实时画面传 null。
class FullscreenControls {
  const FullscreenControls({
    required this.seekBy,
    required this.setSpeed,
    required this.togglePlay,
    required this.currentSpeed,
    this.position,
    this.duration,
    this.playing,
  });

  /// 相对当前位置快进（正）/ 快退（负）若干秒。
  final Future<void> Function(int seconds) seekBy;

  /// 设置播放倍速（长按快进用 3x，松开恢复原速）。
  final Future<void> Function(double speed) setSpeed;

  final Future<void> Function() togglePlay;

  /// 取当前倍速（长按结束时据此恢复）。
  final double Function() currentSpeed;

  final ValueListenable<Duration>? position;
  final Duration? duration;
  final ValueListenable<bool>? playing;
}

class FullscreenStage extends StatefulWidget {
  const FullscreenStage({
    super.key,
    required this.video,
    required this.title,
    this.controls,
    this.live = false,
  });

  /// 画面 widget（由调用方用同一个 controller / 组件构建）。
  final Widget video;
  final String title;

  /// 非 null 表示可回放（启用快进快退手势）；null 表示实时画面。
  final FullscreenControls? controls;
  final bool live;

  /// 打开全屏（push 全屏路由）。controller 仍归调用方 State 管理。
  static Future<void> show(
    BuildContext context, {
    required Widget video,
    required String title,
    FullscreenControls? controls,
    bool live = false,
  }) async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => FullscreenStage(
        video: video,
        title: title,
        controls: controls,
        live: live,
      ),
    ));
  }

  @override
  State<FullscreenStage> createState() => _FullscreenStageState();
}

class _FullscreenStageState extends State<FullscreenStage> {
  bool _showControls = true;
  String? _hint;
  double _accumDx = 0;
  double _longPressBaseSpeed = 1.0;
  bool _fastForwarding = false;

  /// 稳定的兜底 notifier：实时画面（无 position）时避免每次 build 都换实例。
  final ValueNotifier<Duration> _zeroPosition =
      ValueNotifier<Duration>(Duration.zero);

  FullscreenControls? get _controls => widget.controls;
  bool get _seekable => widget.controls != null;

  @override
  void initState() {
    super.initState();
    // 沉浸式：隐藏系统栏，让画面真正占满屏幕。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _zeroPosition.dispose();
    // 恢复系统栏（不强制改屏幕方向，尊重用户在系统里的旋转锁定）。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    super.dispose();
  }

  void _exit() => Navigator.of(context).maybePop();

  void _setHint(String? s) {
    if (!mounted) return;
    setState(() => _hint = s);
  }

  // ── 左右滑动：快进 / 快退 ────────────────────────────────────────────
  void _onDragStart(DragStartDetails _) {
    _accumDx = 0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_seekable) {
      _setHint('实时画面不支持快进快退，请在录像回放中使用');
      return;
    }
    _accumDx += d.delta.dx;
    final secs = _secondsFromDx(_accumDx);
    _setHint(secs >= 0 ? '快进 +$secs 秒' : '快退 ${-secs} 秒');
  }

  void _onDragEnd(DragEndDetails _) {
    final secs = _secondsFromDx(_accumDx);
    _accumDx = 0;
    _setHint(null);
    if (!_seekable || secs == 0) return;
    _controls!.seekBy(secs);
  }

  /// 约 12 逻辑像素 = 1 秒，单次封顶 ±120 秒，避免一次滑动跨太大。
  int _secondsFromDx(double dx) {
    final s = (dx / 12).round();
    return s > 120 ? 120 : (s < -120 ? -120 : s);
  }

  // ── 长按：临时倍速快进 ───────────────────────────────────────────────
  void _onLongPressStart(LongPressStartDetails _) {
    if (!_seekable) {
      _setHint('实时画面不支持快进，请在录像回放中使用');
      return;
    }
    _longPressBaseSpeed = _controls!.currentSpeed();
    _controls!.setSpeed(3.0);
    _setHint('3x 快进中 · 松开恢复');
  }

  void _endLongPress() {
    if (!_seekable) {
      _setHint(null);
      return;
    }
    _controls!.setSpeed(_longPressBaseSpeed);
    _setHint(null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 画面：居中铺满，不裁切。
          Positioned.fill(child: Center(child: widget.video)),
          // 手势层：覆盖整个画面区域，但不吞掉上层控制条的点击
          //（控制条是 Stack 更高层的兄弟，命中优先级更高）。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => setState(() => _showControls = !_showControls),
              onDoubleTap: _seekable ? () => _controls!.togglePlay() : null,
              onHorizontalDragStart: _onDragStart,
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              onLongPressStart: _onLongPressStart,
              onLongPressEnd: (LongPressEndDetails _) => _endLongPress(),
              onLongPressCancel: _endLongPress,
            ),
          ),
          // 手势提示浮层
          if (_hint != null)
            Center(
              child: IgnorePointer(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                  decoration: BoxDecoration(
                    color: Colors.black72,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(_hint!,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ),
            ),
          // 右上角常驻退出按钮，保证任何状态都能退出全屏。
          Positioned(
            top: 12,
            right: 12,
            child: SafeArea(
              child: _roundButton(
                icon: Icons.fullscreen_exit,
                tooltip: '退出全屏',
                onTap: _exit,
              ),
            ),
          ),
          // 标题
          Positioned(
            top: 14,
            left: 16,
            child: SafeArea(
              child: IgnorePointer(
                child: Text(widget.title,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70)),
              ),
            ),
          ),
          // 底部控制条
          if (_showControls) _bottomBar(),
        ],
      ),
    );
  }

  Widget _bottomBar() => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: <Color>[Color(0xCC000000), Colors.transparent],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_seekable) _progressRow(),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    if (_seekable) ...<Widget>[
                      _iconButton(Icons.replay_10, '快退 10 秒',
                          () => _controls!.seekBy(-10)),
                      const SizedBox(width: 18),
                      _playButton(),
                      const SizedBox(width: 18),
                      _iconButton(Icons.forward_10, '快进 10 秒',
                          () => _controls!.seekBy(10)),
                      const SizedBox(width: 18),
                      _iconButton(
                        Icons.fast_forward,
                        _fastForwarding ? '恢复 1x' : '3x 快进（也可长按画面）',
                        () {
                          final next = !_fastForwarding;
                          _controls!.setSpeed(next ? 3.0 : 1.0);
                          setState(() => _fastForwarding = next);
                          _setHint(next ? '3x 快进中' : null);
                        },
                      ),
                    ] else
                      const Text('实时画面 · 全屏观看',
                          style:
                              TextStyle(fontSize: 11, color: Colors.white60)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _seekable
                      ? '左右滑动快进快退 · 长按画面 3x 快进 · 双击暂停 · 单击隐藏控制条'
                      : '单击隐藏控制条 · 实时画面不支持快进快退',
                  style: const TextStyle(fontSize: 9.5, color: Colors.white38),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _progressRow() => ValueListenableBuilder<Duration>(
        valueListenable: _controls!.position ?? _zeroPosition,
        builder: (BuildContext context, Duration pos, Widget? _) {
          final total = _controls!.duration ?? Duration.zero;
          final text = '${_mmss(pos)} / ${_mmss(total)}';
          return Text(text,
              style: const TextStyle(fontSize: 11, color: Colors.white70));
        },
      );

  Widget _playButton() => (_controls?.playing != null)
      ? ValueListenableBuilder<bool>(
          valueListenable: _controls!.playing!,
          builder: (BuildContext context, bool playing, Widget? _) =>
              _iconButton(
            playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
            playing ? '暂停' : '播放',
            () => _controls!.togglePlay(),
            size: 34,
          ),
        )
      : _iconButton(Icons.play_pause, '播放 / 暂停', () => _controls!.togglePlay(),
          size: 30);

  Widget _iconButton(IconData icon, String tooltip, VoidCallback onTap,
          {double size = 26}) =>
      IconButton(
        tooltip: tooltip,
        iconSize: size,
        color: Colors.white,
        onPressed: onTap,
        icon: Icon(icon),
      );

  Widget _roundButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) =>
      Material(
        color: Colors.black45,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Tooltip(
              message: tooltip,
              child: Icon(icon, size: 22, color: Colors.white),
            ),
          ),
        ),
      );

  String _mmss(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
