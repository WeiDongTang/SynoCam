// 录像片段与事件模型。
// 真实数据源为 SYNO.SurveillanceStation.Event / Query 返回的 data.events[]：
// id / cameraId / startTime / stopTime / status / mode / videoCodec ...
// 不再有任何静态演示数据。
import 'dart:convert';

class Recording {
  const Recording({
    required this.id,
    required this.cameraId,
    required this.cameraName,
    required this.startTime,
    required this.durationSeconds,
    this.locked = false,
    this.recording = false,
    this.eventType = '连续录制',
    this.codec = '',
  });

  final String id;
  final int cameraId;
  final String cameraName;
  final DateTime startTime;
  final int durationSeconds;
  final bool locked;

  /// 仍在录制中（SS status=1）。
  final bool recording;
  final String eventType;
  final String codec;

  DateTime get endTime => startTime
      .add(Duration(seconds: durationSeconds > 0 ? durationSeconds : 1));

  /// 回放/下载请求使用的时间跨度。SS 常出现「有 startTime 无 stopTime」，
  /// 旧逻辑此时 endTime 只有 1 秒，回放流与下载各自取 1 秒 / 60 秒，
  /// 画面内容与标注时间都对不上。此处统一给两条链路同一段真实跨度。
  int get playbackDurationSeconds => durationSeconds > 0 ? durationSeconds : 60;

  DateTime get playbackEndTime =>
      startTime.add(Duration(seconds: playbackDurationSeconds));

  String get durationLabel {
    if (recording) return '录制中';
    final m = durationSeconds ~/ 60;
    final s = durationSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String get dateLabel =>
      '${startTime.year} / ${startTime.month.toString().padLeft(2, '0')} / ${startTime.day.toString().padLeft(2, '0')}';

  /// 从 Event/Query 的一条记录解析（字段名跨版本兼容）。
  factory Recording.fromEventJson(
      Map<String, dynamic> j, Map<int, String> cameraNames) {
    final cameraId = _asInt(j['cameraId'] ?? j['camId'] ?? j['cameraid']);
    final start = _asInt(j['startTime'] ?? j['time'] ?? j['timestamp']);
    final rawStop = j['stopTime'] ?? j['endTime'] ?? j['stop'] ?? j['end'];
    final stop = rawStop == null ? 0 : _asInt(rawStop);
    final status = _asInt(j['status'] ?? j['locked']);
    final mode = _asInt(j['mode'] ?? j['eventType']);
    final startDt = DateTime.fromMillisecondsSinceEpoch(_toMs(start));
    var duration = stop > start ? stop - start : 0;
    if (duration <= 0) {
      // 部分 SS 版本不返回 stopTime，改用显式时长字段。
      duration = _asInt(j['duration'] ??
          j['length'] ??
          j['durationSeconds'] ??
          j['recordingTime']);
    }
    if (duration <= 0 && status == 1) {
      // 仍在录制中的事件没有结束时间：用「此刻 - 开始」得到真实已录时长，
      // 避免 endTime 退化成 startTime + 1 秒，导致回放流只请求 1 秒画面。
      final elapsed = DateTime.now().difference(startDt).inSeconds;
      if (elapsed > 0) duration = elapsed;
    }
    return Recording(
      id: '${j['id'] ?? j['eventId'] ?? '${cameraId}_$start'}',
      cameraId: cameraId,
      cameraName: cameraNames[cameraId] ?? '摄像机 #$cameraId',
      startTime: startDt,
      durationSeconds: duration,
      locked: status == 2 || _asInt(j['locked']) == 1 || j['locked'] == true,
      recording: status == 1,
      eventType: modeLabel(mode),
      codec: '${j['videoCodec'] ?? j['codec'] ?? ''}',
    );
  }

  static int _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is bool) return v ? 1 : 0;
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static int _toMs(int v) => v > 1e12 ? v : v * 1000;

  /// SS 录制模式：0 连续 / 1 移动侦测 / 2 告警 / 3 手动 / 4 外部。
  static String modeLabel(int mode) {
    const labels = <int, String>{
      0: '连续录制',
      1: '移动侦测',
      2: '告警输入',
      3: '手动录制',
      4: '外部事件',
    };
    return labels[mode] ?? '录制事件';
  }
}

/// 从 NAS 下载到的真实录像文件（供 App 内播放器读取）。
class RecordingFile {
  const RecordingFile({
    required this.bytes,
    required this.extension,
    required this.source,
    this.contentType = '',
  });

  final List<int> bytes;
  final String extension;
  final String source;
  final String contentType;
}

/// 媒体字节识别：按文件头判断真实图片/录像，防止把 DSM 的
/// {"error":{"code":400}}（HTTP 200 但内容是错误 JSON）误当画面或录像片段。
/// 纯 Dart，供 SynoClient 与核心自检（verify_core.dart）共用。
class MediaBytes {
  MediaBytes._();

  /// JPEG（FF D8 FF）或 PNG（89 50 4E 47）。
  static bool isImage(List<int> b) {
    if (b.length < 4) return false;
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;
    return b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
  }

  /// 从文件头推断容器扩展名（App 内播放器需按真实格式建临时文件）。
  static String extensionFor(List<int> b) {
    if (b.length >= 12) {
      final s = latin1.decode(b.sublist(4, 12), allowInvalid: true);
      if (s.startsWith('ftyp')) return '.mp4';
    }
    if (b.length >= 4 && b[0] == 0x1A && b[1] == 0x45) return '.mkv';
    if (b.length >= 4 && b[0] == 0x52 && b[1] == 0x49) return '.avi';
    return '.mp4';
  }

  /// 空响应或以 { 开头的 JSON 错误体不是媒体文件。
  static bool looksLikeJsonError(List<int> b) {
    if (b.isEmpty) return true;
    final head = latin1.decode(b.take(64).toList(), allowInvalid: true).trim();
    return head.startsWith('{');
  }
}

/// 时间轴换算：把 24 小时映射到 [0,1]，并把拖动位置解析为真实时刻/片段。
/// 纯 Dart，便于在无 Flutter SDK 的环境里做协议自检。
class TimelineMath {
  TimelineMath._();

  static const int secondsPerDay = 86400;

  static double fractionOf(DateTime t, DateTime dayStart) {
    final s = t.difference(dayStart).inSeconds;
    return (s / secondsPerDay).clamp(0.0, 1.0).toDouble();
  }

  static DateTime timeAt(double fraction, DateTime dayStart) => dayStart.add(
      Duration(seconds: (fraction.clamp(0.0, 1.0) * secondsPerDay).round()));

  /// 命中某个录像片段（含首尾）。
  /// 用 playbackEndTime 而非 endTime：SS 常缺 stopTime，此时 endTime 只有
  /// startTime + 1 秒，拖动几乎永远命不中片段，只能回退到「最近片段」，
  /// 表现为「回放的不是选中时刻，而是临近时间」。回放本身按 60 秒跨度
  /// 请求，命中判定必须与之用同一跨度。
  static Recording? clipAt(List<Recording> clips, DateTime t) {
    for (final r in clips) {
      if (!t.isBefore(r.startTime) && !t.isAfter(r.playbackEndTime)) return r;
    }
    return null;
  }

  /// 选中时刻在该片段内的相对偏移（秒），供「从选中时刻起播」使用。
  /// 超出片段范围时夹到 [0, playbackDurationSeconds]，避免 seek 越界。
  static int seekSecondsInClip(Recording r, DateTime t) {
    final s = t.difference(r.startTime).inSeconds;
    if (s <= 0) return 0;
    final max = r.playbackDurationSeconds;
    return s > max ? max : s;
  }

  /// 拖动时先尝试命中，未命中则取开始时间最接近的片段。
  static Recording? nearestClip(List<Recording> clips, DateTime t) {
    if (clips.isEmpty) return null;
    final hit = clipAt(clips, t);
    if (hit != null) return hit;
    Recording? best;
    var bestDiff = 1 << 62;
    for (final r in clips) {
      final d = r.startTime.difference(t).inSeconds.abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = r;
      }
    }
    return best;
  }

  static String timeLabel(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  /// 完整日期 + 时刻，避免跨天/时区偏差时只看 HH:mm:ss 产生误解。
  static String dateTimeLabel(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')} ${timeLabel(t)}';
}

class SurveillanceEvent {
  const SurveillanceEvent({
    required this.id,
    required this.title,
    required this.time,
    required this.type,
    this.read = false,
    this.cameraId,
    this.detail = '',
  });

  final String id;
  final String title;
  final DateTime time;

  /// continuous / motion / alarm / manual / external / system
  final String type;
  final bool read;
  final int? cameraId;
  final String detail;

  factory SurveillanceEvent.fromRecording(Recording r) => SurveillanceEvent(
        id: r.id,
        title: '${r.cameraName} · ${r.eventType}',
        time: r.startTime,
        type: _typeOf(r.eventType),
        cameraId: r.cameraId,
        detail: '时长 ${r.durationLabel}${r.locked ? ' · 已锁定' : ''}',
      );

  static String _typeOf(String label) {
    if (label.contains('移动')) return 'motion';
    if (label.contains('告警') || label.contains('门')) return 'alarm';
    if (label.contains('手动')) return 'manual';
    if (label.contains('外部')) return 'external';
    return 'continuous';
  }
}
