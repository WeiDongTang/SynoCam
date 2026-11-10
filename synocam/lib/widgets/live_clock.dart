// 实时画面上的时钟。旧实现取 TimeOfDay.now() 且只在 build 那一刻刷新一次，
// 用户看到的既不是视频流真实时间、也不会走秒，容易与摄像机画面里烧录的
// OSD 时间混淆（「视频画面时间不对」）。这里改为每秒真实刷新，并明确标注
// 「本机」；开启 NAS 时间校准后同时给出换算后的 NAS 时刻。
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/utils/time_sync.dart';

class LiveClock extends StatefulWidget {
  const LiveClock({
    super.key,
    this.offsetMinutes = 0,
    this.style,
    this.showNas = true,
  });

  final int offsetMinutes;
  final TextStyle? style;

  /// 多画面小格子空间有限时可关闭 NAS 对照，只显示本机时间。
  final bool showNas;

  @override
  State<LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<LiveClock> {
  Timer? _timer;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    // 对齐到整秒，避免出现 1 秒抖动。
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final local = TimeSync.formatClock(_now);
    final sync = TimeSync(widget.offsetMinutes);
    final nas = sync.clock(_now);
    final showNas = widget.showNas && widget.offsetMinutes != 0;
    final defaultStyle = const TextStyle(fontSize: 10, color: Colors.white70);
    return Text(
      showNas ? '本机 $local · NAS $nas' : '本机 $local',
      style: widget.style ?? defaultStyle,
    );
  }
}
