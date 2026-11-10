// NAS 时间展示校准（纯 Dart，便于自检）。
//
// Synology Surveillance Station 的 Event/Query 返回 Unix 秒时间戳，App 用
// DateTime.fromMillisecondsSinceEpoch 按手机本地时区解析。若 NAS 系统时区/
// 摄像机 OSD 与手机不一致，列表、时间轴、回放画面上的时刻就会与视频里
// 烧录的时间对不上，表现为「视频画面时间不对」。
//
// 设计边界：校准只作用于【展示层】，不改写 Recording.startTime 本身，
// 因此 Event/Query、Recording/Download、VideoStreaming/Stream 等请求用的
// 仍是 NAS 原始时间戳——已能正常回放的链路不会被校准破坏。
class TimeSync {
  const TimeSync([this.offsetMinutes = 0]);

  /// 展示时间相对 NAS 原始解析时间的偏移（分钟，可为负）。
  final int offsetMinutes;

  DateTime display(DateTime raw) => raw.add(Duration(minutes: offsetMinutes));

  String clock(DateTime raw) => formatClock(display(raw));

  String full(DateTime raw) => formatFull(display(raw));

  String short(DateTime raw) => formatShort(display(raw));

  String get offsetLabel {
    if (offsetMinutes == 0) return '未校准（按 NAS 原始时间戳显示）';
    final sign = offsetMinutes > 0 ? '+' : '-';
    final abs = offsetMinutes.abs();
    final h = abs ~/ 60;
    final m = abs % 60;
    final parts = <String>[
      if (h > 0) '$h 小时',
      if (m > 0) '$m 分钟',
    ];
    return '$sign${parts.join(' ')}';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String formatClock(DateTime t) =>
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  static String formatFull(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${formatClock(t)}';

  static String formatShort(DateTime t) =>
      '${_two(t.month)}-${_two(t.day)} ${formatClock(t)}';

  /// 本机当前时间与校准后的 NAS 时间对照，供设置页展示。
  String compare(DateTime now) =>
      '本机 ${formatClock(now)} · NAS ${formatClock(display(now))}';
}
