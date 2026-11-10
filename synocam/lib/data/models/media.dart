// 录像片段与事件模型。
// 真实数据源为 SYNO.SurveillanceStation.Event / Query 返回的 data.events[]：
// id / cameraId / startTime / stopTime / status / mode / videoCodec ...
// 不再有任何静态演示数据。
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

  String get durationLabel {
    if (recording) return '录制中';
    final m = durationSeconds ~/ 60;
    final s = durationSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String get dateLabel =>
      '${startTime.year} / ${startTime.month.toString().padLeft(2, '0')} / ${startTime.day.toString().padLeft(2, '0')}';

  /// 从 Event/Query 的一条记录解析（字段名跨版本兼容）。
  factory Recording.fromEventJson(Map<String, dynamic> j,
      Map<int, String> cameraNames) {
    final cameraId = _asInt(j['cameraId'] ?? j['camId'] ?? j['cameraid']);
    final start = _asInt(j['startTime'] ?? j['time'] ?? j['timestamp']);
    final stop = _asInt(j['stopTime'] ?? j['endTime'] ?? j['startTime']);
    final status = _asInt(j['status'] ?? j['locked']);
    final mode = _asInt(j['mode'] ?? j['eventType']);
    final startDt = DateTime.fromMillisecondsSinceEpoch(_toMs(start));
    final duration = stop > start ? stop - start : 0;
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
